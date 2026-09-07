import AppKit

// Chrome for the capture overlay: the size pill, the horizontal tool strip and
// the vertical action strip (see the MacShot-style reference). All of them are
// plain AppKit views on a `NSVisualEffectView` backing so they read on top of
// any wallpaper, with a 10pt corner radius and a subtle drop shadow.

/// Rounded material plate with a soft shadow. Subclasses add their controls to
/// `contentView`, which is pinned inside `padding`.
class OverlayChromeView: NSView {
    private var hoverArea: NSTrackingArea?
    private weak var hoverButton: NSButton?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a)
        hoverArea = a
    }

    /// Tooltips and cursor follow the button under the pointer (the app is not
    /// active, so AppKit's own tooltip/cursor-rect machinery does not run).
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        var v: NSView? = hitTest(convert(p, to: superview))
        while let cur = v, !(cur is NSButton), cur !== self { v = cur.superview }
        let button = v as? NSButton
        (button is OverlayMoveButton ? NSCursor.openHand : NSCursor.arrow).set()
        // In the gaps between icons keep the current tooltip; it hides on exit.
        guard let button, button !== hoverButton else { return }
        hoverButton = button
        if let tip = (button as? OverlayButton)?.hint ?? button.toolTip, !tip.isEmpty { OverlayTooltip.shared.show(tip, anchor: button) }
        else { OverlayTooltip.shared.hide() }
    }

    override func mouseEntered(with event: NSEvent) { NSCursor.arrow.set() }
    override func mouseExited(with event: NSEvent) {
        hoverButton = nil
        OverlayTooltip.shared.hide()
    }

    let backdrop = NSVisualEffectView()
    /// Inset of the content from the plate's edges.
    var padding = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)

    static let cornerRadius: CGFloat = 10

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.35)
            s.shadowBlurRadius = 10
            s.shadowOffset = NSSize(width: 0, height: -2)
            return s
        }()

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.material = .hudWindow
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = Self.cornerRadius
        backdrop.layer?.cornerCurve = .continuous
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.borderWidth = 1
        backdrop.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// The overlay places chrome with explicit frames; keep the frame in sync
    /// with the auto-layout content so the two never fight over the size.
    var chromeSize: CGSize {
        let size = fittingSize
        if abs(frame.width - size.width) > 0.5 || abs(frame.height - size.height) > 0.5 {
            setFrameSize(size)
        }
        return size
    }

    /// Pins `view` inside the plate honouring `padding`.
    func pin(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding.left),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding.right),
            view.topAnchor.constraint(equalTo: topAnchor, constant: padding.top),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding.bottom),
        ])
        setFrameSize(fittingSize)
    }
}

/// Square icon button used by both strips. `isOn` paints the accent background
/// (the selected tool in the reference shot).
class OverlayButton: NSButton {

    var accent: NSColor = .controlAccentColor { didSet { refresh() } }
    var isOn: Bool = false { didSet { if isOn != oldValue { refresh() } } }
    private var hovered = false { didSet { if hovered != oldValue { refresh() } } }
    private let handler: () -> Void
    private var area: NSTrackingArea?
    /// Tooltip text drawn by `OverlayTooltip` (native tooltips are delayed and need an active app).
    var hint = ""

    static let side: CGFloat = 28

    init(symbol: String, tooltip: String, accessibility: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: CGRect(x: 0, y: 0, width: Self.side, height: Self.side))
        translatesAutoresizingMaskIntoConstraints = false
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        let description = accessibility ?? tooltip
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
            ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: description)
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        hint = tooltip
        setAccessibilityLabel(description)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        target = self
        action = #selector(fire)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { handler() }

    override var isEnabled: Bool { didSet { refresh() } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { hovered = isEnabled }
    override func mouseExited(with event: NSEvent) { hovered = false }

    private func refresh() {
        let background: NSColor
        if isOn { background = accent }
        else if hovered { background = NSColor.labelColor.withAlphaComponent(0.12) }
        else { background = .clear }
        layer?.backgroundColor = background.cgColor
        let tint: NSColor = isOn ? .white : .labelColor
        contentTintColor = isEnabled ? tint : tint.withAlphaComponent(0.35)
        alphaValue = isEnabled ? 1 : 0.55
    }
}

