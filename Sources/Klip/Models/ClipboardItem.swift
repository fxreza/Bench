import Foundation
import AppKit
import CryptoKit
import UniformTypeIdentifiers

/// Represents a single item in the clipboard history
///
/// Every field added after v2.5.0 is optional or defaulted and decoded with
/// `decodeIfPresent`, so an existing `history.json` loads unchanged. Unknown
/// keys are ignored by `JSONDecoder`, so removed fields (`isTruncated`,
/// `originalSizeBytes`) do not break old files either.
struct ClipboardItem: Identifiable, Codable, Equatable {
    let id: UUID
    let type: ClipboardItemType
    /// When this clip was last copied. `var`, not `let`: re-copying content
    /// that is already in the history refreshes the existing clip's date
    /// instead of adding a second row (see `ClipboardStore.resurface`).
    var timestamp: Date
    let sourceApp: String?

    // For text items — inline content (nil for file-backed large text)
    var textContent: String?

    // For large text items — filename reference (stored separately, like images)
    let textFilename: String?

    // For image items — filename reference (stored separately)
    let imageFilename: String?

    /// The UTI (`public.jpeg`, `public.png`, `public.heic`,
    /// `com.compuserve.gif`, `public.webp`, ...) of the exact bytes stored at
    /// `imageFilename`. `nil` for items captured before this field existed —
    /// `resolvedImageUTI` derives a best-effort guess from the filename's
    /// extension for those.
    var imageUTI: String? = nil

    // Pin state (protected + floats to top)
    var isPinned: Bool = false

    // Bookmark state (protected, stays in chronological position)
    var isBookmarked: Bool = false

    // User-defined tags
    var tags: [String] = []

    /// User-given name for this clip, shown in place of the content preview
    /// on the row. `nil` — never an empty string — when the clip has not been
    /// named; `ClipboardStore.setTitle` normalizes blank input back to `nil`.
    ///
    /// Stored on the clip itself rather than on its folder membership, so a
    /// named clip keeps its name when it moves between folders or is dragged
    /// back out into the loose history.
    var title: String? = nil

    // Extracted OCR text (persisted after first extraction)
    var ocrText: String?

    /// Lock state — a locked item can never be deleted or evicted.
    var isLocked: Bool = false

    /// Folder membership, `nil` when the item is loose in the history.
    var folderID: UUID? = nil

    /// Detected semantic kind. `nil` means "not yet detected" (detection is
    /// Phase 3C), not "plain text".
    var kind: ContentKind? = nil

    /// File payload, when this item came from copied files.
    var fileAttachment: FileAttachment? = nil

    /// Filename of the RTF flavor under `texts/` (reserved for Phase 3D).
    var rtfFilename: String? = nil

    /// Filename of the archived pasteboard flavors under `flavors/`
    /// (reserved for Phase 3D).
    var flavorsFilename: String? = nil

    // --- Phase 4A (iCloud Drive sync) ---
    /// Last time any field of this item changed locally. Seeded from
    /// `timestamp` for items captured (or decoded) before sync existed, and
    /// bumped by every `ClipboardStore` mutation. The sync merge resolves a
    /// same-`id` conflict by keeping the record with the newest `updatedAt`.
    var updatedAt: Date
    // --- end Phase 4A ---

    /// When this clip was moved to the trash. Only ever set on records inside
    /// `ClipboardStore.trashedItems` — an item in the history proper always
    /// has `nil` here — and it is what the retention purge measures against.
    var deletedAt: Date? = nil

    /// Manual position inside `folderID`, lower first. `nil` for a clip that
    /// has never been dragged into place — those sort below the ordered ones,
    /// newest first, so a folder that was never hand-sorted looks exactly as
    /// it always did.
    ///
    /// Only ever consulted in folder scope: All and Favorites stay
    /// chronological (pinned first). Inside a folder the manual order wins
    /// outright — a pinned clip does **not** float to the top there, because
    /// the whole point of hand-sorting is that the row stays where it was put.
    var folderSortIndex: Double? = nil

