import AppKit
import SwiftUI
import BenchCore

// MARK: - Small controls

/// Flat icon button used across the editor toolbar and the pin overlay.
/// Draws its own background so a selected tool can use the accent color.
@MainActor
final class ToolbarIconButton: NSView {

    var onClick: (() -> Void)?
    var isOn = false { didSet { if isOn != oldValue { updateTint(); needsDisplay = true } } }
    var isDisabledLooking = false {
        didSet { if isDisabledLooking != oldValue { updateTint(); needsDisplay = true } }
    }
    var accent: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    /// Draws the background as a circle (used by pin overlay buttons).
    var isCircular = false { didSet { needsDisplay = true } }
    /// Fill drawn even when the button is off and not hovered.
    var restingBackground: NSColor? { didSet { needsDisplay = true } }

    private let imageView = NSImageView()
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var pressed = false { didSet { if pressed != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    init(symbolName: String, fallback: String, tooltip: String, size: CGSize = CGSize(width: 28, height: 26)) {
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = tooltip

        imageView.image = Self.symbol(symbolName, fallback: fallback)
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.width),
            heightAnchor.constraint(equalToConstant: size.height),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateTint()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// SF Symbol with a graceful fallback when the name is unavailable.
    static func symbol(_ name: String, fallback: String, pointSize: CGFloat = 13, weight: NSFont.Weight = .medium) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            return image.withSymbolConfiguration(config)
        }
        if let image = NSImage(systemSymbolName: fallback, accessibilityDescription: nil) {
            return image.withSymbolConfiguration(config)
        }
        return nil
    }

    private func updateTint() {
        imageView.contentTintColor = isOn ? .white : (isDisabledLooking ? .tertiaryLabelColor : .labelColor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false; pressed = false }

    override func mouseDown(with event: NSEvent) {
        guard !isDisabledLooking else { return }
        pressed = true
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        guard !isDisabledLooking, inside else { return }
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius: CGFloat = isCircular ? rect.height / 2 : 6
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        if isOn {
            (pressed ? accent.blended(withFraction: 0.2, of: .black) ?? accent : accent).setFill()
            path.fill()
        } else if let resting = restingBackground, !hovered {
            resting.setFill()
            path.fill()
        } else if hovered && !isDisabledLooking {
            NSColor.secondaryLabelColor.withAlphaComponent(pressed ? 0.24 : 0.14).setFill()
            path.fill()
        }
    }
}

/// Vertical hairline between toolbar groups.
@MainActor
final class ToolbarSeparatorView: NSView {
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 1, height: 20))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 1),
            heightAnchor.constraint(equalToConstant: 20),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        bounds.fill()
    }
}

/// The ⠿ handle: press and drag to drag the flattened image out to Finder,
/// Mail, Slack… as a real PNG file.
@MainActor
final class DragHandleView: NSView, NSDraggingSource {

    /// Supplies the image to drag (flattened) and its pixel scale.
    var imageProvider: (() -> (CGImage, CGFloat)?)?
    /// Supplies the app the image was captured from, if known.
    var sourceAppNameProvider: (() -> String?)?

