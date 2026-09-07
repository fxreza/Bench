import SwiftUI

/// Horizontal row of tag suggestions.
///
/// Two call sites in `HistoryContentView` feed different lists via `tags`:
/// typing `#` in search shows `viewModel.tagSuggestions` (prefix-filtered,
/// alphabetical) above the chip row, unchanged from before task 6B. The Tags
/// chip shows `viewModel.tagsByUsage` (most-used first) under the chip row.
/// Both route a tap through `applyTagFilter`, which sets `activeTagFilter`.
struct TagAutocompleteBar: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var viewModel: HistoryViewModel
    let tags: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    Button(action: {
                        viewModel.applyTagFilter(tag)
                    }) {
                        Text("#\(tag)")
                            .font(.klip(.chip))
                            .foregroundStyle(TagChip.color(for: tag))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(TagChip.color(for: tag).opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }
}
