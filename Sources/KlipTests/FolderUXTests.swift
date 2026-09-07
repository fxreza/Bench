import Foundation
import BenchTestKit
@testable import Klip

// Folder UX (Phase 3B): the view-model side of rename / delete / move / new
// folder, plus the drag payload codec. The AppKit halves (NSDraggingSession,
// the sidebar drop target) cannot be driven headlessly, so what is testable
// here is the payload encoding and the handlers the drop calls into.

enum FolderUXTests {
    static let tests: [(String, () throws -> Void)] = [
        // Rename
        ("rename_prefillsCurrentName", testRenamePrefill),
        ("rename_confirmTrimsAndApplies", testRenameConfirm),
        ("rename_blankNameCannotBeConfirmed", testRenameBlank),
        ("rename_cancelLeavesNameUntouched", testRenameCancel),
        ("keyRenameFolder_onlyActsOnAFolderScope", testKeyRename),
        // Delete
        ("delete_emptyFolderGoesImmediately", testDeleteEmpty),
        ("delete_emptyFolderFallsBackToAllScope", testDeleteEmptyScopeFallback),
        ("delete_nonEmptyOpensTheChoiceStage", testDeleteOpensPrompt),
        ("delete_moveOutKeepsClipsAndTheirLock", testDeleteMoveOut),
        ("delete_deleteItemsWithNoLockedRunsImmediately", testDeleteItemsUnlocked),
        ("delete_lockedClipsRequireTheTypedGate", testDeleteLockedGate),
        ("delete_typedGateMustMatchExactly", testDeleteTypedGateExactness),
        ("delete_includingLockedRemovesEverything", testDeleteIncludingLocked),
        ("delete_keepingLockedReportsTheResult", testDeleteKeepingLocked),
        ("delete_scopeFallsBackAfterFolderIsGone", testDeleteScopeFallback),
        // Move
        ("moveSelection_movesTheWholeMultiSelection", testMoveSelectionMulti),
        ("moveSelection_nilRemovesFromFolder", testMoveSelectionOut),
        ("moveSelection_unknownFolderIsANoOp", testMoveUnknownFolder),
        ("moveToFolder_promptOptionsFilterOnTyping", testMovePromptFiltering),
        ("moveToFolder_removeOptionOnlyWhenFiled", testMoveRemoveOption),
        ("moveToFolder_arrowKeysClampAndReturnApplies", testMovePromptKeys),
        // New folder
        ("newFolder_selectsTheNewScope", testNewFolderSelectsScope),
        // Prompt plumbing
        ("prompts_areMutuallyExclusiveAndEscUnwindsThem", testPromptStack),
        // Drag and drop
        ("dragPayload_roundTrips", testDragPayloadRoundTrip),
        ("dragPayload_dropsGarbageAndDuplicates", testDragPayloadGarbage),
        ("dragIDs_useTheSelectionWhenTheRowIsPartOfIt", testDragIDs),
        ("handleDrop_routesByScope", testHandleDrop),
        ("reorderFolder_dropsIntoTheGapBelowTheTarget", testReorderFolderBelow),
        ("reorderFolder_dropsIntoTheGapAboveTheTarget", testReorderFolderAbove),
        ("reorderFolder_reachesTheTopOfTheList", testReorderFolderToTop),
        ("reorderFolder_reachesTheBottomOfTheList", testReorderFolderToBottom),
        ("reorderFolder_noOpsOnSelfUnknownAndSameGap", testReorderFolderNoOps),
        // review-2B test gaps #2 and #3.
        ("dragAndDrop_carriesImageAndFileClipsToo", testDragImageAndFileClips),
        ("orderedScopes_areAllFavoritesFoldersThenTrash", testOrderedScopes),
    ]

    // MARK: - Harness

    static func withViewModel<R>(_ body: (HistoryViewModel, ClipboardStore) throws -> R) throws -> R {
        try ClipboardStoreTests.withStore { store, _ in
            let viewModel = HistoryViewModel(store: store)
            viewModel.applyFilters(resetSelection: .keep)
            return try body(viewModel, store)
        }
    }

    static func text(_ s: String) -> ClipboardItem {
        ClipboardItem(type: .text, textContent: s)
    }

