import AppKit
import CoreGraphics
@testable import Shot

/// Picking + handle tests. No XCTest: each case is a named throwing closure.
enum HitTestingTests {

    private struct TestFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private static func check(_ cond: Bool, _ msg: String) throws {
        if !cond { throw TestFailure(message: msg) }
    }

    static let suite: (String, [(String, () throws -> Void)]) = ("HitTesting", [

        ("tapered arrow hits in the head and misses far away", {
            var a = Annotation(kind: .arrow)
            a.arrowType = .tapered
            a.thickness = 6
            a.start = CGPoint(x: 20, y: 20)
            a.end = CGPoint(x: 220, y: 20)
            // head length = clamp(6*4, 14, 60) = 24, so 8pt back from the end is inside it
            try check(HitTesting.hits(a, point: CGPoint(x: 212, y: 20), tolerance: 0),
                      "should hit inside the arrow head")
            try check(HitTesting.hits(a, point: CGPoint(x: 120, y: 20), tolerance: 0),
                      "should hit on the shaft centre line")
            try check(!HitTesting.hits(a, point: CGPoint(x: 120, y: 200), tolerance: 4),
                      "should miss far from the arrow")
            try check(!HitTesting.hits(a, point: CGPoint(x: 400, y: 20), tolerance: 4),
                      "should miss past the end")
        }),

        ("thin arrow hits the head and the shaft", {
            var a = Annotation(kind: .arrow)
            a.arrowType = .thin
            a.thickness = 4
            a.start = CGPoint(x: 0, y: 0)
            a.end = CGPoint(x: 100, y: 0)
            try check(HitTesting.hits(a, point: CGPoint(x: 50, y: 1), tolerance: 2), "shaft hit")
            // head length = clamp(4*3.5, 12, 40) = 14, half-width 5.6 at its base (x = 86);
            // (89, 4) is inside the head flare but outside the 4pt shaft.
            try check(HitTesting.hits(a, point: CGPoint(x: 89, y: 4), tolerance: 0), "head hit")
            try check(!HitTesting.hits(a, point: CGPoint(x: 50, y: 60), tolerance: 3), "far miss")
        }),

        ("line hit uses its thickness", {
            var a = Annotation(kind: .line)
            a.thickness = 10
            a.start = CGPoint(x: 0, y: 0)
            a.end = CGPoint(x: 100, y: 0)
            try check(HitTesting.hits(a, point: CGPoint(x: 50, y: 4), tolerance: 0), "inside the stroke")
            try check(!HitTesting.hits(a, point: CGPoint(x: 50, y: 40), tolerance: 2), "outside the stroke")
        }),

        ("rect outline hits the edge but not the centre", {
            var a = Annotation(kind: .rectangle)
            a.shapeStyle = .outline
            a.thickness = 4
            a.rect = CGRect(x: 10, y: 10, width: 100, height: 60)
            try check(HitTesting.hits(a, point: CGPoint(x: 60, y: 10), tolerance: 2), "top edge should hit")
            try check(HitTesting.hits(a, point: CGPoint(x: 10, y: 40), tolerance: 2), "left edge should hit")
            try check(!HitTesting.hits(a, point: CGPoint(x: 60, y: 40), tolerance: 2), "centre must not hit")
        }),

        ("translucent and solid rects hit their centre", {
            var a = Annotation(kind: .rectangle)
            a.rect = CGRect(x: 10, y: 10, width: 100, height: 60)
            a.shapeStyle = .translucent
            try check(HitTesting.hits(a, point: CGPoint(x: 60, y: 40), tolerance: 0), "translucent centre should hit")
            a.shapeStyle = .solid
            try check(HitTesting.hits(a, point: CGPoint(x: 60, y: 40), tolerance: 0), "solid centre should hit")
            try check(!HitTesting.hits(a, point: CGPoint(x: 300, y: 300), tolerance: 4), "far miss")
        }),

        ("oval outline follows the ellipse, not the box", {
            var a = Annotation(kind: .oval)
            a.shapeStyle = .outline
            a.thickness = 3
            a.rect = CGRect(x: 0, y: 0, width: 100, height: 100)
            try check(HitTesting.hits(a, point: CGPoint(x: 50, y: 0), tolerance: 2), "top of the ellipse")
            try check(!HitTesting.hits(a, point: CGPoint(x: 0, y: 0), tolerance: 2), "box corner is outside the ellipse")
            try check(!HitTesting.hits(a, point: CGPoint(x: 50, y: 50), tolerance: 2), "centre of an outline oval")
        }),

        ("blur hits anywhere inside", {
            var a = Annotation(kind: .blur)
            a.rect = CGRect(x: 10, y: 10, width: 50, height: 50)
            try check(HitTesting.hits(a, point: CGPoint(x: 35, y: 35), tolerance: 0), "inside")
            try check(!HitTesting.hits(a, point: CGPoint(x: 200, y: 200), tolerance: 2), "outside")
        }),

        ("counter hits the badge", {
            var a = Annotation(kind: .counter)
            a.size = .m
            a.start = CGPoint(x: 100, y: 100)
            try check(HitTesting.hits(a, point: CGPoint(x: 100, y: 100), tolerance: 0), "centre")
            try check(HitTesting.hits(a, point: CGPoint(x: 100 + SizeStep.m.counterDiameter / 2 - 1, y: 100), tolerance: 0), "rim")
            try check(!HitTesting.hits(a, point: CGPoint(x: 200, y: 100), tolerance: 2), "far miss")
        }),

        ("freehand hits near the stroke only", {
            var a = Annotation(kind: .freehand)
            a.thickness = 4
            a.points = (0...20).map { CGPoint(x: CGFloat($0) * 5, y: 50) }
            try check(HitTesting.hits(a, point: CGPoint(x: 50, y: 51), tolerance: 2), "on the stroke")
            try check(!HitTesting.hits(a, point: CGPoint(x: 50, y: 120), tolerance: 3), "far from the stroke")
        }),

        ("topmost returns the last drawn hit", {
            var a = Annotation(kind: .rectangle)
            a.shapeStyle = .solid
            a.rect = CGRect(x: 0, y: 0, width: 100, height: 100)
            var b = Annotation(kind: .rectangle)
            b.shapeStyle = .solid
            b.rect = CGRect(x: 50, y: 50, width: 100, height: 100)
            let top = HitTesting.topmost(in: [a, b], at: CGPoint(x: 75, y: 75), tolerance: 0)
            try check(top?.id == b.id, "later annotation should win")
            let only = HitTesting.topmost(in: [a, b], at: CGPoint(x: 10, y: 10), tolerance: 0)
            try check(only?.id == a.id, "only the first covers (10,10)")
            try check(HitTesting.topmost(in: [a, b], at: CGPoint(x: 400, y: 400), tolerance: 2) == nil, "no hit")
        }),

        ("rect kinds expose eight handles, text only its pointer tip", {
            var r = Annotation(kind: .rectangle)
            r.rect = CGRect(x: 0, y: 0, width: 40, height: 20)
            try check(HitTesting.handles(for: r).count == 8, "rect should have 8 handles")

            var t = Annotation(kind: .text)
            t.rect = CGRect(x: 0, y: 0, width: 40, height: 20)
            t.textPointer = true
            t.pointerTip = CGPoint(x: -20, y: 60)
            let th = HitTesting.handles(for: t)
            try check(th.count == 1 && th[0].kind == .pointerTip, "text should expose only the pointer tip")
            t.textPointer = false
            try check(HitTesting.handles(for: t).isEmpty, "text without a pointer has no handles")

            var arrow = Annotation(kind: .arrow)
            arrow.start = .zero
            arrow.end = CGPoint(x: 10, y: 10)
            let ah = HitTesting.handles(for: arrow).map(\.kind)
            try check(ah == [.start, .end], "arrow handles should be start/end, got \(ah)")

            var c = Annotation(kind: .counter)
            c.start = CGPoint(x: 5, y: 5)
            let ch = HitTesting.handles(for: c)
            try check(ch.count == 1 && ch[0].kind == .nubbin, "counter should expose the nubbin")
        }),

        ("handle(at:) finds the nearest handle inside the radius", {
            var r = Annotation(kind: .rectangle)
            r.rect = CGRect(x: 0, y: 0, width: 100, height: 50)
            try check(HitTesting.handle(at: CGPoint(x: 99, y: 49), for: r, radius: 6) == .bottomRight,
                      "should find bottomRight")
            try check(HitTesting.handle(at: CGPoint(x: 50, y: 25), for: r, radius: 6) == nil,
                      "centre is not a handle")
        }),

        ("dragging bottomRight grows the rect", {
            var a = Annotation(kind: .rectangle)
            a.rect = CGRect(x: 10, y: 10, width: 50, height: 30)
            let moved = HitTesting.drag(handle: .bottomRight, original: a, to: CGPoint(x: 120, y: 90), shift: false)
            try check(moved.rect.origin == CGPoint(x: 10, y: 10), "origin should not move, got \(moved.rect.origin)")
            try check(moved.rect.width == 110 && moved.rect.height == 80,
                      "expected 110x80, got \(moved.rect.size)")
            try check(moved.rect.width > a.rect.width && moved.rect.height > a.rect.height, "should grow")
        }),

        ("dragging topLeft moves the origin and keeps a minimum size", {
            var a = Annotation(kind: .oval)
            a.rect = CGRect(x: 10, y: 10, width: 50, height: 30)
            let moved = HitTesting.drag(handle: .topLeft, original: a, to: CGPoint(x: 0, y: 0), shift: false)
            try check(moved.rect == CGRect(x: 0, y: 0, width: 60, height: 40), "got \(moved.rect)")
            let tiny = HitTesting.drag(handle: .topLeft, original: a, to: CGPoint(x: 60, y: 40), shift: false)
            try check(tiny.rect.width >= HitTesting.minSize && tiny.rect.height >= HitTesting.minSize,
                      "min size enforced, got \(tiny.rect)")
        }),

        ("shift-dragging a corner makes it square", {
            var a = Annotation(kind: .rectangle)
            a.rect = CGRect(x: 0, y: 0, width: 40, height: 40)
            let moved = HitTesting.drag(handle: .bottomRight, original: a, to: CGPoint(x: 100, y: 30), shift: true)
            try check(abs(moved.rect.width - moved.rect.height) < 0.001,
                      "expected a square, got \(moved.rect.size)")
        }),

        ("dragging a freehand handle scales its points", {
            var a = Annotation(kind: .freehand)
            a.points = [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0), CGPoint(x: 50, y: 50), CGPoint(x: 0, y: 50)]
            let moved = HitTesting.drag(handle: .bottomRight, original: a, to: CGPoint(x: 100, y: 100), shift: false)
            try check(moved.points.count == 4, "point count preserved")
            try check(abs(moved.points[2].x - 100) < 0.001 && abs(moved.points[2].y - 100) < 0.001,
                      "far corner should follow the handle, got \(moved.points[2])")
            try check(abs(moved.points[0].x) < 0.001 && abs(moved.points[0].y) < 0.001,
                      "anchor corner stays put")
        }),

        ("dragging the nubbin sets the angle", {
            var a = Annotation(kind: .counter)
            a.start = CGPoint(x: 100, y: 100)
            a.angle = 0
            let down = HitTesting.drag(handle: .nubbin, original: a, to: CGPoint(x: 100, y: 180), shift: false)
            try check(abs(down.angle) < 0.001, "straight down is angle 0, got \(down.angle)")
            let right = HitTesting.drag(handle: .nubbin, original: a, to: CGPoint(x: 180, y: 100), shift: false)
            try check(abs(right.angle - .pi / 2) < 0.001, "right is +90 degrees, got \(right.angle)")
            let up = HitTesting.drag(handle: .nubbin, original: a, to: CGPoint(x: 100, y: 20), shift: false)
            try check(abs(abs(up.angle) - .pi) < 0.001, "up is +-180 degrees, got \(up.angle)")
            let snapped = HitTesting.drag(handle: .nubbin, original: a, to: CGPoint(x: 170, y: 180), shift: true)
            let step = CGFloat.pi / 4
            try check(abs((snapped.angle / step) - (snapped.angle / step).rounded()) < 0.001,
                      "shift should snap to 45 degrees, got \(snapped.angle)")
        }),

        ("dragging start/end moves the endpoints", {
            var a = Annotation(kind: .arrow)
            a.start = CGPoint(x: 0, y: 0)
            a.end = CGPoint(x: 100, y: 0)
            let e = HitTesting.drag(handle: .end, original: a, to: CGPoint(x: 40, y: 40), shift: false)
            try check(e.end == CGPoint(x: 40, y: 40) && e.start == a.start, "end moved only")
            let s = HitTesting.drag(handle: .start, original: a, to: CGPoint(x: -10, y: -10), shift: false)
            try check(s.start == CGPoint(x: -10, y: -10) && s.end == a.end, "start moved only")
            let snapped = HitTesting.drag(handle: .end, original: a, to: CGPoint(x: 100, y: 12), shift: true)
            try check(abs(snapped.end.y) < 0.001, "shift should snap back to horizontal, got \(snapped.end)")
        }),

        ("dragging the pointer tip moves only the tip", {
            var a = Annotation(kind: .text)
            a.rect = CGRect(x: 100, y: 100, width: 50, height: 24)
            a.textPointer = true
            a.pointerTip = CGPoint(x: 60, y: 180)
            let moved = HitTesting.drag(handle: .pointerTip, original: a, to: CGPoint(x: 200, y: 220), shift: false)
            try check(moved.pointerTip == CGPoint(x: 200, y: 220), "tip should follow the mouse")
            try check(moved.rect == a.rect, "bubble must not resize")
        }),

        ("text label hits its bubble and its tail", {
            var a = Annotation(kind: .text)
            a.text = "test"
            a.textStyle = .label
            a.textPointer = true
            a.rect = CGRect(x: 100, y: 100, width: 0, height: 0)
            a.rect = AnnotationRenderer.measureTextRect(for: a)
            a.pointerTip = AnnotationRenderer.defaultPointerTip(forBubble: a.rect)
            try check(HitTesting.hits(a, point: CGPoint(x: a.rect.midX, y: a.rect.midY), tolerance: 0),
                      "bubble centre should hit")
            try check(HitTesting.hits(a, point: a.pointerTip!, tolerance: 3), "the tail tip should hit")
            try check(!HitTesting.hits(a, point: CGPoint(x: a.rect.maxX + 80, y: a.rect.minY - 80), tolerance: 2),
                      "far miss")
        }),
    ])
}
