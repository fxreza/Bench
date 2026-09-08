import AppKit
import CoreGraphics
import BenchCore

/// One stitched frame's worth of results, produced off the main actor.
private nonisolated struct ScrollFrameOutcome: Sendable {
    var result: StitchResult
    /// Only built when the preview is due for a refresh (see the 10 fps throttle).
    var image: CGImage?
    var coveredHeight: Int
    var frameCount: Int
}

/// A manual scrolling capture over a region the caller has already picked.
///
/// `present()` puts the border + Start/Cancel chrome on screen; nothing is
/// captured until the user presses Start. From then on a main-actor task grabs
/// the region every `frameInterval` and hands each frame to a `ScrollStitcher`
/// on a background task (one append in flight at a time), while the preview
/// panel shows the growing canvas. Done builds a `.scrolling` `CaptureResult`,
/// Cancel (or Done with no frames) reports `nil`.
///
///     let session = ScrollCaptureSession(region: rect)
///     session.onFinished = { result in ... }
///     session.present()
@MainActor
final class ScrollCaptureSession: NSObject {

    /// Target period between frames. `ScreenCapturer` manages roughly 8 fps.
    private static let frameInterval: TimeInterval = 0.08
    /// Minimum spacing between preview bitmap rebuilds (~10 fps).
    private static let previewInterval: TimeInterval = 0.1
    /// How long the "Scroll a little slower" hint stays up.
    private static let hintDuration: TimeInterval = 1.0

    /// Global AppKit rect (points) being captured.
    private let region: CGRect

    /// The app the region sat over when the session started, credited on the
    /// finished capture. Resolved once, up front: by the time the user presses
    /// Done, the frontmost app is our own chrome.
    private let sourceAppName: String?
    private let sourceBundleID: String?

    /// `nil` = the session was cancelled or nothing was ever captured.
    var onFinished: ((CaptureResult?) -> Void)?

    private var panels: ScrollCapturePanels?
    private var stitcher: ScrollStitcher?
    private var loopTask: Task<Void, Never>?

    /// Pixel scale of the first captured frame; the stitched canvas is in those
    /// same pixels, so it is the scale of the result.
    private var pixelScale: CGFloat = 1
    private var lastPreviewAt: Date = .distantPast

    private var presented = false
    private var capturing = false
    private var finishing = false
    private var settled = false

    private var localMonitor: Any?
    private var globalMonitor: Any?

    // MARK: - Lifecycle

    init(region: CGRect, sourceAppName: String? = nil, sourceBundleID: String? = nil) {
        self.region = region.standardized
        self.sourceAppName = sourceAppName
        self.sourceBundleID = sourceBundleID
        super.init()
    }

    /// True from `present()` until the session finishes or is cancelled.
    var isRunning: Bool { presented && !settled }

    /// Shows the border + controls. Capture starts only when the user presses Start.
    func present() {
        guard !presented, !settled else { return }
        guard region.width >= 1, region.height >= 1 else {
            settled = true
            onFinished?(nil)
            return
        }
        presented = true

        let panels = ScrollCapturePanels(region: region)
        panels.onStart = { [weak self] in self?.start() }
        panels.onDone = { [weak self] in self?.requestFinish() }
        defer { start() }
        panels.onCancel = { [weak self] in self?.cancel() }
        self.panels = panels
        panels.show()

        installMonitors()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
    }

    /// Tears everything down and reports `nil`.
    func cancel() {
        guard !settled else { return }
        settled = true
        capturing = false
        loopTask?.cancel()
        loopTask = nil
        teardown()
        onFinished?(nil)
    }

    // MARK: - Capture loop

