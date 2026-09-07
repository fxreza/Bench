import Foundation
import BenchTestKit
@testable import Klip

// Content dedupe (5B): re-copying something already in the history brings the
// existing clip back to the top instead of adding a second identical row.
//
// The identity is `ClipboardItem.contentKey`, derived from the payload only —
// capture date and source app are deliberately not part of it.

enum DedupeTests {
    static let tests: [(String, () throws -> Void)] = [
        ("contentKey_text_ignoresNothingButTheText", testTextKey),
        ("contentKey_text_isFullTextNotAPrefix", testTextKeyIsFullText),
        ("contentKey_image_keyedOnBytesNotFilename", testImageKey),
        ("contentKey_file_keyedOnNamesAndSize", testFileKey),
        ("add_sameText_resurfacesInsteadOfDuplicating", testResurfaceText),
        ("add_sameText_ignoresDateAndSourceApp", testIgnoresDateAndSource),
        ("resurface_keepsPinTagsLockAndFolder", testResurfaceKeepsState),
        ("add_differentText_stillAddsASecondRow", testDifferentTextAdds),
        ("resurface_discardsTheRedundantPayloadKeepsTheSurvivors", testResurfaceDeletesIncomingAssets),
        ("backfillContentKeys_letsAnOldClipDedupe", testBackfillEnablesDedupe),
    ]

    // MARK: - Key construction

    static func testTextKey() throws {
        try expectNil(ClipboardItem.contentKey(forText: ""), "empty text has no identity")
        let a = ClipboardItem.contentKey(forText: "hello")
        let b = ClipboardItem.contentKey(forText: "hello")
        let c = ClipboardItem.contentKey(forText: "Hello")
        try expectEqual(a, b, "same text, same key")
        try expect(a != c, "case is significant")
        try expect(a?.hasPrefix("txt:") == true, "text keys are namespaced")
    }

    static func testTextKeyIsFullText() throws {
        // Two long clips sharing a 10 KB opening must not fold — the watcher's
        // consecutive-duplicate check hashes a prefix, the content key does not.
        let shared = String(repeating: "a", count: 20_000)
        let a = ClipboardItem.contentKey(forText: shared + "one")
        let b = ClipboardItem.contentKey(forText: shared + "two")
        try expect(a != b, "a shared prefix is not a shared identity")
    }

    static func testImageKey() throws {
        let bytes = Data([0x01, 0x02, 0x03])
        try expectEqual(
            ClipboardItem.contentKey(forImageData: bytes),
            ClipboardItem.contentKey(forImageData: Data([0x01, 0x02, 0x03])),
            "same bytes, same key — the on-disk filename is irrelevant"
        )
        try expect(
            ClipboardItem.contentKey(forImageData: bytes) != ClipboardItem.contentKey(forImageData: Data([0x01, 0x02, 0x04])),
            "different bytes, different key"
        )
    }

    static func testFileKey() throws {
        try expectNil(ClipboardItem.contentKey(forFileNames: [], byteSize: 10), "no names, no identity")
        try expectEqual(
            ClipboardItem.contentKey(forFileNames: ["a.pdf", "b.pdf"], byteSize: 42),
            ClipboardItem.contentKey(forFileNames: ["a.pdf", "b.pdf"], byteSize: 42)
        )
        try expect(
            ClipboardItem.contentKey(forFileNames: ["a.pdf"], byteSize: 42)
                != ClipboardItem.contentKey(forFileNames: ["a.pdf"], byteSize: 43),
            "size is part of the identity"
        )
    }

    // MARK: - Store behavior

    static func testResurfaceText() throws {
        try ClipboardStoreTests.withStore { store, _ in
            let first = ClipboardItem.text("shared clipboard note")
            store.add(first)
            store.add(ClipboardItem.text("something else"))
            try expectEqual(store.items.count, 2, "two distinct clips")
            try expect(store.items.first?.id != first.id, "the older clip is no longer on top")

            let recopy = ClipboardItem.text("shared clipboard note")
            store.add(recopy)

            try expectEqual(store.items.count, 2, "the re-copy did not add a third row")
            try expectEqual(store.items.first?.id, first.id, "the original clip came back to the top")
            try expect(!store.items.contains { $0.id == recopy.id }, "the incoming duplicate was discarded")
            try expect(
                store.items.first!.timestamp >= recopy.timestamp.addingTimeInterval(-1),
                "the surviving clip's date was refreshed to the new copy's"
            )
        }
    }

