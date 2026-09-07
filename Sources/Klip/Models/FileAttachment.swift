import Foundation

/// File payload attached to a clipboard item.
///
/// Two storage strategies, distinguished by `isReference`:
/// - **copied**: bytes live under `files/<item-uuid>/` inside the app's storage
///   directory; `storedRelativePath` is the path relative to that directory.
/// - **reference**: only the original on-disk location is remembered
///   (`referencePath` plus, when available, a security-scoped `bookmark`).
///
/// Multi-file copies keep the first name in `originalName` and the rest in
/// `additionalNames`, so the row can render "Foo.pdf +3" without loading
/// anything from disk.
struct FileAttachment: Codable, Equatable {
    /// Display name of the (first) file, e.g. "Report.pdf".
    var originalName: String

    /// Display names of any further files in the same copy operation.
    var additionalNames: [String] = []

    /// Path relative to the storage root when the file was copied in
    /// (`files/<uuid>/<name>`). `nil` for reference attachments.
    var storedRelativePath: String?

    /// Absolute path of the original file when it was not copied in.
    var referencePath: String?

    /// Security-scoped bookmark for `referencePath`, so the file stays
    /// reachable across launches.
    var bookmark: Data?

    /// Uniform Type Identifier, e.g. "com.adobe.pdf".
    var uti: String?

    /// Total size in bytes of the attachment (all files).
    var byteSize: Int64

    // --- Phase 4A (iCloud Drive sync) ---
    /// Set when the payload was too large for the sync attachment cap
    /// (`sync.maxAttachmentMB`) and was therefore left local-only. The clip
    /// itself still syncs; only its bytes stay on this Mac.
    var syncSkippedLarge: Bool = false
    // --- end Phase 4A ---

    /// True when the bytes were left in place rather than copied into storage.
    var isReference: Bool { storedRelativePath == nil }

    init(
        originalName: String,
        additionalNames: [String] = [],
        storedRelativePath: String? = nil,
        referencePath: String? = nil,
        bookmark: Data? = nil,
        uti: String? = nil,
        byteSize: Int64 = 0,
        syncSkippedLarge: Bool = false
    ) {
        self.originalName = originalName
        self.additionalNames = additionalNames
        self.storedRelativePath = storedRelativePath
        self.referencePath = referencePath
        self.bookmark = bookmark
        self.uti = uti
        self.byteSize = byteSize
        self.syncSkippedLarge = syncSkippedLarge
    }

    enum CodingKeys: String, CodingKey {
        case originalName, additionalNames, storedRelativePath, referencePath, bookmark, uti, byteSize
        case syncSkippedLarge
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.originalName = try container.decode(String.self, forKey: .originalName)
        self.additionalNames = try container.decodeIfPresent([String].self, forKey: .additionalNames) ?? []
        self.storedRelativePath = try container.decodeIfPresent(String.self, forKey: .storedRelativePath)
        self.referencePath = try container.decodeIfPresent(String.self, forKey: .referencePath)
        self.bookmark = try container.decodeIfPresent(Data.self, forKey: .bookmark)
        self.uti = try container.decodeIfPresent(String.self, forKey: .uti)
        self.byteSize = try container.decodeIfPresent(Int64.self, forKey: .byteSize) ?? 0
        self.syncSkippedLarge = try container.decodeIfPresent(Bool.self, forKey: .syncSkippedLarge) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(originalName, forKey: .originalName)
        try container.encode(additionalNames, forKey: .additionalNames)
        try container.encodeIfPresent(storedRelativePath, forKey: .storedRelativePath)
        try container.encodeIfPresent(referencePath, forKey: .referencePath)
        try container.encodeIfPresent(bookmark, forKey: .bookmark)
        try container.encodeIfPresent(uti, forKey: .uti)
        try container.encode(byteSize, forKey: .byteSize)
        try container.encode(syncSkippedLarge, forKey: .syncSkippedLarge)
    }
}
