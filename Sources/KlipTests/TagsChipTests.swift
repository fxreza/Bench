import Foundation
import BenchTestKit
@testable import Klip

// Task 6B — the Tags chip / `# tags` legend hint. `FilterStateTests` covers
// the pure `.tagged` filtering rule; this covers the view-model side that
// `FilterChipBar` and `HistoryContentView` delegate to: `tapChip`,
// `chipIsActive` and `showTagsChipBar` (see `HistoryViewModel`'s
// "Chip row (task 6B)" section).

enum TagsChipTests {
    static let tests: [(String, () throws -> Void)] = [
        ("tapChip_tagged_activatesTheChipAndShowsTheBar", testActivateShowsBar),
        ("tapChip_taggedAgain_deactivatesTheChipAndClearsTheTagFilter", testDeactivateClearsTagFilter),
        ("tapChip_all_clearsAnActiveTagsChipAndTagFilter", testTapAllClearsBoth),
        ("chipIsActive_tagged_readsActiveFromHashTagFilterAlone", testHashTagFilterLightsChipWithoutTap),
        ("tapChip_taggedWhileHashTagFilterIsLive_clearsBoth", testTapTaggedWhileHashFilterLive),
        ("showTagsChipBar_hiddenWhileHashSearchAutocompleteIsShowing", testBarHiddenDuringHashSearch),
        ("showTagsChipBar_hiddenWhenNoTagsExist", testBarHiddenWithNoTags),
        ("clearingTagFilter_viaBackspace_keepsTheChipActive", testBackspaceKeepsChipActive),
        ("tapChip_kindChip_neverTouchesTheTagFilter", testKindChipLeavesTagFilterAlone),
    ]

    // MARK: - Harness

    static func withViewModel<R>(_ body: (HistoryViewModel, ClipboardStore) throws -> R) throws -> R {
        try ClipboardStoreTests.withStore { store, _ in
            let viewModel = HistoryViewModel(store: store)
            viewModel.applyFilters(resetSelection: .keep)
            return try body(viewModel, store)
        }
    }

    static func text(_ s: String, tags: [String] = []) -> ClipboardItem {
        ClipboardItem(type: .text, textContent: s, tags: tags)
    }

    @discardableResult
    static func seed(_ viewModel: HistoryViewModel, _ store: ClipboardStore, _ items: [ClipboardItem]) -> [ClipboardItem] {
        store.items = items
        viewModel.applyFilters(resetSelection: .keep)
        return items
    }

    // MARK: - Tests

    /// Tapping the inactive Tags chip activates it (all tagged clips, no
    /// specific tag) and the bar becomes visible.
    static func testActivateShowsBar() throws {
        try withViewModel { vm, store in
            seed(vm, store, [text("a", tags: ["work"]), text("b")])

            try expect(!vm.chipIsActive(.tagged), "Tags starts inactive")
            try expect(!vm.showTagsChipBar, "the bar is hidden before the chip is tapped")

            vm.tapChip(.tagged)

            try expectEqual(vm.chipFilter, ChipFilter.tagged, "tapping Tags sets chipFilter")
            try expectNil(vm.activeTagFilter, "activating the chip does not pick a specific tag")
            try expect(vm.chipIsActive(.tagged), "Tags now reads active")
            // The bar only exists while there is a tag UI at all
            // (`Features.tagsEnabled`); the filtering below is the part that
            // keeps working either way.
            try expectEqual(vm.showTagsChipBar, Features.tagsEnabled, "the bar shows once the chip is active")
            try expectEqual(vm.filteredItems.map { $0.textContent }, ["a"], "only the tagged clip shows")
        }
    }

    /// Tapping an already-active Tags chip clears both the chip and any
    /// specific tag filter picked from the bar.
    static func testDeactivateClearsTagFilter() throws {
        try withViewModel { vm, store in
            seed(vm, store, [text("a", tags: ["work"]), text("b", tags: ["home"])])

            vm.tapChip(.tagged)
            vm.applyTagFilter("work")
            try expectEqual(vm.activeTagFilter, "work", "picking a tag from the bar narrows further")

            vm.tapChip(.tagged)

            try expectEqual(vm.chipFilter, ChipFilter.all, "the second tap clears the chip")
            try expectNil(vm.activeTagFilter, "and the tag filter")
            try expect(!vm.chipIsActive(.tagged), "Tags reads inactive again")
            try expect(!vm.showTagsChipBar, "the bar is hidden again")
        }
    }

