import SwiftUI

/// Inline "Name Clip" card, opened by F2, the row context menu, or clicking a
/// clip's name in the preview pane.
///
/// Deliberately usable on *any* clip, unlike edit mode: an image, a file or an
/// oversized text clip has no editable body but is exactly the kind of thing
/// that benefits from a name. Return commits, Esc cancels through
/// `HistoryViewModel.keyEscape()`'s prompt layer, and an empty field is a
/// valid commit — it removes the name.
struct RenameClipPrompt: View {
    @ObservedObject var viewModel: HistoryViewModel
    @FocusState private var isFieldFocused: Bool

    /// One line of the clip itself, so it is obvious which row is being named
    /// when the prompt covers the list.
    private var subject: String {
        guard let item = viewModel.renameClipTarget else { return "" }
        return item.previewText
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private var hasExistingName: Bool {
        viewModel.renameClipTarget?.displayTitle != nil
    }

    var body: some View {
        PromptCard(width: 320, onDismiss: { viewModel.cancelRenameClip() }) {
            Label(hasExistingName ? "Rename Clip" : "Name Clip", systemImage: "text.cursor")
                .font(.klip(.sidebarTitle))

            if !subject.isEmpty {
                Text(subject)
                    .font(.klip(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            TextField("Clip name", text: $viewModel.renameClipText)
                .textFieldStyle(.plain)
                .font(.klip(.preview))
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                )
                .focused($isFieldFocused)
                .onSubmit { viewModel.confirmRenameClip() }

            Text(hasExistingName
                 ? "Leave it empty to remove the name."
                 : "The name replaces the clip's first line in the list.")
                .font(.klip(.caption))
                .foregroundStyle(.tertiary)

            HStack(spacing: 10) {
                Spacer()
                PromptButton(title: "Cancel", isProminent: false) {
                    viewModel.cancelRenameClip()
                }
                PromptButton(title: "Save", isProminent: true) {
                    viewModel.confirmRenameClip()
                }
                .disabled(!viewModel.canConfirmRenameClip)
            }
        }
        .onAppear {
            DispatchQueue.main.async { isFieldFocused = true }
        }
    }
}
