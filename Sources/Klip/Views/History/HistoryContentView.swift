import SwiftUI
import AppKit
import BenchCore

/// Root of the history window: sidebar | (search / chips / list + preview /
/// action bar), on an opaque `windowBackgroundColor` card with an 18pt radius
/// and a hairline border — Clipfield's shell.
///
/// All state lives in `HistoryViewModel` (owned by `HistoryWindowController`)
/// except the `@FocusState` flags, which SwiftUI only supports inside a `View`.
/// This view is layout plus the change/notification wiring that drives the view
/// model.
struct HistoryContentView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var viewModel: HistoryViewModel
    @ObservedObject var settings: SettingsManager = .shared
    /// Bench's app-wide light/dark choice; the panel sets its own appearance
    /// because it is a borderless `NSPanel` that never inherits `NSApp`'s.
    @ObservedObject private var appearance: AppearanceSettings = .shared

    @FocusState private var isSearchFocused: Bool
    @FocusState private var isTagInputFocused: Bool
    @FocusState private var isTextEditorFocused: Bool
    /// Edit mode's *title* field. Separate from `isTextEditorFocused` because
    /// edit mode now has two fields, and losing the body editor's focus to
    /// the title field is not the same thing as leaving edit mode — see the
    /// `.onChange` handler that commits the edit.
    @FocusState private var isEditTitleFocused: Bool
    @FocusState private var isFolderFieldFocused: Bool

    /// Commits the edit once focus has genuinely left the editor.
    ///
    /// Edit mode has two fields — the title and the body — and clicking from
    /// one to the other lands as *two* focus changes: the old field goes
    /// false, then the new one goes true. Committing on the first of those
    /// dropped the user out of edit mode the moment they clicked the title
    /// field. Deferring by one run loop lets the hand-off settle, so the edit
    /// only commits when neither field ends up focused.
    private func commitIfEditorLostFocus() {
        guard viewModel.isEditing else { return }
        DispatchQueue.main.async {
            guard viewModel.isEditing else { return }
            guard !isTextEditorFocused, !isEditTitleFocused else { return }
            viewModel.exitEditMode()
        }
    }

    /// The panels' allowed widths, measured from what they have to draw —
    /// see `PaneMetrics`.
    private var sidebarRange: ClosedRange<Double> {
        PaneMetrics.sidebarRange(listFontScale: settings.listFontScale)
    }

    private var previewRange: ClosedRange<Double> {
        PaneMetrics.previewRange(previewFontScale: settings.previewFontScale)
    }

    /// Pull a stored width back inside the current range.
    ///
    /// The minimums used to be smaller, and they move with the font-size
    /// settings, so a width saved under either can be narrower than the panel
    /// is now allowed to be. Without this the panel would keep that width
    /// until the divider was next dragged — which is exactly the state a user
    /// who had already dragged it to the old minimum would open the app in.
    private func clampPaneWidths() {
        let sidebar = sidebarRange
        if settings.sidebarWidth < sidebar.lowerBound || settings.sidebarWidth > sidebar.upperBound {
            settings.sidebarWidth = min(max(settings.sidebarWidth, sidebar.lowerBound), sidebar.upperBound)
        }
        let preview = previewRange
        if settings.previewWidth < preview.lowerBound || settings.previewWidth > preview.upperBound {
            settings.previewWidth = min(max(settings.previewWidth, preview.lowerBound), preview.upperBound)
        }
    }

    /// Reduce Motion turns the open animation into a plain cut.
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// The body is split into a panel plus three modifier groups on purpose:
    /// as one expression the chain of `onChange`/`onReceive` modifiers is too
    /// much for the type-checker (it gave up at the `ZStack`), and the split
    /// also reads as what it is: layout, chrome, focus hand-offs, observers.
    var body: some View {
        observers(focusHandoffs(chrome(panel)))
    }

    private var panel: some View {
        ZStack {
            HStack(spacing: 0) {
                if !settings.sidebarCollapsed {
                    Sidebar(store: store, viewModel: viewModel)
                        .frame(width: settings.sidebarWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    PanelResizer(width: $settings.sidebarWidth, range: sidebarRange, side: .leading)
                }

                // Middle column: search / chips / list / action bar. 180
                // keeps the list usable at the 560pt minimum window width
                // with the sidebar at its 120pt minimum and the preview at
                // its 200pt minimum.
                VStack(spacing: 0) {
                    SearchBar(store: store, viewModel: viewModel, isSearchFocused: $isSearchFocused)

                    if Features.tagsEnabled, viewModel.showTagAutocomplete, !store.allTags.isEmpty {
                        TagAutocompleteBar(store: store, viewModel: viewModel, tags: viewModel.tagSuggestions)
                    }

                    FilterChipBar(viewModel: viewModel)

                    // Task 6B: the Tags chip shows every tag (most-used
                    // first) under the chip row so a tap sets
                    // `activeTagFilter` without needing `#` search. Hidden
                    // while the `#`-mode bar above is already showing its
                    // own (differently ordered) list, so the two never
                    // double up.
                    if Features.tagsEnabled, viewModel.showTagsChipBar {
                        TagAutocompleteBar(store: store, viewModel: viewModel, tags: viewModel.tagsByUsage)
                    }

                    // 5E: sort + retention note + Empty Trash, only in the
                    // trash. Everything above this line is shared with every
                    // other scope.
                    if viewModel.isTrashScope {
                        TrashBar(viewModel: viewModel)
                    }

                    Divider()

                    listPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider()

                    ActionBar(viewModel: viewModel, settings: settings)
                }
                .frame(minWidth: 180, maxWidth: .infinity)
                .overlay(alignment: .bottom) { ToastOverlay(toast: viewModel.toast) }

                // User item 5: the preview is a *panel*, a sibling of the
                // sidebar, so it runs the full height of the window instead
                // of being boxed in between the chip bar and the action bar.
                // `PreviewPane` carries its own 13pt top padding, matching
                // the search bar's, so the columns' first lines line up.
                if settings.showPreviewPane {
                    PanelResizer(width: $settings.previewWidth, range: previewRange, side: .trailing)
                    PreviewPane(
                        store: store,
                        viewModel: viewModel,
                        isTextEditorFocused: $isTextEditorFocused,
                        isEditTitleFocused: $isEditTitleFocused,
                        isTagInputFocused: $isTagInputFocused
                    )
                    .frame(width: settings.previewWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }

            if viewModel.showNewFolderPrompt {
                NewFolderPrompt(viewModel: viewModel, isFieldFocused: $isFolderFieldFocused)
            }

            if viewModel.showRenameClipPrompt {
                RenameClipPrompt(viewModel: viewModel)
            }

            if viewModel.showQRPrompt {
                QRCodePrompt(viewModel: viewModel)
            }

            FolderPromptLayer(viewModel: viewModel)  // 3B: rename / delete / move

            TrashPromptLayer(viewModel: viewModel)   // 5E: purge / empty trash
        }
    }

    /// Size, opaque background, tooltip layer, rounded clip and border, the
    /// open animation, and Bench's accent and colour scheme.
    private func chrome<Content: View>(_ content: Content) -> some View {
        content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Opaque on purpose: `.regularMaterial` let the desktop through, and
        // over a dark wallpaper the text was barely readable. See
        // `Theme.panelBackground` for the light/dark values.
        .background(Theme.panelBackground)
        // Any press nothing else wants drags the window.
        .modifier(WindowDragModifier())
        // The single window-level layer that draws every `.klipHelp` tooltip.
        // AppKit's own tooltips never fire in this borderless non-activating
        // panel — the full explanation is at the top of
        // `Views/Theme/KlipTooltip.swift`.
        //
        // Placed *before* `.clipShape` on purpose, so tooltips are clipped to
        // the rounded window and can never spill onto the desktop. It has to
        // live out here rather than on the individual buttons: the sidebar and
        // the 200-440pt preview pane are `HStack` siblings, so a per-call-site
        // overlay would be painted under the neighbouring column (and, inside
        // `ClipList`'s ScrollView, clipped outright).
        .klipTooltipHost()
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.panelCornerRadius)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .scaleEffect(viewModel.isPresented || reduceMotion ? 1 : 0.96)
        .opacity(viewModel.isPresented || reduceMotion ? 1 : 0)
        .tint(Theme.accent)
        .preferredColorScheme(appearance.colorScheme.swiftUI)
    }

    /// Which text field holds the keyboard as prompts and the editor come
    /// and go.
    private func focusHandoffs<Content: View>(_ content: Content) -> some View {
        content
        .onChange(of: viewModel.showTagInput) { _, newValue in
            if newValue {
                isSearchFocused = false
                isTextEditorFocused = false
                // Defer by one run loop so the TextField is in the hierarchy before focusing
                DispatchQueue.main.async { isTagInputFocused = true }
            } else {
                isTagInputFocused = false
                // Restore search field focus when tag input is dismissed
                isSearchFocused = true
            }
        }
        .onChange(of: viewModel.isEditing) { _, newValue in
            // Focus half of enter/exitEditMode — the state half is in the view model.
            if newValue {
                isSearchFocused = false
                DispatchQueue.main.async { isTextEditorFocused = true }
            } else {
                isTextEditorFocused = false
                isEditTitleFocused = false
                isSearchFocused = true
            }
        }
        .onChange(of: viewModel.showNewFolderPrompt) { _, newValue in
            if newValue {
                isSearchFocused = false
            } else {
                isFolderFieldFocused = false
                isSearchFocused = true
            }
        }
        .onChange(of: viewModel.showRenameClipPrompt) { _, newValue in
            // Same hand-off as every other prompt: the search field lets go
            // of focus while the card is up, and takes it back afterwards.
            if newValue {
                isSearchFocused = false
                isTextEditorFocused = false
                isEditTitleFocused = false
            } else {
                isSearchFocused = true
            }
        }
        .animation(Theme.promptSpring, value: viewModel.showRenameClipPrompt)
        .onChange(of: viewModel.showQRPrompt) { _, newValue in
            // The QR card has no text field of its own, but the search field
            // still has to let go: otherwise a keystroke aimed at the card
            // lands in the query behind it.
            if newValue {
                isSearchFocused = false
                isTextEditorFocused = false
                isEditTitleFocused = false
            } else {
                isSearchFocused = true
            }
        }
        .animation(Theme.promptSpring, value: viewModel.showQRPrompt)
    }

    /// Store, selection, window and font-scale observers, plus the key
    /// monitor that routes shortcuts to the view model.
    private func observers<Content: View>(_ content: Content) -> some View {
        content
        .onChange(of: isTextEditorFocused) { _, _ in commitIfEditorLostFocus() }
        .onChange(of: isEditTitleFocused) { _, _ in commitIfEditorLostFocus() }
        .onChange(of: viewModel.selectedItem?.id) { _, newID in
            // Moving the selection *away from the item being edited* commits the
            // edit. Comparing against `editingItemID` (rather than "is editing at
            // all") lets an action select a row and open the editor in the same
            // turn — the row context menu's Edit does exactly that.
            if viewModel.isEditing && viewModel.editingItemID != newID {
                viewModel.exitEditMode()
            }
            if viewModel.showTagInput {
                viewModel.showTagInput = false
                viewModel.tagInputText = ""
            }
        }
        .onChange(of: store.items) { _, _ in
            viewModel.applyFilters(resetSelection: .preserve)
        }
        // 5E: in trash scope the list is fed by `trashedItems`, so it has to
        // watch that array too — a delete made elsewhere in the app (or a
        // retention purge) changes what the trash shows.
        .onChange(of: store.trashedItems) { _, _ in
            viewModel.applyFilters(resetSelection: .preserve)
        }
        .onChange(of: store.folders) { _, _ in
            viewModel.validateScope()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            if viewModel.isEditing {
                viewModel.exitEditMode()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            if viewModel.isEditing {
                viewModel.exitEditMode()
            }
        }
        .onAppear { clampPaneWidths() }
        .onChange(of: settings.listFontScale) { _, _ in clampPaneWidths() }
        .onChange(of: settings.previewFontScale) { _, _ in clampPaneWidths() }
        .onReceive(NotificationCenter.default.publisher(for: .bufferWindowDidOpen)) { _ in
            clampPaneWidths()
            viewModel.handleWindowDidOpen()
            // Delay needed for NSHostingView to have settled as key window
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isSearchFocused = true
            }
        }
        .onAppear {
            viewModel.applyFilters(resetSelection: .keep)
        }
        .task(id: viewModel.selectedItem?.id) {
            await viewModel.reloadPreview()
        }
        .background(GlobalKeyMonitor(
            viewModel: viewModel,
            onBackspace: { viewModel.keyBackspace(searchFieldHasFocus: isSearchFocused) }
        ))
    }

    @ViewBuilder
    private var listPane: some View {
        if viewModel.filteredItems.isEmpty {
            emptyState
        } else {
            ClipList(store: store, viewModel: viewModel)
        }
    }

    private var emptyState: some View {
        let isFiltered = !viewModel.searchText.isEmpty
            || viewModel.activeTagFilter != nil
            || viewModel.chipFilter != .all
            || viewModel.scope != .all

        // 5E: an empty trash is a normal, good state, not a failed search —
        // saying "No matches" there would read as something having gone
        // wrong. A *filtered* trash still says "No matches", same as anywhere.
        let trashIsEmpty = viewModel.isTrashScope && viewModel.trashIsEmpty

        return VStack(spacing: 10) {
            Image(systemName: emptyStateIcon(isFiltered: isFiltered, trashIsEmpty: trashIsEmpty))
                .font(Theme.icon(34))
                .foregroundStyle(.tertiary)
            Text(emptyStateTitle(isFiltered: isFiltered, trashIsEmpty: trashIsEmpty))
                .font(.klip(.preview))
                .foregroundStyle(.secondary)
            if trashIsEmpty {
                Text("Deleted clips wait here before they are erased.")
                    .font(.klip(.caption))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyStateIcon(isFiltered: Bool, trashIsEmpty: Bool) -> String {
        if trashIsEmpty { return "trash" }
        return isFiltered ? "magnifyingglass" : "doc.on.clipboard"
    }

    private func emptyStateTitle(isFiltered: Bool, trashIsEmpty: Bool) -> String {
        if trashIsEmpty { return "Trash is empty" }
        return isFiltered ? "No matches" : "No clipboard history"
    }
}
