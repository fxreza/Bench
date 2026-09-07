import Foundation
import BenchTestKit
@testable import Klip

// Folder CRUD, membership and persistence (Phase 1B).
// Shares the temp-directory harness with ClipboardStoreTests.

enum FolderTests {
    static let tests: [(String, () throws -> Void)] = [
        ("createFolder_trimsName_andDefaultsToUntitled", testCreateFolder),
        ("createFolder_allowsDuplicateNames", testDuplicateNames),
        ("renameFolder_updatesNameOnly", testRenameFolder),
        ("deleteFolder_moveItemsOut_keepsItems", testDeleteFolderMoveOut),
        ("deleteFolder_deleteItems_excludingLocked_keepsFolder", testDeleteFolderExcludingLocked),
        ("deleteFolder_deleteItems_includingLocked_removesFolder", testDeleteFolderIncludingLocked),
        ("moveItems_intoFolder_locksThem", testMoveItemsLocks),
        ("moveItems_outOfFolder_leavesLockUnchanged", testMoveItemsOutKeepsLock),
        ("folderCounts_countsMembership", testFolderCounts),
        ("reorderFolders_rewritesSortIndexes", testReorderFolders),
        ("folders_persistAsVersionedFile", testFoldersPersistence),
    ]

    static func withStore<R>(_ body: (ClipboardStore, URL) throws -> R) throws -> R {
        try ClipboardStoreTests.withStore(body)
    }

    static func text(_ s: String) -> ClipboardItem {
        ClipboardItem(type: .text, textContent: s)
    }

    // MARK: - Create / rename

    static func testCreateFolder() throws {
        try withStore { store, _ in
            let trimmed = store.createFolder(name: "  Receipts  ")
            try expectEqual(trimmed.name, "Receipts", "the name should be trimmed")

            let blank = store.createFolder(name: "   ")
            try expectEqual(blank.name, "Untitled Folder", "a blank name should fall back to Untitled Folder")

            let empty = store.createFolder(name: "")
            try expectEqual(empty.name, "Untitled Folder", "an empty name should fall back to Untitled Folder")

            try expectEqual(store.folders.count, 3, "three folders should exist")
            try expectEqual(store.folders.map { $0.sortIndex }, [0, 1, 2], "sortIndex should increment on create")
            try expectEqual(store.folders[0].id, trimmed.id, "folders should stay in sortIndex order")
        }
    }

    static func testDuplicateNames() throws {
        try withStore { store, _ in
            let a = store.createFolder(name: "Snippets")
            let b = store.createFolder(name: "Snippets")
            try expect(a.id != b.id, "duplicate names should still produce distinct folders")
            try expectEqual(store.folders.count, 2, "both folders should be kept")
        }
    }

    static func testRenameFolder() throws {
        try withStore { store, _ in
            let folder = store.createFolder(name: "Old")
            store.renameFolder(id: folder.id, to: "  New  ")
            try expectEqual(store.folders[0].name, "New", "rename should trim and apply")
            try expectEqual(store.folders[0].id, folder.id, "rename should not change the id")
            try expectEqual(store.folders[0].createdAt, folder.createdAt, "rename should not change createdAt")

            store.renameFolder(id: folder.id, to: "  ")
            try expectEqual(store.folders[0].name, "Untitled Folder", "renaming to blank falls back to Untitled Folder")

            store.renameFolder(id: UUID(), to: "Ghost")
            try expectEqual(store.folders.count, 1, "renaming an unknown folder should be a no-op")
        }
    }

    // MARK: - Delete

