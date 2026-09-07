import Foundation
import BenchTestKit
@testable import Klip

// Store persistence, eviction, lock and delete coverage (Phase 1B).
//
// Every test runs against a throwaway storage root handed to the store
// explicitly (`ClipboardStore(directory:)`), so nothing here touches the
// app's real `~/Library/Application Support/Bench/Klip`.

enum ClipboardStoreTests {
    static let tests: [(String, () throws -> Void)] = [
        ("historyLimit_fromStoredRaw_mappingTable", testHistoryLimitMapping),
        ("load_v1BareArray_isReSavedAsV2Wrapper", testLoadV1BareArray),
        ("roundTrip_v2_preservesEveryNewField", testV2RoundTrip),
        ("load_corruptFile_isRenamedNotOverwritten", testCorruptFileQuarantined),
        ("eviction_respectsMaxItems", testEvictionRespectsMaxItems),
        ("eviction_neverEvictsProtectedItems", testEvictionSkipsProtected),
        ("add_alwaysKeepsTheJustCopiedClip", testAddAlwaysKeepsNewClip),
        ("eviction_unlimited_neverEvicts", testUnlimitedNeverEvicts),
        ("handleLimitChanged_trimsOnlyUnprotected", testHandleLimitChanged),
        ("delete_refusesLockedItem", testDeleteRefusesLocked),
        ("deleteBatch_reportsSkippedLocked", testDeleteBatchSkippedLocked),
        ("clear_keepsLockedAndFolderedItems", testClearKeepsProtected),
        ("clear_keepProtectedFalse_stillKeepsLocked", testClearAllStillKeepsLocked),
        ("itemSize_usesFileAttachmentByteSize", testItemSizeFileAttachment),
        ("purge_removesFilesFlavorsAndRtfAssets", testDeleteRemovesAssets),
        ("backfillKindsIfNeeded_fillsMissingKindsAndPersists", testBackfillFillsMissingKinds),
        ("backfillKindsIfNeeded_leavesExistingKindsUntouched", testBackfillLeavesExistingKindAlone),
        ("backfillKindsIfNeeded_secondCall_isIdempotent", testBackfillIsIdempotent),
    ]

    // MARK: - Harness

    /// Runs `body` against a fresh ClipboardStore rooted in a temp directory.
    /// `seed` may populate that directory before the store is constructed.
    static func withStore<R>(
        limit: HistoryLimit = .k10,
        seed: ((URL) throws -> Void)? = nil,
        _ body: (ClipboardStore, URL) throws -> R
    ) throws -> R {
        try withTempDir { dir in
            let previousLimit = SettingsManager.shared.historyLimit
            SettingsManager.shared.historyLimit = limit
            defer { SettingsManager.shared.historyLimit = previousLimit }

            try seed?(dir)

            let store = ClipboardStore(directory: dir)
            defer { store.flushPendingSave() }
            return try body(store, dir)
        }
    }

    static func historyURL(_ dir: URL) -> URL { dir.appendingPathComponent("history.json") }

