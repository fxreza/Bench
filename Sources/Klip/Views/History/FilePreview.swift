import AppKit
import SwiftUI
import QuickLookThumbnailing

/// Thumbnail plumbing for `.file` items (Phase 3F; reworked in 3.0.1).
///
/// **Only `QLThumbnailGenerator` is used — never a QuickLook *UI* class.**
/// `QLPreviewView` (Quartz/QuickLookUI) used to render the live preview in
/// `PreviewPane.fileBody`, but `-[QLPreviewView setPreviewItem:]` raises a
/// QuickLook assertion (`_QLRaiseAssert` → `abort`) when it is set from
/// inside a SwiftUI layout pass, which is exactly where
/// `NSViewRepresentable.updateNSView` runs. Three user crashes on 3.0.0 came
/// from that single call, so the whole live-preview path is gone: the pane
/// now renders a static raster thumbnail, which is generated off the main
/// thread and can never assert during layout.
///
/// `QLThumbnailGenerator` renders that raster: cheap enough to ask for on
/// every row in a scrolling list (`ClipRow`'s 38×38 badge) and, at pane
/// width × 320 pt, good enough to stand in for the live preview — pdf, csv,
/// txt, code, images and office docs all produce a real page/content
/// thumbnail rather than a generic icon.
enum FilePreview {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 500
        return cache
    }()

    /// Plain `String` (Sendable) rather than `NSString` — bridged to `NSString`
    /// only at the point of each cache call, so it can be captured directly
    /// in the `@Sendable` completion handler below without a warning.
    private static func cacheKey(itemID: UUID, size: CGSize) -> String {
        "\(itemID.uuidString)#\(Int(size.width))x\(Int(size.height))"
    }

    /// Square convenience used by the row badge.
    static func thumbnail(for url: URL, itemID: UUID, size: CGFloat) async -> NSImage? {
        await thumbnail(for: url, itemID: itemID, size: CGSize(width: size, height: size))
    }

    /// Async thumbnail for `url`, cached by item id + size so the same row
    /// (or pane width) never re-renders one twice. Returns `nil` when
    /// QuickLook has nothing to offer for this file type — callers fall back
    /// to `fileIcon(store:)` / the fallback card.
    static func thumbnail(for url: URL, itemID: UUID, size: CGSize) async -> NSImage? {
        let key = cacheKey(itemID: itemID, size: size)
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }

        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2 }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )

        return await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                guard let representation else {
                    continuation.resume(returning: nil)
                    return
                }
                let image = representation.nsImage
                cache.setObject(image, forKey: key as NSString)
                continuation.resume(returning: image)
            }
        }
    }

    /// Human-readable kind ("PDF document", "PNG image") for the preview
    /// pane's fallback card. Falls back to the uppercased extension when the
    /// file is gone, and to `nil` when there is nothing to say.
    static func kindLabel(for url: URL?, name: String?) -> String? {
        if let url,
           let description = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey]).localizedTypeDescription,
           !description.isEmpty {
            return description
        }
        let ext = (url?.pathExtension.isEmpty == false ? url?.pathExtension : nil)
            ?? (name as NSString?)?.pathExtension
        guard let ext, !ext.isEmpty else { return nil }
        return "\(ext.uppercased()) file"
    }
}

/// The preview pane's file thumbnail: a plain SwiftUI `Image` fed by
/// `FilePreview.thumbnail`, sized to the pane's current width and capped at
/// `maxHeight`.
///
/// Deliberately *not* an `NSViewRepresentable` — the whole point of 3.0.1's
/// crash fix is that nothing in the file preview path touches AppKit/QuickLook
/// during a SwiftUI update. Renders to nothing (zero height) while loading and
/// when QuickLook has no thumbnail, so the fallback card below it stands alone.
struct FileThumbnailView: View {
    let url: URL
    let itemID: UUID
    var maxHeight: CGFloat = 320

    @State private var image: NSImage?
    @State private var width: CGFloat = 0

    /// Width quantized to 40 pt so dragging the pane resizer does not kick off
    /// a new generation (and a new cache entry) on every frame.
    private var requestWidth: CGFloat {
        guard width > 0 else { return 0 }
        return (width / 40).rounded(.up) * 40
    }

    var body: some View {
        VStack(spacing: 0) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    )
                    .accessibilityLabel("Preview of \(url.lastPathComponent)")
            }
        }
        .frame(maxWidth: .infinity)
        .background(WidthReader { measured in
            guard abs(measured - width) > 0.5 else { return }
            width = measured
        })
        .task(id: "\(itemID.uuidString)#\(Int(requestWidth))") {
            let requested = requestWidth
            guard requested > 0 else { return }
            let result = await FilePreview.thumbnail(
                for: url,
                itemID: itemID,
                size: CGSize(width: requested, height: maxHeight)
            )
            guard !Task.isCancelled else { return }
            image = result
        }
    }
}

/// Reports its available width. Used as a `.background`, so it never affects
/// the layout it measures.
private struct WidthReader: View {
    let onChange: (CGFloat) -> Void

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { onChange(geo.size.width) }
                .onChange(of: geo.size.width) { _, newValue in onChange(newValue) }
        }
    }
}