    static func testDeleteFolderMoveOut() throws {
        try withStore { store, _ in
            let folder = store.createFolder(name: "Work")
            let a = text("a"), b = text("b"), outside = text("outside")
            store.items = [a, b, outside]
            store.moveItems(ids: [a.id, b.id], toFolder: folder.id)

            let result = store.deleteFolder(id: folder.id, mode: .moveItemsOut)
            try expectEqual(result, ClipboardStore.FolderDeleteResult(
                folderDeleted: true, movedOut: 2, deleted: 0, skippedLocked: 0
            ), "moveItemsOut should report two moved and delete the folder")
            try expectEqual(store.folders.count, 0, "the folder should be gone")
            try expectEqual(store.items.count, 3, "no items should be deleted")
            try expect(store.items.allSatisfy { $0.folderID == nil }, "membership should be cleared")
            try expect(store.items.filter { $0.id != outside.id }.allSatisfy { $0.isLocked },
                       "moving out should leave the lock the folder applied untouched")
        }
    }

    static func testDeleteFolderExcludingLocked() throws {
        try withStore { store, _ in
            let folder = store.createFolder(name: "Work")
            let a = text("a"), b = text("b")
            store.items = [a, b]
            store.moveItems(ids: [a.id, b.id], toFolder: folder.id)
            // Filing locks both; unlock one so there is something deletable.
            store.setLocked(ids: [a.id], locked: false)

            let result = store.deleteFolder(id: folder.id, mode: .deleteItems(includeLocked: false))
            try expectEqual(result, ClipboardStore.FolderDeleteResult(
                folderDeleted: false, movedOut: 0, deleted: 1, skippedLocked: 1
            ), "the locked item should be skipped and the folder kept")
            try expectEqual(store.folders.count, 1, "the folder must survive while a locked item is still inside")
            try expectEqual(store.items.count, 1, "only the unlocked item should be deleted")
            try expectEqual(store.items[0].id, b.id, "the locked item should remain")
            try expectEqual(store.items[0].folderID, folder.id, "the locked item stays in the folder")

            // No locked items left after unlocking: the folder now goes too.
            store.setLocked(ids: [b.id], locked: false)
            let second = store.deleteFolder(id: folder.id, mode: .deleteItems(includeLocked: false))
            try expectEqual(second, ClipboardStore.FolderDeleteResult(
                folderDeleted: true, movedOut: 0, deleted: 1, skippedLocked: 0
            ), "with nothing locked the folder and its items go together")
            try expectEqual(store.folders.count, 0, "the folder should be gone")
            try expectEqual(store.items.count, 0, "the folder's items should be gone")
        }
    }

    static func testDeleteFolderIncludingLocked() throws {
        try withStore { store, _ in
            let folder = store.createFolder(name: "Work")
            let a = text("a"), b = text("b"), outside = text("outside")
            store.items = [a, b, outside]
            store.moveItems(ids: [a.id, b.id], toFolder: folder.id)

            let result = store.deleteFolder(id: folder.id, mode: .deleteItems(includeLocked: true))
            try expectEqual(result, ClipboardStore.FolderDeleteResult(
                folderDeleted: true, movedOut: 0, deleted: 2, skippedLocked: 0
            ), "includeLocked should delete everything in the folder")
            try expectEqual(store.folders.count, 0, "the folder should be gone")
            try expectEqual(store.items.count, 1, "only the item outside the folder should remain")
            try expectEqual(store.items[0].id, outside.id, "the outside item should be untouched")

            let ghost = store.deleteFolder(id: UUID(), mode: .moveItemsOut)
            try expectEqual(ghost.folderDeleted, false, "deleting an unknown folder should be a no-op")
        }
    }

    // MARK: - Membership

    static func testMoveItemsLocks() throws {
        try withStore { store, _ in
            let folder = store.createFolder(name: "Work")
            let a = text("a"), b = text("b")
            store.items = [a, b]

            store.moveItems(ids: [a.id], toFolder: folder.id)
            try expectEqual(store.items[0].folderID, folder.id, "the item should be filed")
            try expect(store.items[0].isLocked, "filing an item into a folder locks it by default")
            try expect(store.items[0].isProtected, "a foldered item is protected from eviction")
            try expectNil(store.items[1].folderID, "the other item should be untouched")
            try expect(!store.items[1].isLocked, "the other item should not be locked")

            store.moveItems(ids: [b.id], toFolder: UUID())
            try expectNil(store.items[1].folderID, "moving into an unknown folder should be a no-op")
        }
    }

