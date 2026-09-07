import AppKit

/// Shared math for 8-handle rectangles (crop box, capture selection).
nonisolated enum RectGeometry {
    static let edgeHandles: [HandleKind] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]

    /// Handle centers for a rect in a y-down coordinate space.
    static func handlePositions(for r: CGRect) -> [HandleKind: CGPoint] {
        [
            .topLeft: CGPoint(x: r.minX, y: r.minY), .top: CGPoint(x: r.midX, y: r.minY), .topRight: CGPoint(x: r.maxX, y: r.minY),
            .right: CGPoint(x: r.maxX, y: r.midY), .bottomRight: CGPoint(x: r.maxX, y: r.maxY), .bottom: CGPoint(x: r.midX, y: r.maxY),
            .bottomLeft: CGPoint(x: r.minX, y: r.maxY), .left: CGPoint(x: r.minX, y: r.midY),
        ]
    }

    static func handle(at p: CGPoint, in r: CGRect, radius: CGFloat) -> HandleKind? {
        let pos = handlePositions(for: r)
        // corners take priority over edges
        for k in [HandleKind.topLeft, .topRight, .bottomRight, .bottomLeft, .top, .right, .bottom, .left] {
            if let c = pos[k], abs(c.x - p.x) <= radius, abs(c.y - p.y) <= radius { return k }
        }
        return nil
    }

    /// Resizes `original` by dragging `handle` to `p`. Opposite edge stays fixed.
    /// `shift` keeps the original aspect ratio for corner handles. Result is standardized and at least `minSize`.
    static func resize(_ original: CGRect, handle: HandleKind, to p: CGPoint, shift: Bool = false, minSize: CGFloat = 1, aspect: CGFloat? = nil) -> CGRect {
        var minX = original.minX, minY = original.minY, maxX = original.maxX, maxY = original.maxY
        switch handle {
        case .topLeft: minX = p.x; minY = p.y
        case .top: minY = p.y
        case .topRight: maxX = p.x; minY = p.y
        case .right: maxX = p.x
        case .bottomRight: maxX = p.x; maxY = p.y
        case .bottom: maxY = p.y
        case .bottomLeft: minX = p.x; maxY = p.y
        case .left: minX = p.x
        default: break
        }
        var r = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
        let ratio = aspect ?? (original.height > 0 ? original.width / original.height : 1)
        if shift || aspect != nil, [.topLeft, .topRight, .bottomRight, .bottomLeft].contains(handle), ratio > 0 {
            // keep the anchor corner fixed and fit to the ratio
            let w = r.width, h = r.height
            let useWidth = w / ratio >= h
            let nw = useWidth ? w : h * ratio
            let nh = useWidth ? w / ratio : h
            switch handle {
            case .topLeft: r = CGRect(x: original.maxX - nw, y: original.maxY - nh, width: nw, height: nh)
            case .topRight: r = CGRect(x: original.minX, y: original.maxY - nh, width: nw, height: nh)
            case .bottomRight: r = CGRect(x: original.minX, y: original.minY, width: nw, height: nh)
            case .bottomLeft: r = CGRect(x: original.maxX - nw, y: original.minY, width: nw, height: nh)
            default: break
            }
        }
        if r.width < minSize { r.size.width = minSize }
        if r.height < minSize { r.size.height = minSize }
        return r
    }

    static func cursor(for handle: HandleKind?) -> NSCursor {
        switch handle {
        case .top?, .bottom?: return .resizeUpDown
        case .left?, .right?: return .resizeLeftRight
        case .topLeft?, .bottomRight?, .topRight?, .bottomLeft?: return .crosshair
        default: return .arrow
        }
    }

    /// Rect from two drag points, optionally constrained to a square (shift).
    static func rect(from a: CGPoint, to b: CGPoint, square: Bool) -> CGRect {
        var w = b.x - a.x, h = b.y - a.y
        if square {
            let s = max(abs(w), abs(h))
            w = w < 0 ? -s : s
            h = h < 0 ? -s : s
        }
        return CGRect(x: a.x, y: a.y, width: w, height: h).standardized
    }

    /// Snaps a segment end to 45 degree increments around `a` (shift for lines/arrows).
    static func snapped45(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 0 else { return b }
        let angle = atan2(dy, dx)
        let step = CGFloat.pi / 4
        let snapped = (angle / step).rounded() * step
        return CGPoint(x: a.x + cos(snapped) * len, y: a.y + sin(snapped) * len)
    }
}