    /// Content identity, used to fold a re-copy of something already in the
    /// history into the clip that is already there instead of appending a
    /// second row.
    ///
    /// Derived from the payload alone: the capture date, the source app and
    /// the item's own id are deliberately **not** part of it, so the same
    /// text copied from Chrome two days ago and from a text editor today
    /// produces the same key. `nil` for an item captured before this field
    /// existed (`ClipboardStore.backfillContentKeysIfNeeded` fills those in
    /// at launch) or for one with no usable payload.
    var contentKey: String? = nil

    init(
        id: UUID = UUID(),
        type: ClipboardItemType,
        timestamp: Date = Date(),
        sourceApp: String? = nil,
        textContent: String? = nil,
        textFilename: String? = nil,
        imageFilename: String? = nil,
        imageUTI: String? = nil,
        isPinned: Bool = false,
        isBookmarked: Bool = false,
        tags: [String] = [],
        ocrText: String? = nil,
        isLocked: Bool = false,
        folderID: UUID? = nil,
        kind: ContentKind? = nil,
        fileAttachment: FileAttachment? = nil,
        rtfFilename: String? = nil,
        flavorsFilename: String? = nil,
        updatedAt: Date? = nil,
        contentKey: String? = nil,
        folderSortIndex: Double? = nil,
        deletedAt: Date? = nil,
        title: String? = nil
    ) {
        self.id = id
        self.type = type
        self.timestamp = timestamp
        self.sourceApp = sourceApp
        self.textContent = textContent
        self.textFilename = textFilename
        self.imageFilename = imageFilename
        self.imageUTI = imageUTI
        self.isPinned = isPinned
        self.isBookmarked = isBookmarked
        self.tags = tags
        self.ocrText = ocrText
        self.isLocked = isLocked
        self.folderID = folderID
        self.kind = kind
        self.fileAttachment = fileAttachment
        self.rtfFilename = rtfFilename
        self.flavorsFilename = flavorsFilename
        self.updatedAt = updatedAt ?? timestamp
        self.contentKey = contentKey
        self.folderSortIndex = folderSortIndex
        self.deletedAt = deletedAt
        self.title = title
    }

    enum CodingKeys: String, CodingKey {
        case id, type, timestamp, sourceApp, textContent, textFilename, imageFilename
        case imageUTI
        case isPinned, isBookmarked, tags, ocrText
        case isLocked, folderID, kind, fileAttachment, rtfFilename, flavorsFilename
        case updatedAt
        case contentKey
        case folderSortIndex
        case deletedAt
        case title
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.type = try container.decode(ClipboardItemType.self, forKey: .type)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.sourceApp = try container.decodeIfPresent(String.self, forKey: .sourceApp)
        self.textContent = try container.decodeIfPresent(String.self, forKey: .textContent)
        self.textFilename = try container.decodeIfPresent(String.self, forKey: .textFilename)
        self.imageFilename = try container.decodeIfPresent(String.self, forKey: .imageFilename)
        self.imageUTI = try container.decodeIfPresent(String.self, forKey: .imageUTI)
        self.isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        self.isBookmarked = try container.decodeIfPresent(Bool.self, forKey: .isBookmarked) ?? false
        self.tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.ocrText = try container.decodeIfPresent(String.self, forKey: .ocrText)
        self.isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        self.folderID = try container.decodeIfPresent(UUID.self, forKey: .folderID)
        self.kind = try container.decodeIfPresent(ContentKind.self, forKey: .kind)
        self.fileAttachment = try container.decodeIfPresent(FileAttachment.self, forKey: .fileAttachment)
        self.rtfFilename = try container.decodeIfPresent(String.self, forKey: .rtfFilename)
        self.flavorsFilename = try container.decodeIfPresent(String.self, forKey: .flavorsFilename)
        // Pre-sync files have no `updatedAt`; the capture time is the best
        // available approximation and keeps merges deterministic.
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? self.timestamp
        self.contentKey = try container.decodeIfPresent(String.self, forKey: .contentKey)
        self.folderSortIndex = try container.decodeIfPresent(Double.self, forKey: .folderSortIndex)
        self.deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(sourceApp, forKey: .sourceApp)
        try container.encodeIfPresent(textContent, forKey: .textContent)
        try container.encodeIfPresent(textFilename, forKey: .textFilename)
        try container.encodeIfPresent(imageFilename, forKey: .imageFilename)
        try container.encodeIfPresent(imageUTI, forKey: .imageUTI)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encode(isBookmarked, forKey: .isBookmarked)
        try container.encode(tags, forKey: .tags)
        try container.encodeIfPresent(ocrText, forKey: .ocrText)
        try container.encode(isLocked, forKey: .isLocked)
        try container.encodeIfPresent(folderID, forKey: .folderID)
        try container.encodeIfPresent(kind, forKey: .kind)
        try container.encodeIfPresent(fileAttachment, forKey: .fileAttachment)
        try container.encodeIfPresent(rtfFilename, forKey: .rtfFilename)
        try container.encodeIfPresent(flavorsFilename, forKey: .flavorsFilename)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(contentKey, forKey: .contentKey)
        try container.encodeIfPresent(folderSortIndex, forKey: .folderSortIndex)
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
        try container.encodeIfPresent(title, forKey: .title)
    }

