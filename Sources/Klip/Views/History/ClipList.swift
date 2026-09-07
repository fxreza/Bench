import SwiftUI
import AppKit

/// The scrolling list of clips. Replaces `Views/ClipboardListView.swift`.
///
/// **Click semantics are unchanged from Buffer and must stay that way**
/// (Clipfield's single-click-pastes is explicitly not adopted):
/// - single click → select only, via the `ClickModifierDetector` overlay so the
///   ⌘ / ⇧ modifiers are visible;
/// - ⌘-click toggles, ⇧-click extends from the anchor;
/// - double-click → paste, exactly as ↩ does (both go through `keyEnter`).
struct ClipList: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var viewModel: HistoryViewModel

    /// Ids of the rows LazyVStack currently has on screen, maintained by each
    /// row's `onAppear`/`onDisappear` (user item 7).
    ///
    /// Only ever read for the *selected* id, and only to pick a scroll
    /// anchor, so the fact that a LazyVStack keeps a small off-screen margin
    /// alive (making this a slight superset of what is literally visible) is
    /// harmless: the worst case is a minimal nudge instead of a centre-scroll.
    @State private var visibleIDs: Set<UUID> = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 3) {
                    let items = viewModel.filteredItems
                    // 5A-14: `ForEach(Array(items.enumerated()), …)` copied
                    // 10,000 `(Int, ClipboardItem)` tuples on *every* body
                    // pass. `FilterState.apply` guarantees a pinned-first
                    // partition, so the pinned run is a prefix: counting it
                    // costs only the number of pinned items, and the two
                    // things the index was used for (the "is this the first
                    // unpinned row" separator, and the click handlers' index)
                    // are derived from that instead.
                    // 5C: in folder scope the list is in the user's own drag
                    // order, so there is no pinned run at the top to head or
                    // separate — a pinned clip sits wherever it was dropped.
                    // 5E: the trash has its own ordering too (`trashSort`),
                    // and a pinned clip in there is just a deleted clip — no
                    // pinned run, so no "Pinned" header and no separator.
                    let pinnedCount = (viewModel.isFolderScope || viewModel.isTrashScope)
                        ? 0
                        : items.prefix(while: { $0.isPinned }).count
                    let separatorID: UUID? = (pinnedCount > 0 && pinnedCount < items.count)
                        ? items[pinnedCount].id
                        : nil

                    if items.isEmpty, let message = noMatchesMessage {
                        emptyState(message)
                    } else {
                        if pinnedCount > 0 {
                            pinnedHeader
                        }

                        ForEach(items) { item in
                            // Separator between the pinned group and the rest.
                            if item.id == separatorID {
                                Rectangle()
                                    .fill(Theme.separator)
                                    .frame(height: 0.5)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                            }

                            row(item)
                        }
                    }
                }
                .padding(8)
            }
            // User item 7: keyboard navigation sometimes moved the highlight
            // without scrolling. Every one of these paths now goes through
            // `reveal`, which scrolls twice — once synchronously, once on the
            // next run loop, because a selection change that also changes the
            // list contents (a filter or a delete) is not laid out yet when
            // the first call runs and SwiftUI silently drops a `scrollTo` for
            // a row it has not built.
            .onChange(of: viewModel.selectedID) { _, id in
                reveal(id, with: proxy)
            }
            .onChange(of: viewModel.scrollTrigger) { _, trigger in
                // `scrollTrigger` is the "this selection move came from the
                // keyboard / a scope switch" flag. Driving a scroll off it as
                // well as off `selectedID` covers the case where the new
                // selection lands on the id it already had — a scope or chip
                // change that snaps back to the same row.
                guard trigger else { return }
                reveal(viewModel.selectedID, with: proxy)
                viewModel.scrollTrigger = false
            }
            .onChange(of: viewModel.filteredItems.count) { _, _ in
                // The list changed under the selection (search, filter,
                // delete, a new clip arriving). Only re-scroll if the
                // selected row is no longer on screen — otherwise this would
                // yank the list away from wherever the user scrolled it.
                guard let id = viewModel.selectedID, !visibleIDs.contains(id) else { return }
                reveal(id, with: proxy)
            }
            .onReceive(NotificationCenter.default.publisher(for: .bufferWindowDidOpen)) { _ in
                // Bring the restored / default selection into view on reopen.
                let scrollTarget = viewModel.selectedID ?? viewModel.filteredItems.first?.id
                if let id = scrollTarget {
                    proxy.scrollTo(id, anchor: .center)
                    DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    // MARK: - Scroll to selection

    /// Bring `id` into view, now and again on the next run loop.
    ///
    /// A row that is already on screen is only nudged (`anchor: nil` scrolls
    /// the minimum distance, and does nothing at all when the row is fully
    /// visible) so this never fights the user's own scrolling.
    ///
    /// An arrow-key step (`isStepMove`) also uses the minimum distance even
    /// though the new row is by definition off screen: stepping down past the
    /// last visible row should reveal exactly that one row, not centre it and
    /// scroll half a window. Centring is left for the jumps that really are
    /// jumps — a click on an off-screen row, a filter or scope change, a
    /// reopen — where a large scroll is what the user asked for.
    private func reveal(_ id: UUID?, with proxy: ScrollViewProxy) {
        guard let id else { return }
        let minimal = viewModel.isStepMove || visibleIDs.contains(id)
        let anchor: UnitPoint? = minimal ? nil : .center
        let animation: Animation? = viewModel.animateSelection ? Theme.selectionSpring : nil

        withAnimation(animation) { proxy.scrollTo(id, anchor: anchor) }
        DispatchQueue.main.async {
            defer { viewModel.isStepMove = false }
            guard viewModel.selectedID == id else { return }
            withAnimation(animation) { proxy.scrollTo(id, anchor: anchor) }
        }
    }

    // MARK: - Empty state

    /// Help text shown only when a non-empty, non-`#tag` query matches
    /// nothing — a bare empty history or an empty tag/chip result stays
    /// silent, as before.
    private var noMatchesMessage: String? {
        let query = viewModel.debouncedSearchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !query.hasPrefix("#") else { return nil }
        return "No clips match \"\(query)\". Try a tag with #, or a chip filter."
    }

    private func emptyState(_ message: String) -> some View {
        Text(message)
            .font(.klip(.rowSubtitle))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
            .padding(.horizontal, 24)
    }

    // MARK: - Pieces

    private var pinnedHeader: some View {
        HStack(spacing: 4) {
            Image(systemName: "pin.fill")
                .rotationEffect(.degrees(40))
            Text("Pinned")
        }
        .font(.klip(.sectionHeader))
        .fontWeight(.bold)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ item: ClipboardItem) -> some View {
        ClipRow(
            item: item,
            store: store,
            isPrimarySelection: item.id == viewModel.selectedID,
            isMultiSelected: viewModel.selectedIDs.contains(item.id) && item.id != viewModel.selectedID,
            // User item 4: a key-driven selection move applies the highlight
            // with no spring, which is what read as a blink while holding an
            // arrow key. A mouse click still animates.
            animatesSelection: viewModel.animateSelection,
            // Unchanged: tapping a row's tag chip sets the filter and nothing else.
            onTagTap: { tag in viewModel.activeTagFilter = tag }
        )
        .id(item.id)
        .contentShape(Rectangle())
        .onAppear { visibleIDs.insert(item.id) }
        .onDisappear { visibleIDs.remove(item.id) }
        .overlay(
            ClickModifierDetector(
                onClickWithModifiers: { modifiers in
                    viewModel.animateSelection = true
                    viewModel.focusIndex(of: item.id)

                    if modifiers.hasCommand {
                        viewModel.toggleSelection(item.id)
                    } else if modifiers.hasShift {
                        viewModel.extendSelectionTo(item.id)
                    } else {
                        viewModel.selectSingle(item.id)
                    }
                },
                // 3B: evaluated on mouse-down *before* the click above runs, so
                // pressing a row that belongs to a multi-selection still drags
                // the whole selection. Nothing happens until the pointer moves
                // past the drag threshold, so a plain click is unaffected.
                dragPayload: {
                    // 5E: nothing in the trash can be dragged anywhere — the
                    // only drop targets are folders and All, and a trashed
                    // clip has to be restored before it can be filed.
                    guard !viewModel.isTrashScope else { return nil }
                    let ids = viewModel.dragIDs(startingAt: item.id)
                    guard !ids.isEmpty else { return nil }
                    return ClipDragRequest(
                        ids: ids,
                        image: ClipRowDragImage.make(for: item, count: ids.count)
                    )
                },
                onDragBegan: { ids in viewModel.restoreSelection(ids) },
                // 5A-19: the right-click selection happens here, on the
                // mouse-down, not inside the `.contextMenu` ViewBuilder.
                onRightMouseDown: { viewModel.selectForContextMenu(item.id) },
                // 5C: rows only accept a reorder drop inside a folder. In All
                // and Favorites the handler is nil, the view unregisters its
                // dragged types, and a clip drag behaves exactly as before —
                // only the sidebar takes it.
                onReorderDrop: viewModel.isFolderScope
                    ? { ids, edge in
                        viewModel.reorderInFolder(ids, relativeTo: item.id, insertAbove: edge == .above)
                    }
                    : nil
            ),
            alignment: .center
        )
        .simultaneousGesture(
            TapGesture(count: 1)
                .onEnded { _ in
                    // Handled by ClickModifierDetector — kept so the
                    // double-click recogniser has a single-tap sibling.
                }
        )
        .highPriorityGesture(
            TapGesture(count: 2)
                .onEnded { _ in
                    // Double-click is ↩ with the mouse: same action, same
                    // rules, one implementation. It used to copy the clip to
                    // the clipboard and close instead, which meant the two
                    // most obvious ways to "use this clip" did different
                    // things and only one of them put the text where you were
                    // typing.
                    //
                    // `keyEnter` acts on the selection, and the mouse-down
                    // that opened this double-click has already selected this
                    // row (`ClickModifierDetector`), so it is this clip that
                    // gets pasted. Everything else comes along for free:
                    // restore rather than paste in the trash, paste-plain if
                    // that is the default, a multi-selection pasted as one,
                    // and Keep Open leaving the window up afterwards.
                    viewModel.focusIndex(of: item.id)
                    viewModel.keyEnter()
                }
        )
        .contextMenu {
            // Right-clicking a row outside the current selection selects it
            // first; right-clicking inside an existing multi-selection
            // leaves it untouched (Phase 3D) — see
            // `HistoryViewModel.selectForContextMenu`.
            //
            // 5A-19: that selection change used to be made *inside* this
            // ViewBuilder (`let _ = viewModel.selectForContextMenu(...)`),
            // i.e. observable state mutated during a view update — undefined
            // behaviour if SwiftUI ever evaluates the builder outside a
            // right-click. It now happens on the right mouse-down above, so
            // this builder is a pure read.
            RowContextMenu(viewModel: viewModel, item: item)
        }
    }
}
