import AppKit
import CoreGraphics
@testable import Shot

/// Renderer + flattener tests. No XCTest: each case is a named throwing closure.
enum RendererTests {

    private struct TestFailure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    private static func check(_ cond: Bool, _ msg: String) throws {
        if !cond { throw TestFailure(message: msg) }
    }

    // MARK: - Fixtures

    private static func solidImage(width: Int, height: Int, gray: CGFloat = 0.5) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// 8px checkerboard so a blur visibly changes the pixels it touches.
    private static func checkerImage(width: Int, height: Int) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        for y in stride(from: 0, to: height, by: 8) {
            for x in stride(from: 0, to: width, by: 8) where ((x / 8) + (y / 8)) % 2 == 0 {
                ctx.fill(CGRect(x: x, y: y, width: 8, height: 8))
            }
        }
        return ctx.makeImage()!
    }

    /// Reads one pixel (top-left origin, pixel coordinates) as RGBA 0...255.
    private static func pixel(_ image: CGImage, x: Int, y: Int) -> (Int, Int, Int, Int) {
        var data = [UInt8](repeating: 0, count: 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        data.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                bytesPerRow: 4, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .none
            // Draw the source so that (x, y) lands in the single destination pixel.
            ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y),
                                       width: image.width, height: image.height))
        }
        return (Int(data[0]), Int(data[1]), Int(data[2]), Int(data[3]))
    }

    // MARK: - Suite

    static let suite: (String, [(String, () throws -> Void)]) = ("Renderer", [

        ("flatten keeps pixel size", {
            let img = solidImage(width: 120, height: 80)
            let out = ImageFlattener.flatten(image: img, pixelScale: 2, annotations: [])
            try check(out.width == 120 && out.height == 80,
                      "expected 120x80, got \(out.width)x\(out.height)")
        }),

        ("flatten draws a solid red rect", {
            let img = solidImage(width: 200, height: 100, gray: 0.5)     // 200x100 px @2x = 100x50 pt
            var a = Annotation(kind: .rectangle)
            a.rect = CGRect(x: 10, y: 10, width: 40, height: 20)          // points
            a.shapeStyle = .solid
            a.color = .shottrRed
            let out = ImageFlattener.flatten(image: img, pixelScale: 2, annotations: [a])
            try check(out.width == 200 && out.height == 100, "wrong pixel size")
            // point (30, 20) -> pixel (60, 40)
            let p = pixel(out, x: 60, y: 40)
            try check(p.0 > 200 && p.1 < 80 && p.2 < 80, "expected red inside rect, got \(p)")
            let outside = pixel(out, x: 180, y: 90)
            try check(abs(outside.0 - 128) < 20 && abs(outside.1 - 128) < 20,
                      "expected untouched gray outside rect, got \(outside)")
        }),

        ("flatten at scale 1 matches point coordinates", {
            let img = solidImage(width: 60, height: 60, gray: 0.5)
            var a = Annotation(kind: .rectangle)
            a.rect = CGRect(x: 5, y: 5, width: 20, height: 20)
            a.shapeStyle = .solid
            let out = ImageFlattener.flatten(image: img, pixelScale: 1, annotations: [a])
            let inside = pixel(out, x: 15, y: 15)
            try check(inside.0 > 200 && inside.1 < 80, "expected red at (15,15), got \(inside)")
        }),

        ("measureTextRect grows with the text", {
            var a = Annotation(kind: .text)
            a.textStyle = .label
            a.size = .m
            a.text = "a"
            let small = AnnotationRenderer.measureTextRect(for: a)
            a.text = "aaaaaaaaaaaaaaaaaaaa"
            let big = AnnotationRenderer.measureTextRect(for: a)
            try check(big.width > small.width + 10, "wide text should be wider: \(small.width) vs \(big.width)")
            try check(abs(big.height - small.height) < 1, "single line height should not change")
            a.text = "a\nb\nc"
            let tall = AnnotationRenderer.measureTextRect(for: a)
            try check(tall.height > small.height * 2, "three lines should be much taller: \(tall.height)")
        }),

        ("measureTextRect grows with the size step and pads the bubble", {
            var a = Annotation(kind: .text)
            a.textStyle = .label
            a.text = "test"
            a.fontSize = 16
            let s = AnnotationRenderer.measureTextRect(for: a)
            a.fontSize = 42
            let xl = AnnotationRenderer.measureTextRect(for: a)
            try check(xl.width > s.width && xl.height > s.height, "xl should be bigger than s")
            a.size = .m
            a.textStyle = .plain
            let plain = AnnotationRenderer.measureTextRect(for: a)
            a.textStyle = .label
            let label = AnnotationRenderer.measureTextRect(for: a)
            try check(abs(label.width - plain.width - AnnotationRenderer.labelPaddingH * 2) < 1.5,
                      "label should add horizontal padding")
            try check(abs(label.height - plain.height - AnnotationRenderer.labelPaddingV * 2) < 1.5,
                      "label should add vertical padding")
        }),

        ("measureTextRect keeps the annotation origin", {
            var a = Annotation(kind: .text)
            a.text = "hello"
            a.rect = CGRect(x: 33, y: 44, width: 0, height: 0)
            let r = AnnotationRenderer.measureTextRect(for: a)
            try check(r.origin == CGPoint(x: 33, y: 44), "origin must be preserved, got \(r.origin)")
        }),

        ("blur stays inside its rect", {
            let img = checkerImage(width: 120, height: 120)
            var a = Annotation(kind: .blur)
            a.rect = CGRect(x: 20, y: 20, width: 40, height: 40)
            a.blurMode = .mosaic
            a.blurStrength = 0.5
            let out = ImageFlattener.flatten(image: img, pixelScale: 1, annotations: [a])

            // A pixel well outside the rect must be byte-identical to the source.
            for (x, y) in [(5, 5), (100, 100), (10, 70), (70, 10), (61, 40), (40, 61)] {
                let before = pixel(img, x: x, y: y)
                let after = pixel(out, x: x, y: y)
                try check(before == after, "pixel (\(x),\(y)) outside rect changed: \(before) -> \(after)")
            }
            // Something inside must actually have changed (checker -> averaged blocks).
            var changed = false
            for x in 22..<58 where !changed {
                for y in 22..<58 where !changed {
                    if pixel(img, x: x, y: y) != pixel(out, x: x, y: y) { changed = true }
                }
            }
            try check(changed, "mosaic blur did not change anything inside the rect")
        }),

        ("gaussian blur stays inside its rect", {
            let img = checkerImage(width: 120, height: 120)
            var a = Annotation(kind: .blur)
            a.rect = CGRect(x: 30, y: 30, width: 40, height: 40)
            a.blurMode = .gaussian
            a.blurStrength = 0.7
            let out = ImageFlattener.flatten(image: img, pixelScale: 1, annotations: [a])
            for (x, y) in [(5, 5), (110, 110), (28, 50), (72, 50)] {
                try check(pixel(img, x: x, y: y) == pixel(out, x: x, y: y),
                          "pixel (\(x),\(y)) outside gaussian rect changed")
            }
        }),

        ("outlinePath matches the drawn geometry", {
            var rect = Annotation(kind: .rectangle)
            rect.rect = CGRect(x: 10, y: 20, width: 50, height: 30)
            let rb = AnnotationRenderer.outlinePath(for: rect).boundingBox
            try check(abs(rb.minX - 10) < 0.6 && abs(rb.minY - 20) < 0.6
                      && abs(rb.width - 50) < 1.2 && abs(rb.height - 30) < 1.2,
                      "rect outline bounds wrong: \(rb)")

            var oval = Annotation(kind: .oval)
            oval.rect = CGRect(x: 0, y: 0, width: 40, height: 20)
            let ob = AnnotationRenderer.outlinePath(for: oval).boundingBox
            try check(abs(ob.width - 40) < 0.6 && abs(ob.height - 20) < 0.6, "oval bounds wrong: \(ob)")

            var counter = Annotation(kind: .counter)
            counter.start = CGPoint(x: 100, y: 100)
            counter.size = .m
            let cb = AnnotationRenderer.outlinePath(for: counter).boundingBox
            try check(abs(cb.midX - 100) < 0.5 && abs(cb.width - SizeStep.m.counterDiameter) < 0.5,
                      "counter circle wrong: \(cb)")
        }),

        ("tapered arrow head sits at the end point", {
            var a = Annotation(kind: .arrow)
            a.arrowType = .tapered
            a.thickness = 6
            a.start = CGPoint(x: 10, y: 10)
            a.end = CGPoint(x: 110, y: 10)
            let p = AnnotationRenderer.taperedArrowPath(a)
            try check(p.contains(a.end, using: .winding) || p.boundingBox.maxX >= 109.5,
                      "arrow polygon should reach the end point: \(p.boundingBox)")
            let half = max(1.5, a.thickness * 0.35) / 2
            try check(p.boundingBox.height > half * 2 + 4, "head should be wider than the tail")
        }),

        ("counter nubbin points where the angle says", {
            var a = Annotation(kind: .counter)
            a.start = CGPoint(x: 50, y: 50)
            a.size = .m
            a.angle = 0
            let down = AnnotationRenderer.counterNubbinTip(a)
            try check(abs(down.x - 50) < 0.001 && down.y > 50, "angle 0 should point down, got \(down)")
            a.angle = .pi / 2
            let right = AnnotationRenderer.counterNubbinTip(a)
            try check(right.x > 50 && abs(right.y - 50) < 0.001,
                      "angle +90 should point right (counter-clockwise on screen), got \(right)")
        }),

        ("defaultPointerTip lands below-left of the bubble", {
            let bubble = CGRect(x: 200, y: 100, width: 40, height: 26)
            let tip = AnnotationRenderer.defaultPointerTip(forBubble: bubble)
            try check(tip.x < bubble.minX, "tip should be left of the bubble")
            try check(tip.y > bubble.maxY, "tip should be below the bubble")
        }),

        ("highlighter renders translucent (does not fully cover)", {
            let img = solidImage(width: 60, height: 60, gray: 1.0)
            var a = Annotation(kind: .highlighter)
            a.color = .highlighterYellow
            a.thickness = 20
            a.points = [CGPoint(x: 5, y: 30), CGPoint(x: 55, y: 30)]
            let out = ImageFlattener.flatten(image: img, pixelScale: 1, annotations: [a])
            let p = pixel(out, x: 30, y: 30)
            try check(p.2 < 200, "blue channel should drop under the yellow marker, got \(p)")
            try check(p.0 > 200 && p.1 > 150, "red/green should stay high under yellow, got \(p)")
        }),

        ("text label paints its bubble color", {
            let img = solidImage(width: 200, height: 100, gray: 1.0)
            var a = Annotation(kind: .text)
            a.text = "test"
            a.textStyle = .label
            a.textPointer = false
            a.color = .shottrRed
            a.rect = CGRect(x: 20, y: 20, width: 0, height: 0)
            a.rect = AnnotationRenderer.measureTextRect(for: a)
            let out = ImageFlattener.flatten(image: img, pixelScale: 1, annotations: [a])
            let p = pixel(out, x: Int(a.rect.minX) + 3, y: Int(a.rect.midY))
            try check(p.0 > 180 && p.1 < 100, "expected red bubble edge, got \(p)")
        }),
    ])
}