    /// Seeds `count` text items (newest first, like the store) and refreshes
    /// the view model's cached list.
    @discardableResult
    static func seed(_ viewModel: HistoryViewModel, _ store: ClipboardStore, _ contents: [String]) -> [ClipboardItem] {
        let items = contents.map { text($0) }
        store.items = items
        viewModel.applyFilters(resetSelection: .keep)
        return items
    }

    // MARK: - Rename

    static func testRenamePrefill() throws {
        try withViewModel { vm, store in
            let folder = store.createFolder(name: "Work")
            vm.requestRenameFolder(id: folder.id)
            try expect(vm.showRenameFolderPrompt, "the rename prompt should open")
            try expectEqual(vm.renameFolderName, "Work", "the field should be prefilled")
            try expectEqual(vm.renameFolderID, folder.id, "the target folder should be recorded")
            try expect(vm.isPromptShowing, "isPromptShowing should cover the rename prompt")

            vm.cancelRenameFolder()
            vm.requestRenameFolder(id: UUID())
            try expect(!vm.showRenameFolderPrompt, "an unknown folder should not open the prompt")
        }
    }

    static func testRenameConfirm() throws {
        try withViewModel { vm, store in
            let folder = store.createFolder(name: "Work")
            vm.requestRenameFolder(id: folder.id)
            vm.renameFolderName = "  Receipts  "
            vm.confirmRenameFolder()

            try expectEqual(store.folders[0].name, "Receipts", "rename should trim and apply")
            try expect(!vm.showRenameFolderPrompt, "confirming should close the prompt")
            try expectNil(vm.renameFolderID, "the target should be cleared")
        }
    }

    static func testRenameBlank() throws {
        try withViewModel { vm, store in
            let folder = store.createFolder(name: "Work")
            vm.requestRenameFolder(id: folder.id)
            vm.renameFolderName = "   "
            try expect(!vm.canConfirmRenameFolder, "a blank name must not be confirmable")
            vm.confirmRenameFolder()
            try expectEqual(store.folders[0].name, "Work", "a blank confirm should be a no-op")
            try expect(vm.showRenameFolderPrompt, "the prompt should stay open")
        }
    }

    static func testRenameCancel() throws {
        try withViewModel { vm, store in
            let folder = store.createFolder(name: "Work")
            vm.requestRenameFolder(id: folder.id)
            vm.renameFolderName = "Nope"
            vm.cancelRenameFolder()
            try expectEqual(store.folders[0].name, "Work", "cancel must not rename")
            try expect(!vm.showRenameFolderPrompt, "cancel should close the prompt")
        }
    }

    static func testKeyRename() throws {
        try withViewModel { vm, store in
            let folder = store.createFolder(name: "Work")

            vm.scope = .all
            vm.keyRenameFolder()
            try expect(!vm.showRenameFolderPrompt, "⌘R in All should do nothing")

            vm.scope = .favorites
            vm.keyRenameFolder()
            try expect(!vm.showRenameFolderPrompt, "⌘R in Favorites should do nothing")

            vm.scope = .folder(folder.id)
            vm.keyRenameFolder()
            try expect(vm.showRenameFolderPrompt, "⌘R in a folder scope should open the prompt")
            try expectEqual(vm.renameFolderID, folder.id, "it should target the visible folder")
        }
    }

    // MARK: - Delete

    static func testDeleteEmpty() throws {
        try withViewModel { vm, store in
            let folder = store.createFolder(name: "Empty")
            vm.requestDeleteFolder(id: folder.id)
            try expect(!vm.showDeleteFolderPrompt, "an empty folder should not need a confirmation")
            try expectEqual(store.folders.count, 0, "the folder should be gone immediately")
        }
    }

    static func testDeleteEmptyScopeFallback() throws {
        try withViewModel { vm, store in
            let folder = store.createFolder(name: "Empty")
            vm.scope = .folder(folder.id)
            vm.requestDeleteFolder(id: folder.id)
            try expectEqual(vm.scope, Scope.all, "the scope should fall back to All")
        }
    }

    static func testDeleteOpensPrompt() throws {
        try withViewModel { vm, store in
            let folder = store.createFolder(name: "Work")
            let items = seed(vm, store, ["a", "b"])
            store.moveItems(ids: [items[0].id], toFolder: folder.id)

            vm.requestDeleteFolder(id: folder.id)
            try expect(vm.showDeleteFolderPrompt, "a non-empty folder should ask first")
            try expectEqual(vm.deleteFolderStage, HistoryViewModel.FolderDeleteStage.choice, "it should open on the choice stage")
            try expectEqual(vm.deleteFolderItemCount, 1, "it should count the clips inside")
            try expectEqual(vm.deleteFolderLockedCount, 1, "filing locks clips, so it is locked")
            try expectEqual(store.folders.count, 1, "nothing should be deleted yet")
        }
    }

