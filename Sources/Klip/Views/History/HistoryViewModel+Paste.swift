import AppKit

/// Rich/plain paste-mode plumbing and row-context-menu support (Phase 3D,
/// decision D5).
///
/// The core idea: an unmarked "Copy"/"Paste" always uses `defaultPasteMode`,
/// which honors the "Always paste as plain text" setting. The *explicit*
/// "Paste as Plain Text" / "Copy as Plain Text" action (⌥↩, ⌥⌘C, the row
/// context menu, and the paste-button's split menu) always uses
/// `alternatePasteMode` — the opposite of whatever the default currently is —
/// so flipping the setting never strands you without a way to get the other
/// mode with the same key/menu item; its label just swaps to
/// "... with Formatting".
extension HistoryViewModel {

    /// What an unmarked "Copy"/"Paste" actually does.
    var defaultPasteMode: PasteMode {
        SettingsManager.shared.alwaysPastePlain ? .plain : .rich
    }

    /// What the explicit "Paste/Copy as Plain Text" action does — always the
    /// opposite of `defaultPasteMode`.
    var alternatePasteMode: PasteMode {
        defaultPasteMode == .plain ? .rich : .plain
    }

    // MARK: - Row context menu / split-button entry points

    /// Paste `item` with an explicit mode. Mirrors `keyEnter()`'s choice
    /// between a single paste and a multi-paste: if `item` is part of a
    /// multi-selection, the whole selection pastes together (matching what
    /// ↩ would do), otherwise just `item` pastes.
    func pasteFromMenu(_ item: ClipboardItem, mode: PasteMode) {
        if selectedItems.count > 1, selectedIDs.contains(item.id) {
            onPasteMultiple(selectedItems, mode)
        } else {
            onPaste(item, mode)
        }
    }

    /// Copy `item` with an explicit mode. Copy has no multi-item form, so
    /// this always targets exactly `item`, independent of the wider
    /// selection.
    func copyFromMenu(_ item: ClipboardItem, mode: PasteMode) {
        if store.fileIsMissing(item) {
            showToast("Some files are missing from disk")
        }
        onCopyToClipboard(item, mode)
    }

    /// Right-click prep for `ClipList`'s `.contextMenu`: selects `id` unless
    /// it is already part of the current selection, so right-clicking a row
    /// that is part of an existing multi-selection leaves the whole
    /// selection intact (bulk actions apply to it), while right-clicking an
    /// unselected row selects just that row first.
    func selectForContextMenu(_ id: UUID) {
        guard !selectedIDs.contains(id) else { return }
        selectSingle(id)
    }

    // MARK: - Open Link

    /// Opens a `.link`-kind item's text in the default browser/handler.
    func openLink(_ item: ClipboardItem) {
        let text = (store.fullText(for: item) ?? item.textContent ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme, !scheme.isEmpty else { return }
        NSWorkspace.shared.open(url)
    }
}
