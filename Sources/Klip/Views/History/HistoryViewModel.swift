import AppKit
import SwiftUI

/// All mutable state and behaviour of the history window.
///
/// Before the Phase 1 split this lived as ~35 `@State` properties plus a dozen
/// private helpers inside `HistoryContentView`. It is owned by
/// `HistoryWindowController` so it survives SwiftUI view identity resets, which
/// is why `shouldResetOnOpen` / `savedSelectedID` no longer need `@Binding`
/// plumbing back to the controller.
///
/// Focus is deliberately *not* here: `@FocusState` only works inside a `View`,
/// so `HistoryContentView` owns the three focus flags and reacts to
/// `isEditing` / `showTagInput` changes.
@MainActor
final class HistoryViewModel: ObservableObject {
    let store: ClipboardStore

    // MARK: - Controller callbacks (wired by HistoryWindowController)

    // Phase 3D: every write-back takes an explicit `PasteMode` (rich/plain) —
    // `HistoryWindowController` threads it straight through to
    // `PasteController`. Call sites that don't care about the distinction
    // (multi-select bulk actions, etc.) pass `defaultPasteMode`.
    var onCopyToClipboard: (ClipboardItem, PasteMode) -> Void = { _, _ in }
    var onPaste: (ClipboardItem, PasteMode) -> Void = { _, _ in }
    var onPasteMultiple: ([ClipboardItem], PasteMode) -> Void = { _, _ in }
    var onDismiss: () -> Void = { }
    /// Open the focused clip in the system Quick Look panel (Space / ⌘Y).
    /// Wired by `HistoryWindowController`, which owns the panel Quick Look has
    /// to take key focus from.
    var onQuickLook: (ClipboardItem) -> Void = { _ in }
    /// Write the rendered QR code to disk (the card's "Save PNG…"). Wired by
    /// `HistoryWindowController` for the same reason as `onQuickLook`: the
    /// save panel takes key focus, and the panel has to be told not to close
    /// behind it.
    var onSaveQRCode: (Data, String) -> Void = { _, _ in }

    // MARK: - Controller-owned persistence of search/selection across opens

    /// Set to true by `HistoryWindowController` when the window has been closed for
    /// more than 90 seconds (or on the very first open). Search/tag state is reset
    /// only when this is true; the open handler then writes false back so a second
    /// notification in the same session is a no-op.
    var shouldResetOnOpen: Bool = true
    /// Last selected item UUID, kept in sync with `selectedID` and restored on
    /// reopen within the threshold.
    var savedSelectedID: UUID?

    // MARK: - Search

    /// Whether what is typed in the search field is a `#tag` query rather than
    /// text to look for.
    ///
    /// Always false while tags are hidden (`Features.tagsEnabled`), so `#` is
    /// then just a character like any other: it searches, ↩ still pastes, and
    /// ⇥ does not try to complete a tag name. Without this the leading `#`
    /// kept its old meaning with none of the UI that made it legible — a
    /// query starting with `#` matched nothing and swallowed the paste key.
    var isTagQuery: Bool {
        Features.tagsEnabled && searchText.hasPrefix("#")
    }

    @Published var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            let newValue = searchText
            showTagAutocomplete = Features.tagsEnabled && newValue.hasPrefix("#")

            searchDebounceTask?.cancel()

