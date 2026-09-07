import Foundation

/// A flat, one-level folder that clipboard items can be filed into.
///
/// Membership lives on the item (`ClipboardItem.folderID`), not here, so a
/// folder is pure metadata and can be reordered/renamed without rewriting the
/// items array. Persisted in `folders.json` next to `history.json`.
struct Folder: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    let createdAt: Date
    /// Position in the sidebar; lower sorts first. Duplicates are tolerated.
    var sortIndex: Int

    // --- Phase 4A (iCloud Drive sync) ---
    /// Last local change to this folder (rename, reorder). Seeded from
    /// `createdAt` for folders written before sync existed; the sync merge
    /// keeps the newest record for a given `id`.
    var updatedAt: Date
    // --- end Phase 4A ---

    init(id: UUID = UUID(), name: String, createdAt: Date = Date(), sortIndex: Int = 0, updatedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.sortIndex = sortIndex
        self.updatedAt = updatedAt ?? createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, createdAt, sortIndex, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.sortIndex = try container.decodeIfPresent(Int.self, forKey: .sortIndex) ?? 0
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? self.createdAt
    }
}
