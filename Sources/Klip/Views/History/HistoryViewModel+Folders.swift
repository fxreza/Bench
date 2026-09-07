import AppKit
import SwiftUI

/// Folder UX (Phase 3B): rename, delete, move, and the drag-and-drop entry
/// points. Stored state lives in the `// MARK: - 3B state` block at the end of
/// `HistoryViewModel` so the two Phase 3 tasks editing that file stay mergeable.
///
/// Every confirmation is an inline `PromptCard`, never an `NSAlert`: the history
/// window is a borderless panel that closes as soon as it resigns key.
extension HistoryViewModel {

    /// Typed exactly to unlock "delete the locked clips too".
    static var lockedDeleteConfirmationWord: String { "DELETE" }

    // MARK: - Prompt bookkeeping

    /// True while any 3B prompt owns the keyboard. `isPromptShowing` folds this
    /// in so `GlobalKeyMonitor` stands down and Esc unwinds one layer.
    var isFolderPromptShowing: Bool {
        showRenameFolderPrompt || showDeleteFolderPrompt || showMoveToFolderPrompt
    }

    /// Esc handling for the 3B prompts, newest layer first.
    @discardableResult
    func dismissTopFolderPrompt() -> Bool {
        if showMoveToFolderPrompt {
            cancelMoveToFolder()
            return true
        }
        if showDeleteFolderPrompt {
            cancelDeleteFolder()
            return true
        }
        if showRenameFolderPrompt {
            cancelRenameFolder()
            return true
        }
        return false
    }

    /// Wipe every 3B prompt (window reopen).
    func resetFolderPrompts() {
        showRenameFolderPrompt = false
        renameFolderID = nil
        renameFolderName = ""

        showDeleteFolderPrompt = false
        deleteFolderID = nil
        deleteFolderStage = .choice
        deleteLockedConfirmText = ""
        folderActionMessage = nil

        showMoveToFolderPrompt = false
        moveFolderQuery = ""
        moveFolderHighlight = 0
        pendingMoveIDs = []

        dropTargetScope = nil
    }

    /// Only one prompt at a time — opening a folder prompt closes the others.
    private func closeOtherPrompts() {
        showNewFolderPrompt = false
        newFolderName = ""
        showRenameFolderPrompt = false
        showDeleteFolderPrompt = false
        showMoveToFolderPrompt = false
        folderActionMessage = nil
    }

    func folder(_ id: UUID?) -> Folder? {
        guard let id = id else { return nil }
        return store.folders.first(where: { $0.id == id })
    }

    /// The folder the sidebar is currently showing, if any.
    var activeFolder: Folder? {
        guard case .folder(let id) = scope else { return nil }
        return folder(id)
    }

    // MARK: - New folder

    /// ⌘N (wired by 3E).
    func keyNewFolder() {
        guard !isEditing else { return }
        closeOtherPrompts()
        requestNewFolder()
    }

    // MARK: - Rename

    /// Open the inline rename prompt, prefilled with the current name.
    func requestRenameFolder(id: UUID) {
        guard let folder = folder(id) else { return }
        closeOtherPrompts()
        renameFolderID = folder.id
        renameFolderName = folder.name
        showRenameFolderPrompt = true
    }

    /// ⌘R (wired by 3E) — renames the folder the sidebar is showing. A no-op in
    /// All / Favorites, which cannot be renamed.
    func keyRenameFolder() {
        guard !isEditing else { return }
        guard let folder = activeFolder else { return }
        requestRenameFolder(id: folder.id)
    }

