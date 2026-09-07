import Foundation

/// Which sidebar section the list is showing.
///
/// `Hashable` so it can key `matchedGeometryEffect` comparisons and sidebar
/// row identity.
enum Scope: Hashable {
    case all
    case favorites
    case folder(UUID)
    /// The Trash (5E). Unlike every other scope this one does not read
    /// `ClipboardStore.items` at all — `HistoryViewModel.applyFilters` feeds
    /// `trashedItems` in instead — so the trash stays structurally invisible
    /// to the history (see `ClipboardStore.trashedItems`).
    case trash
}

/// How the Trash list is ordered (5E).
///
/// Deletion date first by default: the clip someone came to the trash for is
/// nearly always the one they just lost. The other three exist because the
/// trash is browsed, not scanned — a month of deletions is not something you
/// find by scrolling a timeline.
///
/// Every ordering falls back to the deletion date and then the id, so the
/// result is a strict weak ordering (`sorted` is free to shuffle equal
/// elements otherwise) and two clips that tie on the chosen key still come out
/// newest-deletion-first rather than in whatever order the array held.
enum TrashSort: String, CaseIterable, Hashable {
    case dateDeleted
    case dateAdded
    case name
    case kind

    static let `default`: TrashSort = .dateDeleted

    var label: String {
        switch self {
        case .dateDeleted: return "Date Deleted"
        case .dateAdded:   return "Date Added"
        case .name:        return "Name"
        case .kind:        return "Type"
        }
    }

    var systemImage: String {
        switch self {
        case .dateDeleted: return "clock.arrow.circlepath"
        case .dateAdded:   return "clock"
        case .name:        return "textformat"
        case .kind:        return "square.grid.2x2"
        }
    }

    func order(_ items: [ClipboardItem]) -> [ClipboardItem] {
        items.sorted { a, b in
            switch self {
            case .dateDeleted:
                break
            case .dateAdded:
                if a.timestamp != b.timestamp { return a.timestamp > b.timestamp }
            case .name:
                let (x, y) = (Self.sortName(a), Self.sortName(b))
                if x != y { return x < y }
            case .kind:
                let (x, y) = (a.displayKind.label, b.displayKind.label)
                if x != y { return x < y }
            }
            // Newest deletion first; a record with no deletion date (only
            // possible for a hand-edited trash.json) sorts last rather than
            // first, so it can never push a real deletion off the top.
            switch (a.deletedAt, b.deletedAt) {
            case let (x?, y?):
                if x != y { return x > y }
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            case (nil, nil):
                break
            }
            // Deleting a multi-selection stamps every clip in it with the
            // same instant, so without this the whole batch would fall
            // through to the id — i.e. random order — right at the top of the
            // default sort. Capture date puts the batch back in the order the
            // history had them in.
            if a.timestamp != b.timestamp { return a.timestamp > b.timestamp }
            return a.id.uuidString < b.id.uuidString
        }
    }

    /// The string the **Name** sort compares: the clip's own preview text,
    /// folded the same way search is, so "Éclair" and "eclair" land together
    /// and an image sorts under its "Image" label rather than at random.
    static func sortName(_ item: ClipboardItem) -> String {
        item.previewText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }
}

/// The content-kind filter chosen in the chip row under the search field.
///
/// `.all` is the neutral state. The chips deliberately do not offer
/// `ContentKind.richText`: rich-text capture is Phase 3D, and until then a
/// rich-text clip reads as plain text to the user, so it lives under the
/// **Text** chip (see `FilterState.matches`).
enum ChipFilter: Hashable {
    case all
    case kind(ContentKind)
    /// Task 6B: matches any item carrying at least one tag, regardless of
    /// which one. Combines with `FilterState.tag` (an exact `#tag` match)
    /// the same way every other chip does — see `matches(_:chip:)`.
    case tagged

