import AppKit
import BenchCore

/// Drives the in-place capture overlay: freezes every display, puts one
/// `OverlayPanel` on each, and hands the finished capture to the app (copy,
/// save, pin, editor).
///
/// The whole flow lives on the frozen bitmaps, so the desktop underneath keeps
/// running while the user drags, annotates and re-frames the selection.
final class OverlayController {

    static let shared = OverlayController()

    enum Mode { case area, window, screen }

    // MARK: wiring (set by the app)

    /// Hand the document to the editor window. The overlay closes first.
    var onOpenInEditor: ((AnnotationDocument, CaptureResult) -> Void)?
    /// Pin the flattened image. `rect` is the global AppKit rect it occupied.
    var onPin: ((CGImage, CGFloat, CGRect) -> Void)?
    /// Screen Recording permission is missing - nothing was shown.
    var onPermissionMissing: (() -> Void)?

    // MARK: state

    private(set) var panels: [OverlayPanel] = []
    private var regionCompletion: ((CGRect?) -> Void)?
    private var textCompletion: ((CGImage?) -> Void)?
    private var isPresenting = false
    private var windowCaptureInFlight = false

    var isActive: Bool { !panels.isEmpty }

    init() {}

    // MARK: - entry points

    /// Freezes all screens and shows the overlay in `mode`. `format` is the
    /// file format the shortcut that started this capture saves as; it rides
    /// along on the document the overlay produces.
    func begin(mode: Mode, format: CaptureFileFormat = .png) async {
        await present(mode: mode, purpose: .capture, format: format)
    }

    /// Region-only picker used by the scrolling capture: dim, crosshair, drag,
    /// handles, size label and a [Cancel] [Start Capture] strip.
    /// `completion` gets the global AppKit rect, or nil when cancelled.
    func selectRegion(completion: @escaping (CGRect?) -> Void) async {
        guard !isActive, !isPresenting else { completion(nil); return }
        regionCompletion = completion
        await present(mode: .area, purpose: .region)
        if !isActive { finishRegion(nil) }   // presentation failed
    }

    /// Region picker for the text grab: same drag as an area capture, but the
    /// overlay closes on mouse-up and hands back the cropped pixels instead of
    /// opening an editor. `completion` gets nil when cancelled.
    func selectTextRegion(completion: @escaping (CGImage?) -> Void) async {
        guard !isActive, !isPresenting else { completion(nil); return }
        textCompletion = completion
        await present(mode: .area, purpose: .text)
        if !isActive { finishText(nil) }   // presentation failed
    }

    /// Closes the overlay without producing anything.
    func cancel() {
        let completion = regionCompletion
        let text = textCompletion
        regionCompletion = nil
        textCompletion = nil
        closeAll()
        completion?(nil)
        text?(nil)
    }

    // MARK: - presentation

    private func present(mode: Mode, purpose: OverlayView.Purpose, format: CaptureFileFormat = .png) async {
        guard !isActive, !isPresenting else { return }
        guard ScreenCapturer.shared.hasPermission else {
            onPermissionMissing?()
            return
        }
        isPresenting = true
        defer { isPresenting = false }

        let frozen: [FrozenScreen]
        do {
            frozen = try await ScreenCapturer.shared.freezeAllScreens()
        } catch CaptureError.noPermission {
            onPermissionMissing?()
            return
        } catch {
            NSLog("Shot: could not freeze the screens: \(error)")
            // ScreenCaptureKit reports a revoked/declined permission as -3801 even
            // when CGPreflightScreenCaptureAccess still says yes (e.g. after a rebuild).
            let ns = error as NSError
            if ns.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain", ns.code == -3801 {
                // Snapper latched this into its own PermissionsState
                // (`markScreenRecordingDenied`); BenchCore's has no such
                // override, so the Permissions pane is simply shown - it
                // re-asks macOS, which is what cleared the latch anyway.
                onPermissionMissing?()
            } else {
                let alert = NSAlert()
                alert.messageText = "Could not capture the screen"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
            return
        }
        guard !frozen.isEmpty else { return }

        let windows = purpose == .capture ? WindowEnumerator.onScreenWindows() : []
        let mouse = NSEvent.mouseLocation

        for screen in frozen {
            let panel = OverlayPanel(frozen: screen, controller: self)
            panel.overlayView.prepare(mode: mode,
                                      purpose: purpose,
                                      windows: windows,
                                      screen: Self.screen(for: screen),
                                      outputFormat: format)
            panel.orderFrontRegardless()
            panels.append(panel)
        }

        let key = panels.first { $0.frozen.screenFrame.contains(mouse) } ?? panels.first
        key?.makeKeyAndOrderFront(nil)
        if let key { key.makeFirstResponder(key.overlayView) }
        CaptureCursor.crosshair.set()

        if mode == .screen, purpose == .capture { key?.overlayView.selectWholeScreen() }
    }