    /// Tapping All resets a live Tags chip + tag filter combination too, not
    /// just the content-kind chips.
    static func testTapAllClearsBoth() throws {
        try withViewModel { vm, store in
            seed(vm, store, [text("a", tags: ["work"])])

            vm.tapChip(.tagged)
            vm.applyTagFilter("work")

            vm.tapChip(.all)

            try expectEqual(vm.chipFilter, ChipFilter.all)
            try expectNil(vm.activeTagFilter)
        }
    }

    /// Picking a tag via `#tag` search (never tapping the chip) still lights
    /// the Tags chip, per "activeTagFilter != nil implies the chip reads as
    /// active".
    static func testHashTagFilterLightsChipWithoutTap() throws {
        try withViewModel { vm, store in
            seed(vm, store, [text("a", tags: ["work"])])

            try expect(!vm.chipIsActive(.tagged), "not active before any tag filter")

            vm.applyTagFilter("work")

            try expectEqual(vm.chipFilter, ChipFilter.all, "applyTagFilter alone does not touch chipFilter")
            try expect(vm.chipIsActive(.tagged), "but the chip reads active because activeTagFilter is set")
        }
    }

    /// Tapping Tags while it reads active purely via `activeTagFilter`
    /// (chip itself still `.all`) clears both, same as the chip-driven case.
    static func testTapTaggedWhileHashFilterLive() throws {
        try withViewModel { vm, store in
            seed(vm, store, [text("a", tags: ["work"])])
            vm.applyTagFilter("work")
            try expectEqual(vm.chipFilter, ChipFilter.all)

            vm.tapChip(.tagged)

            try expectEqual(vm.chipFilter, ChipFilter.all, "still .all — there was nothing chip-active to turn on")
            try expectNil(vm.activeTagFilter, "the tag filter is cleared")
        }
    }

    /// The chip-driven bar defers to the `#`-mode bar above the chips so the
    /// two lists (differently ordered) never show at once — and with tags
    /// hidden (`Features.tagsEnabled`) neither bar exists, so `#` opens
    /// nothing at all.
    static func testBarHiddenDuringHashSearch() throws {
        try withViewModel { vm, store in
            seed(vm, store, [text("a", tags: ["work"])])
            vm.tapChip(.tagged)
            try expectEqual(vm.showTagsChipBar, Features.tagsEnabled, "bar shows once the chip is active")

            vm.searchText = "#wo"
            try expectEqual(vm.showTagAutocomplete, Features.tagsEnabled, "typing # opens the search-mode bar")
            try expect(!vm.showTagsChipBar, "the chip-driven bar steps aside")
        }
    }

    static func testBarHiddenWithNoTags() throws {
        try withViewModel { vm, store in
            seed(vm, store, [text("a"), text("b")])
            vm.tapChip(.tagged)
            try expect(vm.chipIsActive(.tagged), "the chip can still be activated with no tags in the store")
            try expect(!vm.showTagsChipBar, "but there is nothing to show in the bar")
        }
    }

    /// ⌫ on an empty, focused search field clears just the tag filter — the
    /// chip (and therefore "all tagged clips") stays active.
    static func testBackspaceKeepsChipActive() throws {
        try withViewModel { vm, store in
            seed(vm, store, [text("a", tags: ["work"]), text("b", tags: ["home"])])
            vm.tapChip(.tagged)
            vm.applyTagFilter("work")
            try expectEqual(vm.filteredItems.map { $0.textContent }, ["a"])

            let consumed = vm.keyBackspace(searchFieldHasFocus: true)

            try expect(consumed, "backspace should consume the keystroke")
            try expectNil(vm.activeTagFilter, "the specific tag filter clears")
            try expectEqual(vm.chipFilter, ChipFilter.tagged, "the chip itself stays active")
            try expectEqual(vm.filteredItems.compactMap { $0.textContent }.sorted(), ["a", "b"], "back to all tagged clips")
        }
    }

    /// A content-kind chip's tap never reaches into `activeTagFilter` —
    /// only `.all` and `.tagged` do.
    static func testKindChipLeavesTagFilterAlone() throws {
        try withViewModel { vm, store in
            seed(vm, store, [text("a", tags: ["work"])])
            vm.applyTagFilter("work")

            vm.tapChip(.kind(.text))

            try expectEqual(vm.chipFilter, ChipFilter.kind(.text))
            try expectEqual(vm.activeTagFilter, "work", "a kind chip tap leaves an existing tag filter untouched")
        }
    }
}
