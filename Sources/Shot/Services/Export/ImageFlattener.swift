import AppKit
import CoreGraphics

/// Renders a document (base bitmap + annotations) into a single bitmap at the
/// document's pixel size. Annotations are drawn in image points into a flipped,
/// scaled context so the result matches the live canvas exactly.
@MainActor
enum ImageFlattener {

    static func flatten(_ document: AnnotationDocument) -> CGImage {
        flatten(image: document.image, pixelScale: document.pixelScale, annotations: document.annotations)
    }

    static func flatten(image: CGImage, pixelScale: CGFloat, annotations: [Annotation]) -> CGImage {
        let w = image.width
        let h = image.height
        guard w > 0, h > 0 else { return image }
        let scale = max(1, pixelScale)
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return image
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))

        guard !annotations.isEmpty else { return ctx.makeImage() ?? image }

        // Flip to top-left origin and switch to image points.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        AnnotationRenderer.draw(annotations, sourceImage: image, pixelScale: scale, in: ctx)

        return ctx.makeImage() ?? image
    }
}
