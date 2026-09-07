import AppKit
import CoreGraphics
import CoreImage

/// Draws annotations into an already-flipped CGContext (origin top-left, y down,
/// 1 unit = 1 image point). Used by both the live canvas and `ImageFlattener`,
/// so what you see is exactly what you export.
@MainActor
enum AnnotationRenderer {

    // MARK: - Entry points

    static func draw(_ annotations: [Annotation], sourceImage: CGImage, pixelScale: CGFloat, in ctx: CGContext) {
        for a in annotations {
            draw(a, sourceImage: sourceImage, pixelScale: pixelScale, in: ctx)
        }
    }

    static func draw(_ annotation: Annotation, sourceImage: CGImage, pixelScale: CGFloat, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        ctx.setLineJoin(.round)
        switch annotation.kind {
        case .arrow:       drawArrow(annotation, in: ctx)
        case .line:        drawLine(annotation, in: ctx)
        case .rectangle:   drawShape(annotation, in: ctx)
        case .oval:        drawShape(annotation, in: ctx)
        case .freehand:    drawFreehand(annotation, in: ctx)
        case .highlighter: drawHighlighter(annotation, in: ctx)
        case .blur:        drawBlur(annotation, sourceImage: sourceImage, pixelScale: pixelScale, in: ctx)
        case .text:        drawText(annotation, in: ctx)
        case .counter:     drawCounter(annotation, in: ctx)
        }
        ctx.restoreGState()
    }

    // MARK: - Outline path (hover glow, selection outline, hit testing)

    static func outlinePath(for annotation: Annotation) -> CGPath {
        switch annotation.kind {
        case .arrow:
            if annotation.arrowType == .tapered { return taperedArrowPath(annotation) }
            let p = CGMutablePath()
            p.move(to: annotation.start)
            p.addLine(to: annotation.end)
            p.addPath(thinArrowHeadPath(annotation))
            return p
        case .line:
            let p = CGMutablePath()
            p.move(to: annotation.start)
            p.addLine(to: annotation.end)
            return p
        case .rectangle:
            return roundedRectPath(annotation.rect.standardized, radius: rectCornerRadius(annotation.rect))
        case .oval:
            return CGPath(ellipseIn: annotation.rect.standardized, transform: nil)
        case .blur:
            return CGPath(rect: annotation.rect.standardized, transform: nil)
        case .freehand, .highlighter:
            return smoothedPath(annotation.points)
        case .text:
            return textOutlinePath(annotation)
        case .counter:
            let d = annotation.size.counterDiameter
            return CGPath(ellipseIn: CGRect(x: annotation.start.x - d / 2, y: annotation.start.y - d / 2,
                                            width: d, height: d), transform: nil)
        }
    }

    // MARK: - Emphasis

    static func drawEmphasis(for annotation: Annotation, hovered: Bool, selected: Bool, accent: CGColor, in ctx: CGContext) {
        guard hovered || selected else { return }
        let path = outlinePath(for: annotation)
        guard !path.isEmpty else { return }

        ctx.saveGState()
        ctx.setShouldAntialias(true)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        let base: CGFloat
        switch annotation.kind {
        case .arrow, .line, .freehand, .highlighter: base = max(annotation.thickness, 2)
        default: base = 2
        }

        if hovered {
            let comps = accent.components ?? [0, 0.48, 1, 1]
            let glow = CGColor(srgbRed: comps.count > 0 ? comps[0] : 0,
                               green: comps.count > 1 ? comps[1] : 0.48,
                               blue: comps.count > 2 ? comps[2] : 1,
                               alpha: 0.20)
            let glow2 = CGColor(srgbRed: comps.count > 0 ? comps[0] : 0,
                                green: comps.count > 1 ? comps[1] : 0.48,
                                blue: comps.count > 2 ? comps[2] : 1,
                                alpha: 0.32)
            ctx.setStrokeColor(glow)
            ctx.setLineWidth(base + 9)
            ctx.addPath(path)
            ctx.strokePath()
            ctx.setStrokeColor(glow2)
            ctx.setLineWidth(base + 4.5)
            ctx.addPath(path)
            ctx.strokePath()
        }

        if selected {
            ctx.setStrokeColor(accent)
            ctx.setLineWidth(1.5)
            ctx.addPath(path)
            ctx.strokePath()
        }

        ctx.restoreGState()
    }

