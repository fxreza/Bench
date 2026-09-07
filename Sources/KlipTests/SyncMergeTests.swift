import Foundation
import BenchTestKit
@testable import Klip

// Phase 4A: every rule of the iCloud Drive merge, as pure-function tests.
// `SyncMerge` does no I/O and reads no clock (`now` is passed in), so these run
// instantly and deterministically — the file-level behaviour on top of it is
// covered by `CloudDriveSyncTests`.

enum SyncMergeTests {
    static let tests: [(String, () throws -> Void)] = [
        ("sameID_newestUpdatedAtWinsWholeRecord", testNewestUpdatedAtWins),
        ("sameID_tagsAreUnioned", testTagsUnioned),
        ("remoteOnlyItems_areAdopted", testRemoteOnlyItemsAdopted),
        ("localOnlyItems_survive", testLocalOnlyItemsSurvive),
        ("tombstoneNewerThanUpdatedAt_deletesTheItem", testTombstoneDeletes),
        ("tombstoneOlderThanUpdatedAt_losesToTheEdit", testStaleTombstoneLoses),
        ("tombstones_areUnionedAndPrunedAtThirtyDays", testTombstonePruning),
        ("evictedID_neverResurrectsFromAnotherDevice", testEvictionIgnore),
        ("evictedID_doesNotDropAStillPresentLocalItem", testEvictionIgnoreOnlyRemoteOnly),
        ("evictionIgnore_expiresAfterThirtyDays", testEvictionIgnoreExpires),
        ("contentDedupe_keepsOlderAndUnionsFlagsTagsFolder", testContentDedupe),
        ("contentDedupe_neverFoldsTwoLocalClips", testNoLocalDedupe),
        ("contentDedupe_ignoresEmptyContent", testEmptyContentNotDeduped),
        ("folders_newestUpdatedAtWins", testFolderNewestWins),
        ("folderTombstone_removesFolderAndOrphansItemsKeepingTheLock", testDeletedFolderOrphansItems),
        ("items_areSortedNewestFirst", testOrdering),
        ("convergedState_reportsNoChange", testIdempotent),
        ("removedItems_listsWhatTheMergeDropped", testRemovedItemsReported),
        ("arrivedItemIDs_listsWhatCameFromRemote", testArrivedIDsReported),
    ]

    // MARK: - Harness

    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    static func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

    static func item(
        _ text: String,
        id: UUID = UUID(),
        created: TimeInterval = 0,
        updated: TimeInterval? = nil,
        tags: [String] = [],
        pinned: Bool = false,
        bookmarked: Bool = false,
        locked: Bool = false,
        folderID: UUID? = nil
    ) -> ClipboardItem {
        ClipboardItem(
            id: id,
            type: .text,
            timestamp: at(created),
            textContent: text,
            isPinned: pinned,
            isBookmarked: bookmarked,
            tags: tags,
            isLocked: locked,
            folderID: folderID,
            updatedAt: at(updated ?? created)
        )
    }

    static func folder(
        _ name: String,
        id: UUID = UUID(),
        created: TimeInterval = 0,
        updated: TimeInterval? = nil,
        sortIndex: Int = 0
    ) -> Folder {
        Folder(id: id, name: name, createdAt: at(created), sortIndex: sortIndex, updatedAt: at(updated ?? created))
    }

    static func remote(
        _ id: String = "device-B",
        items: [ClipboardItem] = [],
        folders: [Folder] = [],
        deleted: [SyncTombstone] = [],
        deletedFolders: [SyncTombstone] = []
    ) -> SyncDeviceSnapshot {
        SyncDeviceSnapshot(
            deviceID: id,
            deviceName: id,
            lastPush: at(1000),
            items: items,
            folders: folders,
            deleted: deleted,
            deletedFolders: deletedFolders
        )
    }

    static func merge(
        local: [ClipboardItem] = [],
        localFolders: [Folder] = [],
        localDeleted: [SyncTombstone] = [],
        localDeletedFolders: [SyncTombstone] = [],
        ignored: [UUID: Date] = [:],
        remotes: [SyncDeviceSnapshot] = [],
        now: TimeInterval = 2000
    ) -> SyncMerge.Result {
        SyncMerge.merge(SyncMerge.Input(
            localItems: local,
            localFolders: localFolders,
            localDeleted: localDeleted,
            localDeletedFolders: localDeletedFolders,
            ignoredIDs: ignored,
            remotes: remotes,
            now: at(now)
        ))
    }

    // MARK: - Same id

    static func testNewestUpdatedAtWins() throws {
        let id = UUID()
        let mine = item("old text", id: id, created: 10, updated: 20, pinned: true)
        var theirs = mine
        theirs.textContent = "new text"
        theirs.updatedAt = at(50)
        theirs.isPinned = false

        let result = merge(local: [mine], remotes: [remote(items: [theirs])])

        try expectEqual(result.items.count, 1, "same id must not duplicate")
        try expectEqual(result.items[0].textContent, "new text", "newest updatedAt wins")
        try expect(!result.items[0].isPinned, "the whole record is replaced, not merged field by field")
        try expect(result.changed, "the local copy changed")

        // …and the other way round: an older remote loses.
        let reverse = merge(local: [theirs], remotes: [remote(items: [mine])])
        try expectEqual(reverse.items[0].textContent, "new text", "an older remote must not win")
        try expect(!reverse.changed, "nothing to apply when the local copy is already newest")
    }