            if newValue.isEmpty {
                // Instantly update when search text is cleared
                debouncedSearchText = newValue
            } else {
                searchDebounceTask = Task { [weak self] in
                    // 200ms debounce
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    guard !Task.isCancelled else { return }
                    await MainActor.run { self?.debouncedSearchText = newValue }
                }
            }
        }
    }

    @Published var debouncedSearchText = "" {
        didSet {
            guard debouncedSearchText != oldValue else { return }
            // Don't reset selection when in tag autocomplete mode (list is unchanged)
            applyFilters(resetSelection: (Features.tagsEnabled && debouncedSearchText.hasPrefix("#")) ? .keep : .defaultItem)
        }
    }

    private var searchDebounceTask: Task<Void, Never>?

    // MARK: - Filtering

    @Published var activeTagFilter: String? = nil {
        didSet {
            guard activeTagFilter != oldValue else { return }
            // Reset selection to the first item of the new tag filter
            applyFilters(resetSelection: .defaultItem)
        }
    }

    /// Sidebar section (All / Favorites / a folder).
    @Published var scope: Scope = .all {
        didSet {
            guard scope != oldValue else { return }
            applyFilters(resetSelection: .defaultItem)
            scrollTrigger = true
        }
    }

    /// Content-kind chip under the search field.
    @Published var chipFilter: ChipFilter = .all {
        didSet {
            guard chipFilter != oldValue else { return }
            applyFilters(resetSelection: .defaultItem)
            scrollTrigger = true
        }
    }

    /// Trash ordering (5E). Only consulted in `.trash` scope; kept here rather
    /// than in `SettingsManager` on purpose — it is a per-visit way of looking
    /// at the trash, not a preference, and every visit should start on the
    /// deletion date.
    @Published var trashSort: TrashSort = .default {
        didSet {
            guard trashSort != oldValue else { return }
            applyFilters(resetSelection: .defaultItem)
            scrollTrigger = true
        }
    }

    @Published var filteredItems: [ClipboardItem] = []

    var filterState: FilterState {
        FilterState(
            query: debouncedSearchText,
            tag: activeTagFilter,
            scope: scope,
            chip: chipFilter,
            trashSort: trashSort
        )
    }

    // MARK: - Chip row (task 6B)
    //
    // `FilterChipBar`'s tap handler and "is this chip lit up" check both live
    // here rather than inline in the view, so the Tags-specific rules —
    // reading active off `activeTagFilter` too, and a tap on an active Tags
    // chip clearing both `chipFilter` and `activeTagFilter` — are unit
    // testable without instantiating SwiftUI.

    /// Whether `filter` should read as selected in the chip row.
    ///
    /// Every chip but Tags is a straight match against `chipFilter`. Tags
    /// also reads active whenever `activeTagFilter != nil` — typing `#tag` in
    /// search and picking a suggestion lights the chip even though it was
    /// never tapped.
    func chipIsActive(_ filter: ChipFilter) -> Bool {
        if filter == .tagged {
            return chipFilter == .tagged || activeTagFilter != nil
        }
        return chipFilter == filter
    }

    /// Chip-row tap handler.
    ///
    /// - `.all` always resets everything, including a tag filter picked up
    ///   via `#` search.
    /// - `.tagged`: tapping it while already active (whether that's because
    ///   the chip itself is selected or because a `#tag` filter is live)
    ///   clears both `chipFilter` and `activeTagFilter`; tapping it while
    ///   inactive just activates the chip, leaving any specific tag filter
    ///   alone (the tag bar then reads as "all tagged clips").
    /// - Every other chip toggles between itself and `.all`, same as before
    ///   task 6B, and never touches `activeTagFilter`.
    func tapChip(_ filter: ChipFilter) {
        let active = chipIsActive(filter)
        switch filter {
        case .all:
            chipFilter = .all
            activeTagFilter = nil
        case .tagged:
            if active {
                chipFilter = .all
                activeTagFilter = nil
            } else {
                chipFilter = .tagged
            }
        default:
            chipFilter = active ? .all : filter
        }
    }

    /// Whether the Tags chip's tag bar (`TagAutocompleteBar`, sorted by use
    /// count) should show under the chip row. Suppressed while the `#`-mode
    /// bar above the chips is already showing its own (alphabetical,
    /// prefix-filtered) list, so the two never double up.
    ///
    /// False outright while tags are hidden (`Features.tagsEnabled`), so the
    /// answer is the same here as it is on screen — the view gates the bar
    /// too, but a view model that says a bar is showing when no bar can show
    /// is a thing to be caught out by later.
    var showTagsChipBar: Bool {
        Features.tagsEnabled && chipFilter == .tagged && !showTagAutocomplete && !store.allTags.isEmpty
    }

    // MARK: - Inline prompts
    //
    // A system alert would make the borderless panel resign key and close, so
    // every confirmation is an inline `PromptCard` over a scrim instead.

    /// New-folder prompt visibility. Rename/delete prompts arrive in 3B.
    @Published var showNewFolderPrompt = false
    @Published var newFolderName = ""

    /// True while any inline prompt owns the keyboard, so list shortcuts stand
    /// down and Esc dismisses the prompt rather than the window.
    var isPromptShowing: Bool {
        showNewFolderPrompt || isFolderPromptShowing || showRenameClipPrompt || showQRPrompt
    }

    // MARK: - Selection

    @Published var selectedIndex = 0 {
        didSet {
            guard selectedIndex != oldValue else { return }
            selectedID = filteredItems[safe: selectedIndex]?.id
        }
    }
    /// Track selection by ID so it survives list insertions.
    @Published var selectedID: UUID? {
        didSet {
            guard selectedID != oldValue else { return }
            // Keep savedSelectedID in sync so the controller can restore it on next open
            savedSelectedID = selectedID
        }
    }
    @Published var selectedIDs: Set<UUID> = []
    @Published var selectionAnchor: UUID?
    /// Triggers scroll-to-selection in `ClipList` on keyboard navigation / scope changes.
    @Published var scrollTrigger = false

    /// Set by the arrow-key handlers: this selection change is a *one-row*
    /// step, so `ClipList.reveal` scrolls the minimum distance to bring the
    /// new row into view instead of centring it.
    ///
    /// Without it, stepping past the last visible row scrolled half a window
    /// (the row is off screen, and `reveal`'s off-screen branch centres), so
    /// arrowing down the list lurched instead of moving one row at a time.
    /// Not `@Published`: it only ever qualifies the scroll that the
    /// `selectedID` / `scrollTrigger` change already drives, and publishing it
    /// would cost an extra body pass per keypress. `reveal` clears it.
    var isStepMove = false

    /// Whether the *next* selection change should animate (user item 4).
    ///
    /// Mouse clicks keep the spring; key-driven moves turn it off, because
    /// holding an arrow key restarted the spring on every row and read as a
    /// blinking highlight. `ClipList` passes this into `ClipRow` and also
    /// uses it for the scroll animation.
    @Published var animateSelection = true

    // MARK: - Detail pane

    /// Decoded previews by clip id, so returning to a clip costs nothing and
    /// a redraw never re-reads the disk. Bounded rather than unbounded: a
    /// full-size screenshot is not small, and the pane only ever shows one.
    private let previewCache: NSCache<NSUUID, PreviewPayload> = {
        let cache = NSCache<NSUUID, PreviewPayload>()
        cache.countLimit = 24
        return cache
    }()

    @Published var chunkedText = ChunkedTextState()
    @Published var isExtractingText = false
    @Published var showDeleteConfirmation = false

    // MARK: - Trash prompts (5E)
    //
    // Both are confirmations for the two things in the trash that actually
    // destroy something. They are `PromptCard`s rather than `NSAlert`s for the
    // same reason every other confirmation in this window is: an alert makes
    // the borderless panel resign key, which closes it.

    /// "Empty Trash?" — erases every trashed clip.
    @Published var showEmptyTrashPrompt = false
    /// "Delete N clips permanently?" — erases the selection only.
    @Published var showPurgePrompt = false

    // MARK: - Tag input

    @Published var showTagAutocomplete: Bool = false
    @Published var showTagInput: Bool = false
    @Published var tagInputText: String = ""

    // MARK: - Editing

    @Published var isEditing = false
    @Published var editText = ""
    @Published var editingItemID: UUID?

    // MARK: - Presentation

    /// Drives the panel's open animation (scale 0.96 → 1 + fade). Flipped by
    /// `HistoryWindowController` right after the window is ordered in.
    @Published var isPresented = false

    // MARK: - 3E state
    //
    // Custom shortcuts (Phase 3E) need no additional stored state here: the
    // key → action table lives in `ShortcutManager.shared` (observed
    // directly by `ActionBar` and `Views/Settings/ShortcutsTab.swift`), and
    // every dispatch target in `GlobalKeyMonitor`/
    // `HistoryViewModel+Shortcuts.swift` reuses selection/mode state that
    // already exists above (`isEditing`, `showTagInput`, `selectedItem`,
    // `filteredItems`, …). This block is a marker for future 3E-owned state,
    // kept separate from sibling tasks' own `// MARK: - 3x state` blocks.

    // MARK: - Init

    init(store: ClipboardStore) {
        self.store = store
    }

    // MARK: - Derived values

    var tagSuggestions: [String] {
        let query = isTagQuery ? String(searchText.dropFirst()).lowercased() : ""
        if query.isEmpty { return store.allTags }
        return store.allTags.filter { $0.hasPrefix(query) }
    }

    /// Every tag in use, ordered by how many items carry it (most first) and
    /// then by name. Feeds `TagAutocompleteBar` when it is opened from the
    /// Tags chip (task 6B) — unlike `tagSuggestions`, which stays plain
    /// alphabetical for `#` search mode, this surfaces the tags the user
    /// reaches for most.
    var tagsByUsage: [String] {
        var counts: [String: Int] = [:]
        for item in store.items {
            for tag in item.tags { counts[tag, default: 0] += 1 }
        }
        return counts.keys.sorted { a, b in
            let (countA, countB) = (counts[a] ?? 0, counts[b] ?? 0)
            return countA != countB ? countA > countB : a < b
        }
    }

    func tagInputSuggestions(excluding existing: [String]) -> [String] {
        guard !tagInputText.isEmpty else { return [] }
        return store.allTags.filter { $0.hasPrefix(tagInputText.lowercased()) && !existing.contains($0) }
    }

    /// Get the first unpinned item, or the first pinned item if no unpinned items exist
    var defaultSelectedItem: ClipboardItem? {
        return filteredItems.first(where: { !$0.isPinned }) ?? filteredItems.first
    }

    /// Get all selected items in filtered list order
    var selectedItems: [ClipboardItem] {
        filteredItems.filter { selectedIDs.contains($0.id) }
    }

    /// Get the primary selected item (for detail pane when multiple selected or single item)
    /// Returns the first selected item in list order
    var selectedItem: ClipboardItem? {
        selectedItems.first
    }

    /// Selection status for UI display
    var selectionCount: Int {
        selectedIDs.count
    }

    /// Total size of all selected items
    var selectedItemsTotalSize: Int {
        selectedItems.reduce(0) { sum, item in
            sum + (store.itemSize(for: item) ?? 0)
        }
    }

    // MARK: - Filtering + selection reset

    /// How `applyFilters` should re-point the selection after recomputing the list.
    enum SelectionReset {
        /// Leave the selection untouched (first render, and `#…` autocomplete typing).
        case keep
        /// Snap to the first unpinned item (or the first item if all are pinned).
        case defaultItem
        /// Keep the selected UUID if it survived; otherwise take the item now at the
        /// same position, or the last one. Used when the store's items change.
        case preserve
        /// Restore the given UUID if it is still in the list, else `defaultItem`.
        /// The caller passes the value captured *before* any other reset ran, which
        /// is what the pre-split code observed (its `savedSelectedID` write was
        /// deferred to the next SwiftUI update pass).
        case restore(UUID?)
    }

    /// The single recompute-and-reselect path. Replaces the five copy-pasted
    /// blocks that used to live in `HistoryContentView`'s onChange/onReceive
    /// handlers.
    func applyFilters(resetSelection: SelectionReset) {
        // 5E: the trash is a different array, not a filtered view of the
        // history — `ClipboardStore` keeps it that way deliberately so nothing
        // that reads `items` can ever see a deleted clip. Everything after
        // this line (search, tag, chip, selection) is identical either way.
        let currentFiltered = FilterState.apply(filterSource, filterState)
        self.filteredItems = currentFiltered

        // 5A-22: clamp before anything reads `filteredItems[selectedIndex]`.
        // `.keep` and the `.preserve` early-return (`guard let id =
        // selectedID`) both leave the index untouched, so a stale index that
        // outlived its row would turn the next ⇧↑ into an out-of-range crash.
        if selectedIndex >= currentFiltered.count {
            selectedIndex = max(0, currentFiltered.count - 1)
        }

        switch resetSelection {
        case .keep:
            return

        case .defaultItem:
            // Find first unpinned item in filtered results
            let defaultItem = currentFiltered.first(where: { !$0.isPinned }) ?? currentFiltered.first
            point(at: defaultItem?.id, in: currentFiltered)

        case .restore(let saved):
            // • Within threshold + saved UUID still in filtered list → restore it
            // • Otherwise → first unpinned item (or first if all pinned)
            let targetID: UUID?
            if let saved = saved, currentFiltered.contains(where: { $0.id == saved }) {
                targetID = saved
            } else {
                targetID = (currentFiltered.first(where: { !$0.isPinned }) ?? currentFiltered.first)?.id
            }
            point(at: targetID, in: currentFiltered)

        case .preserve:
            // Remove deleted items from selection set
            selectedIDs = selectedIDs.filter { id in
                currentFiltered.contains { $0.id == id }
            }

            // Preserve selection by UUID lookup, adjust index if needed
            guard let id = selectedID else { return }
            if let newIndex = currentFiltered.firstIndex(where: { $0.id == id }) {
                if selectedIndex != newIndex { selectedIndex = newIndex }
            } else {
                // Selected item was deleted — select the item now at the same position (or last)
                let fallbackIndex = min(selectedIndex, currentFiltered.count - 1)
                if let fallbackItem = currentFiltered[safe: fallbackIndex] {
                    selectedID = fallbackItem.id
                    selectedIDs = [fallbackItem.id]
                    selectionAnchor = fallbackItem.id
                    selectedIndex = fallbackIndex
                } else {
                    selectedID = nil
                    selectedIDs = []
                    selectionAnchor = nil
                    selectedIndex = 0
                }
            }
        }
    }

    /// Make `targetID` the one and only selection, syncing index and anchor.
    private func point(at targetID: UUID?, in list: [ClipboardItem]) {
        selectedID = targetID
        if let id = targetID {
            selectedIDs = [id]
            selectionAnchor = id
        } else {
            selectedIDs = []
            selectionAnchor = nil
        }
        // Calculate the correct index
        if let index = list.firstIndex(where: { $0.id == targetID }) {
            selectedIndex = index
        } else {
            selectedIndex = 0
        }
    }

    // MARK: - Selection helpers

    /// Point `selectedIndex` at `id`'s row.
    ///
    /// `ClipList` used to be able to hand the index straight in, because its
    /// `ForEach` enumerated the array; it no longer does (5A-14), and a click
    /// is rare enough that one lookup costs nothing.
    func focusIndex(of id: UUID) {
        guard let index = filteredItems.firstIndex(where: { $0.id == id }) else { return }
        selectedIndex = index
    }

    /// Select a single item (clears previous multi-selection)
    func selectSingle(_ id: UUID) {
        selectedIDs = [id]
        selectionAnchor = id
        selectedID = id  // Explicitly set selectedID
        if let index = filteredItems.firstIndex(where: { $0.id == id }) {
            selectedIndex = index
        }
    }

    /// Toggle an item in multi-select (Cmd+click behavior)
    func toggleSelection(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
        selectionAnchor = id
        if let index = filteredItems.firstIndex(where: { $0.id == id }) {
            selectedIndex = index
            // selectedID is synced by selectedIndex's didSet
        }
    }

    /// Extend selection from anchor to target item (Shift+click behavior)
    func extendSelectionTo(_ targetID: UUID) {
        guard let anchorID = selectionAnchor else {
            selectSingle(targetID)
            return
        }

        guard let anchorIndex = filteredItems.firstIndex(where: { $0.id == anchorID }),
              let targetIndex = filteredItems.firstIndex(where: { $0.id == targetID }) else {
            return
        }

        let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
        selectedIDs = Set(filteredItems[range].map { $0.id })
        selectedIndex = targetIndex
    }

    /// Extend selection upward (Shift+↑ behavior)
    ///
    /// 5A-22: both ends go through `[safe:]`, like `navigateUp`/`navigateDown`
    /// already did — an out-of-range `selectedIndex` returns instead of
    /// trapping.
    func extendSelectionUp() {
        guard selectedIndex > 0 else { return }

        guard let currentItem = filteredItems[safe: selectedIndex] else { return }
        let previousIndex = selectedIndex - 1
        guard let previousItem = filteredItems[safe: previousIndex] else { return }

        if selectedIDs.isEmpty {
            selectSingle(currentItem.id)
            return
        }

        // If moving up, always include the new item
        selectedIDs.insert(previousItem.id)
        selectionAnchor = selectionAnchor ?? currentItem.id

        selectedIndex = previousIndex
    }

    /// Extend selection downward (Shift+↓ behavior)
    func extendSelectionDown() {
        guard selectedIndex < filteredItems.count - 1 else { return }

        guard let currentItem = filteredItems[safe: selectedIndex] else { return }
        let nextIndex = selectedIndex + 1
        guard let nextItem = filteredItems[safe: nextIndex] else { return }

        if selectedIDs.isEmpty {
            selectSingle(currentItem.id)
            return
        }

        // If moving down, always include the new item
        selectedIDs.insert(nextItem.id)
        selectionAnchor = selectionAnchor ?? currentItem.id

        selectedIndex = nextIndex
    }

    /// Clear all selections
    func clearSelection() {
        selectedIDs = []
        selectionAnchor = nil
        selectedID = nil
    }

    func navigateUp() {
        if selectedIndex > 0 {
            selectedIndex -= 1
            // Clear multi-selection when navigating without Shift
            if let item = filteredItems[safe: selectedIndex] {
                selectedID = item.id
                selectedIDs = [item.id]
                selectionAnchor = item.id
            }
        }
    }

    func navigateDown() {
        if selectedIndex < filteredItems.count - 1 {
            selectedIndex += 1
            // Clear multi-selection when navigating without Shift
            if let item = filteredItems[safe: selectedIndex] {
                selectedID = item.id
                selectedIDs = [item.id]
                selectionAnchor = item.id
            }
        }
    }

    // MARK: - Scopes (sidebar)

    /// Every selectable scope in sidebar order: All, Favorites, then folders.
    /// Keyboard scope cycling (⌘[ / ⌘]) was removed in 3.0.1 — the sidebar is
    /// the only way to change scope — but the ordering is still what the
    /// sidebar renders and what `validateScope` falls back through.
    var orderedScopes: [Scope] {
        [.all, .favorites] + store.folders.map { .folder($0.id) } + [.trash]
    }

    var favoritesCount: Int {
        store.items.reduce(0) { $0 + ($1.isBookmarked ? 1 : 0) }
    }

    /// Display name of the current scope, used by the empty state.
    func title(for scope: Scope) -> String {
        switch scope {
        case .all: return "All"
        case .favorites: return "Favorites"
        case .folder(let id): return store.folders.first(where: { $0.id == id })?.name ?? "Folder"
        case .trash: return "Trash"
        }
    }

    /// Drop back to `.all` if the selected folder disappeared (deleted in 3B,
    /// or a stale scope after a store reload).
    func validateScope() {
        if case .folder(let id) = scope, !store.folders.contains(where: { $0.id == id }) {
            scope = .all
        }
    }

    // MARK: - Folders (create; rename/delete/drag are 3B)

    /// Open the inline "New Folder" prompt. A system alert cannot be used here:
    /// it makes the borderless panel resign key, which closes the window.
    func requestNewFolder() {
        newFolderName = ""
        showNewFolderPrompt = true
    }

    /// Create the folder and switch the sidebar to it.
    func confirmNewFolder() {
        let name = newFolderName
        showNewFolderPrompt = false
        newFolderName = ""
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let folder = store.createFolder(name: name)
        scope = .folder(folder.id)
    }

    func cancelNewFolder() {
        showNewFolderPrompt = false
        newFolderName = ""
    }

    /// Esc while a prompt is up closes the top-most prompt only.
    /// Returns true when a prompt was dismissed.
    @discardableResult
    func dismissTopPrompt() -> Bool {
        if dismissTopTrashPrompt() { return true }   // 5E
        if dismissTopFolderPrompt() { return true }  // 3B
        if showQRPrompt {
            cancelQRCode()
            return true
        }
        if showRenameClipPrompt {
            cancelRenameClip()
            return true
        }
        if showNewFolderPrompt {
            cancelNewFolder()
            return true
        }
        return false
    }

    // MARK: - Layout toggles (persisted in SettingsManager)

    func toggleSidebar() {
        SettingsManager.shared.sidebarCollapsed.toggle()
    }

    func togglePreviewPane() {
        SettingsManager.shared.showPreviewPane.toggle()
    }

    /// Keep Open. Toasts because, unlike the sidebar and preview toggles, the
    /// thing that changed is not visible in the layout — only the lit button
    /// in the action bar says so, and the mode's whole effect happens later,
    /// after a paste that would otherwise have closed the window.
    func toggleKeepOpen() {
        let settings = SettingsManager.shared
        settings.keepWindowOpen.toggle()
        showToast(
            text: settings.keepWindowOpen
                ? "Keep Open on - the window stays after a paste"
                : "Keep Open off",
            systemImage: "macwindow"
        )
    }

    // MARK: - Window lifecycle

    /// Runs on `.bufferWindowDidOpen`. Returns nothing; the view still owns the
    /// deferred search-field focus because focus cannot live in an ObservableObject.
    func handleWindowDidOpen() {
        // Captured before the resets below, because those can move the selection
        // (and therefore savedSelectedID) as a side effect.
        let restoreTarget = savedSelectedID

        // The sidebar scope and the top filter chips always go back to All,
        // however briefly the window was away.
        //
        // They used to be part of the `shouldResetOnOpen` block below, so
        // reopening within 90 seconds brought back whatever folder or kind
        // chip was last active. That reads as clips having gone missing:
        // Klip is summoned to grab something that was *just* copied, and it
        // opens showing one folder, or narrowed to Images, with the new clip
        // nowhere in the list. A scope and a chip are a view onto the
        // history, not work in progress — unlike the search query below,
        // which is something the user typed and may well be coming back to.
        //
        // `validateScope()` is not needed here any more: a folder deleted
        // while the window was closed cannot strand the sidebar on an empty
        // scope when the scope is always All by the time it is shown.
        scope = .all
        chipFilter = .all
        activeTagFilter = nil
        trashSort = .default   // 5E: reset with the scope, not separately

        // Only reset persistent search state if the window was closed long enough ago
        // (or this is the first open). shouldResetOnOpen is set by the controller in
        // showWindow(_:) before the notification fires.
        if shouldResetOnOpen {
            searchText = ""
            debouncedSearchText = ""
        } else {
            debouncedSearchText = searchText
        }

        // Transient UI state always resets
        showTagAutocomplete = false
        showTagInput = false
        tagInputText = ""
        isEditing = false
        editTitleText = ""
        cancelRenameClip()
        showNewFolderPrompt = false
        newFolderName = ""
        showDeleteConfirmation = false
        showEmptyTrashPrompt = false   // 5E
        showPurgePrompt = false        // 5E
        resetFolderPrompts()  // 3B

        // Recalculate cache immediately and point at the restored / default item
        applyFilters(resetSelection: shouldResetOnOpen ? .defaultItem : .restore(restoreTarget))

        // Trigger scroll so ClipList brings the selected row into view
        scrollTrigger = true
    }

    // MARK: - Editing

    func enterEditMode() {
        // 5E: a trashed clip is a record, not a live clip — editing it would
        // write through `store.items`, where it no longer is.
        guard !isTrashScope else { return }
        guard let item = selectedItem, item.isEditable else { return }
        editingItemID = item.id
        editText = item.textContent ?? ""
        editTitleText = item.displayTitle ?? ""
        isEditing = true
        showTagInput = false
    }

    func exitEditMode() {
        // Commit edit to the original item (not selectedItem, which may have changed)
        if let itemID = editingItemID,
           let item = store.items.first(where: { $0.id == itemID }) {
            store.updateText(editText, for: item)
            // The clip's byte size is cached with the rest of its preview
            // facts, and editing is the one thing that changes it.
            invalidatePreview(for: itemID)
            // The title field sits above the body in the same editor, so it
            // commits on the same exit. Blank clears the name (see
            // `ClipboardStore.setTitle`).
            store.setTitle(editTitleText, for: item)

            // Phase 3D deliverable 3: editing a rich item keeps plain text
            // only — its RTF/flavors backing is now stale (it describes text
            // that no longer exists) and is dropped along with the files.
            if item.rtfFilename != nil || item.flavorsFilename != nil {
                store.clearRichFlavors(for: item)
            }

            NotificationCenter.default.post(name: .bufferIgnoreNextChange, object: nil)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(editText, forType: .string)
        }
        editingItemID = nil
        editTitleText = ""
        isEditing = false
    }

    func toggleEditMode() {
        if isEditing {
            exitEditMode()
        } else {
            enterEditMode()
        }
    }

    // MARK: - Item actions

    func copySelected() {
        if let item = selectedItem { onCopyToClipboard(item, defaultPasteMode) }
    }

    func copy(_ item: ClipboardItem) {
        if store.fileIsMissing(item) {
            showToast("Some files are missing from disk")
        }
        onCopyToClipboard(item, defaultPasteMode)
    }

    func togglePinOnSelection() {
        guard !isTrashScope else { return }   // 5E
        if let item = selectedItem { store.togglePin(for: item) }
    }

    func toggleBookmarkOnSelection() {
        guard !isTrashScope else { return }   // 5E
        if let item = selectedItem { store.toggleBookmark(for: item) }
    }

    // Delete entry points below all funnel through `performDelete(ids:)`
    // (Views/History/HistoryViewModel+Lock.swift, task 3A) so locked items are
    // skipped consistently, kept selected, and reported via `toast` no matter
    // which UI path triggered the delete.

    // 5E: in trash scope there is nothing left to delete *to* — the same
    // gesture means "erase this for good", which is destructive and therefore
    // always goes through a confirmation (`requestPurge`).

    func deleteSelection() {
        guard let item = selectedItem else { return }
        if isTrashScope {
            requestPurge(ids: selectedIDs.isEmpty ? [item.id] : selectedIDs)
            return
        }
        performDelete(ids: [item.id])
    }

    func delete(_ item: ClipboardItem) {
        if isTrashScope {
            requestPurge(ids: [item.id])
            return
        }
        performDelete(ids: [item.id])
    }

    func deleteSelectedItems() {
        if isTrashScope {
            requestPurge(ids: selectedIDs)
            return
        }
        performDelete(ids: selectedIDs)
    }

    func saveSelectedImage() {
        guard let item = selectedItem, item.type == .image else { return }
        PasteController.saveImageToDisk(for: item, store: store)
    }

    /// Save an arbitrary image item (row context menu). Reads the stored
    /// bytes directly (6C) rather than going through the decoded preview, so
    /// the file written matches the original capture exactly.
    func saveImage(for item: ClipboardItem) {
        guard item.type == .image else { return }
        PasteController.saveImageToDisk(for: item, store: store)
    }

    func extractTextFromSelection() async {
        guard let item = selectedItem, let img = preview(for: item).image else { return }
        isExtractingText = true
        let result = await OCRService.shared.recognizeText(from: img)
        let text = result ?? "No text found in this image."
        store.setOCRText(text, for: item)
        isExtractingText = false
    }

    /// Copy button next to the OCR text under an image preview.
    ///
    /// User item 11: this wrote to `NSPasteboard.general` directly and said
    /// nothing, so there was no way to tell a silent failure from a missed
    /// click on the 12 pt glyph — people gave up and selected the text by
    /// hand. It now goes through `PasteController.copyPlainText` (same
    /// ignore-next-change handshake as every other copy) and confirms with a
    /// toast; `PreviewPane` gives the button a real hit area to go with it.
    ///
    /// `pasteboard` is injectable so the test can assert the write without
    /// clobbering the user's actual clipboard.
    func copyOCRText(_ ocrText: String, to pasteboard: NSPasteboard = .general) {
        guard PasteController.copyPlainText(ocrText, to: pasteboard) else { return }
        showToast(text: "OCR text copied", systemImage: "doc.on.doc")
    }

    // MARK: - Tags

    func addTag(_ tag: String, to item: ClipboardItem) {
        store.addTag(tag, to: item)
    }

    func removeTag(_ tag: String, from item: ClipboardItem) {
        store.removeTag(tag, from: item)
    }

    /// Commit the inline tag input's raw text to `item`.
    func commitTagInput(for item: ClipboardItem?) {
        if let item = item {
            let normalized = TagChip.normalize(tagInputText)
            if !normalized.isEmpty { store.addTag(normalized, to: item) }
        }
        tagInputText = ""
        showTagInput = false
    }

    /// Pick a suggestion from the inline tag input's autocomplete row.
    func applyTagSuggestion(_ suggestion: String, to item: ClipboardItem) {
        store.addTag(suggestion, to: item)
        tagInputText = ""
        showTagInput = false
    }

    func cancelTagInput() {
        tagInputText = ""
        showTagInput = false
    }

    /// Apply a tag as the active list filter (chip tap / autocomplete bar tap).
    func applyTagFilter(_ tag: String) {
        activeTagFilter = tag
        searchText = ""
        showTagAutocomplete = false
    }

    // MARK: - Preview loading

    /// Body of `HistoryContentView`'s `.task(id: selectedItem?.id)`.
    ///
    /// Only the long-text path is left here. The image, its dimensions and the
    /// clip's size used to be loaded here too — cleared to nil first, then
    /// filled back in — and that is what made stepping through image clips
    /// blink.
    ///
    /// `.task(id:)` does not run in the same pass as the selection change; it
    /// is scheduled after it. So each step drew three times: once with the
    /// *previous* clip's image and size still in place under the new clip's
    /// header, once blank after this method cleared them, and once more when
    /// the values arrived. The rows that never blinked — Copied, From, Kind —
    /// were exactly the ones read straight off `item` in the view body, which
    /// change in the same pass as the selection.
    ///
    /// So those three are read straight off the item now too, through
    /// `preview(for:)`. See it for why that is affordable synchronously.
    func reloadPreview() async {
        chunkedText = ChunkedTextState()
        isExtractingText = false
        showTagInput = false
        tagInputText = ""

        guard let item = selectedItem, item.type == .text else { return }
        if item.isFileBacked || (item.textContent?.count ?? 0) > 5000 {
            await loadInitialChunk(for: item)
        } else {
            chunkedText.visibleText = item.textContent ?? ""
            chunkedText.reachedEOF = true
        }
    }

    // MARK: - Synchronous preview facts

    /// The image, pixel dimensions and byte size for a clip, resolved without
    /// suspending and cached so the second look costs nothing.
    ///
    /// **Why this is not async.** Each piece is cheap:
    ///
    /// - `NSImage(contentsOf:)` is lazy — it reads the header and defers the
    ///   pixels until something draws them. The decode happens on the main
    ///   thread at draw time either way, so hoisting the *construction* onto a
    ///   background queue never saved that work; it only guaranteed a frame
    ///   with nothing in it.
    /// - `PixelDimensions.read(contentsOf:)` reads container metadata and
    ///   stops. Its own documentation says it is cheap enough to run on every
    ///   selection change; measuring a decoded `NSImage` instead is the
    ///   expensive way, and this deliberately does not do that.
    /// - `ClipboardStore.itemSize(for:)` is one `stat`, or a count of bytes
    ///   already in memory.
    ///
    /// The cache means the disk is touched once per clip however many times
    /// the pane redraws, so this is safe to call from a view body.
    func preview(for item: ClipboardItem) -> PreviewPayload {
        if let cached = previewCache.object(forKey: item.id as NSUUID) { return cached }

        var image: NSImage?
        var dimensions: PixelDimensions?
        switch item.type {
        case .image:
            image = store.image(for: item)
            if let url = store.imageURL(for: item) {
                dimensions = PixelDimensions.read(contentsOf: url)
            }
        case .file:
            // A Finder copy of a .png/.heic renders as a QuickLook thumbnail
            // and never produces an `NSImage` here, so its dimensions come
            // straight off the file header.
            if let url = store.fileURLs(for: item).first {
                dimensions = PixelDimensions.read(contentsOf: url)
            }
        case .text:
            break
        }

        let payload = PreviewPayload(
            image: image,
            dimensions: dimensions,
            byteSize: store.itemSize(for: item)
        )
        previewCache.setObject(payload, forKey: item.id as NSUUID)
        return payload
    }

    /// Drop a clip's cached facts. Only editing changes any of them — an
    /// image's or a file's bytes are written once at capture and never
    /// rewritten — so this is called when text is committed, where the byte
    /// size really can change.
    func invalidatePreview(for id: UUID) {
        previewCache.removeObject(forKey: id as NSUUID)
    }

    private func loadInitialChunk(for item: ClipboardItem) async {
        chunkedText.isLoadingMore = true // Initial load spinner

        let chunkResult = await Task.detached(priority: .userInitiated) {
            self.store.textChunk(for: item, charCount: ChunkedTextState.initialChars)
        }.value

        if let result = chunkResult {
            chunkedText.visibleText = result.text
            chunkedText.totalBytes = result.totalBytes
            chunkedText.loadedCharCount = result.text.count
            chunkedText.reachedEOF = result.reachedEOF
        }
        chunkedText.isLoadingMore = false
    }

    func loadNextChunk(for item: ClipboardItem) async {
        guard !chunkedText.isLoadingMore && chunkedText.hasMore else { return }

        chunkedText.isLoadingMore = true
        let nextCharCount = chunkedText.loadedCharCount + ChunkedTextState.chunkSize

        let chunkResult = await Task.detached(priority: .userInitiated) {
            self.store.textChunk(for: item, charCount: nextCharCount)
        }.value

        if let result = chunkResult {
            chunkedText.visibleText = result.text
            chunkedText.totalBytes = result.totalBytes
            chunkedText.loadedCharCount = result.text.count
            chunkedText.reachedEOF = result.reachedEOF
        }
        chunkedText.isLoadingMore = false
    }

    // MARK: - Formatting

    func formattedByteCount(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    func formattedSize(bytes: Int) -> String {
        return formattedByteCount(bytes)
    }

    // MARK: - Key handlers (called by GlobalKeyMonitor)

    func keyUp() {
        guard !isEditing else { return }
        animateSelection = false
        scrollTrigger = true
        isStepMove = true
        navigateUp()
    }

    func keyDown() {
        guard !isEditing else { return }
        animateSelection = false
        scrollTrigger = true
        isStepMove = true
        navigateDown()
    }

    func keyExtendUp() {
        guard !isEditing else { return }
        animateSelection = false
        scrollTrigger = true
        isStepMove = true
        extendSelectionUp()
    }

    func keyExtendDown() {
        guard !isEditing else { return }
        animateSelection = false
        scrollTrigger = true
        isStepMove = true
        extendSelectionDown()
    }

    func keyEnter() {
        if isEditing { return }
        // 5E: ↩ is "use this clip". In the trash, using a clip means getting
        // it back — pasting a deleted clip straight into a document, and
        // leaving it deleted, is not a thing anyone means to do.
        if isTrashScope, !showTagInput, !isTagQuery {
            restoreSelectionFromTrash()
            return
        }
        if showTagInput {
            commitTagInput(for: selectedItem)
        } else if isTagQuery {
            let tagQuery = String(searchText.dropFirst()).trimmingCharacters(in: .whitespaces)
            if let match = store.allTags.first(where: { $0 == tagQuery }) ?? store.allTags.first(where: { $0.hasPrefix(tagQuery) }) {
                applyTagFilter(match)
            }
        } else if !selectedItems.isEmpty {
            onPasteMultiple(Array(selectedItems), defaultPasteMode)
        } else if let item = selectedItem {
            onPaste(item, defaultPasteMode)
        }
    }

    /// Esc unwinds one layer at a time: edit mode → tag input → inline prompt →
    /// close the window.
    func keyEscape() {
        if isEditing {
            exitEditMode()
            return
        }
        if showTagInput {
            showTagInput = false
            tagInputText = ""
            return
        }
        if dismissTopPrompt() { return }
        onDismiss()
    }

    func keyDelete() {
        guard !isEditing else { return }
        deleteSelection()
    }

    func keyCopy() {
        guard !isEditing else { return }
        copySelected()
    }

    func keyPin() {
        guard !isEditing else { return }
        togglePinOnSelection()
    }

    func keyBookmark() {
        guard !isEditing else { return }
        toggleBookmarkOnSelection()
    }

    /// ⌘S — "Save to Disk". Generalized in Phase 3F to any selected item
    /// (image/text/file), not just images; the name stays `keySaveImage` so
    /// `GlobalKeyMonitor`'s existing wiring doesn't need to change.
    func keySaveImage() {
        guard !isEditing else { return }
        saveSelectedToDisk()
    }

    func keyAddTag() {
        guard !isEditing else { return }
        guard !isTrashScope else { return }   // 5E: tags are written to `items`
        guard selectedItem != nil else { return }
        showTagInput = true
    }

    func keyEdit() {
        toggleEditMode()
    }

    /// Debug helper (`KLIP_SELECT_FIRST=1`): point the selection at the first
    /// row so screenshots can show the selected state without driving the UI.
    func selectFirstItem() {
        guard let first = filteredItems.first else { return }
        selectSingle(first.id)
    }

    func keyTabComplete() {
        guard !isEditing else { return }
        if showTagInput {
            guard !tagInputText.isEmpty, let item = selectedItem else { return }
            let suggestions = store.allTags.filter {
                $0.hasPrefix(tagInputText.lowercased()) && !item.tags.contains($0)
            }
            guard let first = suggestions.first else { return }
            applyTagSuggestion(first, to: item)
        } else if isTagQuery {
            let tagQuery = String(searchText.dropFirst()).lowercased()
            let suggestions = store.allTags.filter { tagQuery.isEmpty || $0.hasPrefix(tagQuery) }
            guard let first = suggestions.first else { return }
            applyTagFilter(first)
        }
    }

    /// ⌫ with an empty search field clears the active tag filter.
    /// Returns true if the key was consumed. `searchFieldHasFocus` comes from the
    /// view because focus state cannot live here.
    func keyBackspace(searchFieldHasFocus: Bool) -> Bool {
        guard !isEditing else { return false }
        guard searchFieldHasFocus, searchText.isEmpty, activeTagFilter != nil else { return false }
        activeTagFilter = nil
        return true
    }

    // MARK: - 3A state

    /// A transient bottom-of-content message (currently only used for the
    /// "N locked clips were not deleted" notice). Methods live in
    /// `HistoryViewModel+Lock.swift`; rendered by `Views/History/Toast.swift`.
    struct ToastMessage: Equatable {
        let text: String
        let systemImage: String
    }

    @Published var toast: ToastMessage?

    /// Cancelled/replaced whenever a new toast is shown, so an earlier
    /// auto-clear never stomps a newer message.
    var toastDismissTask: Task<Void, Never>?
    // MARK: - 3B state
    //
    // Folder rename / delete / move prompts and drag-and-drop. Behaviour lives
    // in `HistoryViewModel+Folders.swift`; only stored state is here so the file
    // stays mergeable with the other Phase 3 tasks.

    /// Inline rename prompt (double-click a sidebar folder, context menu, ⌘R).
    @Published var showRenameFolderPrompt = false
    @Published var renameFolderID: UUID?
    @Published var renameFolderName = ""

    /// Stages of the inline "Delete Folder" card.
    enum FolderDeleteStage: Equatable {
        /// Move the clips out, or delete them.
        case choice
        /// Locked clips found — typing DELETE is required to include them.
        case lockedConfirm
        /// What happened, after a delete that left locked clips behind.
        case result
    }

    @Published var showDeleteFolderPrompt = false
    @Published var deleteFolderID: UUID?
    @Published var deleteFolderStage: FolderDeleteStage = .choice
    /// Must read exactly `HistoryViewModel.lockedDeleteConfirmationWord`.
    @Published var deleteLockedConfirmText = ""
    /// Outcome line shown in `.result` (e.g. "Deleted 4, kept 2 locked clips…").
    @Published var folderActionMessage: String?

    /// Inline "Move to Folder" picker (⌘M / context menu).
    @Published var showMoveToFolderPrompt = false
    @Published var moveFolderQuery = ""
    /// Index into `moveToFolderOptions`.
    @Published var moveFolderHighlight = 0
    /// Ids the picker will move; captured when it opens so a later selection
    /// change cannot retarget it.
    var pendingMoveIDs: Set<UUID> = []

    /// Sidebar row currently highlighted as a drop target, or nil.
    @Published var dropTargetScope: Scope?

    // MARK: - Clip title state
    //
    // Behaviour lives in `HistoryViewModel+Title.swift`; only stored state is
    // here, matching the 3B block above.

    /// Inline "Rename Clip" prompt (F2, the row context menu, or clicking the
    /// name in the preview pane). Separate from edit mode: an image or a file
    /// has no editable body but can still be named.
    @Published var showRenameClipPrompt = false
    @Published var renameClipID: UUID?
    @Published var renameClipText = ""

    /// The name being edited alongside the body in edit mode. Committed by
    /// `exitEditMode` together with the text.
    @Published var editTitleText = ""

    // MARK: - QR code state
    //
    // Behaviour lives in `Views/History/HistoryViewModel+QRCode.swift`; only
    // stored state is here, matching the blocks above.

    /// "Show QR Code" card visibility (⌘K, the preview pane's icon, or the
    /// row context menu).
    @Published var showQRPrompt = false
    @Published var qrItemID: UUID?
}
