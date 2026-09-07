import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Pixel dimensions of an image, for the preview pane's metadata footer.
///
/// A tiny value type rather than `CGSize` on purpose: `CGSize` is `CGFloat`
/// (i.e. points, and fractional), and the whole point of this row is to show
/// *pixels* as whole numbers. Keeping the type honest about that means a
/// caller can't accidentally hand us a point size and have it render as a
/// plausible-looking lie. `Equatable` so `@Published` republishes only on a
/// real change.
struct PixelDimensions: Equatable {
    let width: Int
    let height: Int

    /// "3000 × 2000 px" — U+00D7 MULTIPLICATION SIGN, not the letter "x".
    var displayString: String {
        "\(width) × \(height) px"
    }

    /// Pixel dimensions of an already-decoded `NSImage`.
    ///
    /// **Why not `NSImage.size`.** `size` is in *points*, not pixels. AppKit
    /// tags a Retina screenshot's bitmap rep with a 2× scale, so a 3000×2000
    /// pixel capture reports `size == 1500×1000` — exactly half the real
    /// pixel count, and the footer would quietly under-report every screenshot
    /// taken on a Retina display. `NSBitmapImageRep.pixelsWide/pixelsHigh` are
    /// the raw sample counts and are immune to that.
    ///
    /// When an image carries several bitmap reps (an `.icns`, a multi-page
    /// TIFF, an @1x/@2x pair) we report the largest one: that is the
    /// full-resolution payload the user actually copied, and for the usual
    /// case of same-aspect reps it is exactly the max of `pixelsWide` and of
    /// `pixelsHigh`.
    ///
    /// Only when there is *no* bitmap rep at all do we fall back to the
    /// rounded `size`. That path matters because some capture paths store
    /// vector/PDF-ish images (`NSPDFImageRep`, `NSEPSImageRep`), which have no
    /// intrinsic pixel grid — points are the only number available, and for a
    /// resolution-independent image they are also the right one.
    nonisolated init?(image: NSImage) {
        let bitmaps = image.representations.compactMap { $0 as? NSBitmapImageRep }

        if let largest = bitmaps
            .filter({ $0.pixelsWide > 0 && $0.pixelsHigh > 0 })
            .max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }) {
            self.width = largest.pixelsWide
            self.height = largest.pixelsHigh
            return
        }

        let size = image.size
        guard size.width >= 1, size.height >= 1 else { return nil }
        self.width = Int(size.width.rounded())
        self.height = Int(size.height.rounded())
    }

    /// Pixel dimensions of an image *file*, read from its header only.
    ///
    /// `.file` clips render through `FileThumbnailView`, so there is no
    /// decoded `NSImage` around to measure — and decoding one just to count
    /// pixels would be absurd for, say, a 400 MB layered TIFF.
    /// `CGImageSourceCopyPropertiesAtIndex` reads the container metadata and
    /// stops; `kCGImageSourceShouldCache: false` keeps ImageIO from holding on
    /// to anything afterwards. Cheap enough to run on every selection change.
    ///
    /// Returns `nil` for anything that isn't an image (a PDF, a folder, a zip),
    /// which is what suppresses the Dimensions row for those clips. The
    /// extension check is only a fast pre-filter — ImageIO would return `nil`
    /// for them anyway, but an unreadable/huge non-image is better not opened
    /// at all. An unknown extension still gets handed to ImageIO, so an image
    /// saved without one is not missed.
    ///
    /// Explicitly `nonisolated` — the build passes `-default-isolation
    /// MainActor`, so without it this would be main-actor-isolated and the
    /// `Task.detached` in `HistoryViewModel.loadFileDimensions` would hop
    /// straight back to the main thread, doing the file read on the UI thread
    /// it was written to stay off. Touches nothing shared, so it is safe.
    nonisolated static func read(contentsOf url: URL) -> PixelDimensions? {
        let ext = url.pathExtension
        if !ext.isEmpty,
           let type = UTType(filenameExtension: ext),
           !type.conforms(to: .image) {
            return nil
        }

        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options as CFDictionary)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }

        // Deliberately *not* swapping for `kCGImagePropertyOrientation`:
        // `kCGImagePropertyPixelWidth/Height` describe the stored pixel grid,
        // which is what Finder's Get Info and Preview's inspector also show
        // for a rotated JPEG.
        return PixelDimensions(width: width, height: height)
    }

    nonisolated private init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// What the preview pane needs to know about a clip, resolved in one go.
///
/// A class because it lives in an `NSCache`, which only holds objects. Every
/// field is a `let` set at construction, so sharing one between the view body
/// and the view model is safe.
final class PreviewPayload {
    let image: NSImage?
    let dimensions: PixelDimensions?
    let byteSize: Int?

    init(image: NSImage?, dimensions: PixelDimensions?, byteSize: Int?) {
        self.image = image
        self.dimensions = dimensions
        self.byteSize = byteSize
    }
}