    /// Decodes the on-disk history file as the v2 wrapper.
    static func readHistoryFile(_ dir: URL) throws -> (version: Int, items: [ClipboardItem]) {
        let data = try Data(contentsOf: historyURL(dir))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? Int else {
            throw TestFailure(message: "history.json is not a versioned wrapper", file: #file, line: #line)
        }
        struct Wrapper: Decodable { let items: [ClipboardItem] }
        let wrapper = try JSONDecoder().decode(Wrapper.self, from: data)
        return (version, wrapper.items)
    }

    static func makeItem(_ text: String, at seconds: TimeInterval) -> ClipboardItem {
        ClipboardItem(type: .text, timestamp: Date(timeIntervalSince1970: seconds), textContent: text)
    }

    /// `backfillKindsIfNeeded()` computes on a background utility queue and
    /// applies its results via `DispatchQueue.main.async`, but this test
    /// binary's `main` never spins a run loop on its own (see
    /// `TestRunner.swift`'s `TestMain`), so a queued main-queue block would
    /// otherwise never get a chance to run before the test moves on. Pumping
    /// `RunLoop.main` briefly lets it drain.
    static func pumpMainRunLoop(until condition: () -> Bool, timeout: TimeInterval = 2.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    // MARK: - HistoryLimit

    static func testHistoryLimitMapping() throws {
        try expectEqual(HistoryLimit.from(storedRaw: nil), .k10, "absent value should use the default")
        try expectEqual(HistoryLimit.default, .k10, "default tier should be 10,000")
        try expectEqual(HistoryLimit.from(storedRaw: 100), .k1, "legacy 'essential' should map to 1,000")
        try expectEqual(HistoryLimit.from(storedRaw: 500), .k1, "legacy 'deep' should map to 1,000")
        try expectEqual(HistoryLimit.from(storedRaw: 1000), .k1, "legacy 'unlimited' (1000) should map to 1,000")
        try expectEqual(HistoryLimit.from(storedRaw: 5000), .k5, "5000 should map to k5")
        try expectEqual(HistoryLimit.from(storedRaw: 10000), .k10, "10000 should map to k10")
        try expectEqual(HistoryLimit.from(storedRaw: 0), .unlimited, "0 should map to unlimited")
        try expectEqual(HistoryLimit.from(storedRaw: 7), .k10, "unknown values should fall back to the default")
        try expectEqual(HistoryLimit.from(storedRaw: -1), .k10, "negative values should fall back to the default")

        try expectEqual(HistoryLimit.k1.maxItems, 1000, "k1 cap")
        try expectEqual(HistoryLimit.k5.maxItems, 5000, "k5 cap")
        try expectEqual(HistoryLimit.k10.maxItems, 10000, "k10 cap")
        try expectNil(HistoryLimit.unlimited.maxItems, "unlimited has no cap")
        try expect(HistoryLimit.unlimited.isUnlimited, "unlimited.isUnlimited should be true")
        try expect(!HistoryLimit.k10.isUnlimited, "k10.isUnlimited should be false")
        try expectEqual(HistoryLimit.allCases.count, 4, "there should be four tiers")
        try expectEqual(HistoryLimit.unlimited.label, "Unlimited", "unlimited label")
        try expectEqual(HistoryLimit.k1.label, "1,000", "k1 label")
    }

    // MARK: - Persistence

    static func testLoadV1BareArray() throws {
        let id = UUID()
        try withStore(seed: { dir in
            // A Buffer 2.5.0 history file: a bare array, no wrapper.
            let json = """
            [
              {
                "id": "\(id.uuidString)",
                "type": "text",
                "timestamp": 1700000000,
                "textContent": "legacy clip",
                "isPinned": false,
                "isBookmarked": false,
                "tags": []
              }
            ]
            """
            try Data(json.utf8).write(to: historyURL(dir))
        }) { store, dir in
            try expectEqual(store.items.count, 1, "a v1 bare array should load")
            try expectEqual(store.items[0].id, id, "the legacy item's id should survive")
            try expectEqual(store.items[0].textContent, "legacy clip", "the legacy text should survive")
            try expectEqual(store.items[0].isLocked, false, "missing isLocked should default to false")
            try expectNil(store.items[0].folderID, "missing folderID should default to nil")
            try expectNil(store.items[0].kind, "missing kind should default to nil")

            store.flushPendingSave()

            let onDisk = try readHistoryFile(dir)
            try expectEqual(onDisk.version, 2, "a loaded v1 file should be re-saved as v2")
            try expectEqual(onDisk.items.count, 1, "the item should still be there after the upgrade")
            try expectEqual(onDisk.items[0].id, id, "the upgraded file should keep the item's id")
        }
    }

    static func testV2RoundTrip() throws {
        let folderID = UUID()
        let attachment = FileAttachment(
            originalName: "Report.pdf",
            additionalNames: ["Notes.txt", "Data.csv"],
            storedRelativePath: "files/abc/Report.pdf",
            referencePath: nil,
            bookmark: Data([0x01, 0x02, 0x03]),
            uti: "com.adobe.pdf",
            byteSize: 4096
        )
        let original = ClipboardItem(
            type: .text,
            timestamp: Date(timeIntervalSince1970: 1_700_000_100),
            sourceApp: "Finder",
            textContent: "payload",
            textFilename: "abc.txt",
            imageFilename: nil,
            isPinned: true,
            isBookmarked: true,
            tags: ["work"],
            ocrText: "ocr",
            isLocked: true,
            folderID: folderID,
            kind: .file,
            fileAttachment: attachment,
            rtfFilename: "abc.rtf",
            flavorsFilename: "abc.plist"
        )

        try withStore { store, dir in
            store.add(original)
            store.flushPendingSave()

            let onDisk = try readHistoryFile(dir)
            try expectEqual(onDisk.version, 2, "history.json should be the v2 wrapper")
            try expectEqual(onDisk.items.count, 1, "one item should be on disk")
            try expectEqual(onDisk.items[0], original, "every new field should round-trip through the file")
            try expectEqual(onDisk.items[0].fileAttachment, attachment, "the file attachment should round-trip")
            try expectEqual(onDisk.items[0].folderID, folderID, "folderID should round-trip")
            try expectEqual(onDisk.items[0].kind, .file, "kind should round-trip")
            try expectEqual(onDisk.items[0].isLocked, true, "isLocked should round-trip")
            try expectEqual(onDisk.items[0].rtfFilename, "abc.rtf", "rtfFilename should round-trip")
            try expectEqual(onDisk.items[0].flavorsFilename, "abc.plist", "flavorsFilename should round-trip")

            // A second store over the same directory must see the same thing.
            let reopened = ClipboardStore(directory: dir)
            try expectEqual(reopened.items, [original], "reopening the store should reproduce the item exactly")
        }
    }

    static func testCorruptFileQuarantined() throws {
        try withStore(seed: { dir in
            try Data("{ this is not json".utf8).write(to: historyURL(dir))
        }) { store, dir in
            try expectEqual(store.items.count, 0, "a corrupt history should start empty")

            let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            let quarantined = contents.filter { $0.hasPrefix("history.corrupt-") && $0.hasSuffix(".json") }
            try expectEqual(quarantined.count, 1, "the bad file should be renamed to history.corrupt-<stamp>.json")

            try expect(
                !FileManager.default.fileExists(atPath: historyURL(dir).path),
                "the corrupt file must be moved aside, never overwritten in place"
            )

            let salvaged = try String(contentsOf: dir.appendingPathComponent(quarantined[0]), encoding: .utf8)
            try expectEqual(salvaged, "{ this is not json", "the original bytes should be preserved")
        }
    }

    // MARK: - Eviction

    static func testEvictionRespectsMaxItems() throws {
        try withStore(limit: .k1) { store, _ in
            let cap = HistoryLimit.k1.maxItems!
            store.items = (0..<cap).map { makeItem("item \($0)", at: TimeInterval(cap - $0)) }
            try expectEqual(store.items.count, cap, "precondition: the store starts exactly at the cap")

            store.add(makeItem("newest", at: 10_000))

            try expectEqual(store.items.count, cap, "adding past the cap should evict exactly one item")
            try expectEqual(store.items.first?.textContent, "newest", "the new item goes to the top")
            try expectEqual(store.items.last?.textContent, "item \(cap - 2)", "the oldest item should be the one evicted")
        }
    }

    static func testEvictionSkipsProtected() throws {
        try withStore(limit: .k1) { store, _ in
            let cap = HistoryLimit.k1.maxItems!
            var seeded = (0..<cap).map { makeItem("item \($0)", at: TimeInterval(cap - $0)) }
            // Make the five oldest items protected, one flavour each.
            seeded[cap - 1].isLocked = true
            seeded[cap - 2].folderID = UUID()
            seeded[cap - 3].isPinned = true
            seeded[cap - 4].isBookmarked = true
            seeded[cap - 5].tags = ["keep"]
            store.items = seeded
            let protectedIDs = Set(seeded.filter { $0.isProtected }.map { $0.id })
            try expectEqual(protectedIDs.count, 5, "precondition: five protected items")

            // 995 non-protected + 5 protected. Adding one more leaves 996
            // non-protected, still under the cap, so nothing is evicted and the
            // total legitimately exceeds maxItems.
            store.add(makeItem("newest", at: 10_000))
            try expectEqual(store.items.count, cap + 1, "protected items do not count toward the cap")
            try expectEqual(store.items.first?.textContent, "newest", "the just-copied clip is kept")

            // Five more adds push the non-protected count to 1001 on the last
            // one, evicting exactly one *older* non-protected item.
            for index in 0..<5 {
                store.add(makeItem("extra \(index)", at: TimeInterval(10_001 + index)))
            }

            let unprotected = store.items.filter { !$0.isProtected }
            try expectEqual(unprotected.count, cap, "the cap applies to non-protected items only")
            try expectEqual(
                store.items.count, cap + protectedIDs.count,
                "the total may exceed maxItems by exactly the number of protected items"
            )
            try expectEqual(
                Set(store.items.filter { $0.isProtected }.map { $0.id }), protectedIDs,
                "no protected item may be evicted, in any flavour"
            )
            try expectEqual(store.items.first?.textContent, "extra 4", "the newest clip is at the top")
            try expect(store.items.contains { $0.textContent == "newest" }, "earlier new clips are still present")
            try expect(!store.items.contains { $0.textContent == "item \(cap - 6)" },
                       "the oldest non-protected item is the one evicted")

            // With every stored item protected, an add evicts nothing at all.
            for index in store.items.indices { store.items[index].isLocked = true }
            let countBefore = store.items.count
            store.add(makeItem("also newest", at: 20_000))
            try expectEqual(store.items.count, countBefore + 1,
                            "when every stored item is protected the new clip is simply kept")
            try expectEqual(store.items.first?.textContent, "also newest", "and it is at the top")
        }
    }

    /// The clip the user just copied must always be in the history right after
    /// `add`, whatever the cap and whatever is already stored.
    static func testAddAlwaysKeepsNewClip() throws {
        try withStore(limit: .k1) { store, _ in
            let cap = HistoryLimit.k1.maxItems!

            // 1. History exactly at the cap, nothing protected.
            store.items = (0..<cap).map { makeItem("item \($0)", at: TimeInterval(cap - $0)) }
            let a = makeItem("fresh clip A", at: 10_000)
            store.add(a)
            try expect(store.items.contains { $0.id == a.id }, "a new clip survives a full, unprotected history")
            try expectEqual(store.items.first?.id, a.id, "and it is at the top")
            try expectEqual(store.items.count, cap, "an older non-protected item was evicted instead")

            // 2. History at the cap with every item protected.
            var locked = (0..<cap).map { makeItem("locked \($0)", at: TimeInterval(cap - $0)) }
            for index in locked.indices { locked[index].isLocked = true }
            store.items = locked
            let b = makeItem("fresh clip B", at: 10_001)
            store.add(b)
            try expect(store.items.contains { $0.id == b.id }, "a new clip survives a fully protected history")
            try expectEqual(store.items.first?.id, b.id, "and it is at the top")
            try expectEqual(store.items.count, cap + 1, "nothing was evicted to make room for it")

            // 3. History already well over the cap because of protected items.
            store.items = locked + (0..<cap).map { makeItem("loose \($0)", at: TimeInterval(cap - $0)) }
            let c = makeItem("fresh clip C", at: 10_002)
            store.add(c)
            try expect(store.items.contains { $0.id == c.id }, "a new clip survives an over-cap history")
            try expectEqual(store.items.first?.id, c.id, "and it is at the top")
            try expectEqual(store.items.filter { !$0.isProtected }.count, cap,
                            "the non-protected population is trimmed back to the cap")

            // 4. Unlimited.
            SettingsManager.shared.historyLimit = .unlimited
            let d = makeItem("fresh clip D", at: 10_003)
            store.add(d)
            try expectEqual(store.items.first?.id, d.id, "a new clip is kept under an unlimited history too")
        }
    }

    static func testUnlimitedNeverEvicts() throws {
        try withStore(limit: .unlimited) { store, _ in
            store.items = (0..<50).map { makeItem("item \($0)", at: TimeInterval(50 - $0)) }
            for index in 0..<25 {
                store.add(makeItem("extra \(index)", at: TimeInterval(1000 + index)))
            }
            try expectEqual(store.items.count, 75, "unlimited should never evict")

            NotificationCenter.default.post(name: .bufferHistoryLimitChanged, object: nil)
            try expectEqual(store.items.count, 75, "a limit-changed notification under unlimited should trim nothing")
        }
    }

    static func testHandleLimitChanged() throws {
        try withStore(limit: .k10) { store, _ in
            var seeded = (0..<1005).map { makeItem("item \($0)", at: TimeInterval(1005 - $0)) }
            seeded[1004].isLocked = true
            seeded[1003].isPinned = true
            store.items = seeded

            // Shrink the limit, then fire the notification the settings UI posts.
            SettingsManager.shared.historyLimit = .k1
            NotificationCenter.default.post(name: .bufferHistoryLimitChanged, object: nil)

            try expectEqual(store.items.filter { !$0.isProtected }.count, 1000,
                            "the non-protected population should be trimmed down to the new cap")
            try expectEqual(store.items.count, 1002,
                            "the two protected items do not count toward the cap")
            try expect(store.items.contains { $0.isLocked }, "trimming must not drop a locked item")
            try expect(store.items.contains { $0.isPinned }, "trimming must not drop a pinned item")
        }
    }

    // MARK: - Delete / lock

    static func testDeleteRefusesLocked() throws {
        try withStore { store, _ in
            let locked = ClipboardItem(type: .text, textContent: "locked", isLocked: true)
            let loose = ClipboardItem(type: .text, textContent: "loose")
            store.items = [loose, locked]

            try expect(!store.delete(locked), "deleting a locked item should return false")
            try expectEqual(store.items.count, 2, "deleting a locked item should change nothing")

            try expect(store.delete(loose), "deleting an unlocked item should return true")
            try expectEqual(store.items.count, 1, "the unlocked item should be gone")
            try expectEqual(store.items[0].id, locked.id, "only the locked item should remain")

            // Locking through the API and re-trying.
            store.toggleLock(store.items[0])
            try expectEqual(store.items[0].isLocked, false, "toggleLock should unlock a locked item")
            try expect(store.delete(store.items[0]), "an unlocked item should now be deletable")
            try expectEqual(store.items.count, 0, "the store should be empty")
        }
    }

    static func testDeleteBatchSkippedLocked() throws {
        try withStore { store, _ in
            let a = ClipboardItem(type: .text, textContent: "a")
            let b = ClipboardItem(type: .text, textContent: "b", isLocked: true)
            let c = ClipboardItem(type: .text, textContent: "c")
            let d = ClipboardItem(type: .text, textContent: "d", isLocked: true)
            store.items = [a, b, c, d]

            let result = store.delete([a, b, c, d])
            try expectEqual(result.deleted, 2, "two unlocked items should be deleted")
            try expectEqual(result.skippedLocked, 2, "two locked items should be reported as skipped")
            try expectEqual(store.items.count, 2, "only the locked items should remain")
            try expect(store.items.allSatisfy { $0.isLocked }, "everything left should be locked")

            store.setLocked(ids: [b.id, d.id], locked: false)
            let second = store.delete([b, d])
            try expectEqual(second, ClipboardStore.DeleteResult(deleted: 2, skippedLocked: 0),
                            "after unlocking, both should delete cleanly")
            try expectEqual(store.items.count, 0, "the store should be empty")
        }
    }

    static func testClearKeepsProtected() throws {
        try withStore { store, _ in
            let folderID = UUID()
            store.items = [
                ClipboardItem(type: .text, textContent: "loose"),
                ClipboardItem(type: .text, textContent: "pinned", isPinned: true),
                ClipboardItem(type: .text, textContent: "bookmarked", isBookmarked: true),
                ClipboardItem(type: .text, textContent: "tagged", tags: ["t"]),
                ClipboardItem(type: .text, textContent: "locked", isLocked: true),
                ClipboardItem(type: .text, textContent: "foldered", folderID: folderID),
            ]

            let result = store.clear()
            try expectEqual(result.deleted, 1, "only the unprotected item should be cleared")
            try expectEqual(store.items.count, 5, "all five protected items should survive clear()")
            try expect(store.items.contains { $0.isLocked }, "locked items survive clear()")
            try expect(store.items.contains { $0.folderID == folderID }, "foldered items survive clear()")
        }
    }

    static func testClearAllStillKeepsLocked() throws {
        try withStore { store, _ in
            store.items = [
                ClipboardItem(type: .text, textContent: "loose"),
                ClipboardItem(type: .text, textContent: "pinned", isPinned: true),
                ClipboardItem(type: .text, textContent: "locked", isLocked: true),
            ]

            let result = store.clear(keepProtected: false)
            try expectEqual(result.deleted, 2, "clear-everything deletes the loose and pinned items")
            try expectEqual(result.skippedLocked, 1, "the locked item is reported as skipped")
            try expectEqual(store.items.count, 1, "only the locked item survives")
            try expectEqual(store.items[0].textContent, "locked", "a lock outranks an explicit clear")
        }
    }

    // MARK: - Assets

    static func testItemSizeFileAttachment() throws {
        try withStore { store, _ in
            let attachment = FileAttachment(originalName: "Big.zip", byteSize: 987_654)
            let item = ClipboardItem(type: .text, textContent: "Big.zip", fileAttachment: attachment)
            try expectEqual(store.itemSize(for: item), 987_654, "itemSize should report the attachment's byteSize")

            let plain = ClipboardItem.text("hello")
            try expectEqual(store.itemSize(for: plain), 5, "inline text size should still be its UTF-8 byte count")
        }
    }

    static func testDeleteRemovesAssets() throws {
        try withStore { store, dir in
            let item = ClipboardItem(type: .text, textContent: "with assets")
            let fm = FileManager.default

            let itemFiles = dir.appendingPathComponent("files/\(item.id.uuidString)", isDirectory: true)
            try fm.createDirectory(at: itemFiles, withIntermediateDirectories: true)
            try Data("payload".utf8).write(to: itemFiles.appendingPathComponent("Report.pdf"))

            let flavors = dir.appendingPathComponent("flavors/\(item.id.uuidString).plist")
            try Data("flavors".utf8).write(to: flavors)

            let rtf = dir.appendingPathComponent("texts/\(item.id.uuidString).rtf")
            try Data("rtf".utf8).write(to: rtf)

            store.add(item)
            try expect(store.delete(item), "the item should delete")

            // 5D: a delete is recoverable, so the assets outlive it and are
            // destroyed only when the trashed record is purged.
            try expect(fm.fileExists(atPath: itemFiles.path), "files/<uuid>/ survives while the clip is in the trash")
            try expectEqual(store.purgeFromTrash(ids: [item.id]), 1)

            try expect(!fm.fileExists(atPath: itemFiles.path), "files/<uuid>/ should be removed")
            try expect(!fm.fileExists(atPath: flavors.path), "flavors/<uuid>.plist should be removed")
            try expect(!fm.fileExists(atPath: rtf.path), "texts/<uuid>.rtf should be removed")
        }
    }

    // MARK: - Content kind backfill (Phase 3C)

    /// Seeds a bare v2 history file (as `loadHistory()` would read on
    /// startup) with one item missing `kind` and one that already has one,
    /// bypassing `store.add(_:)` entirely so nothing sets `kind` up front —
    /// exactly the shape of history saved before Phase 3C existed.
    private static func seedHistory(_ dir: URL, itemsJSON: String) throws {
        let json = "{\"version\": 2, \"items\": [\(itemsJSON)]}"
        try Data(json.utf8).write(to: historyURL(dir))
    }

    static func testBackfillFillsMissingKinds() throws {
        let linkID = UUID()
        try withStore(seed: { dir in
            try seedHistory(dir, itemsJSON: """
            {
              "id": "\(linkID.uuidString)",
              "type": "text",
              "timestamp": 1700000000,
              "textContent": "https://example.com",
              "isPinned": false,
              "isBookmarked": false,
              "tags": []
            }
            """)
        }) { store, dir in
            // ClipboardStore.init() calls backfillKindsIfNeeded() right after
            // loadHistory(), but the work happens on a background queue —
            // right after construction the kind should still be nil.
            guard let beforeIndex = store.items.firstIndex(where: { $0.id == linkID }) else {
                throw TestFailure(message: "seeded item missing right after load", file: #file, line: #line)
            }
            try expectNil(store.items[beforeIndex].kind, "backfill must not block init/loadHistory synchronously")

            pumpMainRunLoop(until: { store.items.first(where: { $0.id == linkID })?.kind != nil })

            let kind = store.items.first(where: { $0.id == linkID })?.kind
            try expectEqual(kind, .link, "a bare URL clip should backfill to .link")

            store.flushPendingSave()
            let onDisk = try readHistoryFile(dir)
            try expectEqual(onDisk.items.first(where: { $0.id == linkID })?.kind, .link, "the backfilled kind should be saved to disk")
        }
    }

    static func testBackfillLeavesExistingKindAlone() throws {
        let linkID = UUID()
        let colorID = UUID()
        try withStore(seed: { dir in
            try seedHistory(dir, itemsJSON: """
            {
              "id": "\(linkID.uuidString)",
              "type": "text",
              "timestamp": 1700000000,
              "textContent": "https://example.com",
              "isPinned": false,
              "isBookmarked": false,
              "tags": []
            },
            {
              "id": "\(colorID.uuidString)",
              "type": "text",
              "timestamp": 1700000001,
              "textContent": "#336699",
              "isPinned": false,
              "isBookmarked": false,
              "tags": [],
              "kind": "code"
            }
            """)
        }) { store, _ in
            // The color item already has a kind (deliberately "code", which
            // detection would never produce for this text) — backfill only
            // touches items whose kind is nil, so this must survive as-is.
            pumpMainRunLoop(until: { store.items.first(where: { $0.id == linkID })?.kind != nil })

            let preExistingKind = store.items.first(where: { $0.id == colorID })?.kind
            try expectEqual(preExistingKind, .code, "an item that already had a kind must not be recomputed")
        }
    }

    static func testBackfillIsIdempotent() throws {
        let id = UUID()
        try withStore(seed: { dir in
            try seedHistory(dir, itemsJSON: """
            {
              "id": "\(id.uuidString)",
              "type": "text",
              "timestamp": 1700000000,
              "textContent": "just some plain text",
              "isPinned": false,
              "isBookmarked": false,
              "tags": []
            }
            """)
        }) { store, _ in
            pumpMainRunLoop(until: { store.items.first(where: { $0.id == id })?.kind != nil })
            try expectEqual(store.items.first(where: { $0.id == id })?.kind, .text)

            // Nothing left to compute — a second call must be a harmless no-op.
            store.backfillKindsIfNeeded()
            pumpMainRunLoop(until: { false }, timeout: 0.2)
            try expectEqual(store.items.first(where: { $0.id == id })?.kind, .text, "a repeat call must not change an already-set kind")
        }
    }
}