    /// The chips shown, in bar order.
    ///
    /// `.tagged` is only in the bar while `Features.tagsEnabled` is on. The
    /// case itself stays: `matches(_:chip:)` still implements it, and a
    /// stored or hand-written filter naming it still behaves, so the chip
    /// comes back with the flag and nothing about the filtering had to be
    /// unpicked to take it off the bar.
    static let bar: [ChipFilter] = {
        var chips: [ChipFilter] = [
            .all,
            .kind(.text),
            .kind(.link),
            .kind(.image),
            .kind(.file),
            .kind(.color),
            .kind(.code),
            .kind(.email),
            .kind(.phone),
        ]
        if Features.tagsEnabled { chips.append(.tagged) }
        return chips
    }()

    var label: String {
        switch self {
        case .all: return "All"
        case .kind(let kind): return kind.label
        case .tagged: return "Tags"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .kind(let kind): return kind.systemImage
        case .tagged: return "tag"
        }
    }
}

/// The inputs that decide which clipboard items the history list shows.
///
/// Kept as a plain value type with a pure `apply` so the filtering rules can be
/// unit-tested without a store, a window or SwiftUI (see `Tests/FilterStateTests.swift`).
struct FilterState: Equatable {
    /// Raw search field text (already debounced by the view model).
    var query: String
    /// Active tag chip filter, or nil.
    var tag: String?
    /// Sidebar section.
    var scope: Scope
    /// Content-kind chip.
    var chip: ChipFilter
    /// Trash ordering (5E). Ignored in every other scope.
    var trashSort: TrashSort

    init(
        query: String = "",
        tag: String? = nil,
        scope: Scope = .all,
        chip: ChipFilter = .all,
        trashSort: TrashSort = .default
    ) {
        self.query = query
        self.tag = tag
        self.scope = scope
        self.chip = chip
        self.trashSort = trashSort
    }

    /// Does `item` belong to `scope`?
    ///
    /// Per decision D4, filing a clip into a folder does **not** remove it from
    /// "All" — the history stays a complete timeline.
    static func matches(_ item: ClipboardItem, scope: Scope) -> Bool {
        switch scope {
        case .all:            return true
        case .favorites:      return item.isBookmarked
        case .folder(let id): return item.folderID == id
        // The array handed to `apply` in trash scope *is* the trash, so
        // membership is not a question this can answer — or needs to.
        case .trash:          return true
        }
    }

    /// Does `item` belong under `chip`?
    ///
    /// `kind` is `nil` for every item captured before Phase 3C's detector
    /// existed, so the rules are written to be correct for un-detected items:
    /// - `.all` matches everything.
    /// - **Image** and **File** key off the storage `type`, which is always set.
    /// - **Text** is the catch-all for text items that have not been classified
    ///   as something more specific (`kind == nil`) plus explicit
    ///   `.text` / `.richText`.
    /// - **Tags** (`.tagged`, task 6B) matches any item carrying at least one
    ///   tag — it does not care which one; picking a specific tag is
    ///   `FilterState.tag`, applied separately in `apply(_:_:)`.
    /// - Every other chip requires an exact `kind` match, so it shows nothing
    ///   until detection backfills.
    static func matches(_ item: ClipboardItem, chip: ChipFilter) -> Bool {
        switch chip {
        case .all:
            return true
        case .kind(.image):
            return item.type == .image
        case .kind(.file):
            return item.isFile
        case .kind(.text):
            return item.type == .text && (item.kind == nil || item.kind == .text || item.kind == .richText)
        case .kind(let kind):
            return item.kind == kind
        case .tagged:
            return !item.tags.isEmpty
        }
    }

