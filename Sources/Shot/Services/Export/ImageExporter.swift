import AppKit
import BenchCore
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ImageFormat: String, CaseIterable {
    case png, jpeg, heic, tiff

    var utType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .heic: return UTType("public.heic") ?? .jpeg
        case .tiff: return .tiff
        }
    }

    /// Extension we write for this format.
    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .tiff: return "tiff"
        }
    }
}

nonisolated enum ImageExporter {

    /// JPEG/HEIC quality used when a caller does not pass one of its own
    /// (drag-out temp files, the pasteboard, anything not driven by a capture
    /// shortcut). Capture saves pass `SettingsManager.jpegQualityFraction`.
    static let lossyQuality: CGFloat = 0.9

    /// Clamps a quality to the range Image I/O accepts, where 0 is the
    /// smallest file and 1 the best-looking one.
    static func clampQuality(_ quality: CGFloat) -> CGFloat { min(max(quality, 0), 1) }

    // MARK: - Encode

    /// Encodes `image`, stamping DPI = 72 * `pixelScale` so Preview and Finder
    /// report the logical (point) size rather than the pixel size - the same
    /// trick Shottr uses to write 144 dpi for Retina captures.
    ///
    /// `quality` only applies to the lossy formats (jpeg, heic); png and tiff
    /// ignore it.
    static func data(_ image: CGImage,
                     pixelScale: CGFloat,
                     format: ImageFormat,
                     quality: CGFloat = lossyQuality) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, format.utType.identifier as CFString, 1, nil) else {
            return nil
        }
        let dpi = 72.0 * Double(max(pixelScale, 0.01))
        var properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        switch format {
        case .jpeg, .heic:
            properties[kCGImageDestinationLossyCompressionQuality] = Double(clampQuality(quality))
            properties[kCGImagePropertyJFIFDictionary] = [
                kCGImagePropertyJFIFXDensity: dpi,
                kCGImagePropertyJFIFYDensity: dpi,
                kCGImagePropertyJFIFDensityUnit: 1,
            ] as CFDictionary
        case .png:
            properties[kCGImagePropertyPNGDictionary] = [
                kCGImagePropertyPNGXPixelsPerMeter: Int((dpi / 0.0254).rounded()),
                kCGImagePropertyPNGYPixelsPerMeter: Int((dpi / 0.0254).rounded()),
            ] as CFDictionary
        case .tiff:
            properties[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFXResolution: dpi,
                kCGImagePropertyTIFFYResolution: dpi,
                kCGImagePropertyTIFFResolutionUnit: 2,
            ] as CFDictionary
        }

        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// png for anything we do not recognise.
    static func format(forExtension ext: String) -> ImageFormat {
        switch ext.trimmingCharacters(in: .whitespaces).lowercased() {
        case "jpg", "jpeg": return .jpeg
        case "heic", "heif": return .heic
        case "tif", "tiff": return .tiff
        default: return .png
        }
    }

    /// Writes `image` to `url`; the format comes from the URL's extension and
    /// `quality` applies when that format is lossy.
    ///
    /// `sourceAppName` is the app the pixels came from; when it is known the
    /// written file gets a "Where from" entry naming it, the way a download
    /// records the site it came from.
    static func write(_ image: CGImage,
                      pixelScale: CGFloat,
                      to url: URL,
                      quality: CGFloat = lossyQuality,
                      sourceAppName: String? = nil) throws {
        let format = format(forExtension: url.pathExtension)
        guard let data = data(image, pixelScale: pixelScale, format: format, quality: quality) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
        if let name = sourceAppName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            setWhereFrom([name], on: url)
        }
    }

    // MARK: - Where from

    /// The extended attribute Finder's Get Info reads for its "Where from" row.
    static let whereFromsAttribute = "com.apple.metadata:kMDItemWhereFroms"

    /// Writes `names` (typically one app name) to `url`'s "Where from"
    /// metadata: a binary property list holding an array of strings, which is
    /// exactly what Safari writes for a download and what Finder, `mdls` and
    /// `xattr -p` read back.
    ///
    /// Best effort - a read-only volume or a file system without extended
    /// attributes only logs.
    static func setWhereFrom(_ names: [String], on url: URL) {
        let cleaned = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        guard let plist = try? PropertyListSerialization.data(fromPropertyList: cleaned,
                                                             format: .binary,
                                                             options: 0) else {
            NSLog("Shot: could not encode Where from for %@", url.lastPathComponent)
            return
        }
        let status = plist.withUnsafeBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return setxattr(url.path, whereFromsAttribute, base, buffer.count, 0, 0)
        }
        if status != 0 {
            NSLog("Shot: could not set Where from on %@ (errno %d)", url.lastPathComponent, errno)
        }
    }

    // MARK: - Pasteboard

    /// Puts `image` on the general pasteboard in `format`.
    ///
    /// For png that means a PNG **and** a TIFF representation, so both Finder
    /// (which prefers TIFF) and apps like Slack (which prefer PNG) accept it.
    /// For jpeg it is the JPEG alone: adding a TIFF fallback would let every
    /// app that prefers TIFF paste a lossless image instead, which is the
    /// opposite of what choosing JPG asks for.
    ///
    /// When `sourceAppName` is known it rides along on the same item under
    /// `SourceAppPasteboard.sourceAppNameType`, so Klip credits the captured
    /// app instead of Bench - the frontmost app when the pasteboard changes is
    /// our own overlay or editor window.
    @MainActor
    static func copyToPasteboard(_ image: CGImage,
                                 pixelScale: CGFloat,
                                 format: ImageFormat = .png,
                                 quality: CGFloat = lossyQuality,
                                 sourceAppName: String? = nil) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        if let encoded = data(image, pixelScale: pixelScale, format: format, quality: quality) {
            item.setData(encoded, forType: NSPasteboard.PasteboardType(format.utType.identifier))
        }
        if format == .png, let tiff = data(image, pixelScale: pixelScale, format: .tiff) {
            item.setData(tiff, forType: .tiff)
        }
        if let credit = SourceAppPasteboard.data(for: sourceAppName) {
            item.setData(credit, forType: SourceAppPasteboard.sourceAppNameType)
        }
        pb.writeObjects([item])
    }

    /// Reads an image off the general pasteboard: PNG or TIFF data, or a file
    /// URL pointing at an image. The scale is inferred from DPI metadata.
    @MainActor
    static func imageFromPasteboard() -> (CGImage, CGFloat)? {
        let pb = NSPasteboard.general

        for type in [NSPasteboard.PasteboardType.png,
                     NSPasteboard.PasteboardType(UTType.jpeg.identifier),
                     .tiff] {
            if let data = pb.data(forType: type), let result = decode(data: data) {
                return result
            }
        }

        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls where url.isFileURL {
                if let result = load(url: url) { return result }
            }
        }
        return nil
    }

    // MARK: - Load

    /// Loads an image file. `pixelScale` comes from DPI metadata (72 -> 1,
    /// 144 -> 2), defaulting to 1.
    static func load(url: URL) -> (CGImage, CGFloat)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return decode(source: source)
    }

    static func decode(data: Data) -> (CGImage, CGFloat)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return decode(source: source)
    }

    private static func decode(source: CGImageSource) -> (CGImage, CGFloat)? {
        guard CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        return (image, pixelScale(fromDPI: props?[kCGImagePropertyDPIWidth] as? Double))
    }

    /// 144 dpi (and anything at least 1.5x of 72) means a 2x Retina bitmap.
    static func pixelScale(fromDPI dpi: Double?) -> CGFloat {
        guard let dpi, dpi > 0 else { return 1 }
        let scale = dpi / 72.0
        guard scale >= 1.5 else { return 1 }
        return CGFloat((scale).rounded())
    }

    // MARK: - Drag-out temp files

    static let dragFolderName = "Shot-drag"
    private static let dragFileLifetime: TimeInterval = 24 * 60 * 60

    /// Directory used for drag-out temp files.
    static var dragDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(dragFolderName, isDirectory: true)
    }

    /// Writes a PNG into a dedicated temp subfolder for a drag-out, sweeping
    /// anything older than a day first.
    static func writeDragTempFile(_ image: CGImage, pixelScale: CGFloat, sourceAppName: String? = nil) throws -> URL {
        let dir = dragDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sweepDragDirectory()

        let name = ScreenshotDefaults.filename(date: Date(),
                                               ext: "png",
                                               includeDate: true,
                                               baseName: ScreenshotDefaults.sanitized(sourceAppName: sourceAppName)
                                                   ?? ScreenshotDefaults.baseName)
        var url = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) {
            let stem = (name as NSString).deletingPathExtension
            var counter = 2
            repeat {
                url = dir.appendingPathComponent("\(stem) (\(counter)).png")
                counter += 1
            } while FileManager.default.fileExists(atPath: url.path) && counter < 10_000
        }

        try write(image, pixelScale: pixelScale, to: url, sourceAppName: sourceAppName)
        return url
    }

    /// Deletes drag temp files older than a day.
    static func sweepDragDirectory() {
        let fm = FileManager.default
        let dir = dragDirectory
        guard let entries = try? fm.contentsOfDirectory(at: dir,
                                                        includingPropertiesForKeys: [.contentModificationDateKey],
                                                        options: [.skipsHiddenFiles]) else { return }
        let cutoff = Date().addingTimeInterval(-dragFileLifetime)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified > cutoff { continue }
            try? fm.removeItem(at: entry)
        }
    }
}
