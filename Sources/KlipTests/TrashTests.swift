import Foundation
import BenchTestKit
@testable import Klip

// Trash (5D): an explicit delete is recoverable until its retention window
// expires. Cap eviction is not — it stays a hard delete.
//
// The trash lives in its own array and its own `trash.json`, so these tests
// also cover the boundary that keeps it out of everything that reads `items`.

enum TrashTests {
    static let tests: [(String, () throws -> Void)] = [
        ("retention_fromStoredRaw_zeroIsForeverNotUnset", testRetentionMapping),
        ("expiredTrash_onlyPastTheWindow", testExpiredWindow),
        ("expiredTrash_foreverExpiresNothing", testExpiredForever),
        ("expiredTrash_undatedRecordsAreKept", testExpiredUndated),
        ("delete_movesToTrashAndKeepsTheAssets", testDeleteKeepsAssets),
        ("delete_refusesLockedAndTrashesNothing", testDeleteLocked),
        ("deleteBatch_movesEveryUnlockedClip", testDeleteBatch),
        ("clear_movesToTrashToo", testClearGoesToTrash),
        ("eviction_hardDeletes_neverFillsTheTrash", testEvictionSkipsTrash),
        ("restore_putsTheClipBackAndClearsDeletedAt", testRestore),
        ("restore_landsAtTheTopOfTheHistory", testRestoreGoesToTheTop),
        ("restore_ofSeveralKeepsTheTrashOrderAtTheTop", testRestoreManyOrder),
        ("restore_keepsTagsFolderAndPin", testRestoreKeepsMetadata),
        ("restore_dropsAFolderThatIsGone", testRestoreOrphanedFolder),
        ("restore_retractsTheSyncTombstone", testRestoreRetractsTombstone),
        ("purge_removesTheRecordAndItsAssets", testPurgeRemovesAssets),
        ("emptyTrash_clearsEverything", testEmptyTrash),
        ("purgeExpired_onlyTakesWhatIsPastTheWindow", testPurgeExpired),
        ("trash_survivesAReload", testTrashPersistence),
        ("trash_isNotVisibleToTheHistory", testTrashIsInvisible),
    ]

    // MARK: - Retention arithmetic

    static func testRetentionMapping() throws {
        try expectEqual(TrashRetention.from(storedRaw: nil), .days30, "no stored value means the default")
        try expectEqual(TrashRetention.from(storedRaw: 0), .forever, "a stored 0 is a deliberate Forever")
        try expectEqual(TrashRetention.from(storedRaw: 7), .days7)
        try expectEqual(TrashRetention.from(storedRaw: 999), .days30, "an unrecognised value falls back")
        try expectNil(TrashRetention.forever.days)
        try expectEqual(TrashRetention.days90.days, 90)
    }

    static func trashed(_ text: String, deletedDaysAgo: Double?, now: Date) -> ClipboardItem {
        var item = ClipboardItem.text(text)
        item.deletedAt = deletedDaysAgo.map { now.addingTimeInterval(-$0 * 86_400) }
        return item
    }

    static func testExpiredWindow() throws {
        let now = Date()
        let items = [
            trashed("old", deletedDaysAgo: 31, now: now),
            trashed("exactly at the edge", deletedDaysAgo: 30, now: now),
            trashed("fresh", deletedDaysAgo: 1, now: now),
        ]
        let expired = ClipboardStore.expiredTrash(items, retention: .days30, now: now)
        try expectEqual(
            expired.compactMap { $0.textContent },
            ["old", "exactly at the edge"],
            "the window is inclusive at its edge"
        )
    }

    static func testExpiredForever() throws {
        let now = Date()
        let items = [trashed("ancient", deletedDaysAgo: 4_000, now: now)]
        try expectEqual(ClipboardStore.expiredTrash(items, retention: .forever, now: now).count, 0)
    }

    static func testExpiredUndated() throws {
        let now = Date()
        let items = [trashed("no date", deletedDaysAgo: nil, now: now)]
        try expectEqual(
            ClipboardStore.expiredTrash(items, retention: .days7, now: now).count, 0,
            "a record we cannot age is kept, not purged"
        )
    }

    // MARK: - Delete paths

    static func withStore<R>(
        retention: TrashRetention = .days30,
        limit: HistoryLimit = .k10,
        _ body: (ClipboardStore, URL) throws -> R
    ) throws -> R {
        let previous = SettingsManager.shared.trashRetention
        SettingsManager.shared.trashRetention = retention
        defer { SettingsManager.shared.trashRetention = previous }
        return try ClipboardStoreTests.withStore(limit: limit) { store, dir in
            try body(store, dir)
        }
    }