    static func testDeleteMoveOut() throws {
        try withViewModel { vm, store in
            let folder = store.createFolder(name: "Work")
            let items = seed(vm, store, ["a", "b", "c"])
            store.moveItems(ids: [items[0].id, items[1].id], toFolder: folder.id)

            vm.requestDeleteFolder(id: folder.id)
            vm.confirmDeleteFolderMovingOut()

            try expectEqual(store.folders.count, 0, "the folder should be deleted")
            try expectEqual(store.items.count, 3, "no clip should be deleted")
            try expect(store.items.allSatisfy { $0.folderID == nil }, "membership should be cleared")
            try expect(store.items.filter { $0.id != items[2].id }.allSatisfy { $0.isLocked },
                       "clips moved out keep the lock the folder gave them")
            try expect(!vm.showDeleteFolderPrompt, "the prompt should close")
        }
    }

    static func testDeleteItemsUnlocked() throws {
        try withViewModel { vm, store in
            let folder = store.createFolder(name: "Work")
            let items = seed(vm, store, ["a", "b", "c"])
            store.moveItems(ids: [items[0].id, items[1].id], toFolder: folder.id)
            store.setLocked(ids: [items[0].id, items[1].id], locked: false)

            vm.requestDeleteFolder(id: folder.id)
            try expectEqual(vm.deleteFolderLockedCount, 0, "nothing is locked any more")
            vm.requestDeleteFolderItems()

            try expectEqual(store.folders.count, 0, "the folder should be deleted")
            try expectEqual(store.items.count, 1, "both filed clips should be deleted")
            try expectEqual(store.items[0].id, items[2].id, "the clip outside the folder survives")
            try expect(!vm.showDeleteFolderPrompt, "the prompt should close")
            try expectEqual(vm.folderActionMessage, "Deleted 2 clips.", "the outcome should be reported")
        }
    }

    static func testDeleteLockedGate() throws {
        try withViewModel { vm, store in
            let folder = store.createFolder(name: "Work")
            let items = seed(vm, store, ["a", "b"])
            store.moveItems(ids: [items[0].id, items[1].id], toFolder: folder.id)

            vm.requestDeleteFolder(id: folder.id)
            vm.requestDeleteFolderItems()

            try expectEqual(vm.deleteFolderStage, HistoryViewModel.FolderDeleteStage.lockedConfirm,
                            "locked clips should force the second step")
            try expectEqual(store.items.count, 2, "nothing may be deleted before the typed confirmation")
            try expectEqual(store.folders.count, 1, "the folder must survive the first step")
            try expect(!vm.isDeleteLockedConfirmValid, "an empty field must not unlock the button")

            // The button being disabled is UI; the model must refuse too.
            vm.confirmDeleteFolderIncludingLocked()
            try expectEqual(store.items.count, 2, "confirming without the word must be a no-op")
        }
    }

    static func testDeleteTypedGateExactness() throws {
        try withViewModel { vm, store in
            let folder = store.createFolder(name: "Work")
            let items = seed(vm, store, ["a"])
            store.moveItems(ids: [items[0].id], toFolder: folder.id)
            vm.requestDeleteFolder(id: folder.id)
            vm.requestDeleteFolderItems()

            for wrong in ["delete", "Delete", "DELETE ", " DELETE", "DELET", "DELETEE", ""] {
                vm.deleteLockedConfirmText = wrong
                try expect(!vm.isDeleteLockedConfirmValid, "\"\(wrong)\" must not pass the gate")
            }
            vm.deleteLockedConfirmText = "DELETE"
            try expect(vm.isDeleteLockedConfirmValid, "the exact word should pass")
        }
    }