    /// Name the rename prompt would commit, trimmed.
    var renameFolderTrimmedName: String {
        renameFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canConfirmRenameFolder: Bool {
        !renameFolderTrimmedName.isEmpty && renameFolderID != nil
    }

    func confirmRenameFolder() {
        guard let id = renameFolderID, canConfirmRenameFolder else { return }
        let name = renameFolderTrimmedName
        cancelRenameFolder()
        store.renameFolder(id: id, to: name)
    }

    func cancelRenameFolder() {
        showRenameFolderPrompt = false
        renameFolderID = nil
        renameFolderName = ""
    }

    // MARK: - Delete

    /// Empty folders go immediately; anything else opens the confirm card.
    func requestDeleteFolder(id: UUID) {
        guard folder(id) != nil else { return }
        if store.items(inFolder: id).isEmpty {
            performImmediateDelete(id: id)
            return
        }
        closeOtherPrompts()
        deleteFolderID = id
        deleteFolderStage = .choice
        deleteLockedConfirmText = ""
        folderActionMessage = nil
        showDeleteFolderPrompt = true
    }

    /// Delete the folder the sidebar is showing (3E can bind a key to it).
    func keyDeleteFolder() {
        guard !isEditing else { return }
        guard let folder = activeFolder else { return }
        requestDeleteFolder(id: folder.id)
    }

    private func performImmediateDelete(id: UUID) {
        // Mode is irrelevant with no members; moveItemsOut never touches items.
        store.deleteFolder(id: id, mode: .moveItemsOut)
        finishFolderDeletion()
    }

    var deleteFolderTarget: Folder? { folder(deleteFolderID) }

    /// Clips inside the folder awaiting deletion.
    var deleteFolderItemCount: Int {
        guard let id = deleteFolderID else { return 0 }
        return store.items(inFolder: id).count
    }

    /// How many of those are locked (they survive unless explicitly confirmed).
    var deleteFolderLockedCount: Int {
        guard let id = deleteFolderID else { return 0 }
        return store.items(inFolder: id).filter { $0.isLocked }.count
    }

    /// "Move N clips to All" — the default, safe branch. Clips keep their lock.
    func confirmDeleteFolderMovingOut() {
        guard let id = deleteFolderID else { return }
        store.deleteFolder(id: id, mode: .moveItemsOut)
        cancelDeleteFolder()
        finishFolderDeletion()
    }

    /// "Delete N clips". With locked clips present this only advances to the
    /// typed-confirmation stage; nothing is deleted yet.
    func requestDeleteFolderItems() {
        guard let id = deleteFolderID else { return }
        guard deleteFolderLockedCount == 0 else {
            deleteLockedConfirmText = ""
            deleteFolderStage = .lockedConfirm
            return
        }
        let result = store.deleteFolder(id: id, mode: .deleteItems(includeLocked: false))
        cancelDeleteFolder()
        folderActionMessage = Self.message(for: result)
        finishFolderDeletion()
    }

    /// From the locked stage: delete the unlocked clips only. The folder stays,
    /// holding the locked clips, and the card reports what happened.
    func confirmDeleteFolderKeepingLocked() {
        guard let id = deleteFolderID else { return }
        let result = store.deleteFolder(id: id, mode: .deleteItems(includeLocked: false))
        folderActionMessage = Self.message(for: result)
        deleteLockedConfirmText = ""
        if result.folderDeleted {
            cancelDeleteFolder()
            finishFolderDeletion()
        } else {
            deleteFolderStage = .result
        }
    }

    /// Only enabled once DELETE has been typed exactly.
    var isDeleteLockedConfirmValid: Bool {
        deleteLockedConfirmText == Self.lockedDeleteConfirmationWord
    }

    /// The explicit second step: delete the locked clips too.
    func confirmDeleteFolderIncludingLocked() {
        guard let id = deleteFolderID, isDeleteLockedConfirmValid else { return }
        let result = store.deleteFolder(id: id, mode: .deleteItems(includeLocked: true))
        cancelDeleteFolder()
        folderActionMessage = Self.message(for: result)
        finishFolderDeletion()
    }

    func cancelDeleteFolder() {
        showDeleteFolderPrompt = false
        deleteFolderID = nil
        deleteFolderStage = .choice
        deleteLockedConfirmText = ""
    }

    /// Dismiss the `.result` stage.
    func acknowledgeFolderResult() {
        folderActionMessage = nil
        cancelDeleteFolder()
    }

    /// A folder disappearing must not strand the sidebar on an empty scope.
    private func finishFolderDeletion() {
        validateScope()
        applyFilters(resetSelection: .preserve)
    }

    static func message(for result: ClipboardStore.FolderDeleteResult) -> String? {
        if result.skippedLocked > 0 {
            let clips = result.skippedLocked == 1 ? "clip" : "clips"
            return "Deleted \(result.deleted), kept \(result.skippedLocked) locked \(clips) in the folder."
        }
        if result.deleted > 0 {
            let clips = result.deleted == 1 ? "clip" : "clips"
            return "Deleted \(result.deleted) \(clips)."
        }
        if result.movedOut > 0 {
            let clips = result.movedOut == 1 ? "clip" : "clips"
            return "Moved \(result.movedOut) \(clips) to All."
        }
        return nil
    }

    // MARK: - Move

    /// Move the current selection (multi-selection included) into `id`, or out
    /// of any folder when `id` is nil. Used by the context menu (3D), the
    /// move prompt and drag-and-drop.
    func moveSelection(toFolder id: UUID?) {
        // 5E: a trashed clip is not in `items`, so filing it would be a
        // silent no-op. Restore it first.
        guard !isTrashScope else { return }
        var ids = selectedIDs
        if ids.isEmpty, let single = selectedID { ids = [single] }
        move(ids: ids, toFolder: id)
    }

    /// Move an explicit set of ids. Filing into a folder locks them (store rule).
    func move(ids: Set<UUID>, toFolder id: UUID?) {
        guard !ids.isEmpty else { return }
        if let id = id, folder(id) == nil { return }
        store.moveItems(ids: ids, toFolder: id)
        applyFilters(resetSelection: .preserve)
    }

    /// True while the list is showing a single folder — the only scope where
    /// clips can be hand-sorted.
    var isFolderScope: Bool {
        if case .folder = scope { return true }
        return false
    }

    /// Drag-reorder inside a folder (5C): moves `ids` above or below
    /// `targetID` and persists the folder's new manual order. Returns `false`
    /// (changing nothing) outside folder scope, or when the drag is the target
    /// row itself.
    ///
    /// The new order is computed from `filteredItems`, which is already in the
    /// folder's display order, so what the user sees is exactly what gets
    /// written — including when a search or chip filter is narrowing the list,
    /// where the hidden members keep their relative places via
    /// `ClipboardStore.setFolderOrder`'s untouched-members rule.
    @discardableResult
    func reorderInFolder(_ ids: [UUID], relativeTo targetID: UUID, insertAbove: Bool) -> Bool {
        guard case .folder(let folderID) = scope else { return false }
        let current = filteredItems.map { $0.id }
        let dragged = Set(ids)
        // Preserve the dragged rows' own relative order, whatever order the
        // drag payload happened to list them in.
        let moving = current.filter { dragged.contains($0) }
        guard !moving.isEmpty, !dragged.contains(targetID) else { return false }

        var reordered = current.filter { !dragged.contains($0) }
        guard let anchor = reordered.firstIndex(of: targetID) else { return false }
        reordered.insert(contentsOf: moving, at: insertAbove ? anchor : anchor + 1)

        store.setFolderOrder(reordered, in: folderID)
        applyFilters(resetSelection: .preserve)
        return true
    }

    /// ⌘M (wired by 3E) — opens the folder picker for the current selection.
    func keyMoveToFolder() {
        guard !isEditing else { return }
        requestMoveToFolder(ids: selectedIDs.isEmpty ? Set([selectedID].compactMap { $0 }) : selectedIDs)
    }

    func requestMoveToFolder(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        closeOtherPrompts()
        pendingMoveIDs = ids
        moveFolderQuery = ""
        moveFolderHighlight = 0
        showMoveToFolderPrompt = true
    }

    /// One row of the move picker.
    enum MoveTarget: Identifiable, Equatable {
        case folder(Folder)
        /// "Remove from folder" — sets `folderID` back to nil.
        case none

        var id: String {
            switch self {
            case .folder(let f): return f.id.uuidString
            case .none: return "—none—"
            }
        }

        var title: String {
            switch self {
            case .folder(let f): return f.name
            case .none: return "Remove from Folder"
            }
        }

        var systemImage: String {
            switch self {
            case .folder: return "folder.fill"
            case .none: return "tray.full.fill"
            }
        }
    }

    /// Folders matching the typed filter, plus "Remove from Folder" when at
    /// least one of the pending clips is currently filed somewhere.
    var moveToFolderOptions: [MoveTarget] {
        let query = moveFolderQuery.trimmingCharacters(in: .whitespaces).lowercased()
        var options: [MoveTarget] = store.folders
            .filter { query.isEmpty || $0.name.lowercased().contains(query) }
            .map { .folder($0) }

        let anyFiled = store.items.contains { pendingMoveIDs.contains($0.id) && $0.folderID != nil }
        if anyFiled, query.isEmpty || "remove from folder".contains(query) {
            options.append(.none)
        }
        return options
    }

    /// Highlight index clamped to the current option list.
    var moveFolderClampedHighlight: Int {
        let count = moveToFolderOptions.count
        guard count > 0 else { return 0 }
        return min(max(moveFolderHighlight, 0), count - 1)
    }

    func moveHighlightBy(_ delta: Int) {
        let count = moveToFolderOptions.count
        guard count > 0 else { return }
        let next = moveFolderClampedHighlight + delta
        moveFolderHighlight = min(max(next, 0), count - 1)
    }

    func confirmMoveToFolder() {
        let options = moveToFolderOptions
        guard let target = options[safe: moveFolderClampedHighlight] else { return }
        apply(target)
    }

    func apply(_ target: MoveTarget) {
        let ids = pendingMoveIDs
        cancelMoveToFolder()
        switch target {
        case .folder(let folder): move(ids: ids, toFolder: folder.id)
        case .none: move(ids: ids, toFolder: nil)
        }
    }

    func cancelMoveToFolder() {
        showMoveToFolderPrompt = false
        moveFolderQuery = ""
        moveFolderHighlight = 0
        pendingMoveIDs = []
    }

    // MARK: - Drag and drop

    /// Ids a drag starting on `id` should carry: the whole selection when the
    /// pressed row is part of it, otherwise just that row. Ordered by the list
    /// so the drag image's title is stable.
    func dragIDs(startingAt id: UUID) -> [UUID] {
        guard selectedIDs.contains(id), selectedIDs.count > 1 else { return [id] }
        let ordered = filteredItems.map { $0.id }.filter { selectedIDs.contains($0) }
        return ordered.isEmpty ? [id] : ordered
    }

    /// Re-apply a multi-selection that the mouse-down collapsed, so the rows
    /// being dragged stay highlighted for the length of the drag.
    func restoreSelection(_ ids: [UUID]) {
        guard ids.count > 1 else { return }
        selectedIDs = Set(ids)
        if let first = ids.first(where: { $0 == selectedID }) ?? ids.first {
            selectedID = first
            if let index = filteredItems.firstIndex(where: { $0.id == first }) {
                selectedIndex = index
            }
        }
    }

    /// Handle clips dropped on a sidebar row. Returns false for scopes that do
    /// not accept clips (Favorites, Trash), so AppKit can show the reject
    /// cursor.
    ///
    /// 5E deliberately leaves Trash out: a drop is an easy gesture to make by
    /// accident, and "I dropped my clip somewhere and it disappeared" is worse
    /// than having to use ⌘⌫ or the row menu to delete. `Sidebar` never
    /// registers the row as a drop target, so this is only the second line of
    /// defence.
    @discardableResult
    func handleDrop(ids: [UUID], on scope: Scope) -> Bool {
        guard !ids.isEmpty else { return false }
        switch scope {
        case .all:
            move(ids: Set(ids), toFolder: nil)
            return true
        case .folder(let folderID):
            guard folder(folderID) != nil else { return false }
            move(ids: Set(ids), toFolder: folderID)
            return true
        case .favorites, .trash:
            return false
        }
    }

    /// Sidebar reorder: `dragged` is placed immediately above or below
    /// `target` in the folder list.
    ///
    /// The gap, not the row, is the target. Dropping *onto* a folder — which
    /// is what this used to do — is the gesture that files clips into it, so
    /// reusing it for reordering meant one drag with two meanings and no way
    /// to tell from the screen which you were about to get. Worse, "take the
    /// target's slot" cannot express the two positions people actually reach
    /// for: there was no way to land a folder above the first one or below
    /// the last. An insertion point has both, and the sidebar draws it as a
    /// line in the gap (`SidebarDropTarget`), matching how clips already
    /// reorder inside a folder (`reorderInFolder(_:relativeTo:insertAbove:)`).
    @discardableResult
    func reorderFolder(dragged: UUID, relativeTo target: UUID, insertAbove: Bool) -> Bool {
        guard dragged != target else { return false }
        var order = store.folders.map { $0.id }
        guard order.contains(dragged), let from = order.firstIndex(of: dragged) else { return false }
        order.remove(at: from)
        // The anchor is looked up *after* the removal, so its index already
        // accounts for the dragged folder having left the list — which is what
        // makes "below the last folder" land at the end rather than one short
        // of it when the dragged folder came from above the anchor.
        guard let anchor = order.firstIndex(of: target) else { return false }
        order.insert(dragged, at: insertAbove ? anchor : anchor + 1)
        // A drag that puts the folder back exactly where it started is not
        // worth a write: `reorderFolders` stamps `updatedAt` on everything it
        // renumbers, and a no-op reorder would still push that to iCloud.
        guard order != store.folders.map({ $0.id }) else { return false }
        store.reorderFolders(order)
        return true
    }
}
