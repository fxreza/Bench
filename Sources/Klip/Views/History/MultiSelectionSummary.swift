import SwiftUI

/// Preview-pane content shown when more than one item is selected: counts,
/// total size, type breakdown, Download All, first-item preview and the
/// Delete button. The delete confirmation is no longer inline here: it is the
/// `DeleteClipsPrompt` card, shared with ⌘⌫ and the row menu.
///
/// 5E: in Trash scope the two actions at the bottom become Restore All and
/// Delete Permanently; everything above them (the counts, the breakdown, the
/// first-item preview) is the same either way.
struct MultiSelectionSummary: View {
    @ObservedObject var viewModel: HistoryViewModel

    @State private var isDeleteHovered = false

    var body: some View {
        let selectionCount = viewModel.selectionCount
        let selectedItems = viewModel.selectedItems

        VStack(alignment: .leading, spacing: 12) {
            // Count breakdown
            HStack(spacing: 20) {
                statTile("Items", value: "\(selectionCount)")
                statTile("Total Size", value: viewModel.formattedByteCount(viewModel.selectedItemsTotalSize))
                Spacer(minLength: 0)
            }

            Divider()

            // Type breakdown
            let textCount = selectedItems.filter { $0.type == .text }.count
            let imageCount = selectedItems.filter { $0.type == .image }.count
            let fileCount = selectedItems.filter { $0.type == .file }.count
            let lockedCount = selectedItems.filter { $0.isLocked }.count

            VStack(alignment: .leading, spacing: 8) {
                if textCount > 0 {
                    breakdownRow("doc.text", "\(textCount) text \(textCount == 1 ? "item" : "items")")
                }
                if imageCount > 0 {
                    breakdownRow("photo", "\(imageCount) image \(imageCount == 1 ? "item" : "items")")
                }
                if fileCount > 0 {
                    breakdownRow("doc", "\(fileCount) file \(fileCount == 1 ? "item" : "items")")
                }
                if lockedCount > 0 {
                    breakdownRow("lock.fill", "\(lockedCount) locked")
                }
            }

            Divider()

            // 5E: a multi-selection in the trash gets Restore All / Delete
            // Permanently instead of Save All / Delete — saving a deleted
            // clip to disk is a real thing to want, but it is not what
            // someone in the trash is here for, and "Delete" would be
            // ambiguous next to rows that are already deleted.
            if viewModel.isTrashScope {
                trashActions(selectionCount: selectionCount)
            } else {
                historyActions(selectionCount: selectionCount, lockedCount: lockedCount, selectedItems: selectedItems)
            }
        }
    }

    // MARK: - Trash (5E)

    @ViewBuilder
    private func trashActions(selectionCount: Int) -> some View {
        Button(action: { viewModel.restoreSelectionFromTrash() }) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.backward")
                Text("Restore \(selectionCount) Clips")
                Spacer()
            }
            .font(.klip(.preview))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.chipInactive))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        Divider()

        Button(action: { viewModel.requestPurge(ids: viewModel.selectedIDs) }) {
            HStack(spacing: 6) {
                Image(systemName: "trash.slash")
                Text("Delete \(selectionCount) Clips Permanently…")
            }
            .font(.klip(.chip))
            .fontWeight(.medium)
            .foregroundStyle(isDeleteHovered ? Theme.destructive : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isDeleteHovered = $0 }
    }

    // MARK: - History

    @ViewBuilder
    private func historyActions(
        selectionCount: Int,
        lockedCount: Int,
        selectedItems: [ClipboardItem]
    ) -> some View {
        Group {
            // Save All… — images, files and texts together into one chosen
            // folder, with unique names (Phase 3F; replaces the image-only
            // "Download All").
            Button(action: { viewModel.saveAllSelected() }) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.to.line")
                    Text("Save All… (\(selectionCount))")
                    Spacer()
                }
                .font(.klip(.preview))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.chipInactive))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider()

            // First selected item preview (optional)
            if let firstItem = selectedItems.first, firstItem.type == .text {
                VStack(alignment: .leading, spacing: 6) {
                    Text("First item preview")
                        .font(.klip(.caption))
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)

                    let preview = (firstItem.textContent ?? "").prefix(200)
                    Text(String(preview))
                        .font(.klip(.preview))
                        .foregroundStyle(.primary.opacity(0.8))
                        .lineLimit(4)
                        .truncationMode(.tail)
                }
            }

            Divider()

            // Same card as ⌘⌫ and the row menu (`requestDelete`).
            Button(action: { viewModel.deleteSelectedItems() }) {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                    Text("Delete \(selectionCount) Items…")
                }
                .font(.klip(.chip))
                .fontWeight(.medium)
                .foregroundStyle(isDeleteHovered ? Theme.destructive : Color.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isDeleteHovered = hovering
            }
        }
    }

    private func statTile(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.klip(.caption))
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.klip(.preview))
                .fontWeight(.bold)
                .foregroundStyle(.primary)
        }
    }

    private func breakdownRow(_ systemImage: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.klip(.preview))
        }
    }
}
