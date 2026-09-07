import Foundation
import BenchTestKit
@testable import Klip

// Settings > Sync "What to Sync": the per-kind checkboxes, as pure-function
// tests. `CloudDriveSync` applies `SyncKindFilter` to its own snapshot before
// pushing and to every remote snapshot before merging, so these rules decide
// both directions.

enum SyncKindFilterTests {
    static let tests: [(String, () throws -> Void)] = [
        ("everythingChecked_passesEverythingThrough", testAllPasses),
        ("uncheckedKind_isFilteredOut", testUncheckedFiltered),
        ("richText_followsTheTextCheckbox", testRichTextFollowsText),
        ("undetectedKind_fallsBackToTheStorageType", testFallbackToType),
        ("nothingChecked_syncsNothing", testEmptySelection),
    ]

    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    static func item(_ kind: ContentKind?, type: ClipboardItemType = .text) -> ClipboardItem {
        ClipboardItem(
            id: UUID(),
            type: type,
            timestamp: t0,
            textContent: "x",
            kind: kind,
            updatedAt: t0
        )
    }

    static func testAllPasses() throws {
        let items = SyncKindFilter.selectable.map { item($0) }
        let kept = SyncKindFilter.filter(items, enabled: SyncKindFilter.all)
        try expectEqual(kept.count, items.count, "every kind checked should keep every clip")
    }

    static func testUncheckedFiltered() throws {
        let text = item(.text)
        let link = item(.link)
        let image = item(.image, type: .image)
        var kinds = SyncKindFilter.all
        kinds.remove(.image)
        kinds.remove(.link)

        let kept = SyncKindFilter.filter([text, link, image], enabled: kinds)
        try expectEqual(kept.map { $0.id }, [text.id], "only the checked kinds should survive")
    }

    static func testRichTextFollowsText() throws {
        let rich = item(.richText)
        try expect(
            SyncKindFilter.shouldSync(rich, enabled: [.text]),
            "rich text has no checkbox of its own and should follow Text"
        )
        try expect(
            !SyncKindFilter.shouldSync(rich, enabled: [.link, .image]),
            "rich text should not sync when Text is unchecked"
        )
    }

    static func testFallbackToType() throws {
        // Captured before kind detection existed: `kind` is nil, so the
        // checkbox is decided by the storage type.
        let image = item(nil, type: .image)
        try expect(SyncKindFilter.shouldSync(image, enabled: [.image]), "an undetected image should read as Image")
        try expect(!SyncKindFilter.shouldSync(image, enabled: [.text]), "an undetected image is not Text")
    }

    static func testEmptySelection() throws {
        let items = SyncKindFilter.selectable.map { item($0) }
        try expect(SyncKindFilter.filter(items, enabled: []).isEmpty, "no checkbox on means nothing syncs")
    }
}