    /// Case- and diacritic-folded search blob for one item, built once per
    /// filter pass (never per query word). Pulls in every field the query is
    /// allowed to match: `textContent` (the 500-char preview for large,
    /// file-backed text — never the full file, per `ClipboardStore.fullText`'s
    /// doc comment: filtering must not read files), `ocrText`, tag names,
    /// `sourceApp`, and file names (`fileAttachment.originalName` plus
    /// `additionalNames`). Link/email/phone/code items already store their
    /// text in `textContent`, so they need no extra field. A clip's title
    /// joins the blob too, so `⌘F` finds a named clip by its name.
    ///
    /// An image with no OCR text contributes only its (possibly empty) tags
    /// and source app here, matching the old all-or-nothing behaviour for the
    /// common case: no tag, no matching source app, no match.
    static func searchBlob(for item: ClipboardItem) -> String {
        if let cached = blobCache[item.id], cached.stamp == item.updatedAt {
            return cached.blob
        }
        let blob = buildSearchBlob(for: item)
        cache(blob, for: item)
        return blob
    }

    // MARK: - Blob cache (5A-15)
    //
    // The blob above used to be rebuilt — and `.folding(...)`ed, which
    // allocates a fresh String per item — on *every* keystroke: measured at
    // 35.6 ms for a no-match query over 10,000 items, 112 ms to type
    // "project". Nothing about an item's blob changes unless the item does,
    // and every store mutation stamps `updatedAt` (`ClipboardStore.touchItem`),
    // so `(id, updatedAt)` is an exact cache key.
    //
    // Two bounds keep this from becoming a memory problem in its own right:
    // a byte budget (a folded copy of every inline clip could otherwise be up
    // to `inlineTextLimit` × the whole history), and a sweep that drops
    // entries for items that are no longer in the list.

    private struct CachedBlob {
        let stamp: Date
        let blob: String
    }

    private static var blobCache: [UUID: CachedBlob] = [:]
    private static var blobCacheBytes = 0

    /// Roughly 16 MB of folded text. Beyond this, misses are simply not
    /// cached (the newest items — the ones actually on screen — get there
    /// first, so the tail pays the old cost rather than everything thrashing).
    private static let blobCacheByteBudget = 16 * 1024 * 1024

    private static func cache(_ blob: String, for item: ClipboardItem) {
        if let existing = blobCache[item.id] {
            blobCacheBytes -= existing.blob.utf8.count
            blobCache[item.id] = nil
        }
        let size = blob.utf8.count
        guard blobCacheBytes + size <= blobCacheByteBudget else { return }
        blobCache[item.id] = CachedBlob(stamp: item.updatedAt, blob: blob)
        blobCacheBytes += size
    }

    /// Drops cache entries for items that are gone (deleted, evicted, merged
    /// away). Cheap and rare: only runs once the cache has drifted well past
    /// the size of the list it is caching.
    private static func sweepBlobCache(keeping items: [ClipboardItem]) {
        guard blobCache.count > items.count + 512 else { return }
        let live = Set(items.map { $0.id })
        for (id, entry) in blobCache where !live.contains(id) {
            blobCacheBytes -= entry.blob.utf8.count
            blobCache[id] = nil
        }
    }

    /// Test/measurement hook: forget everything, so a cold pass can be timed.
    static func resetSearchBlobCache() {
        blobCache.removeAll()
        blobCacheBytes = 0
    }