    static func testDeleteIncludingLocked() throws {
        try withViewModel { vm, store in
            let folder = store.createFolder(name: "Work")
            let items = seed(vm, store, ["a", "b", "c"])
            store.moveItems(ids: [items[0].id, items[1].id], toFolder: folder.id)

            vm.requestDeleteFolder(id: folder.id)
            vm.requestDeleteFolderItems()
            vm.deleteLockedConfirmText = "DELETE"
            vm.confirmDeleteFolderIncludingLocked()

            try expectEqual(store.folders.count, 0, "the folder should be gone")
            try expectEqual(store.items.count, 1, "both locked clips should be deleted")
            try expectEqual(store.items[0].id, items[2].id, "the outside clip survives")
            try expect(!vm.showDeleteFolderPrompt, "the prompt should close")
            try expectEqual(vm.folderActionMessage, "Deleted 2 clips.", "the outcome should be reported")
        }
    }

    static func testDeleteKeepingLocked() throws {
        try withViewModel { vm, store in
            let folder = store.createFolder(name: "Work")
            let items = seed(vm, store, ["a", "b", "c"])
            store.moveItems(ids: [items[0].id, items[1].id, items[2].id], toFolder: folder.id)
            store.setLocked(ids: [items[0].id], locked: false)

            vm.requestDeleteFolder(id: folder.id)
            vm.requestDeleteFolderItems()
            try expectEqual(vm.deleteFolderStage, HistoryViewModel.FolderDeleteStage.lockedConfirm,
                            "two locked clips should force the second step")

            vm.confirmDeleteFolderKeepingLocked()

            try expectEqual(vm.deleteFolderStage, HistoryViewModel.FolderDeleteStage.result,
                            "the card should report the outcome")
            try expect(vm.showDeleteFolderPrompt, "the card stays up to show the result")
            try expectEqual(store.folders.count, 1, "the folder survives while locked clips are inside")
            try expectEqual(store.items.count, 2, "only the unlocked clip should be deleted")
            try expectEqual(vm.folderActionMessage,
                            "Deleted 1, kept 2 locked clips in the folder.",
                            "the result line should name both numbers")

            vm.acknowledgeFolderResult()
            try expect(!vm.showDeleteFolderPrompt, "Done should dismiss the card")
            try expectNil(vm.folderActionMessage, "Done should clear the message")
        }
    }

    static func testDeleteScopeFallback() throws {
        try withViewModel { vm, store in
            let folder = store.createFolder(name: "Work")
            let items = seed(vm, store, ["a"])
            store.moveItems(ids: [items[0].id], toFolder: folder.id)
            vm.scope = .folder(folder.id)

            vm.requestDeleteFolder(id: folder.id)
            vm.confirmDeleteFolderMovingOut()

            try expectEqual(vm.scope, Scope.all, "the deleted folder's scope must not strand the sidebar")

            // validateScope on its own is the safety net used by the store observer.
            let other = store.createFolder(name: "Other")
            vm.scope = .folder(other.id)
            store.deleteFolder(id: other.id, mode: .moveItemsOut)
            vm.validateScope()
            try expectEqual(vm.scope, Scope.all, "validateScope should drop a stale folder scope")
        }
    }

    // MARK: - Move

    static func testMoveSelectionMulti() throws {
        try withViewModel { vm, store in
            let folder = store.createFolder(name: "Work")
            let items = seed(vm, store, ["a", "b", "c"])
            vm.selectedIDs = [items[0].id, items[2].id]
            vm.selectedID = items[0].id

            vm.moveSelection(toFolder: folder.id)

            try expectEqual(store.items[0].folderID, folder.id, "the first selected clip should be filed")
            try expectEqual(store.items[2].folderID, folder.id, "the third selected clip should be filed")
            try expectNil(store.items[1].folderID, "the unselected clip should be untouched")
            try expect(store.items[0].isLocked && store.items[2].isLocked, "filing locks the clips")
        }
    }

    static func testMoveSelectionOut() throws {
        try withViewModel { vm, store in
            let folder = store.createFolder(name: "Work")
            let items = seed(vm, store, ["a", "b"])
            store.moveItems(ids: [items[0].id], toFolder: folder.id)

            vm.selectedIDs = []
            vm.selectedID = items[0].id
            vm.moveSelection(toFolder: nil)

            try expectNil(store.items[0].folderID, "the clip should leave the folder")
            try expect(store.items[0].isLocked, "moving out leaves the lock alone")
        }
    }

    static func testMoveUnknownFolder() throws {
        try withViewModel { vm, store in
            let items = seed(vm, store, ["a"])
            vm.selectedIDs = [items[0].id]
            vm.moveSelection(toFolder: UUID())
            try expectNil(store.items[0].folderID, "moving into a folder that does not exist is a no-op")
        }
    }

