import SwiftUI
import AppKit

/// Right-click menu on a clip row (Phase 3D — full rewrite of the Phase 2A
/// version, which only had Copy / Pin / Favorite / Edit / Save Image / Delete).
///
/// Right-clicking a row that isn't part of the current selection selects it
/// first (`ClipList`'s `.contextMenu` calls `viewModel.selectForContextMenu`
/// before building this view); right-clicking inside an existing
/// multi-selection leaves it intact, so bulk actions (Move to Folder, Lock,
/// Delete, Save to Disk) apply to the whole thing. Per-item actions (Edit,
/// Add Tag, Reveal in Finder, Open Link) always target the row that was
/// actually clicked (`item`).
///
/// Key equivalents shown in parentheses come from `ShortcutManager`, so a
/// rebind in Settings > Shortcuts is reflected here too. They are plain text,
/// not real SwiftUI `.keyboardShortcut`s — the actual key handling stays in
/// `GlobalKeyMonitor` so a menu item never double-fires alongside it.
struct RowContextMenu: View {
    @ObservedObject var viewModel: HistoryViewModel
    let item: ClipboardItem

    private var isMultiSelection: Bool { viewModel.selectedItems.count > 1 }

    var body: some View {
        // 5E: in the trash almost nothing on the normal menu applies — a
        // deleted clip cannot be pasted, filed, pinned or tagged, and
        // "Delete" means something else. It gets its own short menu instead
        // of a dozen disabled rows.
        if viewModel.isTrashScope {
            trashMenu
        } else {
            historyMenu
        }
    }

    @ViewBuilder
    private var trashMenu: some View {
        Button(RowMenuLabels.restore(selectionCount: selectionCount)) {
            viewModel.restore(item)
        }

        Divider()

        Button(shortcutLabel("Copy", .copy)) {
            viewModel.copyFromMenu(item, mode: viewModel.defaultPasteMode)
        }

        Divider()

        Button(RowMenuLabels.deletePermanently(selectionCount: selectionCount), role: .destructive) {
            viewModel.requestPurge(ids: viewModel.selectedIDs.isEmpty ? [item.id] : viewModel.selectedIDs)
        }

        Button("Empty Trash…", role: .destructive) {
            viewModel.requestEmptyTrash()
        }
    }

