import Foundation
import BenchTestKit
@testable import Klip

// Trash UX (5E): the trash as a sidebar scope — browsed with the same search,
// tag and chip filters as the history, ordered by its own picker, and with
// restore / erase in place of paste / delete.
//
// The AppKit halves (the sidebar row, the prompt cards) cannot be driven
// headlessly; what is testable is every decision behind them, which is all in
// `FilterState` and `HistoryViewModel+Trash`.

enum TrashUXTests {
    static let tests: [(String, () throws -> Void)] = [
        // Browsing
        ("trashScope_listsTheTrashAndNotTheHistory", testScopeSource),
        ("trashScope_searchNarrowsTheTrash", testSearch),
        ("trashScope_chipFilterNarrowsTheTrash", testChipFilter),
        ("trashScope_tagFilterNarrowsTheTrash", testTagFilter),
        // Sorting
        ("sort_defaultsToDateDeletedNewestFirst", testSortDefault),
        ("sort_byDateDeletedPutsTheNewestDeletionFirst", testSortDateDeleted),
        ("sort_byNameIsCaseAndDiacriticInsensitive", testSortName),
        ("sort_byTypeGroupsKinds", testSortKind),
        ("sort_byDateAddedUsesCaptureTime", testSortDateAdded),
        ("sort_neverFloatsPinnedClipsToTheTop", testSortIgnoresPins),
        ("sort_sameBatchDeletionsFallBackToCaptureOrder", testSortSameBatch),
        ("sort_isTotalForClipsThatTieOnEverything", testSortTieBreak),
        ("sort_undatedRecordsSortLast", testSortUndated),
        // Restore
        ("restore_takesTheSelectionAndStaysInTheTrash", testRestoreSelection),
        ("restore_reportsWhereTheClipsWent", testRestoreToast),
        // Erase
        ("delete_inTheTrashArmsTheConfirmationInsteadOfDeleting", testDeleteArmsPrompt),
        ("confirmPurge_erasesOnlyTheSelection", testConfirmPurge),
        ("emptyTrash_erasesEvenWhatTheSearchIsHiding", testEmptyTrashIgnoresFilter),
        ("emptyTrash_isRefusedWhenTheTrashIsEmpty", testEmptyTrashNoop),
        ("escape_closesATrashPromptFirst", testEscapeUnwindsPrompt),
        // The clip is a record, not a live clip
        ("trashScope_refusesEditsPinsTagsAndFolderMoves", testMutationsAreRefused),
        ("trashScope_takesNoSidebarDrops", testNoDrops),
    ]

    // MARK: - Harness

    static func withTrash<R>(
        _ body: (HistoryViewModel, ClipboardStore) throws -> R
    ) throws -> R {
        try ClipboardStoreTests.withStore { store, _ in
            let viewModel = HistoryViewModel(store: store)
            viewModel.applyFilters(resetSelection: .keep)
            return try body(viewModel, store)
        }
    }

    /// Deletes `items` (in the given order) so they land in the trash with
    /// distinct, controlled deletion dates — newest deletion first, which is
    /// the order the store itself produces.
    static func fill(_ store: ClipboardStore, with items: [ClipboardItem]) {
        store.items = items
        for item in items { store.delete(item) }
    }

    /// A trashed record with exact dates. The store stamps `deletedAt` with
    /// `Date()` itself, so the orderings below are exercised through the pure
    /// `TrashSort.order` — no store, no clock, no flakiness.
    static func record(
        _ text: String,
        deletedDaysAgo: Double?,
        capturedDaysAgo: Double = 0,
        kind: ContentKind? = nil,
        pinned: Bool = false,
        now: Date = Date()
    ) -> ClipboardItem {
        var item = ClipboardItem.text(text)
        item.timestamp = now.addingTimeInterval(-capturedDaysAgo * 86_400)
        item.deletedAt = deletedDaysAgo.map { now.addingTimeInterval(-$0 * 86_400) }
        item.kind = kind
        item.isPinned = pinned
        return item
    }

