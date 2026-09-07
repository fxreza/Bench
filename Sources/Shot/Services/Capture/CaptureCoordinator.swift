import AppKit
import UniformTypeIdentifiers
import BenchCore

/// Entry point for every capture flow (menu bar, hotkeys, debug hooks). Wires the
/// overlay, the editor window, the pin windows and scrolling capture together.
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private var scrollSession: ScrollCaptureSession?

    private init() {
        let overlay = OverlayController.shared
        overlay.onOpenInEditor = { document, result in
            EditorWindowController.open(document: document, title: Self.title(for: result.source))
        }
        overlay.onPermissionMissing = { Self.showPermissions() }
    }

    /// Bench owns the Permissions pane, so a capture that cannot run sends
    /// the user there and asks macOS for Screen Recording.
    static func showPermissions() {
        BenchSettings.open(.permissions)
        PermissionsState.shared.requestScreenRecording()
    }

    /// Drops a scrolling-capture session in progress (the feature is being
    /// switched off).
    func cancelScrollSession() {
        scrollSession?.cancel()
        scrollSession = nil
    }

    /// Runs `shortcut`'s action, saving in the format that shortcut is set to.
    func perform(_ shortcut: CaptureShortcut) {
        perform(shortcut.action, format: SettingsManager.shared.format(for: shortcut))
    }

    func perform(_ action: CaptureAction) {
        perform(CaptureShortcut(action, .main))
    }

    func perform(_ action: CaptureAction, format: CaptureFileFormat) {
        switch action {
        case .area: captureArea(format: format)
        case .window: captureWindow(format: format)
        case .screen: captureScreen(format: format)
        case .scrolling: scrollingCapture(format: format)
        case .text: captureText()
        }
    }

    private var canCapture: Bool {
        // The shared poll is stopped again whenever the Permissions window is
        // closed, so the cached flag can be stale by the time a hotkey fires.
        PermissionsState.shared.refresh()
        guard PermissionsState.shared.screenRecordingGranted else {
            Self.showPermissions()
            return false
        }
        guard !OverlayController.shared.isActive, scrollSession == nil else { return false }
        return true
    }

    func captureArea(format: CaptureFileFormat = .png) {
        guard canCapture else { return }
        Task { await OverlayController.shared.begin(mode: .area, format: format) }
    }

    func captureWindow(format: CaptureFileFormat = .png) {
        guard canCapture else { return }
        Task { await OverlayController.shared.begin(mode: .window, format: format) }
    }

    func captureScreen(format: CaptureFileFormat = .png) {
        guard canCapture else { return }
        Task { await OverlayController.shared.begin(mode: .screen, format: format) }
    }

    func scrollingCapture(format: CaptureFileFormat = .png) {
        guard canCapture else { return }
        Task {
            await OverlayController.shared.selectRegion { [weak self] rect in
                guard let self, let rect else { return }
                let session = ScrollCaptureSession(region: rect)
                session.onFinished = { [weak self] result in
                    self?.scrollSession = nil
                    guard let result else { return }
                    EditorWindowController.open(image: result.image,
                                                pixelScale: result.pixelScale,
                                                title: Self.title(for: .scrolling),
                                                outputFormat: format)
                }
                self.scrollSession = session
                session.present()
            }
        }
    }

    /// Select an area, recognize the text in it, put that text on the
    /// clipboard. No image is written to disk, opened in the editor or put on
    /// the clipboard at any point - the pixels only live long enough for
    /// Vision to read them.
    func captureText() {
        guard canCapture else { return }
        Task {
            await OverlayController.shared.selectTextRegion { image in
                guard let image else { return }
                Task { await Self.recognizeAndCopy(image) }
            }
        }
    }

    private static func recognizeAndCopy(_ image: CGImage) async {
        do {
            let text = try await TextRecognizer.recognize(in: image)
            guard !text.isEmpty else {
                let alert = NSAlert()
                alert.messageText = "No text found"
                alert.informativeText = "Nothing readable was recognized in that selection."
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
                return
            }
            EditorActions.copyText(text)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not read the text"
            alert.informativeText = "\(error)"
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    func openImageFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { openImage(at: $0) }
    }

    func openImage(at url: URL) {
        guard let (image, scale) = ImageExporter.load(url: url) else {
            let alert = NSAlert()
            alert.messageText = "Could not open image"
            alert.informativeText = url.lastPathComponent
            alert.runModal()
            return
        }
        EditorWindowController.open(image: image, pixelScale: scale, title: url.lastPathComponent)
    }

    static func title(for source: CaptureSource) -> String {
        switch source {
        case .area: "Area Capture"
        case .window: "Window Capture"
        case .screen: "Screen Capture"
        case .scrolling: "Scrolling Capture"
        case .file: "Image"
        }
    }
}