    private func start() {
        guard isRunning, !capturing, stitcher == nil else { return }
        capturing = true
        panels?.beginCapturing()
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    private func runLoop() async {
        while capturing && !Task.isCancelled {
            let started = Date()
            await captureFrame()
            guard capturing, !Task.isCancelled else { break }
            let remaining = Self.frameInterval - Date().timeIntervalSince(started)
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }
    }

    private func captureFrame() async {
        let excluded = panels?.windowIDs ?? []
        guard let frame = try? await ScreenCapturer.shared.captureRegion(region, excludingWindowIDs: excluded),
              capturing else { return }

        // First frame seeds the stitcher and fixes the pixel scale.
        guard let stitcher else {
            pixelScale = frame.pixelScale
            let fresh = ScrollStitcher(firstFrame: frame.image)
            self.stitcher = fresh
            lastPreviewAt = Date()
            panels?.showFrame(image: fresh.finish(),
                              coveredHeight: fresh.coveredHeight,
                              frameCount: fresh.frameCount)
            return
        }

        // Append (and the preview bitmap build) off the main actor; awaiting the
        // task here is what keeps appends serialized.
        let image = frame.image
        let wantsPreview = Date().timeIntervalSince(lastPreviewAt) >= Self.previewInterval
        let outcome = await Task.detached(priority: .userInitiated) { () -> ScrollFrameOutcome in
            let result = stitcher.append(image)
            var preview: CGImage?
            if wantsPreview, case .aligned = result { preview = stitcher.finish() }
            return ScrollFrameOutcome(result: result,
                                      image: preview,
                                      coveredHeight: stitcher.coveredHeight,
                                      frameCount: stitcher.frameCount)
        }.value

        guard capturing else { return }
        if outcome.image != nil { lastPreviewAt = Date() }

        NSLog("Shot scroll: frame result %@ covered=%d frames=%d", String(describing: outcome.result), outcome.coveredHeight, outcome.frameCount)
        switch outcome.result {
        case .identical:
            break
        case .aligned:
            panels?.showFrame(image: outcome.image,
                              coveredHeight: outcome.coveredHeight,
                              frameCount: outcome.frameCount)
        case .unaligned:
            panels?.flashMessage("Scroll a little slower", duration: Self.hintDuration)
        case .limitReached:
            panels?.setMessage("Limit reached")
            requestFinish()
        }
    }

    // MARK: - Finishing

    private func requestFinish() {
        guard isRunning, !finishing else { return }
        finishing = true
        capturing = false
        Task { [weak self] in await self?.finishCapture() }
    }

    private func finishCapture() async {
        // Let the in-flight append complete before reading the canvas.
        loopTask?.cancel()
        _ = await loopTask?.value
        loopTask = nil

        guard !settled else { return }
        settled = true

        var result: CaptureResult?
        if let stitcher {
            result = CaptureResult(image: stitcher.finish(),
                                   pixelScale: pixelScale,
                                   source: .scrolling,
                                   screenRect: region,
                                   sourceAppName: sourceAppName,
                                   sourceBundleID: sourceBundleID)
        }
        teardown()
        onFinished?(result)
    }

    private func teardown() {
        capturing = false
        removeMonitors()
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
        panels?.close()
        panels = nil
        stitcher = nil
    }

    @objc private func screenParametersChanged() {
        guard isRunning else { return }
        // The region's geometry is no longer trustworthy: keep what was stitched
        // so far, or bail out if nothing was.
        if capturing || stitcher != nil { requestFinish() } else { cancel() }
    }

    // MARK: - Keys

    /// Esc cancels, Return starts (and later finishes). The local monitor covers
    /// our own panels; the global one covers the app the user is scrolling, and
    /// needs Accessibility — without it the buttons still work.
    private func installMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = event.keyCode
            let consumed = MainActor.assumeIsolated {
                self?.handleKey(code, requireKeyWindow: true) ?? false
            }
            return consumed ? nil : event
        }

        guard PermissionsState.shared.accessibilityTrusted else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = event.keyCode
            MainActor.assumeIsolated {
                _ = self?.handleKey(code, requireKeyWindow: false)
            }
        }
    }

    private func removeMonitors() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
    }

    /// Returns true when the key was handled (and should be swallowed).
    private func handleKey(_ keyCode: UInt16, requireKeyWindow: Bool) -> Bool {
        guard isRunning else { return false }
        if requireKeyWindow, panels?.ownsKeyWindow != true { return false }
        switch keyCode {
        case 53:  // Escape
            cancel()
            return true
        case 36, 76:  // Return, keypad Enter
            if capturing { requestFinish() } else { start() }
            return true
        default:
            return false
        }
    }
}
