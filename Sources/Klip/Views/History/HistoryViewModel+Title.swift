import AppKit
import SwiftUI

/// Clip titles: the user-given name shown in place of the content preview on
/// a row.
///
/// There are two ways to set one, because there are two kinds of clip. A text
/// clip is named in edit mode, where the title field sits above the body and
/// both commit together (`enterEditMode` / `exitEditMode` in
/// `HistoryViewModel`). An image, a file or an oversized text clip has no
/// editable body at all, so naming also has to work on its own — that is the
/// inline prompt below, reached by F2, the row context menu, or clicking the
/// name in the preview pane.
///
/// The prompt is a `PromptCard`, never an `NSAlert`, for the same reason
/// every other confirmation in this window is: the history panel closes as
/// soon as it resigns key.
extension HistoryViewModel {

    // MARK: - Rename prompt

    /// Open the inline rename prompt for `id`, prefilled with the current
    /// name. Refuses in the trash, where a write would go to `store.items`
    /// and the clip is no longer there — the same guard tags and edit mode use.
    func requestRenameClip(id: UUID) {
        guard !isTrashScope else { return }
        guard let item = store.items.first(where: { $0.id == id }) else { return }
        if isEditing { exitEditMode() }
        showTagInput = false
        renameClipID = item.id
        renameClipText = item.displayTitle ?? ""
        showRenameClipPrompt = true
    }

    /// F2 — renames the focused clip. A no-op with nothing selected, and in
    /// the trash.
    func keyRenameClip() {
        guard !isEditing else { return }
        guard let item = selectedItem else { return }
        requestRenameClip(id: item.id)
    }

    /// Whether the prompt has a clip to write to. An *empty* field is a valid
    /// commit — it is how a name is removed — so this deliberately does not
    /// check the text, unlike `canConfirmRenameFolder` (a folder must always
    /// have a name; a clip need not).
    var canConfirmRenameClip: Bool { renameClipID != nil }

    func confirmRenameClip() {
        guard let id = renameClipID,
              let item = store.items.first(where: { $0.id == id }) else {
            cancelRenameClip()
            return
        }
        let text = renameClipText
        cancelRenameClip()
        store.setTitle(text, for: item)
    }

    func cancelRenameClip() {
        showRenameClipPrompt = false
        renameClipID = nil
        renameClipText = ""
    }

    /// The clip the prompt is renaming, for the card's subtitle line.
    var renameClipTarget: ClipboardItem? {
        guard let id = renameClipID else { return nil }
        return store.items.first(where: { $0.id == id })
    }
}