    static func testDeleteKeepsAssets() throws {
        try withStore { store, dir in
            let bytes = Data(repeating: 0x11, count: 64)
            guard let filename = store.saveImage(bytes, fileExtension: "png") else {
                throw TestFailure(message: "could not seed an image", file: #file, line: #line)
            }
            let item = ClipboardItem.image(filename: filename, uti: "public.png")
            store.items = [item]

            try expect(store.delete(item), "the delete went through")
            try expectEqual(store.items.count, 0, "gone from the history")
            try expectEqual(store.trashedItems.count, 1, "and sitting in the trash")
            try expectNotNil(store.trashedItems.first?.deletedAt, "stamped with when it went")
            try expect(
                FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("images").appendingPathComponent(filename).path
                ),
                "its bytes are still on disk, so a restore is complete"
            )
        }
    }

    static func testDeleteLocked() throws {
        try withStore { store, _ in
            var locked = ClipboardItem.text("locked")
            locked.isLocked = true
            store.items = [locked]

            try expect(!store.delete(locked), "a locked clip refuses deletion")
            try expectEqual(store.items.count, 1)
            try expectEqual(store.trashedItems.count, 0, "and nothing reached the trash")
        }
    }

    static func testDeleteBatch() throws {
        try withStore { store, _ in
            let a = ClipboardItem.text("a")
            let b = ClipboardItem.text("b")
            var locked = ClipboardItem.text("locked")
            locked.isLocked = true
            store.items = [a, b, locked]

            let result = store.delete([a, b, locked])
            try expectEqual(result, ClipboardStore.DeleteResult(deleted: 2, skippedLocked: 1))
            try expectEqual(store.trashedItems.count, 2)
            try expect(store.trashedItems.allSatisfy { !$0.isLocked }, "trashed records are never locked")
        }
    }

    static func testClearGoesToTrash() throws {
        try withStore { store, _ in
            store.items = [ClipboardItem.text("one"), ClipboardItem.text("two")]
            _ = store.clear()
            try expectEqual(store.items.count, 0)
            try expectEqual(store.trashedItems.count, 2, "Clear History is recoverable too")
        }
    }

    static func testEvictionSkipsTrash() throws {
        try withStore(limit: .k1) { store, _ in
            let cap = HistoryLimit.k1.maxItems!
            store.items = (0..<cap).map {
                ClipboardItem(type: .text, timestamp: Date(timeIntervalSince1970: TimeInterval(cap - $0)), textContent: "item \($0)")
            }
            store.add(ClipboardItem.text("fresh"))

            try expectEqual(store.items.count, cap, "the cap still evicts")
            try expectEqual(
                store.trashedItems.count, 0,
                "but housekeeping is not a delete — it must not grow a second history"
            )
        }
    }

    // MARK: - Restore

    static func testRestore() throws {
        try withStore { store, _ in
            let item = ClipboardItem.text("bring me back")
            store.items = [item]
            store.delete(item)

            try expectEqual(store.restoreFromTrash(ids: [item.id]), 1)
            try expectEqual(store.items.count, 1, "back in the history")
            try expectEqual(store.trashedItems.count, 0, "and out of the trash")
            try expectNil(store.items.first?.deletedAt)
        }
    }

    /// 5E. The clip that comes back is the one someone just went looking for,
    /// so it goes to row one — not back to the position it was deleted from,
    /// which for an old clip is hundreds of rows down.
    static func testRestoreGoesToTheTop() throws {
        try withStore { store, _ in
            let old = ClipboardItem.text("deleted from way down the list")
            let newer = [
                ClipboardItem.text("one"),
                ClipboardItem.text("two"),
                ClipboardItem.text("three"),
            ]
            store.items = newer + [old]
            let before = Date()
            store.delete(old)
            try expectEqual(store.items.count, 3, "the old clip left the history")

            store.restoreFromTrash(ids: [old.id])
            try expectEqual(store.items.first?.id, old.id, "it comes back at the top, not where it was")
            try expectEqual(store.items.count, 4)
            try expect(
                (store.items.first?.timestamp ?? .distantPast) >= before,
                "its date moves to now, so a sync merge's re-sort keeps it there"
            )
        }
    }

    static func testRestoreManyOrder() throws {
        try withStore { store, _ in
            let a = ClipboardItem.text("a")
            let b = ClipboardItem.text("b")
            let c = ClipboardItem.text("c")
            store.items = [a, b, c, ClipboardItem.text("survivor")]
            store.delete([a, b, c])
            try expectEqual(store.trashedItems.map { $0.id }, [a.id, b.id, c.id],
                            "the trash holds them newest-deletion-first")

            store.restoreFromTrash(ids: [a.id, b.id, c.id])
            try expectEqual(
                Array(store.items.prefix(3)).map { $0.id },
                [a.id, b.id, c.id],
                "a bulk restore lands at the top in the order the trash listed them"
            )
        }
    }