    static func testMovePromptFiltering() throws {
        try withViewModel { vm, store in
            _ = store.createFolder(name: "Work")
            _ = store.createFolder(name: "Receipts")
            _ = store.createFolder(name: "Work Notes")
            let items = seed(vm, store, ["a"])

            vm.requestMoveToFolder(ids: [items[0].id])
            try expectEqual(vm.moveToFolderOptions.count, 3, "every folder should be offered")

            vm.moveFolderQuery = "work"
            try expectEqual(vm.moveToFolderOptions.map { $0.title }, ["Work", "Work Notes"],
                            "typing should filter case-insensitively")

            vm.moveFolderQuery = "zzz"
            try expect(vm.moveToFolderOptions.isEmpty, "a query that matches nothing should empty the list")
        }
    }

    static func testMoveRemoveOption() throws {
        try withViewModel { vm, store in
            let folder = store.createFolder(name: "Work")
            let items = seed(vm, store, ["a", "b"])

            vm.requestMoveToFolder(ids: [items[0].id])
            try expect(!vm.moveToFolderOptions.contains(.none),
                       "a clip outside every folder has nothing to be removed from")
            vm.cancelMoveToFolder()

            store.moveItems(ids: [items[0].id], toFolder: folder.id)
            vm.requestMoveToFolder(ids: [items[0].id])
            try expect(vm.moveToFolderOptions.contains(.none),
                       "a filed clip should offer Remove from Folder")

            // Applying it takes the clip back out.
            vm.apply(.none)
            try expectNil(store.items[0].folderID, "Remove from Folder should clear membership")
            try expect(!vm.showMoveToFolderPrompt, "applying should close the picker")
        }
    }

    static func testMovePromptKeys() throws {
        try withViewModel { vm, store in
            let a = store.createFolder(name: "Alpha")
            let b = store.createFolder(name: "Beta")
            let items = seed(vm, store, ["x"])
            vm.requestMoveToFolder(ids: [items[0].id])

            try expectEqual(vm.moveFolderClampedHighlight, 0, "the first option starts highlighted")
            vm.moveHighlightBy(-1)
            try expectEqual(vm.moveFolderClampedHighlight, 0, "↑ at the top should clamp")
            vm.moveHighlightBy(1)
            try expectEqual(vm.moveFolderClampedHighlight, 1, "↓ should move down")
            vm.moveHighlightBy(5)
            try expectEqual(vm.moveFolderClampedHighlight, 1, "↓ past the end should clamp")

            vm.confirmMoveToFolder()
            try expectEqual(store.items[0].folderID, b.id, "Return should apply the highlighted folder")
            try expect(a.id != b.id, "sanity")
        }
    }

    // MARK: - New folder

    static func testNewFolderSelectsScope() throws {
        try withViewModel { vm, store in
            vm.keyNewFolder()
            try expect(vm.showNewFolderPrompt, "⌘N should open the New Folder prompt")
            vm.newFolderName = "Receipts"
            vm.confirmNewFolder()

            try expectEqual(store.folders.count, 1, "the folder should be created")
            try expectEqual(vm.scope, Scope.folder(store.folders[0].id), "the sidebar should switch to it")
            try expect(!vm.showNewFolderPrompt, "the prompt should close")
        }
    }

    // MARK: - Prompt plumbing

    static func testPromptStack() throws {
        try withViewModel { vm, store in
            let folder = store.createFolder(name: "Work")
            let items = seed(vm, store, ["a"])
            store.moveItems(ids: [items[0].id], toFolder: folder.id)

            vm.requestRenameFolder(id: folder.id)
            try expect(vm.isPromptShowing, "rename counts as a prompt")

            // Opening another folder prompt replaces it — never two cards at once.
            vm.requestDeleteFolder(id: folder.id)
            try expect(!vm.showRenameFolderPrompt, "opening delete should close rename")
            try expect(vm.showDeleteFolderPrompt, "delete should be showing")

            try expect(vm.dismissTopPrompt(), "Esc should consume the delete prompt")
            try expect(!vm.isPromptShowing, "no prompt should be left")
            try expect(!vm.dismissTopPrompt(), "Esc with nothing open should fall through to closing the window")

            vm.requestMoveToFolder(ids: [items[0].id])
            try expect(vm.isPromptShowing, "the move picker counts as a prompt")
            vm.resetFolderPrompts()
            try expect(!vm.isPromptShowing, "reopening the window should clear every prompt")
        }
    }