    // MARK: - Content identity

    /// Key for a text clip: the SHA-256 of the **full** text. Hashed rather
    /// than stored raw so a multi-megabyte clip does not carry a second copy
    /// of itself in `history.json`, and full rather than prefixed so two long
    /// documents sharing an opening paragraph never fold into one.
    static func contentKey(forText text: String) -> String? {
        guard !text.isEmpty else { return nil }
        return "txt:" + sha256Hex(Data(text.utf8))
    }

    /// Key for an image clip: the SHA-256 of the exact bytes stored on disk.
    /// Keyed on bytes, not on `imageFilename`, because every capture writes a
    /// freshly named file — the filename is unique by construction and would
    /// never match anything.
    static func contentKey(forImageData data: Data) -> String {
        "img:" + sha256Hex(data)
    }

    /// Key for a file clip: the original name(s) plus the total byte size,
    /// the same identity the iCloud merge already folds on
    /// (`SyncMerge.dedupeKey`). Deliberately excludes the source path, so the
    /// same file copied from Finder and from a Desktop alias is one clip.
    static func contentKey(forFileNames names: [String], byteSize: Int64) -> String? {
        guard let first = names.first, !first.isEmpty else { return nil }
        return "file:\(names.joined(separator: "\u{1}")):\(byteSize)"
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Create a text clipboard item
    static func text(_ content: String, sourceApp: String? = nil) -> ClipboardItem {
        ClipboardItem(
            type: .text,
            sourceApp: sourceApp,
            textContent: content,
            contentKey: contentKey(forText: content)
        )
    }

    /// Create an image clipboard item. `uti` is the UTI of the exact bytes
    /// stored at `filename` (`public.jpeg`, `public.png`, `public.heic`,
    /// `com.compuserve.gif`, `public.webp`, ...); pass `nil` when unknown and
    /// `resolvedImageUTI` will derive a guess from `filename`'s extension.
    static func image(filename: String, uti: String? = nil, sourceApp: String? = nil) -> ClipboardItem {
        ClipboardItem(
            type: .image,
            sourceApp: sourceApp,
            imageFilename: filename,
            imageUTI: uti
        )
    }

    /// Maps a lowercased file extension to the UTI Klip stores images under.
    /// The five recognized raster formats get their canonical UTI; anything
    /// else falls back to `UTType(filenameExtension:)`'s best guess (still
    /// useful for e.g. `.tiff`/`.bmp` fallback captures), or `nil` if even
    /// that can't identify the extension.
    static func uti(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "public.jpeg"
        case "png": return "public.png"
        case "heic": return "public.heic"
        case "gif": return "com.compuserve.gif"
        case "webp": return "public.webp"
        default:
            return UTType(filenameExtension: ext)?.identifier
        }
    }