    private static func buildSearchBlob(for item: ClipboardItem) -> String {
        var parts: [String] = []
        // The clip's own name first: a named clip is nearly always looked up
        // by that name. Content still matches too — naming a clip never makes
        // the text inside it unsearchable.
        if let title = item.displayTitle { parts.append(title) }
        if let text = item.textContent { parts.append(text) }
        if let ocr = item.ocrText { parts.append(ocr) }
        if !item.tags.isEmpty { parts.append(item.tags.joined(separator: " ")) }
        if let sourceApp = item.sourceApp { parts.append(sourceApp) }
        if let attachment = item.fileAttachment {
            parts.append(attachment.originalName)
            if !attachment.additionalNames.isEmpty {
                parts.append(attachment.additionalNames.joined(separator: " "))
            }
        }
        return parts.joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    /// Filter + order `items` for display.
    ///
    /// Rules:
    /// 1. Scope (sidebar section) narrows first.
    /// 2. If a tag filter is active, keep only items carrying that tag.
    /// 3. The content-kind chip narrows next (see `matches(_:chip:)`).
    /// 4. A non-empty query that does not start with `#` matches items whose
    ///    title, text content, OCR text, tag names, source app, or file name(s)
    ///    contain every word of the query, case- and diacritic-insensitively
    ///    (see `searchBlob(for:)`). Multi-word queries are AND'd across all of
    ///    those fields combined, not per-field. An image with none of those
    ///    fields set (no OCR text, no tags, no matching source app) still
    ///    matches nothing, as before. A `#…` query is tag-autocomplete mode
    ///    and does not narrow the list at all.
    /// 5. Pinned items float to the top — except in folder scope, where the
    ///    manual drag order from `folderSortIndex` replaces this step entirely,
    ///    and in trash scope (5E), where `trashSort` does.
    ///
    /// In trash scope the caller passes `ClipboardStore.trashedItems` rather
    /// than `items`; steps 2-4 are identical, which is the whole point — the
    /// trash is searched, tag-filtered and chip-filtered exactly like the
    /// history.
    ///
    /// The pinned-first step is a **stable partition**: pinned items keep their
    /// relative order and so do the rest. (The original used
    /// `sorted { $0.isPinned && !$1.isPinned }`, which is not a strict weak
    /// ordering and let `sort` shuffle equal elements arbitrarily.)
    ///
    /// No relevance ranking is applied anywhere here, intentionally: the list
    /// stays in chronological (pinned-first) order no matter which fields a
    /// query happened to match, so the user's muscle memory for row position
    /// keeps working.
    static func apply(_ items: [ClipboardItem], _ f: FilterState) -> [ClipboardItem] {
        sweepBlobCache(keeping: items)
        var base = items
        // `.trash` is skipped along with `.all`: the caller already handed in
        // the trash, so the filter would keep every element at the cost of a
        // full copy on every keystroke.
        if f.scope != .all, f.scope != .trash {
            base = base.filter { matches($0, scope: f.scope) }
        }
        if let tag = f.tag {
            base = base.filter { $0.tags.contains(tag) }
        }
        if f.chip != .all {
            base = base.filter { matches($0, chip: f.chip) }
        }
        let query = f.query.trimmingCharacters(in: .whitespaces)
        // A leading `#` means "this is a tag query, the tag filter handles it"
        // — but only while there is a tag UI. With tags hidden it is an
        // ordinary character and has to be searched for, or typing `#` would
        // silently empty the list.
        if !query.isEmpty && !(Features.tagsEnabled && query.hasPrefix("#")) {
            let words = query
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                .split(separator: " ")
                .map(String.init)
            base = base.filter { item in
                let blob = searchBlob(for: item)
                return words.allSatisfy { blob.contains($0) }
            }
        }
        // 5E: the trash is ordered by its own picker, and never pinned-first
        // — a pinned clip that was deleted is just a deleted clip, and having
        // it jump the queue above the deletion someone came here to undo
        // would defeat the default sort.
        if case .trash = f.scope {
            return f.trashSort.order(base)
        }

        // 5C: inside a folder the user's own drag order wins outright —
        // including over pins. Hand-sorting a folder is how the clips used
        // most often are kept at the top, and a pinned row jumping out of the
        // position it was dragged to would defeat that. All and Favorites are
        // unaffected and stay chronological, pinned first.
        if case .folder = f.scope {
            return ClipboardStore.folderOrder(base)
        }

        var pinned: [ClipboardItem] = []
        var rest: [ClipboardItem] = []
        pinned.reserveCapacity(base.count)
        rest.reserveCapacity(base.count)
        for item in base {
            if item.isPinned { pinned.append(item) } else { rest.append(item) }
        }
        return pinned + rest
    }
}