    // MARK: - Drag and drop

    static func testDragPayloadRoundTrip() throws {
        let ids = [UUID(), UUID(), UUID()]
        let encoded = ClipDragPayload.encode(ids)
        try expectEqual(encoded.components(separatedBy: "\n").count, 3, "one line per id")
        try expectEqual(ClipDragPayload.decode(encoded), ids, "decode should invert encode, order intact")
        try expectEqual(ClipDragPayload.encode([]), "", "an empty payload encodes to an empty string")
        try expect(ClipDragPayload.decode("").isEmpty, "an empty string decodes to nothing")
    }

    static func testDragPayloadGarbage() throws {
        let a = UUID(), b = UUID()
        let raw = "\(a.uuidString)\nnot-a-uuid\n\n  \(b.uuidString)  \r\n\(a.uuidString)"
        try expectEqual(ClipDragPayload.decode(raw), [a, b],
                        "unparseable lines are dropped, whitespace trimmed, duplicates collapsed")
    }

    static func testDragIDs() throws {
        try withViewModel { vm, store in
            let items = seed(vm, store, ["a", "b", "c"])

            vm.selectedIDs = []
            try expectEqual(vm.dragIDs(startingAt: items[1].id), [items[1].id],
                            "with no selection a drag carries just the pressed row")

            vm.selectedIDs = [items[0].id]
            try expectEqual(vm.dragIDs(startingAt: items[2].id), [items[2].id],
                            "pressing outside the selection carries just that row")

            vm.selectedIDs = [items[0].id, items[2].id]
            try expectEqual(vm.dragIDs(startingAt: items[2].id), [items[0].id, items[2].id],
                            "pressing inside a multi-selection carries all of it, in list order")
        }
    }

    static func testHandleDrop() throws {
        try withViewModel { vm, store in
            let folder = store.createFolder(name: "Work")
            let items = seed(vm, store, ["a", "b"])

            try expect(vm.handleDrop(ids: [items[0].id, items[1].id], on: .folder(folder.id)),
                       "a folder row should accept clips")
            try expectEqual(store.items[0].folderID, folder.id, "the clip should be filed")
            try expect(store.items[0].isLocked, "filing locks")

            try expect(vm.handleDrop(ids: [items[0].id], on: .all),
                       "the All row should accept clips")
            try expectNil(store.items[0].folderID, "dropping on All removes folder membership")

            try expect(!vm.handleDrop(ids: [items[0].id], on: .favorites),
                       "Favorites is not a drop target")
            try expect(!vm.handleDrop(ids: [], on: .all), "an empty payload is rejected")
            try expect(!vm.handleDrop(ids: [items[0].id], on: .folder(UUID())),
                       "a folder that no longer exists rejects the drop")
        }
    }

    /// review-2B test gap #2: the drag payload and the drop handler are
    /// type-agnostic by inspection — nothing had ever exercised them with an
    /// **image** or **file** clip, only text.
    static func testDragImageAndFileClips() throws {
        try withViewModel { vm, store in
            let folder = store.createFolder(name: "Assets")
            let picture = ClipboardItem(type: .image, imageFilename: "\(UUID().uuidString).png")
            let document = ClipboardItem(
                type: .text,
                textContent: "Report.pdf",
                fileAttachment: FileAttachment(
                    originalName: "Report.pdf",
                    referencePath: "/tmp/Report.pdf",
                    byteSize: 1024
                )
            )
            let note = text("just text")
            store.items = [picture, document, note]
            vm.applyFilters(resetSelection: .keep)

            // Payload: an image + a file clip round-trip through the private
            // pasteboard encoding exactly like text clips do.
            vm.selectedIDs = [picture.id, document.id]
            let dragged = vm.dragIDs(startingAt: document.id)
            try expectEqual(dragged, [picture.id, document.id],
                            "a mixed image/file selection drags as a whole, in list order")
            try expectEqual(ClipDragPayload.decode(ClipDragPayload.encode(dragged)), dragged,
                            "image and file ids survive the payload round trip")

            // Drop: both land in the folder and are locked by filing.
            try expect(vm.handleDrop(ids: dragged, on: .folder(folder.id)),
                       "a folder row accepts image and file clips")
            let filed = store.items.filter { $0.folderID == folder.id }
            try expectEqual(Set(filed.map { $0.id }), Set(dragged),
                            "both the image and the file clip are filed")
            try expect(filed.allSatisfy { $0.isLocked }, "filing locks them, whatever their type")
            try expectNil(store.items.first(where: { $0.id == note.id })?.folderID,
                          "the clip that was not dragged is untouched")
        }
    }