    static func previews(_ items: [ClipboardItem]) -> [String] {
        items.map { $0.previewText }
    }

    // MARK: - Browsing

    static func testScopeSource() throws {
        try withTrash { vm, store in
            store.items = [ClipboardItem.text("live one"), ClipboardItem.text("live two")]
            let doomed = ClipboardItem.text("deleted one")
            store.items.append(doomed)
            store.delete(doomed)

            vm.applyFilters(resetSelection: .defaultItem)
            try expectEqual(previews(vm.filteredItems), ["live one", "live two"],
                            "the history never shows a deleted clip")

            vm.scope = .trash
            try expect(vm.isTrashScope, "the scope is the trash")
            try expectEqual(previews(vm.filteredItems), ["deleted one"],
                            "and the trash shows only deleted clips")
            try expectEqual(vm.trashCount, 1)
        }
    }

    static func testSearch() throws {
        try withTrash { vm, store in
            fill(store, with: [
                ClipboardItem.text("invoice number 42"),
                ClipboardItem.text("shopping list"),
            ])
            vm.scope = .trash
            vm.debouncedSearchText = "invoice"
            try expectEqual(previews(vm.filteredItems), ["invoice number 42"],
                            "the trash is searched exactly like the history")

            vm.debouncedSearchText = "nothing here"
            try expectEqual(vm.filteredItems.count, 0)
        }
    }

    static func testChipFilter() throws {
        try withTrash { vm, store in
            var link = ClipboardItem.text("https://example.com")
            link.kind = .link
            fill(store, with: [link, ClipboardItem.text("just text")])

            vm.scope = .trash
            vm.chipFilter = .kind(.link)
            try expectEqual(previews(vm.filteredItems), ["https://example.com"],
                            "the kind chips narrow the trash too")
        }
    }

    static func testTagFilter() throws {
        try withTrash { vm, store in
            var tagged = ClipboardItem.text("tagged clip")
            tagged.tags = ["work"]
            fill(store, with: [tagged, ClipboardItem.text("untagged clip")])

            vm.scope = .trash
            vm.activeTagFilter = "work"
            try expectEqual(previews(vm.filteredItems), ["tagged clip"])

            vm.activeTagFilter = nil
            vm.chipFilter = .tagged
            try expectEqual(previews(vm.filteredItems), ["tagged clip"],
                            "and so does the Tags chip")
        }
    }

    // MARK: - Sorting

    static func testSortDefault() throws {
        try withTrash { vm, store in
            fill(store, with: [ClipboardItem.text("a"), ClipboardItem.text("b")])
            vm.scope = .trash
            try expectEqual(vm.trashSort, .dateDeleted, "the trash opens on the deletion date")

            // Switching the picker re-orders the live list, not just the state.
            vm.trashSort = .name
            try expectEqual(previews(vm.filteredItems), ["a", "b"])
        }
    }

    static func testSortDateDeleted() throws {
        let now = Date()
        let items = [
            record("deleted a month ago", deletedDaysAgo: 30, now: now),
            record("deleted today", deletedDaysAgo: 0, now: now),
            record("deleted last week", deletedDaysAgo: 7, now: now),
        ]
        try expectEqual(
            previews(TrashSort.dateDeleted.order(items)),
            ["deleted today", "deleted last week", "deleted a month ago"],
            "newest deletion first — the clip someone came here for"
        )
    }

    static func testSortName() throws {
        let now = Date()
        let items = [
            record("banana", deletedDaysAgo: 1, now: now),
            record("Éclair", deletedDaysAgo: 2, now: now),
            record("apple", deletedDaysAgo: 3, now: now),
        ]
        try expectEqual(
            previews(TrashSort.name.order(items)),
            ["apple", "banana", "Éclair"],
            "name order ignores case and diacritics"
        )
    }

    static func testSortKind() throws {
        let now = Date()
        let items = [
            record("https://example.com", deletedDaysAgo: 1, kind: .link, now: now),
            record("let x = 1", deletedDaysAgo: 2, kind: .code, now: now),
            record("plain", deletedDaysAgo: 3, kind: .text, now: now),
        ]
        try expectEqual(
            TrashSort.kind.order(items).map { $0.displayKind.label },
            ["Code", "Link", "Text"],
            "type order groups kinds by their label"
        )
    }

