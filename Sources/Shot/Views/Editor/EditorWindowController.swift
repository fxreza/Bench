import AppKit
import SwiftUI
import UniformTypeIdentifiers
import BenchCore

/// Content view of the editor window: the drop target, and the place where
/// window-level key equivalents are intercepted (the app has no main menu, so
/// ⌘C/⌘S/⌘Z… have to be caught here).
@MainActor
final class EditorContentView: NSView {

    weak var controller: EditorWindowController?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if controller?.handleKeyEquivalent(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if controller?.handleKey(event) == true { return }
        super.keyDown(with: event)
    }

    // MARK: drop target

    private func imageOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.canAcceptDrop(sender) == true ? .copy : []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { imageOperation(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { imageOperation(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        controller?.acceptDrop(sender) ?? false
    }
}

/// Shottr-style editor window: a 44pt custom toolbar over a magnifiable,
/// checkerboard-backed canvas, with the floating properties capsule pinned to
/// the top-right. Every capture that is not annotated in place on the overlay
/// (scrolling capture, clipboard, opened files, "Open in editor") lands here.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate,
                                    AnnotationCanvasDelegate, EditorToolbarDelegate {

    /// Every open editor window, so the app can enumerate or close them.
    static private(set) var openControllers: [EditorWindowController] = []

    /// The edited document. Named `annotationDocument` because `NSWindowController.document`
    /// already exists (it is `NSDocument`-typed and unused here).
    let annotationDocument: AnnotationDocument
    let canvas: AnnotationCanvasView
    private let container: EditorCanvasContainer
    private let toolbar = EditorToolbarView()
    private let panelModel = PropertiesPanelModel()
    private let panelHost: PropertiesPanelHost
    private let settings = SettingsManager.shared

    private var forceClose = false
    private var saveFeedbackTask: Task<Void, Never>?
    private var appearanceObserver: NSObjectProtocol?
    /// Last known image size, so only a crop (not every annotation edit) recenters.
    private var lastDocumentSize: CGSize = .zero

    // MARK: - Opening

    @discardableResult
    static func open(document: AnnotationDocument, title: String) -> EditorWindowController {
        let controller = EditorWindowController(document: document, title: title)
        openControllers.append(controller)
        controller.present()
        return controller
    }

    @discardableResult
    static func open(image: CGImage,
                     pixelScale: CGFloat,
                     title: String,
                     outputFormat: CaptureFileFormat? = nil) -> EditorWindowController {
        open(document: AnnotationDocument(image: image, pixelScale: pixelScale, outputFormat: outputFormat), title: title)
    }

    /// Opens an image file in a new editor window. Returns nil if it cannot be decoded.
    @discardableResult
    static func open(url: URL) -> EditorWindowController? {
        guard let (image, scale) = ImageExporter.load(url: url) else { return nil }
        return open(image: image, pixelScale: scale, title: url.lastPathComponent)
    }

    static func closeAll() {
        for controller in openControllers { controller.forceClose = true; controller.window?.close() }
    }

    // MARK: - Init

    private init(document: AnnotationDocument, title: String) {
        self.annotationDocument = document
        canvas = AnnotationCanvasView(document: document)
        container = EditorCanvasContainer(canvas: canvas)
        panelHost = PropertiesPanelHost(model: panelModel)

        let contentSize = Self.initialContentSize(for: document.size)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: contentSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 360)
        window.title = title
        window.titlebarAppearsTransparent = false
        window.tabbingMode = .disallowed
        super.init(window: window)

        window.delegate = self
        window.contentView = makeContentView()
        window.appearance = AppearanceSettings.shared.colorScheme.nsAppearance
        window.center()

        canvas.delegate = self
        canvas.style = settings.toolStyle
        canvas.accentColor = accentColor
        canvas.tool = .select

        toolbar.delegate = self
        toolbar.selectedTool = .select
        toolbar.dimensionText = EditorActions.dimensionString(pointSize: annotationDocument.size, pixelScale: annotationDocument.pixelScale)
        toolbar.zoomText = "100%"

        panelModel.canvas = canvas
        panelModel.onStyleChanged = { [weak self] style in
            self?.settings.toolStyle = style
        }
        panelModel.refresh()

        container.onZoomChange = { [weak self] zoom in self?.zoomDidChange(zoom) }

        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .benchAppearanceChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyAppearance() }
            }

        lastDocumentSize = document.size
        updateChrome()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makeContentView() -> NSView {
        let content = EditorContentView()
        content.controller = self
        content.registerForDraggedTypes([.fileURL, .png, .tiff])

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(container)
        content.addSubview(toolbar)
        content.addSubview(panelHost.view)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            container.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            panelHost.view.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10),
            panelHost.view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
        ])
        return content
    }

    /// Image point size plus toolbar, clamped to 85% of the screen and the min size.
    private static func initialContentSize(for imageSize: CGSize) -> CGSize {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let maxWidth = min(visible.width, visible.width * 0.85)
        let maxHeight = min(visible.height, visible.height * 0.85)
        var width = min(max(imageSize.width, 480), maxWidth)
        var height = min(max(imageSize.height + EditorToolbarView.height, 360), maxHeight)
        width = max(320, width)
        height = max(240, height)
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    private func present() {
        window?.layoutIfNeeded()
        container.applyInitialZoom()
        NSApp.activate()
        showWindow(nil)
        window?.makeFirstResponder(canvas)
        updateChrome()
    }

    // MARK: - Appearance

    private var accentColor: NSColor { Theme.accentNSColor }

    private func applyAppearance() {
        window?.appearance = AppearanceSettings.shared.colorScheme.nsAppearance
        canvas.accentColor = accentColor
        toolbar.applyAccent()
        container.needsDisplay = true
    }

    // MARK: - Chrome updates

    private func updateChrome() {
        toolbar.dimensionText = EditorActions.dimensionString(pointSize: annotationDocument.size, pixelScale: annotationDocument.pixelScale)
        toolbar.setUndoEnabled(annotationDocument.canUndo, redoEnabled: annotationDocument.canRedo)
        toolbar.isCropping = canvas.tool == .crop
        toolbar.selectedTool = canvas.tool
        panelHost.view.isHidden = !panelModel.isVisible
    }

    private func zoomDidChange(_ zoom: CGFloat) {
        toolbar.zoomText = "\(Int((zoom * 100).rounded()))%"
    }

    /// Switches the active tool and keeps toolbar, panel and defaults in sync.
    func setTool(_ tool: EditorTool) {
        canvas.tool = tool
        settings.lastTool = tool
        panelModel.refresh()
        updateChrome()
        window?.makeFirstResponder(canvas)
    }

    // MARK: - Actions

    func copyImage() { EditorActions.copy(annotationDocument) }

    func saveImage() {
        guard let url = EditorActions.save(annotationDocument) else { return }
        showSavedFeedback(folder: url.deletingLastPathComponent().lastPathComponent)
    }

    func saveImageAs() {
        EditorActions.saveAs(annotationDocument, for: window) { [weak self] url in
            guard let self, let url else { return }
            self.showSavedFeedback(folder: url.deletingLastPathComponent().lastPathComponent)
        }
    }


    private func showSavedFeedback(folder: String) {
        window?.subtitle = "Saved to \(folder)"
        saveFeedbackTask?.cancel()
        saveFeedbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.window?.subtitle = ""
        }
    }

    /// ⌘V: an image on the clipboard opens in its own editor window.
    @discardableResult
    func pasteAsNewEditor() -> Bool {
        guard let (image, scale) = ImageExporter.imageFromPasteboard() else { return false }
        Self.open(image: image, pixelScale: scale, title: "Clipboard")
        return true
    }

    func closeWithConfirmation() {
        guard let window else { return }
        if window.delegate?.windowShouldClose?(window) ?? true { window.close() }
    }

    // MARK: - Zoom

    func zoomIn() { container.zoomIn() }
    func zoomOut() { container.zoomOut() }
    func zoomToActualSize() { container.zoomToActualSize() }
    func zoomToFit() { container.zoomToFit() }

    // MARK: - Keyboard

    /// ⌘-shortcuts, delivered before the first responder sees the key.
    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.contains(.command), !mods.contains(.control), !mods.contains(.option) else { return false }
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()
        let shift = mods.contains(.shift)

        // While a text label is being edited the standard editing commands win;
        // there is no main menu to route them, so send them down the chain here.
        if canvas.isEditingText {
            switch key {
            case "c": return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
            case "x": return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
            case "v": return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
            case "a": return NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: self)
            case "z":
                if shift { window?.undoManager?.redo() } else { window?.undoManager?.undo() }
                return true
            default: break
            }
        }

        switch key {
        case "c": copyImage()
        case "s": if shift { saveImageAs() } else { saveImage() }
        case "v": return pasteAsNewEditor()
        case "w": closeWithConfirmation()
        case "z": if shift { canvas.redo() } else { canvas.undo() }
        case "+", "=": zoomIn()
        case "-": zoomOut()
        case "0": zoomToActualSize()
        case "1": zoomToFit()
        default: return false
        }
        return true
    }

    /// Plain keys the canvas did not consume (tool letters, Escape).
    func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !mods.contains(.command) else { return false }

        if event.keyCode == 53 {   // esc
            if canvas.isCropping { canvas.cancelCrop(); updateChrome(); return true }
            closeWithConfirmation()
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76 {  // return
            if canvas.isCropping { canvas.applyCrop(); updateChrome(); return true }
            return false
        }
        guard !mods.contains(.option), !mods.contains(.control) else { return false }
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()
        if let tool = EditorTool.tool(forKey: key) {
            setTool(tool)
            return true
        }
        return false
    }

    /// Reachable through the responder chain even without an Edit menu.
    @objc func undo(_ sender: Any?) { canvas.undo() }
    @objc func redo(_ sender: Any?) { canvas.redo() }

    // MARK: - Drops

    func canAcceptDrop(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if pb.data(forType: .png) != nil || pb.data(forType: .tiff) != nil { return true }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        return pb.canReadObject(forClasses: [NSURL.self], options: options)
    }

    @discardableResult
    func acceptDrop(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            var opened = false
            for url in urls where Self.open(url: url) != nil { opened = true }
            if opened { return true }
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pb.data(forType: type), let (image, scale) = ImageExporter.decode(data: data) {
                Self.open(image: image, pixelScale: scale, title: "Dropped Image")
                return true
            }
        }
        return false
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if forceClose || !annotationDocument.isDirty { return true }
        EditorActions.confirmDiscard(for: sender) { [weak self] discard in
            guard let self, discard else { return }
            self.forceClose = true
            self.window?.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        saveFeedbackTask?.cancel()
        if let appearanceObserver {
            NotificationCenter.default.removeObserver(appearanceObserver)
            self.appearanceObserver = nil
        }
        canvas.delegate = nil
        panelModel.canvas = nil
        Self.openControllers.removeAll { $0 === self }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window, !canvas.isEditingText, !(window.firstResponder is NSText) else { return }
        window.makeFirstResponder(canvas)
    }

    // MARK: - AnnotationCanvasDelegate

    func canvasSelectionDidChange(_ canvas: AnnotationCanvasView) {
        panelModel.refresh()
        updateChrome()
    }

    func canvasDocumentDidChange(_ canvas: AnnotationCanvasView) {
        let size = annotationDocument.size
        if size != lastDocumentSize {
            lastDocumentSize = size
            container.recenter()
        }
        updateChrome()
    }

    func canvasDidPlaceAnnotation(_ canvas: AnnotationCanvasView, tool: EditorTool) {
        if !settings.keepToolActive { setTool(.select) } else { updateChrome() }
        panelModel.refresh()
    }

    func canvasCropStateDidChange(_ canvas: AnnotationCanvasView) {
        updateChrome()
    }

    func canvas(_ canvas: AnnotationCanvasView, didReceiveUnhandledKey event: NSEvent) -> Bool {
        handleKey(event)
    }

    // MARK: - EditorToolbarDelegate

    func toolbarDidTapCopy(_ toolbar: EditorToolbarView) { copyImage() }
    func toolbarDidTapSave(_ toolbar: EditorToolbarView) { saveImage() }
    func toolbarDidTapSaveAs(_ toolbar: EditorToolbarView) { saveImageAs() }
    func toolbarDidSelectTool(_ toolbar: EditorToolbarView, tool: EditorTool) { setTool(tool) }
    func toolbarDidTapUndo(_ toolbar: EditorToolbarView) { canvas.undo() }
    func toolbarDidTapRedo(_ toolbar: EditorToolbarView) { canvas.redo() }

    func toolbarDidTapApplyCrop(_ toolbar: EditorToolbarView) {
        canvas.applyCrop()
        updateChrome()
        container.recenter()
    }

    func toolbarDidTapCancelCrop(_ toolbar: EditorToolbarView) {
        canvas.cancelCrop()
        updateChrome()
    }

    func toolbarDidTapDimensions(_ toolbar: EditorToolbarView) {
        settings.dimensionsInPixels.toggle()
        updateChrome()
    }

    func toolbarDidSelectZoom(_ toolbar: EditorToolbarView, zoom: CGFloat?) {
        if let zoom { container.setZoom(zoom, animated: true) } else { container.zoomToFit() }
    }

    func toolbarDragImage(_ toolbar: EditorToolbarView) -> (CGImage, CGFloat)? {
        (EditorActions.flattened(annotationDocument), annotationDocument.pixelScale)
    }
}
