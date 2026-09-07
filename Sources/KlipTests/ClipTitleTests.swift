import Foundation
import BenchTestKit
@testable import Klip

// Clip titles: the optional user-given name on a clip, and the on-accent tag
// chip that ships with it.
//
// Two things are load-bearing here and both are covered below:
//   1. `title` is optional and decoded with `decodeIfPresent`, so an existing
//      `history.json` written by any earlier build still loads (the same
//      contract every field added since 2.5.0 has).
//   2. A blank name is stored as `nil`, never as `""` — that is how a name is
//      *removed*, and it is why `displayTitle` can be trusted as "has a name".

enum ClipTitleTests {
    static let tests: [(String, () throws -> Void)] = [
        ("decode_fileWithoutTitle_loadsWithNilTitle", testOldFileDecodes),
        ("roundTrip_titleSurvivesSaveAndLoad", testRoundTrip),
        ("setTitle_trimsAndStores", testSetTitleTrims),
        ("setTitle_blankInput_clearsTheName", testSetTitleBlankClears),
        ("setTitle_capsAtTitleMaxLength", testSetTitleCaps),
        ("setTitle_bumpsUpdatedAtForSync", testSetTitleTouches),
        ("displayTitle_whitespaceOnly_readsAsUnnamed", testDisplayTitleWhitespace),
        ("search_matchesOnTitle", testSearchMatchesTitle),
        ("search_stillMatchesContentOfANamedClip", testSearchStillMatchesContent),
        ("renamePrompt_prefillsConfirmsAndClears", testRenamePromptRoundTrip),
        ("renamePrompt_emptyCommitRemovesTheName", testRenamePromptEmptyCommit),
        ("renamePrompt_refusedInTrash", testRenameRefusedInTrash),
        ("renamePrompt_blocksListShortcutsAndEscUnwindsIt", testRenamePromptOwnsKeyboard),
        ("editMode_commitsTitleAlongsideTheText", testEditModeCommitsTitle),
        ("renameClip_hasItsOwnConflictFreeDefaultKey", testRenameShortcutDefault),
        // Tag strip wrapping
        ("flow_packsWhatFitsOnOneRow", testFlowSingleRow),
        ("flow_wrapsRatherThanRunningPastTheEdge", testFlowWraps),
        ("flow_neverDropsASubview", testFlowKeepsEverything),
        ("flow_oversizedSubviewGetsItsOwnRow", testFlowOversized),
        ("flow_rowHeightIsTheTallestSubview", testFlowRowHeight),
    ]

    // MARK: - Helpers

    static func text(_ s: String, title: String? = nil) -> ClipboardItem {
        ClipboardItem(type: .text, textContent: s, title: title)
    }

    // MARK: - Model / codec

