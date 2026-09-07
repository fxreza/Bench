import AppKit

/// One drawn object. A value type with a stable id; all geometry is in image
/// points (1pt = 1 logical pixel of the screenshot). Mutations go through
/// `AnnotationDocument` so they are undoable.
nonisolated struct Annotation: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var kind: AnnotationKind

    // Geometry
    /// arrow/line: start; counter: badge center; text: bubble origin (top-left, y down)
    var start: CGPoint = .zero
    /// arrow/line: end (head end)
    var end: CGPoint = .zero
    /// rectangle/oval/blur/text/crop-like boxes
    var rect: CGRect = .zero
    /// freehand + highlighter strokes
    var points: [CGPoint] = []
    /// text label pointer tip (image coords) when `textPointer` is on
    var pointerTip: CGPoint? = nil
    /// counter nubbin angle in radians, 0 = pointing down, counter-clockwise positive
    var angle: CGFloat = 0

    // Style
    var color: AnnotationColor = .shottrRed
    var thickness: CGFloat = 4
    var arrowType: ArrowType = .tapered
    var shapeStyle: ShapeStyle = .outline
    var blurMode: BlurMode = .mosaic
    var blurStrength: CGFloat = 0.5
    var textStyle: TextStyle = .label
    var textPointer: Bool = true
    var size: SizeStep = .m
    var fontSize: CGFloat = 22

    // Content
    var text: String = ""
    var number: Int = 1

    init(id: UUID = UUID(), kind: AnnotationKind) {
        self.id = id
        self.kind = kind
    }

    /// New annotation pre-filled from the current tool style.
    init(kind: AnnotationKind, style: ToolStyle) {
        self.init(kind: kind)
        color = kind == .highlighter ? style.highlighterColor : style.color
        thickness = kind == .highlighter ? style.highlighterThickness : style.thickness
        arrowType = style.arrowType
        shapeStyle = style.shapeStyle
        blurMode = style.blurMode
        blurStrength = style.blurStrength
        textStyle = style.textStyle
        textPointer = style.textPointer
        size = style.size
        fontSize = style.fontSize
    }

    /// Axis-aligned bounds in image points, ignoring stroke width.
    var bounds: CGRect {
        switch kind {
        case .arrow, .line:
            return CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        case .rectangle, .oval, .blur, .text:
            var r = rect.standardized
            if kind == .text, let tip = pointerTip, textPointer { r = r.union(CGRect(origin: tip, size: .zero)) }
            return r
        case .freehand, .highlighter:
            guard let first = points.first else { return CGRect(origin: start, size: .zero) }
            var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
            for p in points { minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y) }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case .counter:
            let d = size.counterDiameter
            return CGRect(x: start.x - d / 2, y: start.y - d / 2, width: d, height: d)
        }
    }

    /// Bounds padded by the stroke so hit tests and redraws cover the whole mark.
    var visualBounds: CGRect {
        let pad: CGFloat
        switch kind {
        case .arrow: pad = max(thickness * 3, 14)
        case .line, .freehand, .highlighter: pad = thickness / 2 + 2
        case .rectangle, .oval: pad = thickness / 2 + 2
        case .counter: pad = size.counterDiameter * 0.5 + 2   // nubbin sticks out
        case .text: pad = 6
        case .blur: pad = 1
        }
        return bounds.insetBy(dx: -pad, dy: -pad)
    }

    mutating func translate(dx: CGFloat, dy: CGFloat) {
        start.x += dx; start.y += dy
        end.x += dx; end.y += dy
        rect.origin.x += dx; rect.origin.y += dy
        if !points.isEmpty { points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) } }
        if let tip = pointerTip { pointerTip = CGPoint(x: tip.x + dx, y: tip.y + dy) }
    }

    /// Scales geometry by `factor` around the image origin (used by crop/resize).
    mutating func scale(by factor: CGFloat) {
        start = CGPoint(x: start.x * factor, y: start.y * factor)
        end = CGPoint(x: end.x * factor, y: end.y * factor)
        rect = CGRect(x: rect.origin.x * factor, y: rect.origin.y * factor, width: rect.width * factor, height: rect.height * factor)
        points = points.map { CGPoint(x: $0.x * factor, y: $0.y * factor) }
        if let tip = pointerTip { pointerTip = CGPoint(x: tip.x * factor, y: tip.y * factor) }
        thickness *= factor
    }

    /// Whether this annotation is resized via a rect-style handle set.
    var usesRectHandles: Bool {
        switch kind {
        case .rectangle, .oval, .blur, .text, .freehand, .highlighter: return true
        case .arrow, .line, .counter: return false
        }
    }

    /// True when the object is too small to be meaningful (discarded on mouse-up).
    var isDegenerate: Bool {
        switch kind {
        case .arrow, .line: return hypot(end.x - start.x, end.y - start.y) < 4
        case .rectangle, .oval, .blur: return rect.width < 3 || rect.height < 3
        case .freehand, .highlighter: return points.count < 2
        case .text: return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .counter: return false
        }
    }
}
