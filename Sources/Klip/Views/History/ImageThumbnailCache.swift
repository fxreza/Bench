import AppKit

/// Cached, off-main thumbnails for `.image` clips (review 5A-07 / 5A-10).
///
/// Two problems this replaces, both in `ClipRow.loadThumbnail`:
///
/// - **5A-07** — it rendered with `NSImage.lockFocus()` / `draw` /
///   `unlockFocus()` on `DispatchQueue.global`. `lockFocus` pushes a graphics
///   context tied to the window server and is documented main-thread-only;
///   several rows doing it at once while the main thread also draws is the
///   classic off-main-AppKit corruption pattern. Drawing into an
///   `NSBitmapImageRep` through an explicit `NSGraphicsContext` (below) is
///   safe off the main thread, because that context is per-thread and
///   backed by our own bitmap rather than by a window.
///
/// - **5A-10** — the result lived in the row's `@State`, which `LazyVStack`
///   throws away as soon as the row scrolls out of view, so scrolling back
///   re-read the full-resolution PNG from disk and re-rendered it every time.
///   `.file` thumbnails already had an `NSCache`; image thumbnails now get
///   the same treatment, keyed by item id + badge size.
enum ImageThumbnailCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 500
        return cache
    }()

    /// Every size a key has been minted for, so `evict` can clear an item's
    /// entries without being able to enumerate `NSCache`. The set is tiny
    /// (one entry per badge size the user's text-size setting produces).
    private static var knownSizes: Set<Int> = []

    private static func cacheKey(itemID: UUID, size: Int) -> String {
        "\(itemID.uuidString)#\(size)"
    }

    /// Thumbnail for `item`'s stored image, rendered at `size` (points,
    /// drawn at 2× so the badge stays crisp) and cached. Returns `nil` when
    /// the backing file is missing or unreadable.
    static func thumbnail(for item: ClipboardItem, store: ClipboardStore, size: CGFloat) async -> NSImage? {
        let pixelSize = Int(size.rounded())
        let key = cacheKey(itemID: item.id, size: pixelSize)
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        knownSizes.insert(pixelSize)

        let thumbSize = NSSize(width: size * 2, height: size * 2)
        let image = await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let original = store.image(for: item) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: render(original, size: thumbSize))
            }
        }

        if let image {
            cache.setObject(image, forKey: key as NSString)
        }
        return image
    }

    /// Drop every cached size for these items. Called from the delete choke
    /// point so a deleted clip's bytes do not linger in the cache.
    static func evict(itemIDs: some Sequence<UUID>) {
        for id in itemIDs {
            for size in knownSizes {
                cache.removeObject(forKey: cacheKey(itemID: id, size: size) as NSString)
            }
        }
    }

    static func evictAll() {
        cache.removeAllObjects()
    }

    // MARK: - Rendering

    /// Thread-safe replacement for `lockFocus` / `unlockFocus`: draw into a
    /// bitmap rep through an explicit, per-thread `NSGraphicsContext`.
    ///
    /// `nonisolated` so it can run on the background queue above under the
    /// project's `-default-isolation MainActor` build flag.
    nonisolated static func render(_ original: NSImage, size: NSSize) -> NSImage? {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 0, height > 0 else { return nil }

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = size

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        original.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: original.size),
            operation: .copy,
            fraction: 1.0
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let thumbnail = NSImage(size: size)
        thumbnail.addRepresentation(rep)
        return thumbnail
    }
}
