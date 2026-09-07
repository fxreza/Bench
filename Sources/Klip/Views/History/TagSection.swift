import SwiftUI

/// Preview-pane footer strip: the selected item's tag chips and the inline
/// "Add tag" input with its suggestion row.
///
/// A live "3 minutes ago" label used to sit at the right of the chip row. It
/// was removed — the exact copy time is already one line below in the pane's
/// own "Copied" metadata row, and the relative label cost a per-second
/// re-render of the whole window for as long as the app was running (see
/// `ClipRow.subtitle`).
///
/// The chips **wrap** (`FlowLayout`) rather than scrolling sideways. They used
/// to sit in a horizontal `ScrollView`, which meant a couple of long tag names
/// pushed each chip's ✕ and the "Add tag" button past the right edge of the
/// pane — so in a narrow preview pane a tag could neither be removed nor added
/// without widening the window first. Wrapping keeps every control reachable at
/// any pane width, and a single tag too long for even one full line truncates
/// (`TagChip.flexible`) so its ✕ always stays inside the pane.
struct TagSection: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var viewModel: HistoryViewModel
    let item: ClipboardItem
    @FocusState.Binding var isTagInputFocused: Bool

    var body: some View {
        let inputSuggestions = viewModel.showTagInput ? viewModel.tagInputSuggestions(excluding: item.tags) : []
        VStack(alignment: .leading, spacing: 5) {
            FlowLayout(spacing: 4, lineSpacing: 4) {
                ForEach(item.tags, id: \.self) { tag in
                    // 5E: a trashed clip's tags are shown but not
                    // editable — the write would go to `store.items`,
                    // where the clip no longer is. Restore it to
                    // change its tags.
                    TagChip(label: tag, flexible: true, onRemove: viewModel.isTrashScope ? nil : {
                        viewModel.removeTag(tag, from: item)
                    })
                }
                if viewModel.isTrashScope {
                    EmptyView()
                } else if viewModel.showTagInput {
                    tagInput
                } else {
                    addTagButton
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !inputSuggestions.isEmpty {
                // Suggestions stay a horizontal scroller on purpose: there can
                // be as many of them as the user has tags, and letting that
                // wrap would push the clip's own content off the pane.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(inputSuggestions, id: \.self) { suggestion in
                            Button(suggestion) {
                                viewModel.applyTagSuggestion(suggestion, to: item)
                            }
                            .buttonStyle(.plain)
                            .font(.klip(.badge))
                            .foregroundStyle(TagChip.color(for: suggestion))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(TagChip.color(for: suggestion).opacity(0.10)))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    /// The inline "type a tag name" field. Sized to wrap as one unit, so it
    /// drops to its own line rather than being clipped when the chips above it
    /// have filled the row.
    private var tagInput: some View {
        HStack(spacing: 6) {
            TextField("tag name", text: $viewModel.tagInputText)
                .textFieldStyle(.plain)
                .font(.klip(.chip))
                .focused($isTagInputFocused)
                .frame(width: 84)
            Button("Cancel") {
                viewModel.cancelTagInput()
            }
            .buttonStyle(.plain)
            .font(.klip(.chip))
            .foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    private var addTagButton: some View {
        Button(action: { viewModel.showTagInput = true }) {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.klip(.badge))
                    .fontWeight(.bold)
                Text("Add tag")
                    .font(.klip(.chip))
                Text(ShortcutManager.shared.displayString(for: .addTag))
                    .font(.klip(.caption))
                    .foregroundStyle(.quaternary)
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}
