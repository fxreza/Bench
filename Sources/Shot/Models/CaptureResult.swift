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
    /// Display name of the app the pixels came from ("IINA", "Google Chrome"),
    /// when it can be identified. Bench itself is never the source. Used to
    /// credit the app on the clipboard, in the file name and in the file's
    /// "Where from" metadata.
    var sourceAppName: String?
    /// Bundle identifier of that app, when known.
    var sourceBundleID: String?

    var pointSize: CGSize { CGSize(width: CGFloat(image.width) / pixelScale, height: CGFloat(image.height) / pixelScale) }
}