    static func testMoveItemsOutKeepsLock() throws {
        try withStore { store, _ in
            let folder = store.createFolder(name: "Work")
            let a = text("a"), b = text("b")
            store.items = [a, b]
            store.moveItems(ids: [a.id, b.id], toFolder: folder.id)
            store.setLocked(ids: [b.id], locked: false)

            store.moveItems(ids: [a.id, b.id], toFolder: nil)
            try expectNil(store.items[0].folderID, "a should be out of the folder")
            try expectNil(store.items[1].folderID, "b should be out of the folder")
            try expect(store.items[0].isLocked, "moving out leaves a locked item locked")
            try expect(!store.items[1].isLocked, "moving out leaves an unlocked item unlocked")
        }
    }

    static func testFolderCounts() throws {
        try withStore { store, _ in
            let work = store.createFolder(name: "Work")
            let home = store.createFolder(name: "Home")
            let a = text("a"), b = text("b"), c = text("c"), loose = text("loose")
            store.items = [a, b, c, loose]

            store.moveItems(ids: [a.id, b.id], toFolder: work.id)
            store.moveItems(ids: [c.id], toFolder: home.id)

            let counts = store.folderCounts()
            try expectEqual(counts[work.id], 2, "Work should hold two items")
            try expectEqual(counts[home.id], 1, "Home should hold one item")
            try expectEqual(counts.count, 2, "loose items should not appear in the counts")

            try expectEqual(store.items(inFolder: work.id).count, 2, "items(inFolder:) should return Work's items")
            try expectEqual(Set(store.items(inFolder: work.id).map { $0.id }), Set([a.id, b.id]),
                            "items(inFolder:) should return exactly the filed items")
            try expectEqual(store.items(inFolder: UUID()).count, 0, "an unknown folder holds nothing")
        }
    }

    static func testReorderFolders() throws {
        try withStore { store, _ in
            let a = store.createFolder(name: "A")
            let b = store.createFolder(name: "B")
            let c = store.createFolder(name: "C")

            store.reorderFolders([c.id, a.id, b.id])
            try expectEqual(store.folders.map { $0.name }, ["C", "A", "B"], "folders should follow the requested order")
            try expectEqual(store.folders.map { $0.sortIndex }, [0, 1, 2], "sortIndex should be rewritten densely")

            // Ids that are missing keep their relative order at the end.
            store.reorderFolders([b.id])
            try expectEqual(store.folders.map { $0.name }, ["B", "C", "A"], "unlisted folders keep their relative order")

            store.reorderFolders([UUID()])
            try expectEqual(store.folders.map { $0.name }, ["B", "C", "A"], "unknown ids should be ignored")
        }
    }

    static func testFoldersPersistence() throws {
        try withStore { store, dir in
            let work = store.createFolder(name: "Work")
            _ = store.createFolder(name: "Home")

            // `saveFolders()` writes asynchronously on `saveQueue` (5A-24), so
            // drain the queue before reading the bytes back.
            store.flushPendingSave()

            let url = dir.appendingPathComponent("folders.json")
            try expect(FileManager.default.fileExists(atPath: url.path), "folders.json should be written")

            let data = try Data(contentsOf: url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = object["version"] as? Int else {
                throw TestFailure(message: "folders.json is not a versioned wrapper", file: #file, line: #line)
            }
            try expectEqual(version, 1, "folders.json should carry version 1")

            struct Wrapper: Decodable { let folders: [Folder] }
            let wrapper = try JSONDecoder().decode(Wrapper.self, from: data)
            try expectEqual(wrapper.folders.count, 2, "both folders should be on disk")
            try expectEqual(wrapper.folders[0].id, work.id, "the first folder should be Work")

            let reopened = ClipboardStore(directory: dir)
            try expectEqual(reopened.folders, store.folders, "reopening should reproduce the folders exactly")
        }
    }
}