    /// This item's image UTI, falling back to a guess derived from
    /// `imageFilename`'s extension when `imageUTI` is nil (every item
    /// captured before this field existed, and any `.png` migrated from the
    /// old always-PNG capture path).
    var resolvedImageUTI: String? {
        if let imageUTI { return imageUTI }
        guard let filename = imageFilename else { return nil }
        let ext = (filename as NSString).pathExtension
        return ClipboardItem.uti(forExtension: ext)
    }

    /// Create a file clipboard item. Capture of files is Phase 3F; this factory
    /// exists so the `.file` case has a canonical construction path.
    static func file(attachment: FileAttachment, sourceApp: String? = nil) -> ClipboardItem {
        ClipboardItem(
            type: .file,
            sourceApp: sourceApp,
            kind: .file,
            fileAttachment: attachment,
            contentKey: contentKey(
                forFileNames: [attachment.originalName] + attachment.additionalNames,
                byteSize: attachment.byteSize
            )
        )
    }

    /// Create a large text clipboard item (file-backed with inline preview)
    static func largeText(preview: String, filename: String, sourceApp: String? = nil) -> ClipboardItem {
        ClipboardItem(
            type: .text,
            sourceApp: sourceApp,
            textContent: preview,
            textFilename: filename
        )
    }

    /// Whether this item's full text is stored in a separate file
    var isFileBacked: Bool {
        textFilename != nil
    }

    /// Whether this item carries a file payload.
    ///
    /// `ClipboardItemType.file` is deliberately not added yet — it would break
    /// exhaustive switches in the view files currently being split. The enum
    /// case arrives at integration; until then this is the check to use.
    /// `nonisolated` so `ContentDetector.detect(for:fullText:)`, which runs
    /// off the main actor, can ask it.
    nonisolated var isFile: Bool {
        fileAttachment != nil
    }

    /// Protected from **eviction** (the history-limit trim). Deletion is a
    /// separate, stricter rule: only `isLocked` blocks an explicit delete.
    var isProtected: Bool {
        isPinned || isBookmarked || !tags.isEmpty || isLocked || folderID != nil
    }

    /// Whether this item is editable inline
    var isEditable: Bool {
        type == .text && !isFileBacked && !isFile && (textContent?.count ?? 0) <= 5000
    }

    /// Longest name `ClipboardStore.setTitle` will store. A row shows one
    /// line of it, so anything past this is chrome the user never sees.
    static let titleMaxLength = 120

    /// The clip's name with surrounding whitespace removed, or `nil` when it
    /// has none. Views render a title only when this is non-nil, so a clip
    /// carrying a stored `"   "` from an older build still reads as unnamed.
    var displayTitle: String? {
        guard let title = title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Preview text for display (truncated for long content)
    var previewText: String {
        if let attachment = fileAttachment {
            let extra = attachment.additionalNames.count
            return extra > 0 ? "\(attachment.originalName) +\(extra)" : attachment.originalName
        }
        switch type {
        case .text:
            let text = textContent ?? ""
            if text.count > 200 {
                return String(text.prefix(200)) + "…"
            }
            return text
        case .image:
            return "Image"
        case .file:
            return fileAttachment?.originalName ?? "File"
        }
    }

    /// Content hash for duplicate detection
    var contentHash: Int {
        if let attachment = fileAttachment {
            return (attachment.storedRelativePath ?? attachment.referencePath ?? attachment.originalName).hashValue
        }
        switch type {
        case .text:
            return textContent?.hashValue ?? 0
        case .image:
            return imageFilename?.hashValue ?? 0
        case .file:
            return fileAttachment?.originalName.hashValue ?? 0
        }
    }


}

enum ClipboardItemType: String, Codable {
    case text
    case image
    /// One or more files copied from Finder. The payload lives in
    /// `ClipboardItem.fileAttachment`; capture is Phase 3F.
    case file
}