    static func testIgnoresDateAndSource() throws {
        try ClipboardStoreTests.withStore { store, _ in
            var old = ClipboardItem.text("same text", sourceApp: "Google Chrome")
            old.timestamp = Date(timeIntervalSince1970: 1_000)
            old.updatedAt = old.timestamp
            store.add(old)

            store.add(ClipboardItem.text("same text", sourceApp: "TextEdit"))

            try expectEqual(store.items.count, 1, "a different app and a two-day gap are not a different clip")
            try expectEqual(store.items.first?.sourceApp, "Google Chrome", "the original clip is the survivor")
        }
    }

    static func testResurfaceKeepsState() throws {
        try ClipboardStoreTests.withStore { store, _ in
            let folderID = store.createFolder(name: "Snippets").id
            var filed = ClipboardItem.text("keep my state")
            filed.isPinned = true
            filed.isLocked = true
            filed.tags = ["work"]
            filed.folderID = folderID
            filed.folderSortIndex = 12.5
            store.items = [filed]

            store.add(ClipboardItem.text("keep my state"))

            try expectEqual(store.items.count, 1, "still one clip")
            let survivor = store.items[0]
            try expect(survivor.isPinned, "pin survives")
            try expect(survivor.isLocked, "lock survives")
            try expectEqual(survivor.tags, ["work"], "tags survive")
            try expectEqual(survivor.folderID, folderID, "folder membership survives")
            try expectEqual(survivor.folderSortIndex, 12.5, "its manual position inside the folder is untouched")
        }
    }

    static func testDifferentTextAdds() throws {
        try ClipboardStoreTests.withStore { store, _ in
            store.add(ClipboardItem.text("one"))
            store.add(ClipboardItem.text("two"))
            store.add(ClipboardItem.text("one "))   // trailing space is a different clip
            try expectEqual(store.items.count, 3)
        }
    }

    static func testResurfaceDeletesIncomingAssets() throws {
        try ClipboardStoreTests.withStore { store, dir in
            let bytes = Data(repeating: 0x7f, count: 128)
            let key = ClipboardItem.contentKey(forImageData: bytes)

            let survivingFile = store.saveImage(bytes, fileExtension: "png")
            try expectNotNil(survivingFile)
            var survivor = ClipboardItem.image(filename: survivingFile!, uti: "public.png")
            survivor.contentKey = key
            store.items = [survivor]

            let incomingFile = store.saveImage(bytes, fileExtension: "png")
            try expectNotNil(incomingFile)
            var incoming = ClipboardItem.image(filename: incomingFile!, uti: "public.png")
            incoming.contentKey = key
            store.add(incoming)

            let images = dir.appendingPathComponent("images", isDirectory: true)
            try expectEqual(store.items.count, 1, "the duplicate image folded into the existing clip")
            try expect(
                FileManager.default.fileExists(atPath: images.appendingPathComponent(survivingFile!).path),
                "the surviving clip still has its bytes"
            )
            try expect(
                !FileManager.default.fileExists(atPath: images.appendingPathComponent(incomingFile!).path),
                "the redundant copy was removed from disk"
            )
        }
    }

    static func testBackfillEnablesDedupe() throws {
        // A clip written before `contentKey` existed carries none. The launch
        // backfill computes it so a later re-copy still folds.
        try ClipboardStoreTests.withStore { store, _ in
            let legacy = ClipboardItem(type: .text, textContent: "written before 5B")
            try expectNil(legacy.contentKey, "the raw initializer leaves the key unset")
            store.items = [legacy]

            store.backfillContentKeysIfNeeded()
            ClipboardStoreTests.pumpMainRunLoop(until: { store.items.first?.contentKey != nil })
            try expectNotNil(store.items.first?.contentKey, "the backfill filled it in")

            store.add(ClipboardItem.text("written before 5B"))
            try expectEqual(store.items.count, 1, "the old clip is recognised and resurfaced")
            try expectEqual(store.items.first?.id, legacy.id)
        }
    }
}