    private static func screen(for frozen: FrozenScreen) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == frozen.displayID
        } ?? NSScreen.screens.first { $0.frame == frozen.screenFrame }
    }

    private func closeAll() {
        guard !panels.isEmpty else { return }
        let closing = panels
        panels = []
        for panel in closing { panel.teardown() }
        OverlayTooltip.shared.hide()
        windowCaptureInFlight = false
        NSCursor.arrow.set()
    }

    // MARK: - overlay view callbacks

    /// A selection started on `view`: every other display goes back to idle.
    func overlayViewDidSelect(_ view: OverlayView) {
        for panel in panels where panel.overlayView !== view {
            if panel.overlayView.selection != nil { panel.overlayView.resetToIdle() }
        }
        view.window?.makeKeyAndOrderFront(nil)
    }

    /// Window mode: capture the clicked window and show it as the selection.
    func captureWindow(_ info: WindowInfo, on view: OverlayView) {
        guard !windowCaptureInFlight else { return }
        windowCaptureInFlight = true
        let includeShadow = SettingsManager.shared.includeWindowShadow
        Task { [weak self] in
            defer { self?.windowCaptureInFlight = false }
            do {
                let result = try await ScreenCapturer.shared.captureWindow(info, includeShadow: includeShadow)
                guard let self, self.isActive else { return }
                let host = self.panel(showing: result.screenRect) ?? view
                self.overlayViewDidSelect(host)
                host.showWindowCapture(result)
            } catch {
                NSLog("Shot: window capture failed: \(error)")
            }
        }
    }

    /// The overlay view whose display holds the centre of `rect`.
    private func panel(showing rect: CGRect?) -> OverlayView? {
        guard let rect else { return nil }
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        return panels.first { $0.frozen.screenFrame.contains(centre) }?.overlayView
    }

    /// Completes `selectTextRegion` and closes the overlay.
    func finishText(_ image: CGImage?) {
        let completion = textCompletion
        textCompletion = nil
        closeAll()
        completion?(image)
    }

    /// Completes `selectRegion` and closes the overlay.
    func finishRegion(_ rect: CGRect?) {
        let completion = regionCompletion
        regionCompletion = nil
        closeAll()
        completion?(rect)
    }

    // MARK: - actions

    /// Runs one action of the vertical strip (also the ⌘ shortcuts).
    func perform(_ action: OverlayAction, from view: OverlayView) {
        switch action {
        case .close:
            view.escapePressed()
            return
        default:
            break
        }
        guard let document = view.document else { return }
        let panel = view.window
        switch action {
        case .close:
            break
        case .copy:
            EditorActions.copy(document)
            cancel()
        case .save:
            EditorActions.save(document)
            cancel()
        case .saveAs:
            // The panel must stay up for the sheet; close only once it saved.
            EditorActions.saveAs(document, for: panel) { [weak self] url in
                if url != nil { self?.cancel() }
            }
        case .move:
            break
        case .editor:
            let result = view.captureResult ?? CaptureResult(image: document.image,
                                                             pixelScale: document.pixelScale,
                                                             source: .area,
                                                             screenRect: view.globalSelectionRect)
            let open = onOpenInEditor
            cancel()
            open?(document, result)
        }
    }
}
