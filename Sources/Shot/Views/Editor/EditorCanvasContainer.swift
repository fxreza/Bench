import AppKit

/// Clip view that keeps a document view smaller than the viewport centered
/// instead of pinned to the top-left corner.
@MainActor
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        let frame = doc.frame
        if rect.width > frame.width {
            rect.origin.x = (frame.width - rect.width) / 2
        }
        if rect.height > frame.height {
            rect.origin.y = (frame.height - rect.height) / 2
        }
        return rect
    }
}

/// The scrolling, magnifiable, checkerboard-backed host for an
/// `AnnotationCanvasView`. The canvas is the document view; the clip view keeps
/// it centered while it is smaller than the viewport, and the checkerboard is
/// drawn by the scroll view itself so it stays put while the image zooms.
@MainActor
final class EditorCanvasContainer: NSScrollView {

    let canvas: AnnotationCanvasView

    /// Called whenever the magnification changed (pinch, ⌘+/-, menu, fit).
    var onZoomChange: ((CGFloat) -> Void)?

    /// The ladder ⌘+ / ⌘- walk through.
    static let zoomSteps: [CGFloat] = [0.10, 0.25, 0.33, 0.50, 0.75, 1.0, 1.25, 1.50, 2.0, 3.0, 4.0, 6.0, 8.0]

    private var lastReportedZoom: CGFloat = 1
    private let checkerSquare: CGFloat = 8

    init(canvas: AnnotationCanvasView) {
        self.canvas = canvas
        super.init(frame: NSRect(origin: .zero, size: canvas.frame.size))

        let clip = CenteringClipView()
        clip.drawsBackground = false
        contentView = clip
        documentView = canvas

        drawsBackground = false
        borderType = .noBorder
        allowsMagnification = true
        minMagnification = 0.1
        maxMagnification = 8
        magnification = 1
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        usesPredominantAxisScrolling = false

        contentView.postsBoundsChangedNotifications = true
        contentView.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(clipViewChanged),
                           name: NSView.boundsDidChangeNotification, object: contentView)
        center.addObserver(self, selector: #selector(clipViewChanged),
                           name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: zoom

    /// Current magnification (1 = 100%).
    var zoom: CGFloat { magnification }

    /// Magnification that makes the whole image fit; never enlarges past 100%.
    var fitZoom: CGFloat {
        let doc = canvas.frame.size
        let available = bounds.size
        guard doc.width > 1, doc.height > 1, available.width > 1, available.height > 1 else { return 1 }
        return min(1, min(available.width / doc.width, available.height / doc.height))
    }

    /// True when the image does not fit at 100%.
    var needsFitting: Bool { fitZoom < 1 }

    /// Sets the magnification, keeping the current visible center in place.
    func setZoom(_ value: CGFloat, animated: Bool = false) {
        let clamped = min(maxMagnification, max(minMagnification, value))
        guard abs(clamped - magnification) > 0.0001 else { syncZoom(); return }
        let visible = documentVisibleRect
        let anchor = CGPoint(x: visible.midX, y: visible.midY)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                animator().setMagnification(clamped, centeredAt: anchor)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.syncZoom() }
            }
        } else {
            setMagnification(clamped, centeredAt: anchor)
        }
        syncZoom()
    }

    func zoomIn() {
        let next = Self.zoomSteps.first { $0 > magnification + 0.001 } ?? maxMagnification
        setZoom(next)
    }

    func zoomOut() {
        let next = Self.zoomSteps.last { $0 < magnification - 0.001 } ?? minMagnification
        setZoom(next)
    }

    func zoomToActualSize() { setZoom(1) }

    func zoomToFit() { setZoom(fitZoom) }

    /// Picks 100% or fit depending on whether the image needs shrinking, and
    /// re-centers. Used when the window first opens and after a crop.
    func applyInitialZoom() {
        layoutSubtreeIfNeeded()
        setZoom(needsFitting ? fitZoom : 1)
        recenter()
    }

    func recenter() {
        reflectScrolledClipView(contentView)
        let visible = documentVisibleRect
        let doc = canvas.frame
        var origin = visible.origin
        if visible.width >= doc.width { origin.x = (doc.width - visible.width) / 2 }
        if visible.height >= doc.height { origin.y = (doc.height - visible.height) / 2 }
        contentView.setBoundsOrigin(origin)
        reflectScrolledClipView(contentView)
    }

    @objc private func clipViewChanged(_ note: Notification) {
        syncZoom()
    }

    private func syncZoom() {
        let value = magnification
        canvas.viewScale = value
        guard abs(value - lastReportedZoom) > 0.0001 else { return }
        lastReportedZoom = value
        onZoomChange?(value)
    }

    override func layout() {
        super.layout()
        syncZoom()
    }

    // MARK: checkerboard

    private var checkerColors: (NSColor, NSColor) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if dark {
            return (NSColor(white: 0.16, alpha: 1), NSColor(white: 0.21, alpha: 1))
        }
        return (NSColor(white: 1.0, alpha: 1), NSColor(white: 0.91, alpha: 1))
    }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let (base, alternate) = checkerColors
        base.setFill()
        dirtyRect.fill()

        let square = checkerSquare
        alternate.setFill()
        let startX = (dirtyRect.minX / square).rounded(.down) * square
        let startY = (dirtyRect.minY / square).rounded(.down) * square
        var y = startY
        while y < dirtyRect.maxY {
            var x = startX
            while x < dirtyRect.maxX {
                let column = Int((x / square).rounded())
                let row = Int((y / square).rounded())
                if (column + row) % 2 == 0 {
                    NSRect(x: x, y: y, width: square, height: square).intersection(dirtyRect).fill()
                }
                x += square
            }
            y += square
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
