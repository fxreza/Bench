import Foundation

/// Decides which clips iCloud Drive sync is allowed to carry, from the
/// per-kind checkboxes in Settings > Sync.
///
/// Pure and store-free so the rule can be unit-tested without a cloud folder
/// (see `Tests/SyncKindFilterTests.swift`). `CloudDriveSync` applies it in
/// both directions: filtered items are never written into this Mac's snapshot,
/// and a remote snapshot's filtered items are dropped before the merge, so a
/// kind switched off is neither uploaded nor downloaded.
enum SyncKindFilter {
    /// The kinds offered as checkboxes, in the same order as the history chip
    /// bar. `.richText` is deliberately absent: like the chips, a rich-text
    /// clip reads as text to the user and follows the **Text** checkbox.
    static let selectable: [ContentKind] = [
        .text, .link, .image, .file, .color, .code, .email, .phone,
    ]

    /// Everything on - the default, and what an app updating from a build
    /// without this setting keeps.
    static var all: Set<ContentKind> { Set(selectable) }

    /// The checkbox an item answers to. Falls back to the storage type for
    /// clips captured before kind detection existed (`displayKind`), and folds
    /// rich text into plain text.
    static func syncKind(for item: ClipboardItem) -> ContentKind {
        let kind = item.displayKind
        return kind == .richText ? .text : kind
    }

    static func shouldSync(_ item: ClipboardItem, enabled: Set<ContentKind>) -> Bool {
        enabled.contains(syncKind(for: item))
    }

    static func filter(_ items: [ClipboardItem], enabled: Set<ContentKind>) -> [ClipboardItem] {
        // Fast path: the default (everything on) does no work per item.
        guard enabled.count < selectable.count else { return items }
        return items.filter { shouldSync($0, enabled: enabled) }
    }
}
