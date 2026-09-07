import SwiftUI

/// The two confirmations in the Trash (5E), rendered inside the panel for the
/// same reason every other one is — an `NSAlert` would make this borderless
/// window resign key and close (see `PromptCard`).
///
/// Restoring is not confirmed: it destroys nothing and is undone by deleting
/// the clip again. These two are the only trash actions that lose data.
struct TrashPromptLayer: View {
    @ObservedObject var viewModel: HistoryViewModel

    var body: some View {
        ZStack {
            if viewModel.showPurgePrompt {
                PurgeClipsPrompt(viewModel: viewModel)
            } else if viewModel.showEmptyTrashPrompt {
                EmptyTrashPrompt(viewModel: viewModel)
            }
        }
        .animation(Theme.promptSpring, value: viewModel.showPurgePrompt)
        .animation(Theme.promptSpring, value: viewModel.showEmptyTrashPrompt)
    }
}

/// "Delete N clips permanently?" — the selection only.
struct PurgeClipsPrompt: View {
    @ObservedObject var viewModel: HistoryViewModel

    private var count: Int { viewModel.purgeTargetCount }

    var body: some View {
        PromptCard(width: 320, onDismiss: { viewModel.cancelPurge() }) {
            Label(
                count == 1 ? "Delete this clip?" : "Delete \(count) clips?",
                systemImage: "trash.slash"
            )
            .font(.klip(.sidebarTitle))

            Text("\(count == 1 ? "This clip" : "These clips") and any images or files stored with \(count == 1 ? "it" : "them") are erased for good. This cannot be undone.")
                .font(.klip(.rowSubtitle))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Spacer()
                PromptButton(title: "Cancel") { viewModel.cancelPurge() }
                PromptButton(title: "Delete", isDestructive: true) { viewModel.confirmPurge() }
            }
        }
    }
}

/// "Empty Trash?" — everything in it, whatever the list is currently filtered
/// to. The count comes from the store rather than `filteredItems` on purpose:
/// emptying with a search active still erases the clips the search is hiding,
/// and the card has to say so.
struct EmptyTrashPrompt: View {
    @ObservedObject var viewModel: HistoryViewModel

    private var count: Int { viewModel.trashCount }

    var body: some View {
        PromptCard(width: 320, onDismiss: { viewModel.cancelEmptyTrash() }) {
            Label("Empty Trash?", systemImage: "trash.slash")
                .font(.klip(.sidebarTitle))

            Text("All \(count) \(count == 1 ? "clip" : "clips") in the trash are erased for good, including any the current search or filter is hiding. This cannot be undone.")
                .font(.klip(.rowSubtitle))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Spacer()
                PromptButton(title: "Cancel") { viewModel.cancelEmptyTrash() }
                PromptButton(title: "Empty Trash", isDestructive: true) {
                    viewModel.confirmEmptyTrash()
                }
            }
        }
    }
}
