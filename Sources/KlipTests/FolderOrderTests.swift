import Foundation
import BenchTestKit
@testable import Klip

// Manual clip order inside a folder (5C): drag a clip above or below another
// one and it stays there. Only folder scope is hand-sortable — All and
// Favorites keep their chronological, pinned-first order.
//
// The AppKit half (the row's drop target in `ClickModifierDetector`) cannot be
// driven headlessly, so what is covered here is everything it calls into: the
// view model's reorder arithmetic, the store's renumbering, and the display
// order the list is built from.

enum FolderOrderTests {
    static let tests: [(String, () throws -> Void)] = [
        ("folderOrder_manualIndexFirstThenNewest", testFolderOrderSorting),
        ("setFolderOrder_renumbersDensely", testSetFolderOrderRenumbers),
        ("setFolderOrder_unmentionedMembersKeepTheirOrderAtTheEnd", testSetFolderOrderTail),
        ("setFolderOrder_ignoresOtherFolders", testSetFolderOrderIsolation),
        ("filter_folderScope_usesManualOrderOverPins", testFolderScopeIgnoresPins),
        ("filter_allScope_stillFloatsPinned", testAllScopeStillPins),
        ("moveItems_intoFolder_landsAtTheTopOfTheManualOrder", testArrivalIndex),
        ("moveItems_outOfFolder_clearsTheManualPosition", testLeavingClearsIndex),
        ("reorderInFolder_movesBelowTheTargetRow", testReorderBelow),
        ("reorderInFolder_movesAboveTheTargetRow", testReorderAbove),
        ("reorderInFolder_keepsAMultiDragTogetherInOrder", testReorderMultiDrag),
        ("reorderInFolder_isANoOpOutsideFolderScope", testReorderOutsideFolder),
        ("reorderInFolder_isANoOpWhenDroppedOnItself", testReorderOntoSelf),
    ]

    // MARK: - Harness

    static func item(_ text: String, at seconds: TimeInterval, folder: UUID?, order: Double? = nil) -> ClipboardItem {
        var made = ClipboardItem(
            type: .text,
            timestamp: Date(timeIntervalSince1970: seconds),
            textContent: text
        )
        made.folderID = folder
        made.folderSortIndex = order
        return made
    }

    static func texts(_ items: [ClipboardItem]) -> [String] {
        items.compactMap { $0.textContent }
    }

    // MARK: - Ordering rule

    static func testFolderOrderSorting() throws {
        let f = UUID()
        let ordered = ClipboardStore.folderOrder([
            item("never placed, older", at: 100, folder: f),
            item("third", at: 900, folder: f, order: 2),
            item("never placed, newer", at: 200, folder: f),
            item("first", at: 1, folder: f, order: 0),
        ])
        try expectEqual(
            texts(ordered),
            ["first", "third", "never placed, newer", "never placed, older"],
            "hand-placed clips first in their own order, then the rest newest-first"
        )
    }

    // MARK: - Store

    static func testSetFolderOrderRenumbers() throws {
        try ClipboardStoreTests.withStore { store, _ in
            let folder = store.createFolder(name: "Snippets").id
            let a = item("a", at: 3, folder: folder)
            let b = item("b", at: 2, folder: folder)
            let c = item("c", at: 1, folder: folder)
            store.items = [a, b, c]

            store.setFolderOrder([c.id, a.id, b.id], in: folder)

            try expectEqual(texts(ClipboardStore.folderOrder(store.items(inFolder: folder))), ["c", "a", "b"])
            try expectEqual(store.items.first { $0.id == c.id }?.folderSortIndex, 0)
            try expectEqual(store.items.first { $0.id == a.id }?.folderSortIndex, 1)
            try expectEqual(store.items.first { $0.id == b.id }?.folderSortIndex, 2)
        }
    }

    static func testSetFolderOrderTail() throws {
        // A filtered list only knows about the rows on screen; the members it
        // never mentions must not lose their places.
        try ClipboardStoreTests.withStore { store, _ in
            let folder = store.createFolder(name: "Snippets").id
            let shown = item("shown", at: 1, folder: folder)
            let hiddenNew = item("hidden new", at: 500, folder: folder)
            let hiddenOld = item("hidden old", at: 100, folder: folder)
            store.items = [shown, hiddenNew, hiddenOld]

            store.setFolderOrder([shown.id], in: folder)

            try expectEqual(
                texts(ClipboardStore.folderOrder(store.items(inFolder: folder))),
                ["shown", "hidden new", "hidden old"],
                "unmentioned members are appended, newest first"
            )
        }
    }

    static func testSetFolderOrderIsolation() throws {
        try ClipboardStoreTests.withStore { store, _ in
            let a = store.createFolder(name: "A").id
            let b = store.createFolder(name: "B").id
            let inA = item("in a", at: 1, folder: a)
            let inB = item("in b", at: 2, folder: b, order: 7)
            store.items = [inA, inB]

            store.setFolderOrder([inB.id, inA.id], in: a)

            try expectEqual(store.items.first { $0.id == inB.id }?.folderSortIndex, 7, "another folder's clip is untouched")
        }
    }

