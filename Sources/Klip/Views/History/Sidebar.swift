// Adapted from Clipfield (MIT, Copyright 2026 Alex Jolley) —
// UI/Overlay/OverlayView.swift `sidebar` / `sidebarRow`.

import SwiftUI

/// Left rail: app title, the fixed **All** / **Favorites** scopes, the user's
/// folders with live counts, the **Trash** (5E, pinned to the bottom above the
/// action), and the "New Folder" action.
///
/// Selection is an accent-gradient capsule moved between rows with
/// `matchedGeometryEffect("sidebarSel")` under `Theme.selectionSpring`.
///
/// Phase 3B makes the rows interactive beyond selection: double-clicking a
/// folder renames it, the context menu renames/deletes/creates, and every row
/// that can hold clips is an AppKit drop target (`SidebarDropTarget`) for rows
/// dragged out of the list — "All" meaning *remove from folder*. Folders are
/// Folders reorder by dragging too, but through SwiftUI rather than AppKit
/// (`folderDrag` below): press a folder, move, and an insertion line shows the
/// gap it will land in — including above the first folder and below the last.
/// See `SidebarDropTarget` for why that half cannot be an AppKit drag source.
struct Sidebar: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var viewModel: HistoryViewModel

    @Namespace private var sidebarNS

    /// Each folder row's frame, in the window's coordinate space, republished
    /// by the rows themselves. `folderDrag` needs it to answer "which gap is
    /// the pointer in?" — a `DragGesture` reports where the pointer is, not
    /// what is under it.
    @State private var folderFrames: [UUID: CGRect] = [:]
    /// The folder currently being dragged, and where it would land. Local
    /// rather than view-model state: it exists only for the length of one
    /// gesture and nothing outside this view reads it.
    @State private var draggingFolderID: UUID?
    @State private var dropTarget: FolderDropTarget?

    /// A gap in the folder list: above or below one row.
    private struct FolderDropTarget: Equatable {
        let folderID: UUID
        let above: Bool
    }

    var body: some View {
        let counts = store.folderCounts()

        VStack(alignment: .leading, spacing: 3) {
            Text("Klip")
                .font(.klip(.sidebarTitle))
                .fontWeight(.bold)
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .padding(.bottom, 6)

            row(title: "All", systemImage: "tray.full.fill", scopeValue: .all, acceptsClips: true)
                .contextMenu { generalMenu }
            row(
                title: "Favorites",
                systemImage: "star.fill",
                scopeValue: .favorites,
                count: viewModel.favoritesCount
            )
            .contextMenu { generalMenu }

            if !store.folders.isEmpty {
                Text("FOLDERS")
                    .font(.klip(.sectionHeader))
                    .fontWeight(.bold)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 2)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(store.folders) { folder in
                        row(
                            title: folder.name,
                            systemImage: "folder.fill",
                            scopeValue: .folder(folder.id),
                            count: counts[folder.id] ?? 0,
                            acceptsClips: true,
                            folder: folder
                        )
                        .contextMenu { folderMenu(folder) }
                    }
                }
                .onPreferenceChange(FolderFramesKey.self) { folderFrames = $0 }
            }

            Spacer(minLength: 0)

            // Trash (5E). Pinned below the folder list, the way every app
            // that has one places it — it is a scope, not a folder, so it
            // sits outside the scrolling folder list and never moves. It
            // takes no drops on purpose; see `handleDrop`.
            row(
                title: "Trash",
                systemImage: "trash",
                scopeValue: .trash,
                count: viewModel.trashCount
            )
            .contextMenu { trashMenu }
            .padding(.top, 6)

            Button(action: { viewModel.keyNewFolder() }) {
                HStack(spacing: 7) {
                    Image(systemName: "plus.circle.fill")
                        .font(.klip(.sidebar))
                    Text("New Folder")
                        .font(.klip(.sidebar))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 18)
            .padding(.bottom, 12)
            .klipHelp("Create a folder (\(ShortcutManager.shared.displayString(for: .newFolder)))")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Rows

    /// One sidebar row.
    ///
    /// Clicks are SwiftUI tap gestures rather than a `Button` so a folder can
    /// carry a second, double-click gesture (rename) without the button style
    /// swallowing it. `SidebarDropTarget` sits in the **background**: it
    /// forwards mouse-down to the responder chain, so the taps and the context
    /// menu above it keep working.
    @ViewBuilder
    private func row(
        title: String,
        systemImage: String,
        scopeValue: Scope,
        count: Int? = nil,
        acceptsClips: Bool = false,
        folder: Folder? = nil
    ) -> some View {
        let active = viewModel.scope == scopeValue
        let targeted = viewModel.dropTargetScope == scopeValue

        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.klip(.chip))
                .frame(width: .klipScaled(16))
            Text(title).lineLimit(1)
            Spacer(minLength: 4)
            if let count, count > 0 {
                Text("\(count)")
                    .font(.klip(.caption))
                    .monospacedDigit()
                    .foregroundStyle(active ? Theme.onAccentSecondary : Color.secondary)
            }
        }
        .font(.klip(.sidebar))
        .fontWeight(active ? .semibold : .regular)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(active ? Color.white : Color.primary)
        .background {
            if active {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.accentGradient)
                    .matchedGeometryEffect(id: "sidebarSel", in: sidebarNS)
            }
        }
        // Drop feedback: an accent-gradient outline plus a faint fill, so the
        // row reads as a target whether or not it is the selected scope.
        .background {
            if targeted {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.accent.opacity(0.18))
            }
        }
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.accentGradient, lineWidth: 2)
            }
        }
        // Reorder feedback, folder rows only: a line in the gap the dragged
        // folder would land in, and the dragged row itself faded so it reads
        // as the thing in flight.
        .overlay(alignment: .top) { insertionLine(folder, above: true) }
        .overlay(alignment: .bottom) { insertionLine(folder, above: false) }
        .opacity(folder != nil && draggingFolderID == folder?.id ? 0.4 : 1)
        .contentShape(Rectangle())
        .background(clipDropTarget(scopeValue: scopeValue, acceptsClips: acceptsClips))
        .background(frameReporter(folder))
        .onTapGesture(count: 2) {
            if let folder = folder {
                viewModel.requestRenameFolder(id: folder.id)
            } else {
                select(scopeValue)
            }
        }
        .onTapGesture(count: 1) { select(scopeValue) }
        // Applied after the taps so a press that never moves is still a
        // click: `minimumDistance` means the drag only wins once the pointer
        // has actually travelled, which is also what stops a sloppy click
        // from shuffling the sidebar.
        .gesture(folderDrag(folder))
        .padding(.horizontal, 8)
        .animation(.easeOut(duration: 0.12), value: targeted)
    }

    // MARK: - Folder reordering (SwiftUI drag)

    /// Publishes this folder row's frame in window coordinates. Window space
    /// rather than a named one so the gesture below can read locations in the
    /// same space without a `coordinateSpace` modifier wrapping the list.
    @ViewBuilder
    private func frameReporter(_ folder: Folder?) -> some View {
        if let folder {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: FolderFramesKey.self,
                    value: [folder.id: proxy.frame(in: .global)]
                )
            }
        }
    }

    /// The 2pt accent line marking where the dragged folder will land.
    @ViewBuilder
    private func insertionLine(_ folder: Folder?, above: Bool) -> some View {
        if let folder,
           let target = dropTarget,
           target.folderID == folder.id,
           target.above == above,
           // Dropping a folder into one of its own gaps moves nothing, so it
           // gets no line: the feedback and `reorderFolder`'s no-op check
           // must agree.
           draggingFolderID != folder.id {
            Capsule()
                .fill(Theme.accent)
                .frame(height: 2)
                .padding(.horizontal, 2)
        }
    }

    /// Press-and-move on a folder row reorders it.
    ///
    /// The gesture reports a pointer location, so the target gap is resolved
    /// against the row frames collected in `folderFrames`: whichever row
    /// contains the pointer, top half meaning "above it" and bottom half
    /// "below it". Past either end of the list the nearest end row is used, so
    /// dragging up beyond the first folder means "make this the first" instead
    /// of quietly doing nothing.
    private func folderDrag(_ folder: Folder?) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                guard let folder else { return }
                draggingFolderID = folder.id
                dropTarget = target(at: value.location)
            }
            .onEnded { value in
                guard let folder else { return }
                let landing = target(at: value.location)
                draggingFolderID = nil
                dropTarget = nil
                guard let landing else { return }
                _ = withAnimation(Theme.selectionSpring) {
                    viewModel.reorderFolder(
                        dragged: folder.id,
                        relativeTo: landing.folderID,
                        insertAbove: landing.above
                    )
                }
            }
    }

    /// Which gap `point` (window coordinates) is in.
    private func target(at point: CGPoint) -> FolderDropTarget? {
        let rows = store.folders.compactMap { folder -> (UUID, CGRect)? in
            guard let frame = folderFrames[folder.id] else { return nil }
            return (folder.id, frame)
        }
        guard let first = rows.first, let last = rows.last else { return nil }

        if let hit = rows.first(where: { $0.1.minY <= point.y && point.y < $0.1.maxY }) {
            return FolderDropTarget(folderID: hit.0, above: point.y < hit.1.midY)
        }
        // Off the ends: pin to the first or last row rather than losing the
        // drop, which is how "move it to the very top / bottom" is reached.
        if point.y < first.1.minY {
            return FolderDropTarget(folderID: first.0, above: true)
        }
        if point.y >= last.1.maxY {
            return FolderDropTarget(folderID: last.0, above: false)
        }
        // Between two rows, in the 3pt gap the VStack leaves: the row above
        // owns it.
        if let above = rows.last(where: { $0.1.maxY <= point.y }) {
            return FolderDropTarget(folderID: above.0, above: false)
        }
        return nil
    }

    private func select(_ scopeValue: Scope) {
        withAnimation(Theme.selectionSpring) { viewModel.scope = scopeValue }
    }

    private func clipDropTarget(scopeValue: Scope, acceptsClips: Bool) -> some View {
        SidebarDropTarget(
            acceptsClips: acceptsClips,
            onDropClips: { ids in
                viewModel.dropTargetScope = nil
                return viewModel.handleDrop(ids: ids, on: scopeValue)
            },
            onTargetChanged: { isTargeted in
                if isTargeted {
                    viewModel.dropTargetScope = scopeValue
                } else if viewModel.dropTargetScope == scopeValue {
                    viewModel.dropTargetScope = nil
                }
            }
        )
    }

    // MARK: - Menus

    /// Shown on the fixed scopes: only the create action makes sense there.
    @ViewBuilder
    private var generalMenu: some View {
        Button("New Folder…") { viewModel.keyNewFolder() }
    }

    /// Trash context menu (5E). Emptying is the only thing that can be done
    /// to the trash as a whole; restoring and erasing individual clips happen
    /// on the rows.
    @ViewBuilder
    private var trashMenu: some View {
        Button("Show Trash") { viewModel.scope = .trash }

        Divider()

        Button("Empty Trash…", role: .destructive) {
            viewModel.requestEmptyTrash()
        }
        .disabled(viewModel.trashCount == 0)
    }

    /// Folder context menu.
    @ViewBuilder
    private func folderMenu(_ folder: Folder) -> some View {
        Button("Rename…") { viewModel.requestRenameFolder(id: folder.id) }

        if !viewModel.selectedIDs.isEmpty {
            Button("Move Selection Here") {
                viewModel.moveSelection(toFolder: folder.id)
            }
        }

        Divider()

        Button("New Folder…") { viewModel.keyNewFolder() }

        Divider()

        Button("Delete Folder…", role: .destructive) {
            viewModel.requestDeleteFolder(id: folder.id)
        }
    }
}

/// Every folder row's frame in window coordinates, merged up from the rows.
///
/// `nonisolated` is required, not stylistic: the build passes
/// `-default-isolation MainActor`, which would otherwise infer `@MainActor`
/// for these static members and leave them unable to satisfy `PreferenceKey`'s
/// nonisolated requirements (same pattern as `KlipTooltipKey`).
private struct FolderFramesKey: PreferenceKey {
    nonisolated static let defaultValue: [UUID: CGRect] = [:]

    nonisolated static func reduce(value: inout [UUID: CGRect],
                                   nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
