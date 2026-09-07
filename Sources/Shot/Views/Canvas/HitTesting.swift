import AppKit
import CoreGraphics

/// The grab points shown around a selected annotation.
nonisolated enum HandleKind: Sendable, Hashable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    case start, end
    case pointerTip
    case nubbin
}

nonisolated struct AnnotationHandle: Sendable, Hashable {
    var kind: HandleKind
    var position: CGPoint
}

/// Picking and handle geometry. Everything is in image points (y down).
@MainActor
enum HitTesting {

    // MARK: - Hit tests

    static func hits(_ annotation: Annotation, point: CGPoint, tolerance: CGFloat) -> Bool {
        let tol = max(0, tolerance)
        switch annotation.kind {
        case .line:
            return distance(point, toSegment: annotation.start, annotation.end) <= max(annotation.thickness, tol * 2) / 2 + 0.5

        case .arrow:
            if annotation.arrowType == .tapered {
                let p = AnnotationRenderer.outlinePath(for: annotation)
                if p.isEmpty { return false }
                if p.contains(point, using: .winding) { return true }
                return stroked(p, width: max(1, tol * 2)).contains(point, using: .winding)
            }
            if distance(point, toSegment: annotation.start, annotation.end) <= max(annotation.thickness, tol * 2) / 2 + 0.5 { return true }
            let head = AnnotationRenderer.thinArrowHeadPath(annotation)
            if head.isEmpty { return false }
            return head.contains(point, using: .winding) || stroked(head, width: max(1, tol * 2)).contains(point, using: .winding)

        case .rectangle, .oval:
            let r = annotation.rect.standardized
            guard r.width > 0, r.height > 0 else { return false }
            let p = AnnotationRenderer.outlinePath(for: annotation)
            if annotation.shapeStyle == .outline {
                return stroked(p, width: max(annotation.thickness, tol * 2)).contains(point, using: .winding)
            }
            if p.contains(point, using: .winding) { return true }
            return stroked(p, width: max(annotation.thickness, tol * 2)).contains(point, using: .winding)

        case .blur:
            return annotation.rect.standardized.insetBy(dx: -tol, dy: -tol).contains(point)

        case .freehand, .highlighter:
            guard annotation.points.count >= 1 else { return false }
            let p = AnnotationRenderer.outlinePath(for: annotation)
            if p.isEmpty { return false }
            return stroked(p, width: max(annotation.thickness, tol * 2)).contains(point, using: .winding)

        case .text:
            let p = AnnotationRenderer.outlinePath(for: annotation)
            if p.isEmpty { return false }
            if p.contains(point, using: .winding) { return true }
            return stroked(p, width: max(1, tol * 2)).contains(point, using: .winding)

        case .counter:
            let d = annotation.size.counterDiameter
            if hypot(point.x - annotation.start.x, point.y - annotation.start.y) <= d / 2 + tol { return true }
            let nub = AnnotationRenderer.counterNubbinPath(annotation)
            if nub.contains(point, using: .winding) { return true }
            return stroked(nub, width: max(1, tol * 2)).contains(point, using: .winding)
        }
    }

    /// Top-most hit first (the annotation drawn last wins).
    static func topmost(in annotations: [Annotation], at point: CGPoint, tolerance: CGFloat) -> Annotation? {
        for a in annotations.reversed() where hits(a, point: point, tolerance: tolerance) { return a }
        return nil
    }

    // MARK: - Handles

    static func handles(for annotation: Annotation) -> [AnnotationHandle] {
        switch annotation.kind {
        case .text:
            // The bubble is sized by its text, so only the pointer tip is draggable.
            if annotation.textPointer, let tip = annotation.pointerTip {
                return [AnnotationHandle(kind: .pointerTip, position: tip)]
            }
            return []
        case .arrow, .line:
            return [AnnotationHandle(kind: .start, position: annotation.start),
                    AnnotationHandle(kind: .end, position: annotation.end)]
        case .counter:
            return [AnnotationHandle(kind: .nubbin, position: AnnotationRenderer.counterNubbinTip(annotation))]
        case .rectangle, .oval, .blur, .freehand, .highlighter:
            return rectHandles(annotation.bounds.standardized)
        }
    }

    static func rectHandles(_ rect: CGRect) -> [AnnotationHandle] {
        let r = rect.standardized
        return [
            AnnotationHandle(kind: .topLeft, position: CGPoint(x: r.minX, y: r.minY)),
            AnnotationHandle(kind: .top, position: CGPoint(x: r.midX, y: r.minY)),
            AnnotationHandle(kind: .topRight, position: CGPoint(x: r.maxX, y: r.minY)),
            AnnotationHandle(kind: .right, position: CGPoint(x: r.maxX, y: r.midY)),
            AnnotationHandle(kind: .bottomRight, position: CGPoint(x: r.maxX, y: r.maxY)),
            AnnotationHandle(kind: .bottom, position: CGPoint(x: r.midX, y: r.maxY)),
            AnnotationHandle(kind: .bottomLeft, position: CGPoint(x: r.minX, y: r.maxY)),
            AnnotationHandle(kind: .left, position: CGPoint(x: r.minX, y: r.midY)),
        ]
    }

