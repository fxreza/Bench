import AppKit
import CoreGraphics
import BenchCore

// MARK: - Panel

/// Borderless, non-activating floating panel used for every piece of scrolling
/// capture chrome.
///
/// `.nonactivatingPanel` is the whole point: the user has to keep scrolling the
/// app *under* the region, so clicking Start/Done must never bring Bench
/// forward. The panel can still become key (so the local Esc/Return monitor
/// sees key presses) without the app being activated.
final class ScrollCapturePanel: NSPanel {

    /// The border panel never takes key (it is click-through); the controls and
    /// preview panels do.
    var wantsKey: Bool = true

    override var canBecomeKey: Bool { wantsKey }
    override var canBecomeMain: Bool { false }

    convenience init(frame: CGRect, canKey: Bool) {
        self.init(contentRect: frame,
                  styleMask: [.borderless, .nonactivatingPanel],
                  backing: .buffered,
                  defer: false)
        wantsKey = canKey
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        appearance = AppearanceSettings.shared.colorScheme.nsAppearance
    }
}

// MARK: - Border

/// Draws the marching-ants rectangle around the capture region.
///
/// The view's window is the region grown by 3pt on every side, and the 2pt
/// stroke is centred 2pt in from the panel edge — so the dashes occupy points
/// 1...3 of the margin and stop exactly where the region begins. Nothing this
/// view draws can ever land inside a captured frame.
final class ScrollCaptureBorderView: NSView {

    var accentColor: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    var dashPhase: CGFloat = 0 { didSet { needsDisplay = true } }
    /// The "waiting for Start" hint, hidden the moment capturing begins.
    var showsHint: Bool = true { didSet { needsDisplay = true } }
    var hintText: String = "Scroll the content by hand"

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds.insetBy(dx: 2, dy: 2)
        guard rect.width > 0, rect.height > 0 else { return }

        ctx.saveGState()
        ctx.setLineWidth(2)
        ctx.setStrokeColor(accentColor.cgColor)
        ctx.setLineDash(phase: dashPhase, lengths: [6, 4])
        ctx.stroke(rect)
        ctx.restoreGState()

        guard showsHint else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ]
        let text = NSAttributedString(string: hintText, attributes: attributes)
        let textSize = text.size()
        let padH: CGFloat = 8
        let padV: CGFloat = 4
        let box = CGRect(x: rect.minX + 6,
                         y: rect.maxY - 6 - (textSize.height + padV * 2),
                         width: textSize.width + padH * 2,
                         height: textSize.height + padV * 2)
        guard box.width <= rect.width - 12, box.height <= rect.height - 12 else { return }

        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.30).cgColor)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()
        text.draw(at: CGPoint(x: box.minX + padH, y: box.minY + padV))
    }
}

// MARK: - Preview

/// Draws the live stitched bitmap scaled to fit, centred.
final class ScrollCaptureImageView: NSView {

    var image: CGImage? { didSet { needsDisplay = true } }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let frame = bounds
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.12).cgColor)
        ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.fillPath()

        guard let image, image.width > 0, image.height > 0, frame.width > 2, frame.height > 2 else { return }
        let inner = frame.insetBy(dx: 1, dy: 1)
        let scale = min(inner.width / CGFloat(image.width), inner.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let target = CGRect(x: inner.midX - size.width / 2,
                            y: inner.midY - size.height / 2,
                            width: size.width,
                            height: size.height)
        ctx.saveGState()
        ctx.interpolationQuality = .low
        ctx.draw(image, in: target)
        ctx.restoreGState()
    }
}

/// Preview content: the stitched image on top, a monospaced status line and an
/// optional transient message underneath.
final class ScrollCapturePreviewView: NSView {

    private let imageView = ScrollCaptureImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")

