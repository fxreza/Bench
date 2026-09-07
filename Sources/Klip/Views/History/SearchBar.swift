import SwiftUI

/// Top bar: magnifier, active tag chip, the search field, a clear button and
/// the item count.
///
/// Styled like Clipfield's rounded 15pt search field, but deliberately still a
/// SwiftUI `TextField` rather than Clipfield's `NSSearchField` wrapper: Klip's
/// key handling lives in `GlobalKeyMonitor`, and swapping in an
/// `NSViewRepresentable` with its own `doCommandBy` routing would fork that.
/// Debounce, `#tag` mode, the tag pill, the clear X and the count all behave
/// exactly as before.
struct SearchBar: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var viewModel: HistoryViewModel
    @FocusState.Binding var isSearchFocused: Bool

    var body: some View {
        HStack(spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.klip(.sidebar))
                    .foregroundStyle(.secondary)

                if Features.tagsEnabled, let tag = viewModel.activeTagFilter {
                    tagPill(tag)
                }

                TextField(
                    Features.tagsEnabled
                        ? "Search text, tags, apps, files, OCR…"
                        : "Search text, apps, files, OCR…",
                    text: $viewModel.searchText
                )
                .textFieldStyle(.plain)
                .font(.klip(.sidebarTitle))
                .focused($isSearchFocused)

                if !viewModel.searchText.isEmpty {
                    Button(action: { viewModel.searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.klip(.sidebar))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                    .klipHelp("Clear search")
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.rowCornerRadius)
                    .fill(Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.rowCornerRadius)
                    .strokeBorder(Theme.separator, lineWidth: 1)
            )

            Text("\(viewModel.filteredItems.count) items")
                .font(.klip(.caption))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.top, 13)
        .padding(.bottom, 10)
        .animation(.easeOut(duration: 0.12), value: viewModel.searchText.isEmpty)
    }

    private func tagPill(_ tag: String) -> some View {
        HStack(spacing: 3) {
            Text("#\(tag)")
                .font(.klip(.chip))
                .fontWeight(.medium)
                .foregroundStyle(TagChip.color(for: tag))
            Button(action: { viewModel.activeTagFilter = nil }) {
                Image(systemName: "xmark")
                    .font(.klip(.badge))
                    .fontWeight(.bold)
                    .foregroundStyle(TagChip.color(for: tag).opacity(0.6))
            }
            .buttonStyle(.plain)
            .klipHelp("Clear tag filter (\(ShortcutManager.shared.displayString(for: .clearFilter)))")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(TagChip.color(for: tag).opacity(0.12)))
        .overlay(Capsule().strokeBorder(TagChip.color(for: tag).opacity(0.25), lineWidth: 0.5))
        .fixedSize()
    }
}