    static func handle(at point: CGPoint, for annotation: Annotation, radius: CGFloat) -> HandleKind? {
        var best: HandleKind?
        var bestD = CGFloat.greatestFiniteMagnitude
        for h in handles(for: annotation) {
            let d = hypot(point.x - h.position.x, point.y - h.position.y)
            if d <= max(1, radius) && d < bestD { bestD = d; best = h.kind }
        }
        return best
    }

    // MARK: - Handle dragging

    static func drag(handle: HandleKind, original: Annotation, to point: CGPoint, shift: Bool) -> Annotation {
        var a = original
        switch handle {
        case .start:
            a.start = constrainEndpoint(point, anchor: original.end, shift: shift)
        case .end:
            a.end = constrainEndpoint(point, anchor: original.start, shift: shift)
        case .pointerTip:
            let r = original.rect.standardized
            a.pointerTip = shift ? constrainEndpoint(point, anchor: CGPoint(x: r.midX, y: r.midY), shift: true) : point
        case .nubbin:
            var ang = atan2(point.x - original.start.x, point.y - original.start.y)
            if shift {
                let step = CGFloat.pi / 4
                ang = (ang / step).rounded() * step
            }
            a.angle = ang
        case .topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left:
            let old = original.bounds.standardized
            let newRect = resized(old, handle: handle, to: point, shift: shift)
            switch original.kind {
            case .freehand, .highlighter:
                a.points = scalePoints(original.points, from: old, to: newRect)
            case .text:
                // Text bubbles are sized by their text; only move the origin.
                a.rect.origin = newRect.origin
            default:
                a.rect = newRect
            }
        }
        return a
    }

    static let minSize: CGFloat = 3

    private static func resized(_ rect: CGRect, handle: HandleKind, to point: CGPoint, shift: Bool) -> CGRect {
        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        var p = point

        if shift, let anchor = oppositeCorner(of: handle, in: rect) {
            let dx = p.x - anchor.x, dy = p.y - anchor.y
            let s = max(abs(dx), abs(dy))
            p = CGPoint(x: anchor.x + (dx < 0 ? -s : s), y: anchor.y + (dy < 0 ? -s : s))
        }

        switch handle {
        case .topLeft:     minX = p.x; minY = p.y
        case .top:         minY = p.y
        case .topRight:    maxX = p.x; minY = p.y
        case .right:       maxX = p.x
        case .bottomRight: maxX = p.x; maxY = p.y
        case .bottom:      maxY = p.y
        case .bottomLeft:  minX = p.x; maxY = p.y
        case .left:        minX = p.x
        default: break
        }

        var r = CGRect(x: min(minX, maxX), y: min(minY, maxY),
                       width: abs(maxX - minX), height: abs(maxY - minY))
        if r.width < minSize {
            let grow = minSize - r.width
            switch handle {
            case .topLeft, .bottomLeft, .left: r.origin.x -= grow
            default: break
            }
            r.size.width = minSize
        }
        if r.height < minSize {
            let grow = minSize - r.height
            switch handle {
            case .topLeft, .topRight, .top: r.origin.y -= grow
            default: break
            }
            r.size.height = minSize
        }
        return r
    }

    private static func oppositeCorner(of handle: HandleKind, in rect: CGRect) -> CGPoint? {
        switch handle {
        case .topLeft:     return CGPoint(x: rect.maxX, y: rect.maxY)
        case .topRight:    return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.minX, y: rect.minY)
        case .bottomLeft:  return CGPoint(x: rect.maxX, y: rect.minY)
        default: return nil
        }
    }

    private static func scalePoints(_ points: [CGPoint], from old: CGRect, to new: CGRect) -> [CGPoint] {
        let sx = old.width > 0.0001 ? new.width / old.width : 1
        let sy = old.height > 0.0001 ? new.height / old.height : 1
        return points.map { CGPoint(x: new.minX + ($0.x - old.minX) * sx,
                                    y: new.minY + ($0.y - old.minY) * sy) }
    }

    /// Snaps to 45 degree steps around `anchor` when shift is held.
    private static func constrainEndpoint(_ point: CGPoint, anchor: CGPoint, shift: Bool) -> CGPoint {
        guard shift else { return point }
        let dx = point.x - anchor.x, dy = point.y - anchor.y
        let len = hypot(dx, dy)
        guard len > 0.0001 else { return point }
        let step = CGFloat.pi / 4
        let ang = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: anchor.x + cos(ang) * len, y: anchor.y + sin(ang) * len)
    }

    // MARK: - Geometry helpers

    static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let l2 = dx * dx + dy * dy
        if l2 < 0.000001 { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2
        t = max(0, min(1, t))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    private static func stroked(_ path: CGPath, width: CGFloat) -> CGPath {
        path.copy(strokingWithWidth: max(0.5, width), lineCap: .round, lineJoin: .round, miterLimit: 10)
    }
}