    static func testRestoreKeepsMetadata() throws {
        try withStore { store, _ in
            let folder = store.createFolder(name: "Keep")
            var item = ClipboardItem.text("filed and tagged")
            item.folderID = folder.id
            item.folderSortIndex = 2
            item.tags = ["work"]
            item.isPinned = true
            store.items = [item, ClipboardItem.text("other")]
            store.delete(item)
            store.restoreFromTrash(ids: [item.id])

            let restored = store.items.first { $0.id == item.id }
            try expectEqual(restored?.folderID, folder.id, "its folder survives")
            try expectEqual(restored?.folderSortIndex, 2, "and its place in that folder")
            try expectEqual(restored?.tags, ["work"], "and its tags")
            try expectEqual(restored?.isPinned, true, "and its pin")
        }
    }

    static func testRestoreOrphanedFolder() throws {
        try withStore { store, _ in
            let folder = store.createFolder(name: "Snippets")
            var filed = ClipboardItem.text("filed")
            filed.folderID = folder.id
            filed.folderSortIndex = 3
            store.items = [filed]
            store.delete(filed)

            store.deleteFolder(id: folder.id, mode: .moveItemsOut)
            store.restoreFromTrash(ids: [filed.id])

            try expectNil(store.items.first?.folderID, "the folder is gone, so the clip comes back loose")
            try expectNil(store.items.first?.folderSortIndex, "and without a manual position")
        }
    }

    static func testRestoreRetractsTombstone() throws {
        try withStore { store, _ in
            var deletedIDs: [UUID] = []
            var restoredIDs: [UUID] = []
            store.onItemsDeleted = { deletedIDs.append(contentsOf: $0) }
            store.onItemsRestored = { restoredIDs.append(contentsOf: $0) }

            let item = ClipboardItem.text("synced clip")
            store.items = [item]
            store.delete(item)
            store.restoreFromTrash(ids: [item.id])

            try expectEqual(deletedIDs, [item.id], "the delete still tombstones for the other Macs")
            try expectEqual(restoredIDs, [item.id], "and the restore retracts it")
        }
    }

    // MARK: - Purge

    static func testPurgeRemovesAssets() throws {
        try withStore { store, dir in
            let bytes = Data(repeating: 0x22, count: 64)
            guard let filename = store.saveImage(bytes, fileExtension: "png") else {
                throw TestFailure(message: "could not seed an image", file: #file, line: #line)
            }
            let item = ClipboardItem.image(filename: filename, uti: "public.png")
            store.items = [item]
            store.delete(item)

            try expectEqual(store.purgeFromTrash(ids: [item.id]), 1)
            try expectEqual(store.trashedItems.count, 0)
            try expect(
                !FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("images").appendingPathComponent(filename).path
                ),
                "purging is the one path that destroys the bytes"
            )
        }
    }

    static func testEmptyTrash() throws {
        try withStore { store, _ in
            store.items = [ClipboardItem.text("a"), ClipboardItem.text("b")]
            _ = store.clear()
            try expectEqual(store.emptyTrash(), 2)
            try expectEqual(store.trashedItems.count, 0)
        }
    }

    static func testPurgeExpired() throws {
        try withStore(retention: .days7) { store, _ in
            let a = ClipboardItem.text("stale")
            let b = ClipboardItem.text("recent")
            store.items = [a, b]
            _ = store.clear()

            // Age one of the two records past the window.
            let now = Date()
            store.purgeExpiredTrash(now: now)
            try expectEqual(store.trashedItems.count, 2, "nothing is expired yet")

            store.purgeExpiredTrash(now: now.addingTimeInterval(8 * 86_400))
            try expectEqual(store.trashedItems.count, 0, "eight days on, both are past a 7-day window")
        }
    }

    // MARK: - Persistence and isolation

    static func testTrashPersistence() throws {
        try withTempDir { dir in
            let id: UUID
            do {
                let store = ClipboardStore(directory: dir)
                let item = ClipboardItem.text("deleted before a restart")
                id = item.id
                store.items = [item]
                store.delete(item)
                store.flushPendingSave()
            }

            let reopened = ClipboardStore(directory: dir)
            try expectEqual(reopened.trashedItems.count, 1, "trash.json was written and read back")
            try expectEqual(reopened.trashedItems.first?.id, id)
            try expectNotNil(reopened.trashedItems.first?.deletedAt)
        }
    }

    static func testTrashIsInvisible() throws {
        try withStore { store, _ in
            let folder = store.createFolder(name: "Snippets")
            var filed = ClipboardItem.text("filed")
            filed.folderID = folder.id
            store.items = [filed, ClipboardItem.text("loose")]
            store.delete(filed)

            try expectEqual(store.items(inFolder: folder.id).count, 0, "gone from its folder")
            try expectEqual(store.folderCounts()[folder.id] ?? 0, 0, "and from the folder count")
            try expectEqual(
                FilterState.apply(store.items, FilterState(scope: .all)).count, 1,
                "and from the list, without any filter having to know about the trash"
            )
        }
    }
}