    static func testSortDateAdded() throws {
        let now = Date()
        // Captured in the opposite order to the deletions, so the two date
        // sorts cannot accidentally agree.
        let items = [
            record("captured today", deletedDaysAgo: 30, capturedDaysAgo: 0, now: now),
            record("captured long ago", deletedDaysAgo: 1, capturedDaysAgo: 90, now: now),
        ]
        try expectEqual(
            previews(TrashSort.dateDeleted.order(items)),
            ["captured long ago", "captured today"]
        )
        try expectEqual(
            previews(TrashSort.dateAdded.order(items)),
            ["captured today", "captured long ago"],
            "date added sorts on capture time, not deletion time"
        )
    }

    static func testSortIgnoresPins() throws {
        let now = Date()
        let items = [
            record("pinned but deleted", deletedDaysAgo: 30, pinned: true, now: now),
            record("deleted later", deletedDaysAgo: 1, now: now),
        ]
        try expectEqual(
            previews(TrashSort.dateDeleted.order(items)),
            ["deleted later", "pinned but deleted"],
            "a pin does not jump the queue in the trash"
        )
    }

    static func testSortSameBatch() throws {
        let now = Date()
        // One multi-selection delete: every clip carries the same deletedAt.
        let items = [
            record("older capture", deletedDaysAgo: 1, capturedDaysAgo: 5, now: now),
            record("newer capture", deletedDaysAgo: 1, capturedDaysAgo: 1, now: now),
        ]
        try expectEqual(
            previews(TrashSort.dateDeleted.order(items)),
            ["newer capture", "older capture"],
            "a batch deleted in one go keeps the order the history had it in"
        )
    }

    static func testSortTieBreak() throws {
        let now = Date()
        let a = record("same name", deletedDaysAgo: 1, capturedDaysAgo: 1, now: now)
        let b = record("same name", deletedDaysAgo: 1, capturedDaysAgo: 1, now: now)
        try expectEqual(
            TrashSort.name.order([a, b]).map { $0.id },
            TrashSort.name.order([b, a]).map { $0.id },
            "clips that tie on every key still come out in one fixed order"
        )
    }

    static func testSortUndated() throws {
        let now = Date()
        let items = [
            record("no deletion date", deletedDaysAgo: nil, now: now),
            record("deleted a year ago", deletedDaysAgo: 365, now: now),
        ]
        try expectEqual(
            previews(TrashSort.dateDeleted.order(items)),
            ["deleted a year ago", "no deletion date"],
            "a record we cannot date sorts last rather than at the top"
        )
    }

    // MARK: - Restore

    static func testRestoreSelection() throws {
        try withTrash { vm, store in
            let keep = ClipboardItem.text("stays deleted")
            let wanted = ClipboardItem.text("bring this back")
            fill(store, with: [keep, wanted])

            vm.scope = .trash
            vm.selectSingle(wanted.id)
            vm.restoreSelectionFromTrash()

            try expectEqual(store.items.first?.id, wanted.id, "restored to the top of the history")
            try expectEqual(store.trashedItems.map { $0.id }, [keep.id], "and only that one left the trash")
            try expectEqual(vm.scope, .trash, "the scope stays put so the next clip can be restored")
            try expectEqual(previews(vm.filteredItems), ["stays deleted"], "the list drops the restored row")
        }
    }

    static func testRestoreToast() throws {
        try withTrash { vm, store in
            let one = ClipboardItem.text("one")
            let two = ClipboardItem.text("two")
            fill(store, with: [one, two])

            vm.scope = .trash
            vm.selectedIDs = [one.id, two.id]
            vm.restoreSelectionFromTrash()

            try expectEqual(vm.toast?.text, "Restored 2 clips to the top of All",
                            "the toast says where they went, since it is no longer where they were")
            try expectEqual(store.trashedItems.count, 0)
        }
    }

    // MARK: - Erase

