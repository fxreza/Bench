import AppKit

/// Handlers for the `ShortcutAction`s that `GlobalKeyMonitor` dispatches to
/// but that belong to other Phase 3 tasks' models (locking, folders) or that
/// are genuinely new (paste/copy-as-plain-text).
///
/// `keyLock()` lives in `Views/History/HistoryViewModel+Lock.swift` (3A);
/// `keyNewFolder()`, `keyRenameFolder()`, `keyMoveToFolder()` live in
/// `Views/History/HistoryViewModel+Folders.swift` (3B). `keyPastePlain()` and
/// `keyCopyPlain()` below replace the 3E stubs with the real Phase 3D
/// implementation.
extension HistoryViewModel {
    // MARK: - Explicit plain-text paste/copy (Phase 3D)

    /// ⌥↩ — pastes in `alternatePasteMode` (the opposite of whatever an
    /// unmarked paste would do right now). Mirrors `keyEnter()`'s
    /// single-vs-multi choice.
    func keyPastePlain() {
        guard !isEditing else { return }
        let mode = alternatePasteMode
        if !selectedItems.isEmpty {
            onPasteMultiple(Array(selectedItems), mode)
        } else if let item = selectedItem {
            onPaste(item, mode)
        }
    }

    /// ⌥⌘C — copies the selected item in `alternatePasteMode`.
    func keyCopyPlain() {
        guard !isEditing else { return }
        guard let item = selectedItem else { return }
        if store.fileIsMissing(item) {
            showToast("Some files are missing from disk")
        }
        onCopyToClipboard(item, alternatePasteMode)
    }

    /// Space (or ⌘Y) — Quick Look on the focused clip.
    ///
    /// Single-selection only: Quick Look's own arrow keys already page through
    /// a multi-file clip, and previewing a whole multi-selection would fight
    /// the panel's navigation for no clear gain.
    func keyQuickLook() {
        guard !isEditing else { return }
        guard let item = selectedItem else { return }
        onQuickLook(item)
    }

}