    /// 3.0.1 removed ⌘[ / ⌘] scope cycling, but the scope *order* is still
    /// what the sidebar renders and what `validateScope` falls back through.
    static func testOrderedScopes() throws {
        try withViewModel { vm, store in
            let work = store.createFolder(name: "Work")
            let home = store.createFolder(name: "Home")
            try expectEqual(vm.orderedScopes,
                            [.all, .favorites, .folder(work.id), .folder(home.id), .trash],
                            "scope order is All, Favorites, folders in sidebar order, then Trash (5E)")

            // A folder that disappears drops the scope back to All rather
            // than leaving a scope nothing can select.
            vm.scope = .folder(work.id)
            store.deleteFolder(id: work.id, mode: .moveItemsOut)
            vm.validateScope()
            try expectEqual(vm.scope, .all, "a deleted folder's scope falls back to All")
            _ = home
        }
    }

    /// Three folders, A B C, handed to `body` in that order.
    private static func withThreeFolders(
        _ body: (HistoryViewModel, ClipboardStore, Folder, Folder, Folder) throws -> Void
    ) throws {
        try withViewModel { vm, store in
            let a = store.createFolder(name: "A")
            let b = store.createFolder(name: "B")
            let c = store.createFolder(name: "C")
            try expectEqual(store.folders.map { $0.id }, [a.id, b.id, c.id], "initial order")
            try body(vm, store, a, b, c)
        }
    }

    static func testReorderFolderBelow() throws {
        try withThreeFolders { vm, store, a, b, c in
            try expect(vm.reorderFolder(dragged: a.id, relativeTo: c.id, insertAbove: false),
                       "dropping A in the gap under C should reorder")
            try expectEqual(store.folders.map { $0.id }, [b.id, c.id, a.id],
                            "A lands after C")
            try expectEqual(store.folders.map { $0.sortIndex }, [0, 1, 2], "sortIndex is rewritten")
        }
    }

    static func testReorderFolderAbove() throws {
        try withThreeFolders { vm, store, a, b, c in
            try expect(vm.reorderFolder(dragged: c.id, relativeTo: b.id, insertAbove: true),
                       "dropping C in the gap above B should reorder")
            try expectEqual(store.folders.map { $0.id }, [a.id, c.id, b.id], "C lands before B")
        }
    }

    /// The two positions the old drop-onto-a-row reorder could not express at
    /// all: there was no row to drop on that meant "before the first" or
    /// "after the last".
    static func testReorderFolderToTop() throws {
        try withThreeFolders { vm, store, a, _, c in
            try expect(vm.reorderFolder(dragged: c.id, relativeTo: a.id, insertAbove: true),
                       "dropping C above the first folder should reorder")
            try expectEqual(store.folders.first?.id, c.id, "C is now the top folder")
        }
    }

    static func testReorderFolderToBottom() throws {
        try withThreeFolders { vm, store, a, _, c in
            try expect(vm.reorderFolder(dragged: a.id, relativeTo: c.id, insertAbove: false),
                       "dropping A below the last folder should reorder")
            try expectEqual(store.folders.last?.id, a.id, "A is now the bottom folder")
        }
    }

    static func testReorderFolderNoOps() throws {
        try withThreeFolders { vm, store, a, b, _ in
            try expect(!vm.reorderFolder(dragged: a.id, relativeTo: a.id, insertAbove: true),
                       "dropping a folder on itself is a no-op")
            try expect(!vm.reorderFolder(dragged: UUID(), relativeTo: a.id, insertAbove: true),
                       "an unknown folder is a no-op")
            // A drops into the gap it already occupies. Nothing moves, so
            // nothing is renumbered and no `updatedAt` is bumped for sync.
            try expect(!vm.reorderFolder(dragged: a.id, relativeTo: b.id, insertAbove: true),
                       "landing back in the same gap is a no-op")
            try expectEqual(store.folders.map { $0.sortIndex }, [0, 1, 2], "order untouched")
        }
    }
}