    // MARK: - Arrow

    private static func drawArrow(_ a: Annotation, in ctx: CGContext) {
        let (_, len) = unit(from: a.start, to: a.end)
        guard len > 0.5 else { return }
        ctx.setFillColor(a.color.cgColor)
        ctx.setStrokeColor(a.color.cgColor)
        if a.arrowType == .tapered {
            ctx.addPath(taperedArrowPath(a))
            ctx.fillPath(using: .winding)
        } else {
            let head = thinArrowHeadPath(a)
            let stop = thinArrowLineEnd(a)
            ctx.setLineCap(.round)
            ctx.setLineWidth(max(0.75, a.thickness))
            ctx.move(to: a.start)
            ctx.addLine(to: stop)
            ctx.strokePath()
            ctx.addPath(head)
            ctx.fillPath(using: .winding)
        }
    }

    /// Filled tapered polygon: narrow at `start`, widening into a triangular head at `end`.
    static func taperedArrowPath(_ a: Annotation) -> CGPath {
        let p = CGMutablePath()
        let (d, len) = unit(from: a.start, to: a.end)
        guard len > 0.5 else { return p }
        let t = max(0.5, a.thickness)
        let headLen = min(min(max(t * 4, 14), 60), len * 0.92)
        let headHalf = headLen * 0.45
        let tailHalf = max(1.5, t * 0.35) / 2
        let shaftHalf = max(tailHalf, min(t * 0.9, headHalf * 0.65))
        let n = CGPoint(x: -d.y, y: d.x)
        let base = CGPoint(x: a.end.x - d.x * headLen, y: a.end.y - d.y * headLen)
        func off(_ o: CGPoint, _ s: CGFloat) -> CGPoint { CGPoint(x: o.x + n.x * s, y: o.y + n.y * s) }
        p.move(to: off(a.start, tailHalf))
        p.addLine(to: off(base, shaftHalf))
        p.addLine(to: off(base, headHalf))
        p.addLine(to: a.end)
        p.addLine(to: off(base, -headHalf))
        p.addLine(to: off(base, -shaftHalf))
        p.addLine(to: off(a.start, -tailHalf))
        p.closeSubpath()
        return p
    }

    static func thinArrowHeadPath(_ a: Annotation) -> CGPath {
        let p = CGMutablePath()
        let (d, len) = unit(from: a.start, to: a.end)
        guard len > 0.5 else { return p }
        let t = max(0.5, a.thickness)
        let headLen = min(min(max(t * 3.5, 12), 40), len * 0.95)
        let headHalf = headLen * 0.4
        let n = CGPoint(x: -d.y, y: d.x)
        let base = CGPoint(x: a.end.x - d.x * headLen, y: a.end.y - d.y * headLen)
        p.move(to: a.end)
        p.addLine(to: CGPoint(x: base.x + n.x * headHalf, y: base.y + n.y * headHalf))
        p.addLine(to: CGPoint(x: base.x - n.x * headHalf, y: base.y - n.y * headHalf))
        p.closeSubpath()
        return p
    }

    /// Where the thin arrow's shaft stops: inside the head, so there is no seam.
    private static func thinArrowLineEnd(_ a: Annotation) -> CGPoint {
        let (d, len) = unit(from: a.start, to: a.end)
        guard len > 0.5 else { return a.end }
        let t = max(0.5, a.thickness)
        let headLen = min(min(max(t * 3.5, 12), 40), len * 0.95)
        let inset = headLen * 0.55
        return CGPoint(x: a.end.x - d.x * inset, y: a.end.y - d.y * inset)
    }

    // MARK: - Line

    private static func drawLine(_ a: Annotation, in ctx: CGContext) {
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setLineWidth(max(0.75, a.thickness))
        ctx.setLineCap(.round)
        ctx.move(to: a.start)
        ctx.addLine(to: a.end)
        ctx.strokePath()
    }

