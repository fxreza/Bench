import Foundation

/// Lock / protect behaviour (Phase 3A).
///
/// Every delete entry point in `HistoryViewModel` (`deleteSelection`,
/// `delete(_:)`, `deleteSelectedItems`) routes through `performDelete(ids:)`
/// here, so locked items are skipped, kept selected, and reported via
/// `toast` no matter which UI surface triggered the delete: the preview
/// pane's trash button, the multi-selection confirm, the row context menu
/// (3D), or the ⌘⌫ shortcut (`keyDelete` → `deleteSelection`).
extension HistoryViewModel {

    // MARK: - Lock toggling

    /// Toggle lock on the current selection.
    ///
    /// - A single selected item simply flips.
    /// - With multiple items selected: if *any* is unlocked, lock the whole
    ///   selection; otherwise (everything already locked) unlock it all. This
    ///   means one press always moves the whole selection toward a single
    ///   state instead of flipping each item independently.
    func toggleLockSelection() {
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        let shouldLock = targets.contains { !$0.isLocked }
        setLocked(shouldLock, ids: Set(targets.map { $0.id }))
    }

    /// ⌘L (wired by task 3E's `GlobalKeyMonitor`).
    func keyLock() {
        guard !isEditing else { return }
        toggleLockSelection()
    }

    /// Set the lock state on a batch of items via the store.
    func setLocked(_ locked: Bool, ids: Set<UUID>) {
        store.setLocked(ids: ids, locked: locked)
    }

    // MARK: - Delete (single choke point)

    /// The one path every delete entry point funnels through.
    ///
    /// Calls the store, then:
    /// - keeps any locked survivors selected (rather than stranding the
    ///   selection on items that no longer exist), and
    /// - shows a toast when one or more requested items were skipped because
    ///   they were locked.
    @discardableResult
    func performDelete(ids: Set<UUID>) -> ClipboardStore.DeleteResult {
        guard !ids.isEmpty else {
            return ClipboardStore.DeleteResult(deleted: 0, skippedLocked: 0)
        }

        let targets = store.items.filter { ids.contains($0.id) }
        let result = store.delete(targets)

        // 5A-10: a deleted clip's thumbnails go with it. Locked survivors
        // keep theirs — they are still in the list.
        let removed = targets.filter { !$0.isLocked }.map { $0.id }
        ImageThumbnailCache.evict(itemIDs: removed)

        if result.skippedLocked > 0 {
            let survivors = targets.filter { $0.isLocked }.map { $0.id }
            selectedIDs = Set(survivors)
            selectionAnchor = survivors.first
            selectedID = survivors.first
            showLockedSkippedToast(count: result.skippedLocked)
        }

        return result
    }

    // MARK: - Toast

    private func showLockedSkippedToast(count: Int) {
        let text = count == 1
            ? "1 locked clip was not deleted - unlock it first"
            : "\(count) locked clips were not deleted - unlock them first"
        showToast(text: text, systemImage: "lock.fill")
    }

    /// Show `text` as a bottom-of-content toast, auto-clearing after 3s.
    /// Shared by the delete path above and by other 3A surfaces (e.g. a
    /// window-open `ClearHistoryAlert` result, if wired in).
    func showToast(text: String, systemImage: String) {
        toast = ToastMessage(text: text, systemImage: systemImage)

        toastDismissTask?.cancel()
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.toast = nil }
        }
    }
}
