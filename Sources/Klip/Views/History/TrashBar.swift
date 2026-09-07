import SwiftUI

/// The strip that appears under the chip row in Trash scope (5E): how long
/// clips are kept, the sort picker, and Empty Trash.
///
/// It is a scope-specific bar rather than permanent chrome because everything
/// on it is meaningless anywhere else — there is no "date deleted" for a live
/// clip, and no bulk erase for the history. The search field, the tag filter
/// and the kind chips above it are shared with every other scope and are
/// untouched here, which is the point: the trash is browsed exactly like the
/// history, only ordered by its own rules.
struct TrashBar: View {
    @ObservedObject var viewModel: HistoryViewModel
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        HStack(spacing: 10) {
            sortMenu

            Text(retentionNote)
                .font(.klip(.caption))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            Button(role: .destructive) {
                viewModel.requestEmptyTrash()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "trash.slash")
                    Text("Empty Trash…")
                }
                .font(.klip(.chip))
                .fontWeight(.medium)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background { Capsule().fill(Theme.chipInactive) }
                .foregroundStyle(viewModel.trashCount == 0 ? Color.secondary : Theme.destructive)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.trashCount == 0)
            .klipHelp("Erase every clip in the trash for good")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(TrashSort.allCases, id: \.self) { option in
                Button {
                    viewModel.trashSort = option
                } label: {
                    // A checkmark, not a filled row: `Menu` gives no selected
                    // state of its own, and the label is the only place the
                    // current sort is repeated once the menu is open.
                    Label(
                        option.label,
                        systemImage: option == viewModel.trashSort ? "checkmark" : option.systemImage
                    )
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                Text(viewModel.trashSort.label)
            }
            .font(.klip(.chip))
            .fontWeight(.medium)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background { Capsule().fill(Theme.chipInactive) }
            .foregroundStyle(Color.primary)
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .klipHelp("Sort the trash")
    }

    /// Says what will happen on its own, so the retention setting is visible
    /// where it matters instead of only in Settings > History.
    private var retentionNote: String {
        guard let days = settings.trashRetention.days else {
            return "Kept until you empty the trash"
        }
        return "Erased automatically after \(days) days"
    }
}