    private var mouseDownPoint: NSPoint?
    private var hovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    init(size: CGSize = CGSize(width: 22, height: 26)) {
        super.init(frame: NSRect(origin: .zero, size: size))
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = "Drag the image out"
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.width),
            heightAnchor.constraint(equalToConstant: size.height),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) { mouseDownPoint = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let dx = event.locationInWindow.x - start.x
        let dy = event.locationInWindow.y - start.y
        guard hypot(dx, dy) > 3 else { return }
        mouseDownPoint = nil
        beginDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) { mouseDownPoint = nil }

    private func beginDrag(with event: NSEvent) {
        guard let (image, scale) = imageProvider?() else { return }
        let sourceAppName = sourceAppNameProvider?()
        guard let url = try? ImageExporter.writeDragTempFile(image,
                                                             pixelScale: scale,
                                                             sourceAppName: sourceAppName) else { return }

        let pointSize = NSSize(width: CGFloat(image.width) / max(1, scale), height: CGFloat(image.height) / max(1, scale))
        let preview = NSImage(cgImage: image, size: pointSize)
        let maxSide: CGFloat = 180
        let factor = min(1, min(maxSide / max(pointSize.width, 1), maxSide / max(pointSize.height, 1)))
        let previewSize = NSSize(width: max(16, pointSize.width * factor), height: max(16, pointSize.height * factor))

        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let origin = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: origin.x - previewSize.width / 2,
                                     y: origin.y - previewSize.height / 2,
                                     width: previewSize.width, height: previewSize.height),
                              contents: preview)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    nonisolated func draggingSession(_ session: NSDraggingSession,
                                     sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy] : []
    }

    override func draw(_ dirtyRect: NSRect) {
        let color = NSColor.secondaryLabelColor.withAlphaComponent(hovered ? 0.95 : 0.6)
        color.setFill()
        let dot: CGFloat = 2.5
        let gapX: CGFloat = 5, gapY: CGFloat = 5
        let totalW = dot + gapX
        let totalH = dot * 3 + gapY * 2
        let startX = (bounds.width - totalW) / 2
        let startY = (bounds.height - totalH) / 2
        for column in 0..<2 {
            for row in 0..<3 {
                let rect = NSRect(x: startX + CGFloat(column) * gapX,
                                  y: startY + CGFloat(row) * (dot + gapY),
                                  width: dot, height: dot)
                NSBezierPath(ovalIn: rect).fill()
            }
        }
    }
}

/// Right-hand readout: a value line plus a small caption, clickable.
@MainActor
final class ToolbarValueLabel: NSView {

    var onClick: (() -> Void)?

    private let valueField = NSTextField(labelWithString: "")
    private let captionField = NSTextField(labelWithString: "")
    private var hovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    init(caption: String, alignment: NSTextAlignment = .right) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        valueField.font = .systemFont(ofSize: 12, weight: .semibold)
        valueField.textColor = .labelColor
        valueField.alignment = alignment
        captionField.stringValue = caption
        captionField.font = .systemFont(ofSize: 9, weight: .regular)
        captionField.textColor = .secondaryLabelColor
        captionField.alignment = alignment

        let stack = NSStackView(views: [valueField, captionField])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = alignment == .right ? .trailing : .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var value: String {
        get { valueField.stringValue }
        set { valueField.stringValue = newValue }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        NSColor.secondaryLabelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 2), xRadius: 6, yRadius: 6).fill()
    }
}

// MARK: - Toolbar

@MainActor
protocol EditorToolbarDelegate: AnyObject {
    func toolbarDidTapCopy(_ toolbar: EditorToolbarView)
    func toolbarDidTapSave(_ toolbar: EditorToolbarView)
    func toolbarDidTapSaveAs(_ toolbar: EditorToolbarView)
    func toolbarDidSelectTool(_ toolbar: EditorToolbarView, tool: EditorTool)
    func toolbarDidTapUndo(_ toolbar: EditorToolbarView)
    func toolbarDidTapRedo(_ toolbar: EditorToolbarView)
    func toolbarDidTapApplyCrop(_ toolbar: EditorToolbarView)
    func toolbarDidTapCancelCrop(_ toolbar: EditorToolbarView)
    func toolbarDidTapDimensions(_ toolbar: EditorToolbarView)
    /// `nil` means "fit".
    func toolbarDidSelectZoom(_ toolbar: EditorToolbarView, zoom: CGFloat?)
    /// The flattened image + pixel scale for the ⠿ drag handle.
    func toolbarDragImage(_ toolbar: EditorToolbarView) -> (CGImage, CGFloat)?
    /// The app the dragged image was captured from, for the temp file's name
    /// and its "Where from" metadata. nil credits nothing.
    func toolbarDragSourceAppName(_ toolbar: EditorToolbarView) -> String?
}

