import Foundation

/// What Klip knows about the text inside one clip's picture, read the same way
/// by every place that offers to copy it: the preview pane's "Copy text in
/// image" icon, the row context menu's "Copy Text", and the text block under
/// the image.
///
/// Klip reads the text in every image automatically in the background (Vision
/// OCR) and stores it in `ClipboardItem.ocrText`. That field carries three
/// meanings, and the UI must not confuse them:
///
/// - `nil`      - not read yet. Nothing is wrong; the answer is still coming.
/// - `""`       - read, and the image has no text in it.
/// - non-empty  - the text.
///
/// Having one place decide which of those a clip is in keeps the three
/// surfaces from drifting apart (an icon that says "reading" while the menu
/// offers a copy, say), and it is a plain function of the item, so it is
/// testable without a view.
enum ImageTextState: Equatable {
    /// Not an image clip, so there is no picture to have text in.
    case notAnImage
    /// An image whose text has not been read yet (`ocrText == nil`).
    case reading
    /// An image that was read and has no text in it.
    case noText
    /// An image with text. Trimmed of surrounding whitespace, which is also
    /// what is written to the pasteboard and what the preview shows.
    case text(String)

    /// The string older builds stored when the manual "Extract text" found
    /// nothing. The model migrates it to `""`, but a clip that has not been
    /// migrated yet, or one arriving through iCloud sync from a Mac that has
    /// not updated, can still carry it, and it is the *absence* of text, not
    /// text to copy or to show under the picture.
    static let legacyNoTextSentinel = "No text found in this image."

    init(_ item: ClipboardItem) {
        guard item.type == .image else {
            self = .notAnImage
            return
        }
        guard let raw = item.ocrText else {
            self = .reading
            return
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == Self.legacyNoTextSentinel {
            self = .noText
        } else {
            self = .text(trimmed)
        }
    }

    /// The text to show or copy, or nil when there is none (yet).
    var text: String? {
        if case .text(let text) = self { return text }
        return nil
    }

    /// Whether "Copy text in image" can do anything for this clip.
    var canCopy: Bool { text != nil }

    /// Tooltip for the preview pane's icon in this state. The row never drops
    /// the icon (see `PreviewPane.historyActionIcons`), so a disabled one says
    /// why it is off.
    var copyHelp: String {
        switch self {
        case .notAnImage: return "Only images have text to copy"
        case .reading: return "Reading the image…"
        case .noText: return "No text found in this image"
        case .text: return "Copy text in image"
        }
    }
}
