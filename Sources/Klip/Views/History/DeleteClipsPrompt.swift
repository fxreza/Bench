import SwiftUI

/// "Delete N clips?" — the one confirmation for deleting a multi-selection in
/// the history, whichever way it was asked for: ⌘⌫, the row context menu or
/// the preview pane's "Delete N Items…" button (`HistoryViewModel.requestDelete`).
///
/// A `PromptCard` inside the panel, like the trash confirmations, because an
/// `NSAlert` would make the borderless window resign key and close. A single
/// clip is never confirmed: it goes to the trash and can be restored.
struct DeletePromptLayer: View {
    @ObservedObject var viewModel: HistoryViewModel

    var body: some View {
        ZStack {
            if viewModel.showDeleteConfirmation {
                DeleteClipsPrompt(viewModel: viewModel)
            }
        }
        .animation(Theme.promptSpring, value: viewModel.showDeleteConfirmation)
    }
}

struct DeleteClipsPrompt: View {
    @ObservedObject var viewModel: HistoryViewModel

    private var count: Int { viewModel.deleteTargetCount }
    private var locked: Int { viewModel.deleteTargetLockedCount }

    private var detail: String {
        var text = "\(count == 1 ? "It moves" : "They move") to the Trash, where you can restore \(count == 1 ? "it" : "them")."
        if locked > 0 {
            text += " \(locked == 1 ? "1 locked clip is" : "\(locked) locked clips are") kept."
        }
        return text
    }

    var body: some View {
        PromptCard(width: 320, onDismiss: { viewModel.cancelDelete() }) {
            Label(count == 1 ? "Delete this clip?" : "Delete \(count) clips?", systemImage: "trash")
                .font(.klip(.sidebarTitle))

            Text(detail)
                .font(.klip(.rowSubtitle))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Spacer()
                PromptButton(title: "Cancel") { viewModel.cancelDelete() }
                PromptButton(title: "Delete", isDestructive: true) { viewModel.confirmDelete() }
            }
        }
    }
}
