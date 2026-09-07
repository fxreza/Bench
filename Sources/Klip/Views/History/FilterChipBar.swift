// Adapted from Clipfield (MIT, Copyright 2026 Alex Jolley) —
// UI/Overlay/OverlayView.swift `chipBar` / `chip`.

import SwiftUI

/// Capsule chips under the search field: All / Text / Link / Image / File /
/// Color / Code / Email / Phone / Tags.
///
/// The content-kind chips are wired to `ContentKind`. Detection itself is
/// Phase 3C — until it backfills `ClipboardItem.kind`, the Image / File / Text
/// chips still work (they key off the storage type) and the rest correctly
/// show nothing. See `FilterState.matches(_:chip:)`.
///
/// Tags (task 6B) is different: activating it narrows the list to any item
/// carrying at least one tag and shows `TagAutocompleteBar` under this row so
/// the user can click a tag into `activeTagFilter`. It also lights up
/// whenever `activeTagFilter` is set some other way (typing `#tag` in
/// search), even without the chip having been tapped — see
/// `HistoryViewModel.chipIsActive(_:)`.
struct FilterChipBar: View {
    @ObservedObject var viewModel: HistoryViewModel

    @Namespace private var chipNS

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(ChipFilter.bar, id: \.self) { filter in
                    chip(filter)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private func chip(_ filter: ChipFilter) -> some View {
        // Selection semantics (including the Tags-specific "toggle clears
        // both chip and tag filter" rule) live on the view model —
        // `viewModel.tapChip(_:)` / `chipIsActive(_:)` — so they can be unit
        // tested without instantiating SwiftUI (task 6B).
        let active = viewModel.chipIsActive(filter)
        Button {
            withAnimation(Theme.selectionSpring) {
                viewModel.tapChip(filter)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: filter.systemImage)
                Text(filter.label)
            }
            .font(.klip(.chip))
            .fontWeight(.medium)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                if active {
                    // The geometry match is reserved for the chip that is
                    // *actually* `chipFilter` — Tags can read active purely
                    // via `activeTagFilter` while some other chip holds
                    // `chipFilter`, and matching the same id on two chips at
                    // once is undefined.
                    if filter == viewModel.chipFilter {
                        Capsule().fill(Theme.accentGradient)
                            .matchedGeometryEffect(id: "chipSel", in: chipNS)
                    } else {
                        Capsule().fill(Theme.accentGradient)
                    }
                } else {
                    Capsule().fill(Theme.chipInactive)
                }
            }
            .foregroundStyle(active ? Color.white : Color.primary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .klipHelp("Show \(filter.label.lowercased()) items")
    }
}