    // MARK: - Rectangle / oval

    static func rectCornerRadius(_ r: CGRect) -> CGFloat {
        let s = r.standardized
        return min(2, min(s.width, s.height) / 2)
    }

    private static func drawShape(_ a: Annotation, in ctx: CGContext) {
        let r = a.rect.standardized
        guard r.width > 0, r.height > 0 else { return }
        let path = outlinePath(for: a)
        switch a.shapeStyle {
        case .outline:
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setLineWidth(max(0.75, a.thickness))
            ctx.addPath(path)
            ctx.strokePath()
        case .translucent:
            ctx.setFillColor(a.color.withAlpha(a.color.alpha * 0.35).cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.setStrokeColor(a.color.cgColor)
            ctx.setLineWidth(max(0.75, a.thickness))
            ctx.addPath(path)
            ctx.strokePath()
        case .solid:
            ctx.setFillColor(a.color.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
        }
    }

    // MARK: - Freehand / highlighter

    private static func drawFreehand(_ a: Annotation, in ctx: CGContext) {
        guard !a.points.isEmpty else { return }
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setLineWidth(max(0.75, a.thickness))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if a.points.count == 1 {
            let r = max(0.75, a.thickness) / 2
            ctx.setFillColor(a.color.cgColor)
            ctx.fillEllipse(in: CGRect(x: a.points[0].x - r, y: a.points[0].y - r, width: r * 2, height: r * 2))
            return
        }
        ctx.addPath(smoothedPath(a.points))
        ctx.strokePath()
    }

    private static func drawHighlighter(_ a: Annotation, in ctx: CGContext) {
        guard !a.points.isEmpty else { return }
        ctx.saveGState()
        ctx.setBlendMode(.multiply)
        ctx.setStrokeColor(a.color.withAlpha(0.45).cgColor)
        ctx.setLineWidth(max(1, a.thickness))
        ctx.setLineCap(.square)
        ctx.setLineJoin(.round)
        if a.points.count == 1 {
            let r = max(1, a.thickness) / 2
            ctx.setFillColor(a.color.withAlpha(0.45).cgColor)
            ctx.fill(CGRect(x: a.points[0].x - r, y: a.points[0].y - r, width: r * 2, height: r * 2))
        } else {
            ctx.addPath(smoothedPath(a.points))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// Catmull-Rom smoothed path through the sample points.
    static func smoothedPath(_ raw: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        var pts: [CGPoint] = []
        for p in raw {
            if let last = pts.last, abs(last.x - p.x) < 0.01, abs(last.y - p.y) < 0.01 { continue }
            pts.append(p)
        }
        guard pts.count > 1 else {
            if let p = pts.first { path.move(to: p); path.addLine(to: p) }
            return path
        }
        path.move(to: pts[0])
        if pts.count == 2 {
            path.addLine(to: pts[1])
            return path
        }
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = pts[min(i + 2, pts.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }

    // MARK: - Blur

    private struct BlurKey: Hashable {
        var id: UUID
        var x: Int, y: Int, w: Int, h: Int
        var mode: String
        var strength: Int
        var scale: Int
        var imageID: UInt
    }

    private static var blurCache: [BlurKey: CGImage] = [:]
    private static var blurCacheOrder: [BlurKey] = []
    private static let ciContext: CIContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Drops every cached blur tile (call when the document image is replaced).
    static func invalidateBlurCache() {
        blurCache.removeAll()
        blurCacheOrder.removeAll()
    }

    private static func drawBlur(_ a: Annotation, sourceImage: CGImage, pixelScale: CGFloat, in ctx: CGContext) {
        let r = a.rect.standardized
        guard r.width >= 1, r.height >= 1 else { return }
        guard let img = blurredImage(a, sourceImage: sourceImage, pixelScale: pixelScale) else { return }
        ctx.saveGState()
        ctx.clip(to: r)
        ctx.interpolationQuality = a.blurMode == .mosaic ? .none : .high
        // ctx is flipped (y down); flip back locally so the bitmap lands upright.
        ctx.translateBy(x: r.minX, y: r.minY + r.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        ctx.restoreGState()
    }

    private static func blurredImage(_ a: Annotation, sourceImage: CGImage, pixelScale: CGFloat) -> CGImage? {
        let scale = max(1, pixelScale)
        let r = a.rect.standardized
        var px = CGRect(x: (r.minX * scale).rounded(.down), y: (r.minY * scale).rounded(.down),
                        width: (r.width * scale).rounded(.up), height: (r.height * scale).rounded(.up))
        px = px.intersection(CGRect(x: 0, y: 0, width: sourceImage.width, height: sourceImage.height))
        guard px.width >= 1, px.height >= 1 else { return nil }

        let key = BlurKey(id: a.id,
                          x: Int(px.minX), y: Int(px.minY), w: Int(px.width), h: Int(px.height),
                          mode: a.blurMode.rawValue,
                          strength: Int((a.blurStrength * 1000).rounded()),
                          scale: Int((scale * 100).rounded()),
                          imageID: UInt(bitPattern: Int(bitPattern: Unmanaged.passUnretained(sourceImage).toOpaque())))
        if let cached = blurCache[key] { return cached }

        guard let crop = sourceImage.cropping(to: px) else { return nil }
        let result: CGImage?
        switch a.blurMode {
        case .mosaic:  result = mosaic(crop, strength: a.blurStrength, pixelScale: scale)
        case .gaussian: result = gaussian(crop, strength: a.blurStrength, pixelScale: scale)
        }
        guard let out = result else { return nil }
        blurCache[key] = out
        blurCacheOrder.append(key)
        while blurCacheOrder.count > 48 {
            let old = blurCacheOrder.removeFirst()
            blurCache.removeValue(forKey: old)
        }
        return out
    }

    private static func mosaic(_ image: CGImage, strength: CGFloat, pixelScale: CGFloat) -> CGImage? {
        let w = image.width, h = image.height
        var block = Int(((4 + max(0, min(1, strength)) * 36) * pixelScale).rounded())
        block = max(2, block)
        block = min(block, max(1, min(w, h) / 2))       // keep at least 2x2 blocks
        guard block >= 1 else { return image }
        let sw = max(1, Int((Double(w) / Double(block)).rounded(.up)))
        let sh = max(1, Int((Double(h) / Double(block)).rounded(.up)))
        guard let small = makeContext(width: sw, height: sh) else { return nil }
        small.interpolationQuality = .medium
        small.draw(image, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        guard let tiny = small.makeImage(), let big = makeContext(width: w, height: h) else { return nil }
        big.interpolationQuality = .none
        big.draw(tiny, in: CGRect(x: 0, y: 0, width: w, height: h))
        return big.makeImage()
    }

    private static func gaussian(_ image: CGImage, strength: CGFloat, pixelScale: CGFloat) -> CGImage? {
        let radius = (2 + max(0, min(1, strength)) * 28) * pixelScale
        let ci = CIImage(cgImage: image)
        let extent = ci.extent
        if let filter = CIFilter(name: "CIGaussianBlur") {
            filter.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
            filter.setValue(radius, forKey: kCIInputRadiusKey)
            if let out = filter.outputImage,
               let cg = ciContext.createCGImage(out, from: extent) {
                return cg
            }
        }
        return boxBlur(image, radius: Int(radius.rounded()))
    }

    /// Fallback when CoreImage is unavailable: three box passes ~= gaussian.
    private static func boxBlur(_ image: CGImage, radius: Int) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let ctx = makeContext(width: w, height: h) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let bpr = ctx.bytesPerRow
        let buf = data.bindMemory(to: UInt8.self, capacity: bpr * h)
        let r = max(1, min(radius, min(w, h) / 2))
        var tmp = [UInt8](repeating: 0, count: bpr * h)
        for _ in 0..<3 {
            // horizontal
            for y in 0..<h {
                for x in 0..<w {
                    var sums = [Int](repeating: 0, count: 4)
                    var n = 0
                    for dx in -r...r {
                        let sx = x + dx
                        guard sx >= 0, sx < w else { continue }
                        let o = y * bpr + sx * 4
                        for c in 0..<4 { sums[c] += Int(buf[o + c]) }
                        n += 1
                    }
                    let o = y * bpr + x * 4
                    for c in 0..<4 { tmp[o + c] = UInt8(sums[c] / max(1, n)) }
                }
            }
            for i in 0..<(bpr * h) { buf[i] = tmp[i] }
            // vertical
            for y in 0..<h {
                for x in 0..<w {
                    var sums = [Int](repeating: 0, count: 4)
                    var n = 0
                    for dy in -r...r {
                        let sy = y + dy
                        guard sy >= 0, sy < h else { continue }
                        let o = sy * bpr + x * 4
                        for c in 0..<4 { sums[c] += Int(buf[o + c]) }
                        n += 1
                    }
                    let o = y * bpr + x * 4
                    for c in 0..<4 { tmp[o + c] = UInt8(sums[c] / max(1, n)) }
                }
            }
            for i in 0..<(bpr * h) { buf[i] = tmp[i] }
        }
        return ctx.makeImage()
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGContext(data: nil, width: max(1, width), height: max(1, height),
                         bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    // MARK: - Text

    static func textFont(for annotation: Annotation) -> NSFont {
        NSFont.boldSystemFont(ofSize: max(6, annotation.fontSize))
    }

    static let labelPaddingH: CGFloat = 8
    static let labelPaddingV: CGFloat = 4
    static let labelCornerRadius: CGFloat = 5

    private static func attributed(_ a: Annotation) -> NSAttributedString {
        let ps = NSMutableParagraphStyle()
        ps.alignment = .left
        ps.lineBreakMode = .byClipping
        let fg: NSColor = a.textStyle == .label ? .white : a.color.nsColor
        let s = a.text.isEmpty ? " " : a.text
        return NSAttributedString(string: s, attributes: [
            .font: textFont(for: a),
            .foregroundColor: fg,
            .paragraphStyle: ps,
        ])
    }

    static func measureTextRect(for annotation: Annotation) -> CGRect {
        let s = attributed(annotation)
        let b = s.boundingRect(with: CGSize(width: 100_000, height: 100_000),
                               options: [.usesLineFragmentOrigin, .usesFontLeading])
        let tw = ceil(b.width)
        let th = ceil(b.height)
        let padH = annotation.textStyle == .label ? labelPaddingH : 0
        let padV = annotation.textStyle == .label ? labelPaddingV : 0
        let w = max(tw + padH * 2, annotation.textStyle == .label ? 14 : 4)
        let h = max(th + padV * 2, 6)
        return CGRect(origin: annotation.rect.origin, size: CGSize(width: w, height: h))
    }

    static func defaultPointerTip(forBubble rect: CGRect) -> CGPoint {
        let r = rect.standardized
        return CGPoint(x: r.minX - max(12, r.width * 0.25),
                       y: r.maxY + max(20, r.height * 0.9))
    }

    /// Bubble (+ tail) outline for a label; text bounds for plain text.
    private static func textOutlinePath(_ a: Annotation) -> CGPath {
        var r = a.rect.standardized
        if r.width < 1 || r.height < 1 { r = measureTextRect(for: a).standardized }
        guard a.textStyle == .label else { return CGPath(rect: r, transform: nil) }
        let bubble = roundedRectPath(r, radius: min(labelCornerRadius, min(r.width, r.height) / 2))
        guard a.textPointer, let tip = a.pointerTip, let tail = tailPath(bubble: r, tip: tip) else { return bubble }
        let p = CGMutablePath()
        p.addPath(bubble)
        p.addPath(tail)
        return p
    }

    /// Triangle from the bubble edge nearest `tip` out to `tip`. Wound the same
    /// way as `roundedRectPath` so a `.winding` fill unions them without a seam.
    static func tailPath(bubble r: CGRect, tip: CGPoint) -> CGPath? {
        guard r.width > 2, r.height > 2 else { return nil }
        // Shottr: the tail leaves the middle of the edge facing the tip with a
        // wide base and tapers to the tip.
        let dLeft = r.minX - tip.x, dRight = tip.x - r.maxX
        let dTop = r.minY - tip.y, dBottom = tip.y - r.maxY
        let best = max(max(dLeft, dRight), max(dTop, dBottom))
        guard best > 2 else { return nil }
        if best == dBottom || best == dTop {
            let bw = min(max(r.width * 0.5, 12), 70)
            let y = best == dBottom ? r.maxY - 1 : r.minY + 1
            let b0 = CGPoint(x: r.midX + bw / 2, y: y), b1 = CGPoint(x: r.midX - bw / 2, y: y)
            return orientedTriangle(b0, b1, tip, positive: true)
        }
        let bh = min(max(r.height * 0.6, 10), 40)
        let x = best == dRight ? r.maxX - 1 : r.minX + 1
        let b0 = CGPoint(x: x, y: r.midY - bh / 2), b1 = CGPoint(x: x, y: r.midY + bh / 2)
        return orientedTriangle(b0, b1, tip, positive: true)
    }

    private static func drawText(_ a: Annotation, in ctx: CGContext) {
        var r = a.rect.standardized
        if r.width < 1 || r.height < 1 { r = measureTextRect(for: a).standardized }
        let string = attributed(a)

        if a.textStyle == .label {
            ctx.saveGState()
            ctx.setFillColor(a.color.cgColor)
            ctx.addPath(textOutlinePath(a))
            ctx.fillPath(using: .winding)
            ctx.restoreGState()
            drawAttributed(string, at: CGPoint(x: r.minX + labelPaddingH, y: r.minY + labelPaddingV), in: ctx)
        } else {
            let font = textFont(for: a)
            let halo: NSColor = luminance(a.color) < 0.5 ? .white : .black
            let ps = NSMutableParagraphStyle()
            ps.alignment = .left
            ps.lineBreakMode = .byClipping
            let outline = NSAttributedString(string: a.text.isEmpty ? " " : a.text, attributes: [
                .font: font,
                .strokeColor: halo,
                .strokeWidth: (4.0 / font.pointSize) * 100.0,
                .foregroundColor: halo,
                .paragraphStyle: ps,
            ])
            drawAttributed(outline, at: r.origin, in: ctx)
            drawAttributed(string, at: r.origin, in: ctx)
        }
    }

    /// AppKit text drawing into our y-down context.
    private static func drawAttributed(_ s: NSAttributedString, at origin: CGPoint, in ctx: CGContext) {
        let saved = NSGraphicsContext.current
        let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.current = gc
        ctx.saveGState()
        s.draw(with: CGRect(origin: origin, size: CGSize(width: 100_000, height: 100_000)),
               options: [.usesLineFragmentOrigin, .usesFontLeading])
        ctx.restoreGState()
        NSGraphicsContext.current = saved
    }

    private static func luminance(_ c: AnnotationColor) -> CGFloat {
        0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue
    }

    // MARK: - Counter

    /// Outward unit direction of the nubbin. angle 0 = straight down,
    /// positive = counter-clockwise on screen (y down).
    static func counterDirection(_ angle: CGFloat) -> CGPoint {
        CGPoint(x: sin(angle), y: cos(angle))
    }

    static func counterNubbinTip(_ a: Annotation) -> CGPoint {
        let d = a.size.counterDiameter
        let dir = counterDirection(a.angle)
        let dist = d / 2 + d * 0.35
        return CGPoint(x: a.start.x + dir.x * dist, y: a.start.y + dir.y * dist)
    }

    /// Teardrop nubbin: leaves the rim tangentially on both sides and meets at
    /// the tip, so it reads as one pin shape once unioned with the circle.
    static func counterNubbinPath(_ a: Annotation) -> CGPath {
        let d = a.size.counterDiameter
        let r = d / 2
        let phi: CGFloat = 0.62          // half-angle of the base chord on the rim
        let a0 = a.angle + phi
        let a1 = a.angle - phi
        let p0 = CGPoint(x: a.start.x + sin(a0) * r, y: a.start.y + cos(a0) * r)
        let p1 = CGPoint(x: a.start.x + sin(a1) * r, y: a.start.y + cos(a1) * r)
        let tip = counterNubbinTip(a)
        // rim tangents pointing away from the circle, toward the tip
        let t0 = CGPoint(x: -cos(a0), y: sin(a0))
        let t1 = CGPoint(x: cos(a1), y: -sin(a1))
        let k = 0.6 * hypot(tip.x - p0.x, tip.y - p0.y)
        let c0 = CGPoint(x: p0.x + t0.x * k, y: p0.y + t0.y * k)
        let c1 = CGPoint(x: p1.x + t1.x * k, y: p1.y + t1.y * k)

        let area = (p0.x * tip.y - tip.x * p0.y) + (tip.x * p1.y - p1.x * tip.y) + (p1.x * p0.y - p0.x * p1.y)
        let p = CGMutablePath()
        if area >= 0 {
            p.move(to: p0)
            p.addQuadCurve(to: tip, control: c0)
            p.addQuadCurve(to: p1, control: c1)
        } else {
            p.move(to: p1)
            p.addQuadCurve(to: tip, control: c1)
            p.addQuadCurve(to: p0, control: c0)
        }
        p.closeSubpath()
        return p
    }

    private static func drawCounter(_ a: Annotation, in ctx: CGContext) {
        let d = a.size.counterDiameter
        guard d > 1 else { return }
        let circle = CGRect(x: a.start.x - d / 2, y: a.start.y - d / 2, width: d, height: d)

        ctx.saveGState()
        ctx.setFillColor(a.color.cgColor)
        let path = CGMutablePath()
        path.addPath(circlePath(circle))
        path.addPath(counterNubbinPath(a))
        ctx.addPath(path)
        ctx.fillPath(using: .winding)
        ctx.restoreGState()

        // number
        var size = d * 0.55
        let text = String(a.number)
        var string = counterString(text, size: size)
        var w = string.size().width
        while w > d * 0.78 && size > 5 {
            size *= 0.9
            string = counterString(text, size: size)
            w = string.size().width
        }
        let m = string.size()
        drawAttributed(string, at: CGPoint(x: a.start.x - m.width / 2, y: a.start.y - m.height / 2), in: ctx)
    }

    private static func counterString(_ text: String, size: CGFloat) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.boldSystemFont(ofSize: max(5, size)),
            .foregroundColor: NSColor.white,
        ])
    }

    // MARK: - Path helpers

    /// Rounded rect wound so the shoelace signed area is positive (see `orientedTriangle`).
    static func roundedRectPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let r = rect.standardized
        let rad = max(0, min(radius, min(r.width, r.height) / 2))
        let p = CGMutablePath()
        guard r.width > 0, r.height > 0 else { return p }
        if rad <= 0.01 {
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
            return p
        }
        p.move(to: CGPoint(x: r.minX + rad, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - rad, y: r.minY))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + rad), radius: rad)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - rad))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - rad, y: r.maxY), radius: rad)
        p.addLine(to: CGPoint(x: r.minX + rad, y: r.maxY))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - rad), radius: rad)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + rad))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + rad, y: r.minY), radius: rad)
        p.closeSubpath()
        return p
    }

    /// Circle wound positively (same direction as `roundedRectPath`).
    private static func circlePath(_ rect: CGRect) -> CGPath {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        let p = CGMutablePath()
        p.addArc(center: c, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        p.closeSubpath()
        return p
    }

    /// Triangle whose winding matches `positive` (shoelace sign), so unions fill cleanly.
    private static func orientedTriangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, positive: Bool) -> CGPath {
        let area = (a.x * b.y - b.x * a.y) + (b.x * c.y - c.x * b.y) + (c.x * a.y - a.x * c.y)
        let p = CGMutablePath()
        if (area >= 0) == positive {
            p.move(to: a); p.addLine(to: b); p.addLine(to: c)
        } else {
            p.move(to: c); p.addLine(to: b); p.addLine(to: a)
        }
        p.closeSubpath()
        return p
    }

    static func unit(from a: CGPoint, to b: CGPoint) -> (CGPoint, CGFloat) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 0.0001 else { return (CGPoint(x: 1, y: 0), 0) }
        return (CGPoint(x: dx / len, y: dy / len), len)
    }
}
