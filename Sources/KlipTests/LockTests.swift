import Foundation
import BenchTestKit
@testable import Klip

// Lock / protect UX coverage (Phase 3A): the view-model delete choke point
// (`performDelete`), lock-toggle selection semantics, and the store's
// lock-survives-clear guarantee that the view model relies on.
//
// Store-level lock/delete coverage (`delete`, `delete([_])`, `clear`) already
// lives in `ClipboardStoreTests`; this file only repeats the `clear` case
// asked for by the task brief and otherwise focuses on `HistoryViewModel`.

enum LockTests {
    static let tests: [(String, () throws -> Void)] = [
        ("performDelete_mixedSelection_keepsLockedSelectedAndToasts", testPerformDeleteMixedSelection),
        ("performDelete_allUnlocked_deletesEverythingNoToast", testPerformDeleteAllUnlocked),
        ("performDelete_allLocked_deletesNothingSingularToast", testPerformDeleteAllLockedSingular),
        ("performDelete_emptyIDs_isANoOp", testPerformDeleteEmptyIDs),
        ("toggleLockSelection_singleItem_flips", testToggleLockSelectionSingle),
        ("toggleLockSelection_mixedSelection_locksAll", testToggleLockSelectionMixedLocksAll),
        ("toggleLockSelection_allLocked_unlocksAll", testToggleLockSelectionAllLockedUnlocksAll),
        ("keyLock_isToggleLockSelection", testKeyLockMatchesToggle),
        ("setLocked_batchUpdatesStore", testSetLockedBatch),
        ("clear_keepsLockedItems", testClearKeepsLocked),
    ]

    // MARK: - Harness

    /// A `HistoryViewModel` wired to a fresh store, with `filteredItems`
    /// populated (`applyFilters` is otherwise only driven by SwiftUI's
    /// `onChange`/`onAppear`, neither of which runs here).
    static func withViewModel<R>(
        seed: [ClipboardItem],
        _ body: (HistoryViewModel, ClipboardStore) throws -> R
    ) throws -> R {
        try ClipboardStoreTests.withStore { store, _ in
            store.items = seed
            let viewModel = HistoryViewModel(store: store)
            viewModel.applyFilters(resetSelection: .keep)
            return try body(viewModel, store)
        }
    }

    // MARK: - performDelete

    static func testPerformDeleteMixedSelection() throws {
        let a = ClipboardItem(type: .text, textContent: "a")
        let b = ClipboardItem(type: .text, textContent: "b", isLocked: true)
        let c = ClipboardItem(type: .text, textContent: "c")

        try withViewModel(seed: [a, b, c]) { viewModel, store in
            let result = viewModel.performDelete(ids: [a.id, b.id, c.id])

            try expectEqual(result.deleted, 2, "the two unlocked items should be deleted")
            try expectEqual(result.skippedLocked, 1, "the locked item should be reported as skipped")
            try expectEqual(store.items.count, 1, "only the locked item should remain in the store")
            try expectEqual(store.items.first?.id, b.id, "the survivor should be the locked item")

            try expectEqual(viewModel.selectedIDs, [b.id], "the locked survivor should stay selected")
            try expectEqual(viewModel.selectedID, b.id, "selectedID should point at the locked survivor")

            try expectNotNil(viewModel.toast, "a toast should be shown when items were skipped")
            try expectEqual(
                viewModel.toast?.text,
                "1 locked clip was not deleted - unlock it first",
                "singular toast wording"
            )
            try expectEqual(viewModel.toast?.systemImage, "lock.fill")
        }
    }

    static func testPerformDeleteAllUnlocked() throws {
        let a = ClipboardItem(type: .text, textContent: "a")
        let b = ClipboardItem(type: .text, textContent: "b")

        try withViewModel(seed: [a, b]) { viewModel, store in
            let result = viewModel.performDelete(ids: [a.id, b.id])

            try expectEqual(result.deleted, 2)
            try expectEqual(result.skippedLocked, 0)
            try expectEqual(store.items.count, 0, "both unlocked items should be gone")
            try expectNil(viewModel.toast, "no toast when nothing was skipped")
        }
    }

    static func testPerformDeleteAllLockedSingular() throws {
        let a = ClipboardItem(type: .text, textContent: "a", isLocked: true)
        let b = ClipboardItem(type: .text, textContent: "b", isLocked: true)

        try withViewModel(seed: [a, b]) { viewModel, store in
            let result = viewModel.performDelete(ids: [a.id, b.id])

            try expectEqual(result.deleted, 0, "nothing should be deleted")
            try expectEqual(result.skippedLocked, 2)
            try expectEqual(store.items.count, 2, "both locked items should survive")
            try expectEqual(viewModel.selectedIDs, Set([a.id, b.id]), "both survivors should stay selected")
            try expectEqual(
                viewModel.toast?.text,
                "2 locked clips were not deleted - unlock them first",
                "plural toast wording"
            )
        }
    }

