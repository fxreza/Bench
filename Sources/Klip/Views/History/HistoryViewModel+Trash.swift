import Foundation

/// The Trash scope (5E): browsing, restoring and the two destructive paths.
///
/// The trash was menu-only in 3.3.0 — a submenu under the status item listing
/// the last 25 deletions. That could not be searched, filtered, sorted or
/// multi-selected, and anything past the 25th was simply unreachable. It is a
/// sidebar scope now, so the list, the search field, the tag filter and the
/// kind chips all work on it exactly as they do on the history; the only thing
/// that changes is where the rows come from (`filterSource`), what the actions
/// mean (restore / erase instead of paste / delete) and the ordering, which is
/// `trashSort` rather than pinned-first.
extension HistoryViewModel {

    // MARK: - Scope

    var isTrashScope: Bool { scope == .trash }

    /// The array `applyFilters` filters. The one place the trash and the
    /// history diverge: `ClipboardStore` keeps deleted clips out of `items`
    /// entirely (see `ClipboardStore.trashedItems`), so browsing them is a
    /// matter of handing a different array to the same filter.
    var filterSource: [ClipboardItem] {
        isTrashScope ? store.trashedItems : store.items
    }

    var trashCount: Int { store.trashedItems.count }

    /// Whether the trash is showing nothing *because it is empty*, rather than
    /// because a search or a chip filtered everything out. Drives the empty
    /// state's wording.
    var trashIsEmpty: Bool { store.trashedItems.isEmpty }

    // MARK: - Restore

    /// Put the selected clips back. The selection is what every trash action
    /// works on, so this covers ↩, the row menu, the preview pane's button and
    /// the multi-selection summary alike.
    func restoreSelectionFromTrash() {
        restoreFromTrash(ids: selectedIDs)
    }

    func restore(_ item: ClipboardItem) {
        restoreFromTrash(ids: selectedIDs.contains(item.id) ? selectedIDs : [item.id])
    }

    /// The single restore path.
    ///
    /// The scope deliberately stays on Trash afterwards: recovering clips is
    /// usually done a few at a time, and being thrown back to All after each
    /// one would mean walking back into the trash to get the next. The toast
    /// says where they went instead — which matters, because they no longer
    /// go back to where they were deleted from but to the top of the history
    /// (`ClipboardStore.restoreFromTrash`).
    func restoreFromTrash(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let restored = store.restoreFromTrash(ids: ids)
        guard restored > 0 else { return }
        clearSelection()
        applyFilters(resetSelection: .defaultItem)
        showToast(
            text: restored == 1
                ? "Restored to the top of All"
                : "Restored \(restored) clips to the top of All",
            systemImage: "arrow.uturn.backward"
        )
    }

    // MARK: - Delete permanently

    /// How many clips the purge prompt is about to erase.
    var purgeTargetCount: Int { selectedIDs.count }

    /// Arm the "delete permanently" confirmation for `ids`.
    ///
    /// The ids become the selection first, so the prompt, the highlighted
    /// rows and what `confirmPurge` actually erases can never disagree — the
    /// row menu's target row is already selected by `selectForContextMenu`,
    /// and this makes the preview pane's button and the ⌫ key behave the same.
    func requestPurge(ids: Set<UUID>) {
        let targets = ids.isEmpty ? selectedIDs : ids
        guard !targets.isEmpty else { return }
        if targets != selectedIDs {
            selectedIDs = targets
            let first = filteredItems.first { targets.contains($0.id) }
            selectedID = first?.id
            selectionAnchor = first?.id
        }
        showEmptyTrashPrompt = false
        showPurgePrompt = true
    }

    func confirmPurge() {
        let targets = selectedIDs
        showPurgePrompt = false
        guard !targets.isEmpty else { return }
        let purged = store.purgeFromTrash(ids: targets)
        ImageThumbnailCache.evict(itemIDs: Array(targets))
        clearSelection()
        applyFilters(resetSelection: .defaultItem)
        guard purged > 0 else { return }
        showToast(
            text: purged == 1 ? "1 clip erased for good" : "\(purged) clips erased for good",
            systemImage: "trash.slash"
        )
    }

    func cancelPurge() {
        showPurgePrompt = false
    }

    // MARK: - Empty Trash

    func requestEmptyTrash() {
        guard !store.trashedItems.isEmpty else { return }
        showPurgePrompt = false
        showEmptyTrashPrompt = true
    }

    func confirmEmptyTrash() {
        showEmptyTrashPrompt = false
        let ids = store.trashedItems.map { $0.id }
        let emptied = store.emptyTrash()
        ImageThumbnailCache.evict(itemIDs: ids)
        clearSelection()
        applyFilters(resetSelection: .defaultItem)
        guard emptied > 0 else { return }
        showToast(
            text: emptied == 1 ? "1 clip erased for good" : "\(emptied) clips erased for good",
            systemImage: "trash.slash"
        )
    }

    func cancelEmptyTrash() {
        showEmptyTrashPrompt = false
    }

    // MARK: - Esc

    /// Esc closes a trash confirmation before anything else it might close
    /// (see `dismissTopPrompt`). Returns true when one was dismissed.
    @discardableResult
    func dismissTopTrashPrompt() -> Bool {
        if showPurgePrompt {
            cancelPurge()
            return true
        }
        if showEmptyTrashPrompt {
            cancelEmptyTrash()
            return true
        }
        return false
    }
}
