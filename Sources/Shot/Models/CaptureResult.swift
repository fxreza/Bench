import AppKit

nonisolated enum CaptureSource: String, Sendable {
    case area, window, screen, scrolling, file
}

/// A captured bitmap plus where it came from.
nonisolated struct CaptureResult: Sendable {
    var image: CGImage
    /// Bitmap pixels per point on the display it was captured from.
    var pixelScale: CGFloat
    var source: CaptureSource
    /// Global screen rect (AppKit coordinates, points) the image covers, if any.
    var screenRect: CGRect?

    var pointSize: CGSize { CGSize(width: CGFloat(image.width) / pixelScale, height: CGFloat(image.height) / pixelScale) }
}