    static func testArrivalIndex() throws {
        try ClipboardStoreTests.withStore { store, _ in
            let folder = store.createFolder(name: "Snippets").id
            let resident = item("resident", at: 10, folder: folder, order: 0)
            let loose = item("loose", at: 1, folder: nil)
            store.items = [resident, loose]

            store.moveItems(ids: [loose.id], toFolder: folder)

            try expectEqual(
                texts(ClipboardStore.folderOrder(store.items(inFolder: folder))),
                ["loose", "resident"],
                "a freshly filed clip lands at the top of the folder"
            )
        }
    }

    static func testLeavingClearsIndex() throws {
        try ClipboardStoreTests.withStore { store, _ in
            let folder = store.createFolder(name: "Snippets").id
            let filed = item("filed", at: 10, folder: folder, order: 4)
            store.items = [filed]

            store.moveItems(ids: [filed.id], toFolder: nil)

            try expectNil(store.items.first?.folderSortIndex, "out of the folder, the manual position is meaningless")
        }
    }

    // MARK: - Display order

    static func testFolderScopeIgnoresPins() throws {
        let folder = UUID()
        var pinned = item("pinned", at: 5, folder: folder, order: 2)
        pinned.isPinned = true
        let items = [
            pinned,
            item("dragged to top", at: 1, folder: folder, order: 0),
            item("middle", at: 3, folder: folder, order: 1),
        ]
        let shown = FilterState.apply(items, FilterState(scope: .folder(folder)))
        try expectEqual(
            texts(shown),
            ["dragged to top", "middle", "pinned"],
            "the drag order wins inside a folder, pin included"
        )
    }

    static func testAllScopeStillPins() throws {
        let folder = UUID()
        var pinned = item("pinned", at: 5, folder: folder, order: 2)
        pinned.isPinned = true
        let items = [
            item("loose", at: 9, folder: nil),
            pinned,
            item("dragged to top", at: 1, folder: folder, order: 0),
        ]
        let shown = FilterState.apply(items, FilterState(scope: .all))
        try expectEqual(
            texts(shown),
            ["pinned", "loose", "dragged to top"],
            "All is unchanged: pinned first, then the array's own order"
        )
    }

    // MARK: - View model

    static func withFolderScope(
        _ contents: [String],
        _ body: (HistoryViewModel, ClipboardStore, UUID, [ClipboardItem]) throws -> Void
    ) throws {
        try FolderUXTests.withViewModel { vm, store in
            let folder = store.createFolder(name: "Snippets").id
            let items = contents.enumerated().map { offset, text in
                item(text, at: TimeInterval(contents.count - offset), folder: folder, order: Double(offset))
            }
            store.items = items
            vm.scope = .folder(folder)
            vm.applyFilters(resetSelection: .keep)
            try body(vm, store, folder, items)
        }
    }

    static func testReorderBelow() throws {
        try withFolderScope(["a", "b", "c"]) { vm, _, _, items in
            try expect(vm.reorderInFolder([items[0].id], relativeTo: items[2].id, insertAbove: false), "drop accepted")
            try expectEqual(texts(vm.filteredItems), ["b", "c", "a"])
        }
    }

    static func testReorderAbove() throws {
        try withFolderScope(["a", "b", "c"]) { vm, _, _, items in
            try expect(vm.reorderInFolder([items[2].id], relativeTo: items[0].id, insertAbove: true), "drop accepted")
            try expectEqual(texts(vm.filteredItems), ["c", "a", "b"])
        }
    }

    static func testReorderMultiDrag() throws {
        try withFolderScope(["a", "b", "c", "d"]) { vm, _, _, items in
            // Dragged ids handed over in the "wrong" order still land in the
            // order they appear in the list.
            try expect(
                vm.reorderInFolder([items[2].id, items[0].id], relativeTo: items[3].id, insertAbove: true),
                "drop accepted"
            )
            try expectEqual(texts(vm.filteredItems), ["b", "a", "c", "d"])
        }
    }

    static func testReorderOutsideFolder() throws {
        try FolderUXTests.withViewModel { vm, store in
            let items = FolderUXTests.seed(vm, store, ["a", "b"])
            vm.scope = .all
            vm.applyFilters(resetSelection: .keep)
            try expect(
                !vm.reorderInFolder([items[0].id], relativeTo: items[1].id, insertAbove: false),
                "All is chronological and cannot be hand-sorted"
            )
            try expectEqual(texts(vm.filteredItems), ["a", "b"], "and nothing moved")
        }
    }

    static func testReorderOntoSelf() throws {
        try withFolderScope(["a", "b"]) { vm, _, _, items in
            try expect(!vm.reorderInFolder([items[0].id], relativeTo: items[0].id, insertAbove: true), "no-op")
            try expectEqual(texts(vm.filteredItems), ["a", "b"])
        }
    }
}