    static func testTagsUnioned() throws {
        let id = UUID()
        let mine = item("x", id: id, created: 10, updated: 20, tags: ["work"])
        var theirs = mine
        theirs.updatedAt = at(50)
        theirs.tags = ["home"]

        let result = merge(local: [mine], remotes: [remote(items: [theirs])])
        try expectEqual(result.items.count, 1)
        try expectEqual(Set(result.items[0].tags), Set(["work", "home"]), "tags are a union, never a replacement")
    }

    static func testRemoteOnlyItemsAdopted() throws {
        let mine = item("mine", created: 10)
        let theirs = item("theirs", created: 20)
        let result = merge(local: [mine], remotes: [remote(items: [theirs])])
        try expectEqual(result.items.count, 2)
        try expect(result.items.contains { $0.textContent == "theirs" }, "remote item should arrive")
        try expectEqual(result.arrivedItemIDs, [theirs.id])
    }

    static func testLocalOnlyItemsSurvive() throws {
        let mine = item("mine", created: 10)
        let result = merge(local: [mine], remotes: [remote(items: [])])
        try expectEqual(result.items.count, 1)
        try expect(!result.changed, "no remote data means nothing to do")
    }

    // MARK: - Tombstones

    static func testTombstoneDeletes() throws {
        let doomed = item("bye", created: 10, updated: 10)
        let kept = item("stay", created: 20)
        let result = merge(
            local: [doomed, kept],
            remotes: [remote(deleted: [SyncTombstone(id: doomed.id, deletedAt: at(30))])]
        )
        try expectEqual(result.items.map { $0.textContent }, ["stay"])
        try expectEqual(result.removedItems.map { $0.id }, [doomed.id], "the caller must know to delete its assets")
        try expect(result.deleted.contains { $0.id == doomed.id }, "the tombstone is republished so it travels on")
    }

    static func testStaleTombstoneLoses() throws {
        // Deleted on the other Mac at t=30, edited here at t=40: the edit wins,
        // otherwise an old delete would keep eating a re-created clip.
        let edited = item("edited", created: 10, updated: 40)
        let result = merge(
            local: [edited],
            remotes: [remote(deleted: [SyncTombstone(id: edited.id, deletedAt: at(30))])]
        )
        try expectEqual(result.items.count, 1, "an edit newer than the delete keeps the item")
        try expect(result.removedItems.isEmpty, "nothing was removed")
    }

    static func testTombstonePruning() throws {
        // "Now" is 40 days past the old tombstone and an hour past the fresh one.
        let now: TimeInterval = 40 * 24 * 3600
        let old = SyncTombstone(id: UUID(), deletedAt: at(0))
        let fresh = SyncTombstone(id: UUID(), deletedAt: at(now - 3600))
        let result = merge(localDeleted: [old, fresh], now: now)
        try expectEqual(result.deleted.count, 1, "tombstones older than 30 days are dropped")
        try expectEqual(result.deleted.first?.id, fresh.id)

        // Union across devices keeps the newest record of the same delete.
        let id = UUID()
        let union = merge(
            localDeleted: [SyncTombstone(id: id, deletedAt: at(100))],
            remotes: [remote(deleted: [SyncTombstone(id: id, deletedAt: at(300))])]
        )
        try expectEqual(union.deleted.count, 1)
        try expectEqual(union.deleted.first?.deletedAt, at(300))
    }

    // MARK: - Eviction (sync-ignore)

    static func testEvictionIgnore() throws {
        // The cap evicted this clip here; the other Mac still has it. It must
        // not come back — and no tombstone was written, so the other Mac keeps
        // its own copy.
        let evicted = item("evicted", created: 10)
        let result = merge(
            local: [],
            ignored: [evicted.id: at(100)],
            remotes: [remote(items: [evicted])]
        )
        try expect(result.items.isEmpty, "an evicted clip must never resurrect")
        try expect(result.deleted.isEmpty, "eviction writes no tombstone")
        try expect(!result.changed, "no change to apply")
    }

    static func testEvictionIgnoreOnlyRemoteOnly() throws {
        // A stale ignore entry for an item that is present locally again must
        // not delete it.
        let present = item("present", created: 10)
        let result = merge(
            local: [present],
            ignored: [present.id: at(100)],
            remotes: [remote(items: [present])]
        )
        try expectEqual(result.items.count, 1, "the local copy outranks a stale ignore entry")
    }

    static func testEvictionIgnoreExpires() throws {
        let evicted = item("evicted", created: 10)
        let now: TimeInterval = 100 + 40 * 24 * 3600
        let result = merge(
            local: [],
            ignored: [evicted.id: at(100)],
            remotes: [remote(items: [evicted])],
            now: now
        )
        try expectEqual(result.items.count, 1, "after 30 days the ignore entry expires and the clip may return")
    }

