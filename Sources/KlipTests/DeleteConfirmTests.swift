import Foundation
import BenchTestKit
@testable import Klip

// 0.3.4: deleting in the history. One clip goes straight to the trash; a
// multi-selection always asks first, the same way from ⌘⌫, the row context
// menu and the preview pane's button. Before this, ⌘⌫ deleted only the focused
// clip (one per press with several selected), the row menu deleted them all
// with no confirmation, and only the preview pane's button asked.
enum DeleteConfirmTests {
    static let tests: [(String, () throws -> Void)] = [
        ("delete_singleSelection_cmdDeleteRemovesImmediately", testSingleDeletesImmediately),
        ("delete_multiSelection_cmdDeleteAsksFirst", testCmdDeleteAsksForMulti),
        ("delete_multiSelection_contextMenuAsksFirst", testContextMenuAsksForMulti),
        ("delete_confirm_removesTheWholeSelection", testConfirmRemovesAll),
        ("delete_cancel_keepsEverything", testCancelKeepsAll),
        ("delete_escape_dismissesThePrompt", testEscapeDismisses),
        ("delete_promptStandsDownListShortcuts", testPromptIsAPrompt),
    ]

    private static func seeded(_ body: (HistoryViewModel, ClipboardStore, [ClipboardItem]) throws -> Void) throws {
        try FolderUXTests.withViewModel { vm, store in
            let items = FolderUXTests.seed(vm, store, ["one", "two", "three"])
            vm.applyFilters(resetSelection: .defaultItem)
            try body(vm, store, items)
        }
    }

    static func testSingleDeletesImmediately() throws {
        try seeded { vm, store, items in
            vm.selectSingle(items[0].id)
            vm.keyDelete()
            try expect(!vm.showDeleteConfirmation, "one clip is not confirmed")
            try expectEqual(store.items.count, 2, "and it is gone at once")
            try expectEqual(store.trashedItems.map { $0.id }, [items[0].id], "into the trash")
        }
    }

    static func testCmdDeleteAsksForMulti() throws {
        try seeded { vm, store, items in
            vm.selectedIDs = [items[0].id, items[1].id]
            vm.selectedID = items[0].id
            vm.keyDelete()
            try expect(vm.showDeleteConfirmation, "⌘⌫ with two selected asks first")
            try expectEqual(store.items.count, 3, "and deletes nothing until answered")
            try expectEqual(vm.deleteTargetCount, 2)
        }
    }

    static func testContextMenuAsksForMulti() throws {
        try seeded { vm, store, items in
            vm.selectedIDs = [items[0].id, items[1].id]
            vm.selectedID = items[0].id
            vm.deleteSelectedItems()   // what the row menu's Delete calls
            try expect(vm.showDeleteConfirmation, "the row menu asks first too")
            try expectEqual(store.items.count, 3)
        }
    }

    static func testConfirmRemovesAll() throws {
        try seeded { vm, store, items in
            vm.selectedIDs = [items[0].id, items[1].id]
            vm.selectedID = items[0].id
            vm.keyDelete()
            vm.confirmDelete()
            try expect(!vm.showDeleteConfirmation, "the card closes")
            try expectEqual(store.items.map { $0.id }, [items[2].id], "both selected clips are gone in one go")
            try expectEqual(store.trashedItems.count, 2, "and both are in the trash")
            try expectEqual(vm.toast?.text, "2 clips moved to Trash")
        }
    }

    static func testCancelKeepsAll() throws {
        try seeded { vm, store, items in
            vm.selectedIDs = [items[0].id, items[1].id]
            vm.selectedID = items[0].id
            vm.keyDelete()
            vm.cancelDelete()
            try expect(!vm.showDeleteConfirmation, "the card closes")
            try expectEqual(store.items.count, 3, "cancel deletes nothing")
            try expectEqual(vm.selectedIDs, [items[0].id, items[1].id], "and keeps the selection")
        }
    }

    static func testEscapeDismisses() throws {
        try seeded { vm, store, items in
            var dismissedWindow = false
            vm.onDismiss = { dismissedWindow = true }
            vm.selectedIDs = [items[0].id, items[1].id]
            vm.selectedID = items[0].id
            vm.keyDelete()
            vm.keyEscape()
            try expect(!vm.showDeleteConfirmation, "Esc closes the card")
            try expect(!dismissedWindow, "and only the card, not the window")
            try expectEqual(store.items.count, 3)
        }
    }

    static func testPromptIsAPrompt() throws {
        try seeded { vm, _, items in
            vm.selectedIDs = [items[0].id, items[1].id]
            vm.selectedID = items[0].id
            vm.keyDelete()
            try expect(vm.isPromptShowing, "while the card is up, list shortcuts stand down")
        }
    }
}