    /// A history file written before titles existed decodes with `nil`, not a
    /// throw. This is the whole backward-compatibility contract.
    static func testOldFileDecodes() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "type": "text",
          "timestamp": 760000000,
          "isPinned": false,
          "isBookmarked": false,
          "tags": [],
          "isLocked": false,
          "textContent": "no title here",
          "updatedAt": 760000000
        }
        """
        let decoder = JSONDecoder()
        let item = try decoder.decode(ClipboardItem.self, from: Data(json.utf8))
        try expectNil(item.title, "a file without the key decodes with no title")
        try expectNil(item.displayTitle, "and reads as unnamed")
        try expectEqual(item.textContent, "no title here", "the rest of the clip is untouched")
    }

    static func testRoundTrip() throws {
        let item = text("postgres://localhost", title: "Staging DB")
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(ClipboardItem.self, from: data)
        try expectEqual(decoded.title, "Staging DB", "the name survives encode/decode")
        try expectEqual(decoded.displayTitle, "Staging DB")
    }

    static func testDisplayTitleWhitespace() throws {
        try expectNil(text("x", title: "   ").displayTitle, "whitespace-only is not a name")
        try expectNil(text("x", title: "").displayTitle, "empty is not a name")
        try expectEqual(text("x", title: "  Named  ").displayTitle, "Named", "and a real one is trimmed")
    }

    // MARK: - Store

    static func testSetTitleTrims() throws {
        try ClipboardStoreTests.withStore { store, _ in
            store.items = [text("body")]
            store.setTitle("  Invoice template  ", for: store.items[0])
            try expectEqual(store.items[0].title, "Invoice template", "leading/trailing space is stripped")
        }
    }

    static func testSetTitleBlankClears() throws {
        try ClipboardStoreTests.withStore { store, _ in
            store.items = [text("body", title: "Named")]
            store.setTitle("   ", for: store.items[0])
            try expectNil(store.items[0].title, "blank input clears the name rather than storing \"\"")
        }
    }

    static func testSetTitleCaps() throws {
        try ClipboardStoreTests.withStore { store, _ in
            store.items = [text("body")]
            let long = String(repeating: "n", count: ClipboardItem.titleMaxLength + 50)
            store.setTitle(long, for: store.items[0])
            try expectEqual(store.items[0].title?.count, ClipboardItem.titleMaxLength,
                            "the name is capped at titleMaxLength")
        }
    }

    /// Sync resolves a same-id conflict by newest `updatedAt`, so a rename has
    /// to bump it or the new name loses to a stale copy on another device.
    static func testSetTitleTouches() throws {
        try ClipboardStoreTests.withStore { store, _ in
            var item = text("body")
            item.updatedAt = Date(timeIntervalSince1970: 0)
            store.items = [item]

            store.setTitle("Named", for: store.items[0])

            try expect(store.items[0].updatedAt > Date(timeIntervalSince1970: 0),
                       "renaming bumps updatedAt so the merge keeps the rename")
        }
    }

    // MARK: - Search

    static func testSearchMatchesTitle() throws {
        FilterState.resetSearchBlobCache()
        let items = [
            text("aGVsbG8gd29ybGQ=", title: "Staging DB password"),
            text("something else"),
        ]

        let result = FilterState.apply(items, FilterState(query: "staging"))

        try expectEqual(result.count, 1, "the query finds the clip by its name")
        try expectEqual(result.first?.displayTitle, "Staging DB password")
    }

    /// Naming a clip must not hide what is inside it.
    static func testSearchStillMatchesContent() throws {
        FilterState.resetSearchBlobCache()
        let items = [
            text("postgres://localhost:5432", title: "Staging DB"),
            text("nothing to see"),
        ]

        let result = FilterState.apply(items, FilterState(query: "postgres"))

        try expectEqual(result.count, 1, "content is still searchable on a named clip")
    }

    // MARK: - Rename prompt

    static func testRenamePromptRoundTrip() throws {
        try TagsChipTests.withViewModel { vm, store in
            TagsChipTests.seed(vm, store, [text("body", title: "Old name")])
            let id = store.items[0].id

            vm.requestRenameClip(id: id)
            try expect(vm.showRenameClipPrompt, "the card opens")
            try expectEqual(vm.renameClipText, "Old name", "prefilled with the current name")

            vm.renameClipText = "New name"
            vm.confirmRenameClip()

            try expect(!vm.showRenameClipPrompt, "the card closes on commit")
            try expectNil(vm.renameClipID, "and forgets its target")
            try expectEqual(store.items[0].title, "New name", "the store has the new name")
        }
    }

    static func testRenamePromptEmptyCommit() throws {
        try TagsChipTests.withViewModel { vm, store in
            TagsChipTests.seed(vm, store, [text("body", title: "Old name")])
            vm.requestRenameClip(id: store.items[0].id)

            vm.renameClipText = ""
            try expect(vm.canConfirmRenameClip, "an empty name is a valid commit — it removes the name")
            vm.confirmRenameClip()

            try expectNil(store.items[0].title, "committing empty clears the name")
        }
    }

    /// 5E: a trashed clip lives in `trashedItems`, so a rename would write
    /// through `store.items` where it no longer is — same guard as tags/edit.
    static func testRenameRefusedInTrash() throws {
        try TagsChipTests.withViewModel { vm, store in
            TagsChipTests.seed(vm, store, [text("body")])
            let id = store.items[0].id
            vm.scope = .trash

            vm.requestRenameClip(id: id)

            try expect(!vm.showRenameClipPrompt, "the card never opens in the trash")
        }
    }

    static func testRenamePromptOwnsKeyboard() throws {
        try TagsChipTests.withViewModel { vm, store in
            TagsChipTests.seed(vm, store, [text("body")])
            vm.requestRenameClip(id: store.items[0].id)

            try expect(vm.isPromptShowing, "list shortcuts stand down while the card is up")

            vm.keyEscape()
            try expect(!vm.showRenameClipPrompt, "Esc unwinds the card")
            try expect(!vm.isPromptShowing, "and nothing else is left showing")
        }
    }

    // MARK: - Edit mode

    static func testEditModeCommitsTitle() throws {
        try TagsChipTests.withViewModel { vm, store in
            TagsChipTests.seed(vm, store, [text("original body", title: "Original")])
            vm.selectSingle(store.items[0].id)

            vm.enterEditMode()
            try expectEqual(vm.editTitleText, "Original", "the field is prefilled")

            vm.editTitleText = "Renamed in the editor"
            vm.editText = "edited body"
            vm.exitEditMode()

            try expectEqual(store.items[0].title, "Renamed in the editor", "the title commits with the body")
            try expectEqual(store.items[0].textContent, "edited body")
            try expectEqual(vm.editTitleText, "", "and the field is cleared afterwards")
        }
    }

    // MARK: - Shortcut

    static func testRenameShortcutDefault() throws {
        let binding = ShortcutAction.renameClip.defaultBinding
        try expectEqual(binding.keyCode, 120, "F2, the Finder/Ditto convention")
        try expectEqual(binding.modifiers, ClipKeyModifiers(), "no modifiers")
        try expectEqual(binding.display, "F2")

        let others = ShortcutAction.allCases.filter { $0 != .renameClip }
        for action in others {
            try expect(action.defaultBinding != binding,
                       "\(action) must not share F2 with renameClip")
        }
    }

    // MARK: - Tag strip wrapping
    //
    // The preview pane's tag strip used to scroll sideways, which pushed each
    // chip's ✕ and the "Add tag" button off the right edge as soon as the tags
    // were a little long — in a narrow pane there was then no way to add or
    // remove a tag at all. `FlowLayout` wraps instead; these cover the packing
    // rule that makes that true.

    static func size(_ w: CGFloat, _ h: CGFloat = 18) -> CGSize { CGSize(width: w, height: h) }

    static func testFlowSingleRow() throws {
        let rows = FlowLayout.pack([size(40), size(40), size(40)], maxWidth: 200, spacing: 4)
        try expectEqual(rows.count, 1, "three 40pt chips fit on one 200pt row")
        try expectEqual(rows[0].elements.count, 3)
        try expectEqual(rows[0].width, 128, "40 + 4 + 40 + 4 + 40")
    }

    static func testFlowWraps() throws {
        let rows = FlowLayout.pack([size(80), size(80), size(80)], maxWidth: 200, spacing: 4)
        try expectEqual(rows.count, 2, "the third chip does not fit and wraps")
        try expectEqual(rows[0].elements.map(\.index), [0, 1])
        try expectEqual(rows[1].elements.map(\.index), [2], "and lands on the next line, not off the edge")
    }

    /// The whole point of the change: the trailing control — "Add tag", or the
    /// ✕ on the last chip — must still be laid out, never truncated away.
    static func testFlowKeepsEverything() throws {
        let sizes = (0..<9).map { _ in size(70) }
        let rows = FlowLayout.pack(sizes, maxWidth: 150, spacing: 4)
        let placed = rows.flatMap { $0.elements.map(\.index) }
        try expectEqual(placed, Array(0..<9), "every subview is placed, in order, with none dropped")
    }

    static func testFlowOversized() throws {
        // A single tag longer than the whole pane: it is clamped to the
        // container width by `arrange` before it gets here, so what `pack`
        // sees is exactly the container width.
        let rows = FlowLayout.pack([size(40), size(200), size(40)], maxWidth: 200, spacing: 4)
        try expectEqual(rows.count, 3, "the oversized chip takes a line of its own")
        try expectEqual(rows[1].elements.map(\.index), [1])
        try expect(rows[1].width <= 200, "and never exceeds the container width")
    }

    static func testFlowRowHeight() throws {
        // The add-tag field is taller than a chip; the row has to make room
        // for it rather than clipping it.
        let rows = FlowLayout.pack([size(40, 18), size(60, 26)], maxWidth: 200, spacing: 4)
        try expectEqual(rows.count, 1)
        try expectEqual(rows[0].height, 26, "the row is as tall as its tallest subview")
    }
}