    static func testDeleteArmsPrompt() throws {
        try withTrash { vm, store in
            let item = ClipboardItem.text("doomed")
            fill(store, with: [item])

            vm.scope = .trash
            vm.selectSingle(item.id)
            vm.keyDelete()

            try expect(vm.showPurgePrompt, "⌫ in the trash asks first")
            try expectEqual(store.trashedItems.count, 1, "and erases nothing until it is answered")
            try expectEqual(vm.purgeTargetCount, 1)
        }
    }

    static func testConfirmPurge() throws {
        try withTrash { vm, store in
            let doomed = ClipboardItem.text("doomed")
            let spared = ClipboardItem.text("spared")
            fill(store, with: [doomed, spared])

            vm.scope = .trash
            vm.requestPurge(ids: [doomed.id])
            vm.confirmPurge()

            try expect(!vm.showPurgePrompt, "the prompt closes")
            try expectEqual(store.trashedItems.map { $0.id }, [spared.id], "only the selection is erased")
            try expectEqual(store.items.count, 0, "and nothing comes back to the history")
        }
    }

    static func testEmptyTrashIgnoresFilter() throws {
        try withTrash { vm, store in
            fill(store, with: [ClipboardItem.text("invoice"), ClipboardItem.text("receipt")])

            vm.scope = .trash
            vm.debouncedSearchText = "invoice"
            try expectEqual(vm.filteredItems.count, 1, "the search is hiding one of them")

            vm.requestEmptyTrash()
            try expect(vm.showEmptyTrashPrompt, "the confirmation is armed")
            vm.confirmEmptyTrash()

            try expectEqual(store.trashedItems.count, 0,
                            "emptying takes the whole trash, including what the search hid")
        }
    }

    static func testEmptyTrashNoop() throws {
        try withTrash { vm, _ in
            vm.scope = .trash
            vm.requestEmptyTrash()
            try expect(!vm.showEmptyTrashPrompt, "nothing to confirm when the trash is already empty")
        }
    }

    static func testEscapeUnwindsPrompt() throws {
        try withTrash { vm, store in
            let item = ClipboardItem.text("doomed")
            fill(store, with: [item])
            vm.scope = .trash
            vm.selectSingle(item.id)
            vm.requestPurge(ids: [item.id])

            try expect(vm.dismissTopPrompt(), "Esc closes the trash prompt")
            try expect(!vm.showPurgePrompt, "the prompt is gone")
            try expectEqual(store.trashedItems.count, 1, "and cancels the erase")
        }
    }

    // MARK: - Refusals

    static func testMutationsAreRefused() throws {
        try withTrash { vm, store in
            let folder = store.createFolder(name: "Work")
            var item = ClipboardItem.text("editable text")
            item.tags = []
            fill(store, with: [item])

            vm.scope = .trash
            vm.selectSingle(item.id)

            vm.enterEditMode()
            try expect(!vm.isEditing, "a trashed clip cannot be edited — it is not in `items`")

            vm.keyAddTag()
            try expect(!vm.showTagInput, "nor tagged")

            vm.togglePinOnSelection()
            vm.toggleBookmarkOnSelection()
            try expectEqual(store.trashedItems.first?.isPinned, false, "nor pinned")
            try expectEqual(store.trashedItems.first?.isBookmarked, false, "nor favorited")

            vm.moveSelection(toFolder: folder.id)
            try expectNil(store.trashedItems.first?.folderID, "nor filed into a folder")
            try expectEqual(store.trashedItems.count, 1, "and none of that moved it out of the trash")
        }
    }

    static func testNoDrops() throws {
        try withTrash { vm, store in
            let item = ClipboardItem.text("live clip")
            store.items = [item]
            vm.applyFilters(resetSelection: .defaultItem)

            try expect(!vm.handleDrop(ids: [item.id], on: .trash),
                       "dropping on Trash is refused: too easy to do by accident for something destructive")
            try expectEqual(store.items.count, 1, "so the clip is untouched")
            try expectEqual(store.trashedItems.count, 0)
        }
    }
}