    private let padding: CGFloat = 8
    private let lineHeight: CGFloat = 14

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        statusLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byTruncatingTail
        messageLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.alignment = .center
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.isHidden = true
        addSubview(imageView)
        addSubview(statusLabel)
        addSubview(messageLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var image: CGImage? {
        get { imageView.image }
        set { imageView.image = newValue }
    }

    func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    /// `nil` hides the message row and gives the space back to the image.
    func setMessage(_ text: String?, accented: Bool) {
        if let text, !text.isEmpty {
            messageLabel.stringValue = text
            messageLabel.textColor = accented ? .controlAccentColor : .secondaryLabelColor
            messageLabel.isHidden = false
        } else {
            messageLabel.stringValue = ""
            messageLabel.isHidden = true
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = max(0, bounds.width - padding * 2)
        var y = padding
        if !messageLabel.isHidden {
            messageLabel.frame = CGRect(x: padding, y: y, width: width, height: lineHeight)
            y += lineHeight + 2
        }
        statusLabel.frame = CGRect(x: padding, y: y, width: width, height: lineHeight)
        y += lineHeight + 6
        imageView.frame = CGRect(x: padding, y: y, width: width, height: max(0, bounds.height - padding - y))
    }
}

// MARK: - Layout maths

/// Pure placement helpers, kept separate from the panels so the geometry can be
/// reasoned about (and unit tested) without a window server.
enum ScrollCaptureLayout {

    static let gap: CGFloat = 10
    static let previewWidth: CGFloat = 200
    /// The border panel overhangs the region by this much on every side.
    static let borderOverhang: CGFloat = 3

    static func borderFrame(region: CGRect) -> CGRect {
        region.insetBy(dx: -borderOverhang, dy: -borderOverhang)
    }

    /// Centred below the region, else above it, else inside at the bottom;
    /// always clamped into `visible`.
    static func controlsFrame(size: CGSize, region: CGRect, visible: CGRect) -> CGRect {
        var y = region.minY - gap - size.height
        if y < visible.minY {
            let above = region.maxY + gap
            y = (above + size.height <= visible.maxY) ? above : region.minY + gap
        }
        let x = region.midX - size.width / 2
        return clamp(CGRect(x: x, y: y, width: size.width, height: size.height), into: visible)
    }

    /// To the left of the region, else to the right, top-aligned with it.
    static func previewFrame(region: CGRect, visible: CGRect) -> CGRect {
        let width = previewWidth
        var height = min(region.height, visible.height - 16)
        height = max(height, min(160, max(0, visible.height - 16)))

        var x = region.minX - gap - width
        if x < visible.minX {
            let right = region.maxX + gap
            if right + width <= visible.maxX { x = right }
        }
        let y = region.maxY - height
        return clamp(CGRect(x: x, y: y, width: width, height: height), into: visible)
    }

    /// The screen the region sits on (by centre, then by overlap, then main).
    static func screen(for region: CGRect) -> NSScreen? {
        let centre = CGPoint(x: region.midX, y: region.midY)
        return NSScreen.screens.first { $0.frame.contains(centre) }
            ?? NSScreen.screens.first { $0.frame.intersects(region) }
            ?? NSScreen.main
    }

    static func clamp(_ rect: CGRect, into visible: CGRect) -> CGRect {
        var r = rect
        let inset: CGFloat = 4
        if r.width + inset * 2 <= visible.width {
            r.origin.x = min(max(r.minX, visible.minX + inset), visible.maxX - r.width - inset)
        } else {
            r.origin.x = visible.minX
        }
        if r.height + inset * 2 <= visible.height {
            r.origin.y = min(max(r.minY, visible.minY + inset), visible.maxY - r.height - inset)
        } else {
            r.origin.y = visible.minY
        }
        return CGRect(x: r.origin.x.rounded(), y: r.origin.y.rounded(),
                      width: r.width.rounded(), height: r.height.rounded())
    }
}

// MARK: - Controller

/// Owns the three panels of a scrolling capture: the dashed border, the
/// Cancel/Start-Done controls, and (once capturing) the live preview.
///
/// It knows nothing about capturing — it reports button presses through
/// `onStart` / `onDone` / `onCancel` and renders whatever the session hands
/// back through `showFrame(...)`.
@MainActor
final class ScrollCapturePanels: NSObject {

    enum Phase { case waiting, capturing }

    // MARK: Callbacks

    var onStart: (() -> Void)?
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?

    // MARK: State

    private let region: CGRect
    private(set) var phase: Phase = .waiting
    private var closed = false

    private let borderPanel: ScrollCapturePanel
    private let borderView = ScrollCaptureBorderView()
    private let controlsPanel: ScrollCapturePanel
    private let cancelButton = NSButton()
    private let actionButton = NSButton()
    private var previewPanel: ScrollCapturePanel?
    private var previewView: ScrollCapturePreviewView?

    private var dashTimer: Timer?
    private var messageTimer: Timer?

    private let buttonPadding: CGFloat = 10
    private let buttonSpacing: CGFloat = 8

    // MARK: Init

    init(region: CGRect) {
        self.region = region.standardized
        borderPanel = ScrollCapturePanel(frame: ScrollCaptureLayout.borderFrame(region: self.region), canKey: false)
        controlsPanel = ScrollCapturePanel(frame: CGRect(x: 0, y: 0, width: 220, height: 44), canKey: true)
        super.init()

        borderPanel.ignoresMouseEvents = true
        borderView.frame = CGRect(origin: .zero, size: borderPanel.frame.size)
        borderView.autoresizingMask = [.width, .height]
        borderView.accentColor = Self.accentColor
        borderPanel.contentView = borderView

        controlsPanel.hasShadow = true
        controlsPanel.contentView = Self.makeMaterialView()

        configure(cancelButton, title: "Cancel", action: #selector(cancelClicked))
        configure(actionButton, title: "Start Capture", action: #selector(actionClicked))
        makeDefault(actionButton)
        controlsPanel.contentView?.addSubview(cancelButton)
        controlsPanel.contentView?.addSubview(actionButton)
    }

    // MARK: Presentation

    /// Shows border + controls. Capturing does not start here.
    func show() {
        guard !closed else { return }
        layoutControls()
        borderPanel.orderFrontRegardless()
        controlsPanel.orderFrontRegardless()
        controlsPanel.makeKey()
    }

    /// Switches the chrome into capturing mode: Done button, marching ants,
    /// live preview panel.
    func beginCapturing() {
        guard !closed, phase == .waiting else { return }
        phase = .capturing
        borderView.showsHint = false
        actionButton.title = "Done"
        makeDefault(actionButton)
        layoutControls()
        showPreviewPanel()
        startDashAnimation()
    }

    func close() {
        guard !closed else { return }
        closed = true
        dashTimer?.invalidate()
        dashTimer = nil
        messageTimer?.invalidate()
        messageTimer = nil
        previewPanel?.orderOut(nil)
        previewPanel = nil
        previewView = nil
        controlsPanel.orderOut(nil)
        borderPanel.orderOut(nil)
    }

    /// Window IDs of every panel, so the capturer can exclude them from frames.
    var windowIDs: [CGWindowID] {
        [borderPanel, controlsPanel, previewPanel]
            .compactMap { $0 }
            .filter { $0.windowNumber > 0 }
            .map { CGWindowID($0.windowNumber) }
    }

    /// True while one of our panels holds key, i.e. the local key monitor owns
    /// Esc/Return.
    var ownsKeyWindow: Bool {
        [borderPanel, controlsPanel, previewPanel].compactMap { $0 }.contains { $0.isKeyWindow }
    }

    // MARK: Preview updates

    /// Renders one stitched snapshot. `image` may be `nil` when the session
    /// throttled the (potentially large) bitmap build for this frame — the
    /// status line still updates.
    func showFrame(image: CGImage?, coveredHeight: Int, frameCount: Int) {
        guard !closed, let previewView else { return }
        if let image { previewView.image = image }
        previewView.setStatus("\(coveredHeight) px · \(frameCount) frames")
    }

    /// A message that clears itself after `duration` seconds.
    func flashMessage(_ text: String, duration: TimeInterval) {
        guard !closed, let previewView else { return }
        previewView.setMessage(text, accented: false)
        messageTimer?.invalidate()
        messageTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.previewView?.setMessage(nil, accented: false) }
        }
    }

    /// A message that stays put (used for "Limit reached").
    func setMessage(_ text: String?) {
        guard !closed, let previewView else { return }
        messageTimer?.invalidate()
        messageTimer = nil
        previewView.setMessage(text, accented: true)
    }

    // MARK: Actions

    @objc private func cancelClicked() { onCancel?() }

    @objc private func actionClicked() {
        if phase == .waiting { onStart?() } else { onDone?() }
    }

    // MARK: Building blocks

    private static func makeMaterialView() -> NSVisualEffectView {
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.separatorColor.cgColor
        return effect
    }

    private func configure(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.controlSize = .regular
        button.isBordered = true
        button.refusesFirstResponder = true
    }

    /// Blue "default" look that survives the panel being non-key.
    private func makeDefault(_ button: NSButton) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        button.keyEquivalent = "\r"
        button.bezelColor = .controlAccentColor
        button.attributedTitle = NSAttributedString(string: button.title, attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium),
            .paragraphStyle: paragraph,
        ])
    }

    private func layoutControls() {
        cancelButton.sizeToFit()
        actionButton.sizeToFit()
        let height = max(24, max(cancelButton.frame.height, actionButton.frame.height)).rounded()
        let cancelWidth = max(80, cancelButton.frame.width + 16).rounded()
        let actionWidth = max(110, actionButton.frame.width + 16).rounded()

        let size = CGSize(width: buttonPadding * 2 + cancelWidth + buttonSpacing + actionWidth,
                          height: buttonPadding * 2 + height)
        let visible = ScrollCaptureLayout.screen(for: region)?.visibleFrame ?? region
        let frame = ScrollCaptureLayout.controlsFrame(size: size, region: region, visible: visible)
        controlsPanel.setFrame(frame, display: true)

        cancelButton.frame = CGRect(x: buttonPadding, y: buttonPadding, width: cancelWidth, height: height)
        actionButton.frame = CGRect(x: buttonPadding + cancelWidth + buttonSpacing, y: buttonPadding,
                                    width: actionWidth, height: height)
    }

    private func showPreviewPanel() {
        let visible = ScrollCaptureLayout.screen(for: region)?.visibleFrame ?? region
        let frame = ScrollCaptureLayout.previewFrame(region: region, visible: visible)
        let panel = ScrollCapturePanel(frame: frame, canKey: true)
        panel.hasShadow = true
        let effect = Self.makeMaterialView()
        let content = ScrollCapturePreviewView(frame: CGRect(origin: .zero, size: frame.size))
        content.autoresizingMask = [.width, .height]
        content.setStatus("0 px · 0 frames")
        effect.addSubview(content)
        panel.contentView = effect
        content.frame = CGRect(origin: .zero, size: frame.size)
        previewPanel = panel
        previewView = content
        panel.orderFrontRegardless()
        // Keep the controls panel key so Esc/Return keep working after Start.
        controlsPanel.makeKey()
    }

    private func startDashAnimation() {
        dashTimer?.invalidate()
        dashTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                self.borderView.dashPhase = self.borderView.dashPhase >= 100 ? 0 : self.borderView.dashPhase + 2
            }
        }
    }

    /// The user's accent choice, as an `NSColor` (`Theme.accent` is SwiftUI-only).
    private static var accentColor: NSColor { Theme.accentNSColor }
}