    @ViewBuilder
    private var historyMenu: some View {
        Button(shortcutLabel("Paste", .paste)) {
            viewModel.pasteFromMenu(item, mode: viewModel.defaultPasteMode)
        }
        Button(shortcutLabel(pastePlainTitle, .pastePlain)) {
            viewModel.pasteFromMenu(item, mode: viewModel.alternatePasteMode)
        }

        Button(shortcutLabel("Copy", .copy)) {
            viewModel.copyFromMenu(item, mode: viewModel.defaultPasteMode)
        }
        Button(shortcutLabel(copyPlainTitle, .copyPlain)) {
            viewModel.copyFromMenu(item, mode: viewModel.alternatePasteMode)
        }

        Divider()

        // Naming comes before Edit and is offered on every kind: an image or
        // a file has no editable body but is exactly what a name helps with.
        Button(shortcutLabel(item.displayTitle == nil ? "Name Clip…" : "Rename…", .renameClip)) {
            viewModel.selectSingle(item.id)
            viewModel.requestRenameClip(id: item.id)
        }

        if item.isEditable {
            Button(shortcutLabel("Edit", .edit)) {
                viewModel.selectSingle(item.id)
                viewModel.enterEditMode()
            }
        }

        Button(shortcutLabel(item.isPinned ? "Unpin" : "Pin to Top", .pin)) {
            viewModel.store.togglePin(for: item)
        }

        Button(shortcutLabel(item.isBookmarked ? "Unfavorite" : "Favorite", .star)) {
            viewModel.store.toggleBookmark(for: item)
        }

        Button(shortcutLabel(RowMenuLabels.lock(selectionCount: selectionCount, allLocked: allSelectedLocked), .lock)) {
            viewModel.toggleLockSelection()
        }

        Menu(RowMenuLabels.moveToFolder(selectionCount: selectionCount)) {
            ForEach(viewModel.store.folders) { folder in
                Button(folder.name) {
                    viewModel.moveSelection(toFolder: folder.id)
                }
            }
            if item.folderID != nil {
                if !viewModel.store.folders.isEmpty { Divider() }
                Button("Remove from Folder") {
                    viewModel.moveSelection(toFolder: nil)
                }
            }
        }

        if Features.tagsEnabled {
            Button(shortcutLabel("Add Tag…", .addTag)) {
                viewModel.selectSingle(item.id)
                viewModel.keyAddTag()
            }
        }

        Divider()

        Button(shortcutLabel(RowMenuLabels.saveToDisk(selectionCount: selectionCount), .saveToDisk)) {
            if isMultiSelection {
                viewModel.saveAllSelected()
            } else {
                viewModel.saveSelectedToDisk()
            }
        }

        // Per-item, like Edit and Add Tag: one QR code carries one clip, so
        // it always targets the row that was clicked rather than the whole
        // selection. Disabled — not hidden — on a clip with nothing
        // encodable, matching the preview pane's icon.
        Button(shortcutLabel("Show QR Code", .showQR)) {
            viewModel.selectSingle(item.id)
            viewModel.requestQRCode(id: item.id)
        }
        .disabled(!viewModel.canShowQRCode(for: item))

        if item.type == .file {
            Button("Reveal in Finder") {
                if let url = viewModel.store.fileURLs(for: item).first {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }

        if item.displayKind == .link {
            Button("Open Link") {
                viewModel.openLink(item)
            }
        }

        Divider()

        Button(deleteTitle, role: .destructive) {
            if isMultiSelection {
                viewModel.deleteSelectedItems()
            } else {
                viewModel.delete(item)
            }
        }
        .disabled(!isMultiSelection && item.isLocked)
    }

    /// "Paste as Plain Text" swaps to "Paste with Formatting" once "Always
    /// paste as plain text" makes the default paste plain — the alternate
    /// action still does the opposite of the default, only the label changes.
    private var pastePlainTitle: String {
        viewModel.alternatePasteMode == .rich ? "Paste with Formatting" : "Paste as Plain Text"
    }

    private var copyPlainTitle: String {
        viewModel.alternatePasteMode == .rich ? "Copy with Formatting" : "Copy as Plain Text"
    }

    private var deleteTitle: String {
        guard !isMultiSelection, item.isLocked else {
            return shortcutLabel(RowMenuLabels.delete(selectionCount: selectionCount), .delete)
        }
        return "Delete (Locked)"
    }

    /// How many clips the selection-wide entries below will actually act on.
    private var selectionCount: Int { viewModel.selectedItems.count }

    private var allSelectedLocked: Bool {
        let selection = viewModel.selectedItems
        guard !selection.isEmpty else { return item.isLocked }
        return selection.allSatisfy { $0.isLocked }
    }

    private func shortcutLabel(_ title: String, _ action: ShortcutAction) -> String {
        "\(title) (\(ShortcutManager.shared.displayString(for: action)))"
    }
}

/// Labels for the entries that act on the whole selection (review 5A-30).
///
/// Pin and Favorite are per-item everywhere — the row menu, ⌘P and ⌘F all act on
/// the focused clip only — while Lock, Move to Folder, Save to Disk and
/// Delete act on the entire selection. That difference was invisible:
/// right-clicking inside a ten-row selection offered a plain "Lock" whose
/// label was derived from the clicked row's own state while the action
/// toggled all ten. The selection-wide entries now say how many clips they
/// will touch, and the Lock label is derived from the selection rather than
/// from one row. Behaviour is unchanged.
enum RowMenuLabels {
    static func lock(selectionCount: Int, allLocked: Bool) -> String {
        let verb = allLocked ? "Unlock" : "Lock"
        guard selectionCount > 1 else { return verb }
        return "\(verb) \(selectionCount) Clips"
    }

    static func moveToFolder(selectionCount: Int) -> String {
        selectionCount > 1 ? "Move \(selectionCount) Clips to Folder" : "Move to Folder"
    }

    static func saveToDisk(selectionCount: Int) -> String {
        selectionCount > 1 ? "Save \(selectionCount) Clips to Disk…" : "Save to Disk…"
    }

    static func delete(selectionCount: Int) -> String {
        selectionCount > 1 ? "Delete \(selectionCount) Clips" : "Delete"
    }

    // 5E

    static func restore(selectionCount: Int) -> String {
        selectionCount > 1 ? "Restore \(selectionCount) Clips" : "Restore"
    }

    static func deletePermanently(selectionCount: Int) -> String {
        selectionCount > 1
            ? "Delete \(selectionCount) Clips Permanently…"
            : "Delete Permanently…"
    }
}