    // MARK: - Content dedupe

    static func testContentDedupe() throws {
        // Same text captured on both Macs under different ids.
        let mine = item("hello", created: 100, updated: 100, tags: ["work"], pinned: true)
        let folderID = UUID()
        var theirs = item("hello", created: 50, updated: 60, tags: ["home"], locked: true)
        theirs.folderID = folderID

        let result = merge(
            local: [mine],
            localFolders: [folder("Snippets", id: folderID, created: 0)],
            remotes: [remote(items: [theirs])]
        )

        try expectEqual(result.items.count, 1, "the duplicate is folded, not kept twice")
        let merged = result.items[0]
        try expectEqual(merged.id, theirs.id, "the older record survives")
        try expect(merged.isPinned, "flags are OR-ed")
        try expect(merged.isLocked, "flags are OR-ed")
        try expectEqual(Set(merged.tags), Set(["home", "work"]), "tags are unioned")
        try expectEqual(merged.folderID, folderID, "a folder membership from either side is kept")
        try expectEqual(result.removedItems.map { $0.id }, [mine.id], "the local loser's assets can go")
    }

    static func testNoLocalDedupe() throws {
        // Copying the same text twice on this Mac is two history entries.
        let first = item("same", created: 10)
        let second = item("same", created: 20)
        let result = merge(local: [first, second], remotes: [remote(items: [])])
        try expectEqual(result.items.count, 2, "two local clips are never folded into one")
    }

    static func testEmptyContentNotDeduped() throws {
        let mine = ClipboardItem(id: UUID(), type: .text, timestamp: at(10), textContent: nil, updatedAt: at(10))
        let theirs = ClipboardItem(id: UUID(), type: .text, timestamp: at(20), textContent: nil, updatedAt: at(20))
        let result = merge(local: [mine], remotes: [remote(items: [theirs])])
        try expectEqual(result.items.count, 2, "items with no comparable content are never deduped")
    }

    // MARK: - Folders

    static func testFolderNewestWins() throws {
        let id = UUID()
        let mine = folder("Old name", id: id, created: 10, updated: 20)
        let theirs = folder("New name", id: id, created: 10, updated: 40)
        let result = merge(localFolders: [mine], remotes: [remote(folders: [theirs])])
        try expectEqual(result.folders.count, 1)
        try expectEqual(result.folders[0].name, "New name")
    }

    static func testDeletedFolderOrphansItems() throws {
        let folderID = UUID()
        let inFolder = item("filed", created: 10, updated: 10, locked: true, folderID: folderID)
        let result = merge(
            local: [inFolder],
            localFolders: [folder("Doomed", id: folderID, created: 5, updated: 5)],
            remotes: [remote(deletedFolders: [SyncTombstone(id: folderID, deletedAt: at(30))])]
        )
        try expect(result.folders.isEmpty, "the folder is gone")
        try expectEqual(result.items.count, 1, "its items are not deleted with it")
        try expectNil(result.items[0].folderID, "the membership is dropped")
        try expect(result.items[0].isLocked, "the lock survives losing the folder")
    }

    // MARK: - Shape of the result

    static func testOrdering() throws {
        let old = item("old", created: 10)
        let new = item("new", created: 90)
        let mid = item("mid", created: 50)
        let result = merge(local: [old], remotes: [remote(items: [new, mid])])
        try expectEqual(result.items.map { $0.textContent }, ["new", "mid", "old"], "newest first, like the store")
    }

    static func testIdempotent() throws {
        let a = item("a", created: 10)
        let b = item("b", created: 20)
        let first = merge(local: [a], remotes: [remote(items: [b])])
        try expect(first.changed, "the first merge adopts the remote item")

        let second = SyncMerge.merge(SyncMerge.Input(
            localItems: first.items,
            localFolders: first.folders,
            localDeleted: first.deleted,
            localDeletedFolders: first.deletedFolders,
            ignoredIDs: [:],
            remotes: [remote(items: [b])],
            now: at(2000)
        ))
        try expect(!second.changed, "a merged state must merge to itself — otherwise sync ping-pongs")
        try expectEqual(second.items, first.items)
    }

    static func testRemovedItemsReported() throws {
        let doomed = item("bye", created: 10, updated: 10)
        let result = merge(
            local: [doomed],
            remotes: [remote(deleted: [SyncTombstone(id: doomed.id, deletedAt: at(30))])]
        )
        try expectEqual(result.removedItems.count, 1)
        try expectEqual(result.removedItems[0].id, doomed.id)
    }

    static func testArrivedIDsReported() throws {
        let mine = item("mine", created: 10)
        let theirs = item("theirs", created: 20)
        let result = merge(local: [mine], remotes: [remote(items: [theirs])])
        try expectEqual(result.arrivedItemIDs, [theirs.id], "only genuinely new ids need their assets fetched")
    }
}