/// Thin vertical/horizontal rule between button groups.
private func chromeSeparator(vertical: Bool) -> NSView {
    let v = NSView()
    v.translatesAutoresizingMaskIntoConstraints = false
    v.wantsLayer = true
    v.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.22).cgColor
    if vertical {
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 18).isActive = true
    } else {
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        v.widthAnchor.constraint(equalToConstant: 18).isActive = true
    }
    return v
}

// MARK: - Size pill

/// "1657 × 1632 px" pill above the selection. Clicking it toggles px / pt.
final class OverlaySizeLabel: OverlayChromeView {

    var onToggleUnits: (() -> Void)?
    private let field = NSTextField(labelWithString: "")

    override init() {
        super.init()
        padding = NSEdgeInsets(top: 4, left: 9, bottom: 4, right: 9)
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        field.textColor = .labelColor
        field.alignment = .center
        field.toolTip = "Click to switch between pixels and points"
        pin(field)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var text: String {
        get { field.stringValue }
        set {
            guard field.stringValue != newValue else { return }
            field.stringValue = newValue
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    override func mouseDown(with event: NSEvent) { onToggleUnits?() }
}

// MARK: - Tool strip

/// Horizontal strip of drawing tools plus undo / redo.
/// `.crop` is left out: in the overlay the selection itself *is* the crop.
final class OverlayToolStrip: OverlayChromeView {

    static let tools: [EditorTool] = EditorTool.allCases.filter { $0 != .crop }

    var onSelect: ((EditorTool) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?

    var accent: NSColor = .controlAccentColor {
        didSet { buttons.values.forEach { $0.accent = accent } }
    }
    var tool: EditorTool = .select {
        didSet { for (t, b) in buttons { b.isOn = (t == tool) } }
    }

    private var buttons: [EditorTool: OverlayButton] = [:]
    private let undoButton: OverlayButton
    private let redoButton: OverlayButton

    override init() {
        var undoAction: (() -> Void)?
        var redoAction: (() -> Void)?
        undoButton = OverlayButton(symbol: "arrow.uturn.backward", tooltip: "Undo (⌘Z)") { undoAction?() }
        redoButton = OverlayButton(symbol: "arrow.uturn.forward", tooltip: "Redo (⇧⌘Z)") { redoAction?() }
        super.init()
        undoAction = { [weak self] in self?.onUndo?() }
        redoAction = { [weak self] in self?.onRedo?() }

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        for t in Self.tools {
            var pick: (() -> Void)?
            let b = OverlayButton(symbol: t.symbolName, tooltip: t.tooltip, accessibility: t.title) { pick?() }
            pick = { [weak self] in self?.onSelect?(t) }
            buttons[t] = b
            stack.addArrangedSubview(b)
        }
        stack.addArrangedSubview(chromeSeparator(vertical: true))
        stack.addArrangedSubview(undoButton)
        stack.addArrangedSubview(redoButton)
        pin(stack)
        tool = .select
        buttons[.select]?.isOn = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setHistory(canUndo: Bool, canRedo: Bool) {
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
    }
}

// MARK: - Action strip

/// Buttons of the vertical strip right of the selection.
enum OverlayAction: CaseIterable {
    case close, move, copy, save, saveAs, editor

    var symbol: String {
        switch self {
        case .close: "xmark"
        case .copy: "doc.on.doc"
        case .save: "square.and.arrow.down"
        case .saveAs: "square.and.arrow.down.on.square"
        case .move: "arrow.up.and.down.and.arrow.left.and.right"
        case .editor: "macwindow"
        }
    }

    var title: String {
        switch self {
        case .close: "Close"
        case .copy: "Copy"
        case .save: "Save"
        case .saveAs: "Save As…"
        case .move: "Move selection"
        case .editor: "Open in Editor"
        }
    }

    var shortcut: String {
        switch self {
        case .close: "⎋"
        case .copy: "⌘C"
        case .save: "⌘S"
        case .saveAs: "⇧⌘S"
        case .move: "drag"
        case .editor: "⌘E"
        }
    }

    var tooltip: String { "\(title) (\(shortcut))" }
}

/// Vertical strip of result actions, placed right of the selection.
final class OverlayActionStrip: OverlayChromeView {

    var onAction: ((OverlayAction) -> Void)?
    /// Drag on the move button: 0 = began, 1 = moved, 2 = ended (event in window coords).
    var onMoveDrag: ((Int, NSEvent) -> Void)?
    var accent: NSColor = .controlAccentColor { didSet { buttons.values.forEach { $0.accent = accent } } }

    private var buttons: [OverlayAction: OverlayButton] = [:]

    override init() {
        super.init()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 2
        for action in OverlayAction.allCases {
            var run: (() -> Void)?
            let b = action == .move
                ? OverlayMoveButton(symbol: action.symbol, tooltip: action.tooltip, accessibility: action.title) { run?() }
                : OverlayButton(symbol: action.symbol, tooltip: action.tooltip, accessibility: action.title) { run?() }
            if let m = b as? OverlayMoveButton { m.onDrag = { [weak self] phase, event in self?.onMoveDrag?(phase, event) } }
            run = { [weak self] in self?.onAction?(action) }
            buttons[action] = b
            stack.addArrangedSubview(b)
            if action == .close { stack.addArrangedSubview(chromeSeparator(vertical: false)) }
        }
        pin(stack)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setEnabled(_ enabled: Bool, for action: OverlayAction) { buttons[action]?.isEnabled = enabled }
}

// MARK: - Region strip

/// The small [Cancel] [Start Capture] strip of `OverlayController.selectRegion`.
final class OverlayRegionStrip: OverlayChromeView {

    var onCancel: (() -> Void)?
    var onStart: (() -> Void)?

    private let startButton = NSButton(title: "Start Capture", target: nil, action: nil)

    override init() {
        super.init()
        padding = NSEdgeInsets(top: 7, left: 9, bottom: 7, right: 9)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.toolTip = "Cancel (⎋)"
        startButton.bezelStyle = .rounded
        startButton.target = self
        startButton.action = #selector(startTapped)
        startButton.keyEquivalent = "\r"
        startButton.toolTip = "Start Capture (↩)"
        let stack = NSStackView(views: [cancel, startButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        pin(stack)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func cancelTapped() { onCancel?() }
    @objc private func startTapped() { onStart?() }
}


/// The action-strip button that drags the whole selection (Shottr/MacShot "move").
final class OverlayMoveButton: OverlayButton {
    var onDrag: ((Int, NSEvent) -> Void)?
    override func mouseDown(with event: NSEvent) { onDrag?(0, event) }
    override func mouseDragged(with event: NSEvent) { onDrag?(1, event) }
    override func mouseUp(with event: NSEvent) { onDrag?(2, event) }
}


/// Tooltip window for the overlay chrome. AppKit tooltips need an active app;
/// the overlay is a non-activating panel, so it draws its own.
@MainActor
final class OverlayTooltip {
    static let shared = OverlayTooltip()
    private var window: NSWindow?
    private var label: NSTextField?
    private var timer: Timer?
    private var lastHidden = Date.distantPast

    func show(_ text: String, anchor: NSView) {
        timer?.invalidate()
        guard !text.isEmpty else { return }
        present(text, anchor: anchor)
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        if window?.isVisible == true { lastHidden = Date() }
        window?.orderOut(nil)
    }

    private func present(_ text: String, anchor: NSView) {
        guard let anchorWindow = anchor.window, anchorWindow.isVisible else { hide(); return }
        if window == nil {
            let w = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
            w.animationBehavior = .none
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
            w.ignoresMouseEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let back = NSView()
            back.wantsLayer = true
            back.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.96).cgColor
            back.layer?.cornerRadius = 6
            back.layer?.borderWidth = 1
            back.layer?.borderColor = NSColor(white: 1, alpha: 0.18).cgColor
            let l = NSTextField(labelWithString: "")
            l.font = .systemFont(ofSize: 12, weight: .medium)
            l.textColor = .white
            l.translatesAutoresizingMaskIntoConstraints = false
            back.addSubview(l)
            NSLayoutConstraint.activate([
                l.leadingAnchor.constraint(equalTo: back.leadingAnchor, constant: 8),
                l.trailingAnchor.constraint(equalTo: back.trailingAnchor, constant: -8),
                l.topAnchor.constraint(equalTo: back.topAnchor, constant: 4),
                l.bottomAnchor.constraint(equalTo: back.bottomAnchor, constant: -4),
            ])
            w.contentView = back
            window = w
            label = l
        }
        guard let window, let label else { return }
        label.stringValue = text
        label.sizeToFit()
        let size = CGSize(width: label.frame.width + 16, height: label.frame.height + 8)
        let anchorRect = anchorWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        // vertical strips get the tip to their left (one column); horizontal ones above
        let strip = anchor.superview?.superview ?? anchor.superview
        let vertical = (strip?.bounds.height ?? 0) > (strip?.bounds.width ?? 0)
        var origin: CGPoint
        if vertical {
            origin = CGPoint(x: anchorRect.minX - size.width - 8, y: anchorRect.midY - size.height / 2)
        } else {
            origin = CGPoint(x: anchorRect.midX - size.width / 2, y: anchorRect.maxY + 6)
        }
        if let screen = anchorWindow.screen {
            let f = screen.visibleFrame
            if vertical, origin.x < f.minX + 4 { origin.x = anchorRect.maxX + 8 }
            if !vertical, origin.y + size.height > f.maxY { origin.y = anchorRect.minY - size.height - 6 }
            origin.x = min(max(origin.x, f.minX + 4), f.maxX - size.width - 4)
            origin.y = min(max(origin.y, f.minY + 4), f.maxY - size.height - 4)
        }
        window.setFrame(CGRect(origin: origin, size: size), display: true)
        window.orderFrontRegardless()
    }
}

/// Thin crosshair like the macOS screenshot cursor.
@MainActor
enum CaptureCursor {
    static let crosshair: NSCursor = {
        let s: CGFloat = 25
        let image = NSImage(size: CGSize(width: s, height: s), flipped: true) { _ in
            let c = s / 2
            func line(_ a: CGPoint, _ b: CGPoint, _ color: NSColor, _ w: CGFloat) {
                let p = NSBezierPath(); p.move(to: a); p.line(to: b); p.lineWidth = w; color.set(); p.stroke()
            }
            for (col, w) in [(NSColor.white, 3.0), (NSColor.black, 1.0)] {
                line(CGPoint(x: c, y: 0), CGPoint(x: c, y: c - 3), col, w)
                line(CGPoint(x: c, y: c + 3), CGPoint(x: c, y: s), col, w)
                line(CGPoint(x: 0, y: c), CGPoint(x: c - 3, y: c), col, w)
                line(CGPoint(x: c + 3, y: c), CGPoint(x: s, y: c), col, w)
            }
            NSColor.white.set(); NSBezierPath(ovalIn: CGRect(x: c - 2, y: c - 2, width: 4, height: 4)).fill()
            NSColor.black.set(); NSBezierPath(ovalIn: CGRect(x: c - 1, y: c - 1, width: 2, height: 2)).fill()
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: s / 2, y: s / 2))
    }()
}