    static func testPerformDeleteEmptyIDs() throws {
        let a = ClipboardItem(type: .text, textContent: "a")

        try withViewModel(seed: [a]) { viewModel, store in
            let result = viewModel.performDelete(ids: [])
            try expectEqual(result, ClipboardStore.DeleteResult(deleted: 0, skippedLocked: 0))
            try expectEqual(store.items.count, 1, "an empty id set must not touch the store")
            try expectNil(viewModel.toast)
        }
    }

    // MARK: - toggleLockSelection / keyLock

    static func testToggleLockSelectionSingle() throws {
        let a = ClipboardItem(type: .text, textContent: "a")

        try withViewModel(seed: [a]) { viewModel, store in
            viewModel.selectSingle(a.id)

            viewModel.toggleLockSelection()
            try expect(store.items.first?.isLocked == true, "toggling an unlocked item should lock it")

            // In the running app, `HistoryContentView`'s `.onChange(of: store.items)`
            // re-runs `applyFilters` after every store mutation, keeping
            // `filteredItems` (and therefore `selectedItems`) in sync. That
            // observer doesn't exist in this headless harness, so re-run it
            // explicitly before toggling again.
            viewModel.applyFilters(resetSelection: .keep)

            viewModel.toggleLockSelection()
            try expect(store.items.first?.isLocked == false, "toggling it again should unlock it")
        }
    }

    static func testToggleLockSelectionMixedLocksAll() throws {
        let a = ClipboardItem(type: .text, textContent: "a")
        let b = ClipboardItem(type: .text, textContent: "b", isLocked: true)
        let c = ClipboardItem(type: .text, textContent: "c")

        try withViewModel(seed: [a, b, c]) { viewModel, store in
            viewModel.selectedIDs = [a.id, b.id, c.id]

            viewModel.toggleLockSelection()

            try expect(store.items.allSatisfy { $0.isLocked }, "any unlocked item in the selection means lock all")
        }
    }

    static func testToggleLockSelectionAllLockedUnlocksAll() throws {
        let a = ClipboardItem(type: .text, textContent: "a", isLocked: true)
        let b = ClipboardItem(type: .text, textContent: "b", isLocked: true)

        try withViewModel(seed: [a, b]) { viewModel, store in
            viewModel.selectedIDs = [a.id, b.id]

            viewModel.toggleLockSelection()

            try expect(store.items.allSatisfy { !$0.isLocked }, "an all-locked selection should unlock entirely")
        }
    }

    static func testKeyLockMatchesToggle() throws {
        let a = ClipboardItem(type: .text, textContent: "a")

        try withViewModel(seed: [a]) { viewModel, store in
            viewModel.selectSingle(a.id)

            viewModel.keyLock()
            try expect(store.items.first?.isLocked == true, "keyLock should behave like toggleLockSelection")

            viewModel.isEditing = true
            viewModel.keyLock()
            try expect(store.items.first?.isLocked == true, "keyLock is a no-op while editing")
            viewModel.isEditing = false
        }
    }

    // MARK: - setLocked

    static func testSetLockedBatch() throws {
        let a = ClipboardItem(type: .text, textContent: "a")
        let b = ClipboardItem(type: .text, textContent: "b")

        try withViewModel(seed: [a, b]) { viewModel, store in
            viewModel.setLocked(true, ids: [a.id, b.id])
            try expect(store.items.allSatisfy { $0.isLocked }, "both items should be locked")

            viewModel.setLocked(false, ids: [a.id])
            let byID = Dictionary(uniqueKeysWithValues: store.items.map { ($0.id, $0) })
            try expectEqual(byID[a.id]?.isLocked, false)
            try expectEqual(byID[b.id]?.isLocked, true)
        }
    }

    // MARK: - Store clear (requested explicitly by the task brief; the fuller
    // matrix of clear/delete-lock interactions lives in ClipboardStoreTests).

    static func testClearKeepsLocked() throws {
        try ClipboardStoreTests.withStore { store, _ in
            let locked = ClipboardItem(type: .text, textContent: "locked", isLocked: true)
            let loose = ClipboardItem(type: .text, textContent: "loose")
            store.items = [loose, locked]

            let result = store.clear(keepProtected: false)
            try expectEqual(result.deleted, 1, "only the unlocked item should be cleared")
            try expectEqual(result.skippedLocked, 1)
            try expectEqual(store.items.count, 1)
            try expectEqual(store.items.first?.id, locked.id, "a lock outranks an explicit Clear History")
        }
    }
}