/// The 44pt strip at the top of the editor window. A plain `NSView`, not an
/// `NSToolbar`, so the layout can match Shottr's: actions, drag handle, tools,
/// undo/redo, then image size and zoom readouts on the right.
@MainActor
final class EditorToolbarView: NSView {

    static let height: CGFloat = 44

    weak var delegate: EditorToolbarDelegate?

    private var toolButtons: [EditorTool: ToolbarIconButton] = [:]
    private let copyButton: ToolbarIconButton
    private let saveButton: ToolbarIconButton
    private let saveAsButton: ToolbarIconButton
    private let dragHandle = DragHandleView()
    private let undoButton: ToolbarIconButton
    private let redoButton: ToolbarIconButton
    private let cropApplyButton = NSButton(title: "Apply Crop", target: nil, action: nil)
    private let cropCancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let cropGroup = NSStackView()
    private let dimensionLabel = ToolbarValueLabel(caption: "Image size")
    private let zoomLabel = ToolbarValueLabel(caption: "Zoom")
    private let leftStack = NSStackView()

    init() {
        copyButton = ToolbarIconButton(symbolName: "doc.on.doc", fallback: "doc", tooltip: "Copy (⌘C)")
        saveButton = ToolbarIconButton(symbolName: "square.and.arrow.down", fallback: "arrow.down", tooltip: "Save (⌘S)")
        saveAsButton = ToolbarIconButton(symbolName: "square.and.arrow.down.on.square", fallback: "arrow.down", tooltip: "Save As… (⇧⌘S)")
        undoButton = ToolbarIconButton(symbolName: "arrow.uturn.backward", fallback: "arrow.left", tooltip: "Undo (⌘Z)")
        redoButton = ToolbarIconButton(symbolName: "arrow.uturn.forward", fallback: "arrow.right", tooltip: "Redo (⇧⌘Z)")
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: Self.height))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        build()
        applyAccent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: build

    private func build() {
        copyButton.onClick = { [weak self] in guard let self else { return }; self.delegate?.toolbarDidTapCopy(self) }
        saveButton.onClick = { [weak self] in guard let self else { return }; self.delegate?.toolbarDidTapSave(self) }
        saveAsButton.onClick = { [weak self] in guard let self else { return }; self.delegate?.toolbarDidTapSaveAs(self) }
        undoButton.onClick = { [weak self] in guard let self else { return }; self.delegate?.toolbarDidTapUndo(self) }
        redoButton.onClick = { [weak self] in guard let self else { return }; self.delegate?.toolbarDidTapRedo(self) }
        dragHandle.imageProvider = { [weak self] in self.flatMap { $0.delegate?.toolbarDragImage($0) } }
        dragHandle.sourceAppNameProvider = { [weak self] in self.flatMap { $0.delegate?.toolbarDragSourceAppName($0) } }

        leftStack.orientation = .horizontal
        leftStack.alignment = .centerY
        leftStack.spacing = 3
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        leftStack.setViews([copyButton, saveButton, saveAsButton, dragHandle, ToolbarSeparatorView()], in: .leading)

        for tool in EditorTool.allCases {
            let button = ToolbarIconButton(symbolName: tool.symbolName, fallback: "square", tooltip: tool.tooltip)
            button.onClick = { [weak self] in
                guard let self else { return }
                self.delegate?.toolbarDidSelectTool(self, tool: tool)
            }
            toolButtons[tool] = button
            leftStack.addView(button, in: .leading)
        }

        leftStack.addView(ToolbarSeparatorView(), in: .leading)
        leftStack.addView(undoButton, in: .leading)
        leftStack.addView(redoButton, in: .leading)

        // Crop confirmation pair, hidden unless the crop tool is active.
        for button in [cropCancelButton, cropApplyButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.translatesAutoresizingMaskIntoConstraints = false
        }
        cropApplyButton.keyEquivalent = "\r"
        cropApplyButton.target = self
        cropApplyButton.action = #selector(applyCropClicked)
        cropCancelButton.target = self
        cropCancelButton.action = #selector(cancelCropClicked)
        cropGroup.orientation = .horizontal
        cropGroup.spacing = 6
        cropGroup.translatesAutoresizingMaskIntoConstraints = false
        cropGroup.setViews([cropCancelButton, cropApplyButton], in: .leading)
        cropGroup.isHidden = true
        leftStack.addView(cropGroup, in: .leading)

        // Left group clips instead of pushing the readouts off the window.
        let leftContainer = NSView()
        leftContainer.translatesAutoresizingMaskIntoConstraints = false
        leftContainer.clipsToBounds = true
        leftContainer.addSubview(leftStack)

        dimensionLabel.onClick = { [weak self] in guard let self else { return }; self.delegate?.toolbarDidTapDimensions(self) }
        zoomLabel.onClick = { [weak self] in self?.showZoomMenu() }

        let rightStack = NSStackView(views: [dimensionLabel, zoomLabel])
        rightStack.orientation = .horizontal
        rightStack.alignment = .centerY
        rightStack.spacing = 10
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        rightStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        rightStack.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(leftContainer)
        addSubview(rightStack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),

            leftContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            leftContainer.topAnchor.constraint(equalTo: topAnchor),
            leftContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            leftContainer.trailingAnchor.constraint(lessThanOrEqualTo: rightStack.leadingAnchor, constant: -12),

            leftStack.leadingAnchor.constraint(equalTo: leftContainer.leadingAnchor),
            leftStack.centerYAnchor.constraint(equalTo: leftContainer.centerYAnchor),

            rightStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rightStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        let width = leftContainer.widthAnchor.constraint(equalTo: leftStack.widthAnchor)
        width.priority = .defaultLow
        width.isActive = true
    }

    @objc private func applyCropClicked() { delegate?.toolbarDidTapApplyCrop(self) }
    @objc private func cancelCropClicked() { delegate?.toolbarDidTapCancelCrop(self) }

    // MARK: state

    var selectedTool: EditorTool = .select {
        didSet {
            for (tool, button) in toolButtons { button.isOn = (tool == selectedTool) }
        }
    }

    func setUndoEnabled(_ undo: Bool, redoEnabled redo: Bool) {
        undoButton.isDisabledLooking = !undo
        redoButton.isDisabledLooking = !redo
    }

    var dimensionText: String {
        get { dimensionLabel.value }
        set { dimensionLabel.value = newValue }
    }

    var zoomText: String {
        get { zoomLabel.value }
        set { zoomLabel.value = newValue }
    }

    /// Shows/hides the inline [Cancel] [Apply Crop] pair.
    var isCropping: Bool = false {
        didSet { cropGroup.isHidden = !isCropping }
    }

    func applyAccent() {
        let accent = Theme.accentNSColor
        for button in toolButtons.values { button.accent = accent }
        needsDisplay = true
    }

    private func showZoomMenu() {
        let menu = NSMenu()
        for value in [0.25, 0.5, 1.0, 2.0, 4.0] as [CGFloat] {
            let item = NSMenuItem(title: "\(Int(value * 100))%", action: #selector(zoomMenuPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: Double(value))
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let fit = NSMenuItem(title: "Fit", action: #selector(zoomMenuPicked(_:)), keyEquivalent: "")
        fit.target = self
        menu.addItem(fit)
        let origin = NSPoint(x: 0, y: zoomLabel.bounds.height)
        menu.popUp(positioning: nil, at: origin, in: zoomLabel)
    }

    @objc private func zoomMenuPicked(_ sender: NSMenuItem) {
        let value = (sender.representedObject as? NSNumber).map { CGFloat($0.doubleValue) }
        delegate?.toolbarDidSelectZoom(self, zoom: value)
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAccent()
        needsDisplay = true
    }
}
