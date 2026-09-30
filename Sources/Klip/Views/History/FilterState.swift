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

    /// What a query is matched against for one item, in two parts that match
    /// differently (see `matchesQuery`).
    struct SearchFields {
        /// Case- and diacritic-folded text, matched by **substring**: a
        /// query word anywhere inside it counts, so "manu" finds "manual"
        /// and "invoice" finds "Invoice#4471".
        let text: String
        /// The folded words of the image's Vision labels plus their plurals,
        /// matched **whole-word**: a query word has to *be* one of them.
        let labelWords: Set<String>
    }

    /// Case- and diacritic-folded search blob for one item, built once per
    /// filter pass (never per query word). Pulls in every field the query is
    /// allowed to match by substring: `textContent` (the 500-char preview
    /// for large, file-backed text — never the full file, per
    /// `ClipboardStore.fullText`'s doc comment: filtering must not read
    /// files), `ocrText`, tag names, `sourceApp`, and file names
    /// (`fileAttachment.originalName` plus `additionalNames`).
    /// Link/email/phone/code items already store their text in
    /// `textContent`, so they need no extra field. A clip's title joins the
    /// blob too, so `⌘F` finds a named clip by its name.
    ///
    /// Image clips also contribute the text `ImageAnalysisService` read out
    /// of them (`ocrText`). What an image *shows* (`imageLabels`) is not in
    /// this blob any more: see `labelWords(_:)` for why labels are matched
    /// whole-word instead. An image that has not been analyzed yet
    /// contributes only its tags, title and source app, as before.
    static func searchBlob(for item: ClipboardItem) -> String {
        searchFields(for: item).text
    }

    /// Both halves of what `item` is searched by, from the cache when the
    /// item has not changed since they were built.
    static func searchFields(for item: ClipboardItem) -> SearchFields {
        let stamp = BlobStamp(item)
        if let cached = blobCache[item.id], cached.stamp == stamp {
            return cached.fields
        }
        let fields = SearchFields(
            text: buildSearchBlob(for: item),
            labelWords: item.imageLabels.map(labelWords) ?? []
        )
        cache(fields, stamp: stamp, for: item)
        return fields
    }

    /// Does `item` contain every one of `words` (already folded by
    /// `queryWords`)? Each word may land in a different field, as before:
    /// substring anywhere in the text blob, or an exact label word.
    ///
    /// The label set is tried first because it is a hash lookup, and only
    /// when the item has labels at all (hashing the word for an empty set
    /// would be pure cost on every text clip).
    static func matchesQuery(_ item: ClipboardItem, words: [String]) -> Bool {
        let fields = searchFields(for: item)
        return words.allSatisfy { word in
            (!fields.labelWords.isEmpty && fields.labelWords.contains(word)) || fields.text.contains(word)
        }
    }

    // MARK: - Blob cache (5A-15)
    //
    // The blob above used to be rebuilt — and `.folding(...)`ed, which
    // allocates a fresh String per item — on *every* keystroke: measured at
    // 35.6 ms for a no-match query over 10,000 items, 112 ms to type
    // "project". Nothing about an item's blob changes unless the item does,
    // and every user edit stamps `updatedAt` (`ClipboardStore.touchItem`), so
    // `updatedAt` plus the image-analysis fields (see `BlobStamp`) is an
    // exact cache key.
    //
    // Two bounds keep this from becoming a memory problem in its own right:
    // a byte budget (a folded copy of every inline clip could otherwise be up
    // to `inlineTextLimit` × the whole history), and a sweep that drops
    // entries for items that are no longer in the list.

    /// What a cached blob was built from. `updatedAt` covers every user edit;
    /// `ocrText` and `imageLabels` are here as well because image analysis
    /// deliberately does not stamp `updatedAt` (it must not win sync merges,
    /// see `ClipboardStore.setImageAnalysis`), and a sync merge can fill them
    /// in without changing it either. Comparing them is cheap on a hit: an
    /// unchanged item hands back the very same string and array buffers, and
    /// `==` short-circuits on shared storage.
    private struct BlobStamp: Equatable {
        let updatedAt: Date
        let ocrText: String?
        let imageLabels: [String]?

        init(_ item: ClipboardItem) {
            updatedAt = item.updatedAt
            ocrText = item.ocrText
            imageLabels = item.imageLabels
        }
    }

    private struct CachedBlob {
        let stamp: BlobStamp
        let fields: SearchFields
        /// What this entry counts against the budget, remembered so eviction
        /// subtracts exactly what insertion added.
        let bytes: Int
    }

    private static var blobCache: [UUID: CachedBlob] = [:]
    private static var blobCacheBytes = 0

    /// Roughly 16 MB of folded text. Beyond this, misses are simply not
    /// cached (the newest items — the ones actually on screen — get there
    /// first, so the tail pays the old cost rather than everything thrashing).
    private static let blobCacheByteBudget = 16 * 1024 * 1024

    private static func cache(_ fields: SearchFields, stamp: BlobStamp, for item: ClipboardItem) {
        if let existing = blobCache[item.id] {
            blobCacheBytes -= existing.bytes
            blobCache[item.id] = nil
        }
        // The label words are a handful of short strings per image; counting
        // their bytes keeps the budget honest without pretending to measure
        // the Set's own overhead.
        let size = fields.text.utf8.count + fields.labelWords.reduce(0) { $0 + $1.utf8.count }
        guard blobCacheBytes + size <= blobCacheByteBudget else { return }
        blobCache[item.id] = CachedBlob(stamp: stamp, fields: fields, bytes: size)
        blobCacheBytes += size
    }

    /// Drops cache entries for items that are gone (deleted, evicted, merged
    /// away). Cheap and rare: only runs once the cache has drifted well past
    /// the size of the list it is caching.
    private static func sweepBlobCache(keeping items: [ClipboardItem]) {
        guard blobCache.count > items.count + 512 else { return }
        let live = Set(items.map { $0.id })
        for (id, entry) in blobCache where !live.contains(id) {
            blobCacheBytes -= entry.bytes
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
        if let ocr = item.ocrText, !ocr.isEmpty { parts.append(ocr) }
        // No `imageLabels` here on purpose - they go into `labelWords`.
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

    // MARK: - Image labels in search

    /// The words an image's labels can be found by: every word of every
    /// label and of its plural form(s), folded like the query. `["flower",
    /// "golf ball"]` -> `{"flower", "flowers", "golf", "ball", "balls"}`.
    ///
    /// **Whole words, not substrings.** Labels used to join the substring
    /// blob, and that was fine for text but not for a vocabulary of short
    /// English nouns: "man" matched the labels "mango", "german shepherd",
    /// "doberman" and "performance", and "car" matched "cardboard box". A
    /// label is a *claim about what the picture shows*, so a query word has
    /// to name it exactly (or its plural) for the claim to count. Real text
    /// keeps substring matching (`searchBlob`): there, finding "manual" from
    /// "manu" while typing is exactly what people expect.
    ///
    /// The cost is that a half-typed word ("flo") no longer finds a label
    /// ("flower") until it is complete. That is a small loss: the list only
    /// updates once typing pauses (the debounce), usually on a whole word,
    /// and a label match is a best guess about the picture, not text the
    /// user remembers typing.
    ///
    /// Splitting multi-word labels into words keeps what substring matching
    /// did right: "keyboard" still finds "computer keyboard", and "computer
    /// keyboard" still finds it too, because each query word is matched on
    /// its own (AND), the same as for text.
    ///
    /// Built once per item and cached with the text blob, so a query pays a
    /// hash lookup per image, not a scan.
    static func labelWords(_ labels: [String]) -> Set<String> {
        guard !labels.isEmpty else { return [] }
        let folded = labelSearchTerms(labels)
            .joined(separator: " ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return Set(folded.split(whereSeparator: \.isWhitespace).map(String.init))
    }

    /// Each label followed by its plural form(s): `["flower", "computer
    /// monitor"]` -> `["flower", "flowers", "computer monitor", "computer
    /// monitors"]`.
    ///
    /// Only the plural is added because Vision's labels are English
    /// singular nouns, so "the query is plural, the label is not" is the gap
    /// to close. A plural that comes out odd ("golves") costs nothing -
    /// nobody types it - so the rules below err toward adding a form rather
    /// than missing one.
    static func labelSearchTerms(_ labels: [String]) -> [String] {
        var terms: [String] = []
        terms.reserveCapacity(labels.count * 2)
        for label in labels {
            terms.append(label)
            terms.append(contentsOf: pluralForms(of: label))
        }
        return terms
    }

    /// English plural(s) of a label; for a multi-word label only the last
    /// word is inflected ("golf ball" -> "golf balls"). Empty when the label
    /// already looks plural ("sunglasses", "ferns").
    static func pluralForms(of label: String) -> [String] {
        guard let lastSpace = label.lastIndex(of: " ") else { return pluralForms(ofWord: label) }
        let head = label[...lastSpace]
        return pluralForms(ofWord: String(label[label.index(after: lastSpace)...])).map { String(head) + $0 }
    }

    private static let irregularPlurals: [String: [String]] = [
        "person": ["people", "persons"],
        "man": ["men"],
        "woman": ["women"],
        "child": ["children"],
        "mouse": ["mice"],
        "goose": ["geese"],
        "tooth": ["teeth"],
        "foot": ["feet"],
        "ox": ["oxen"],
        "cactus": ["cacti", "cactuses"],
        "fungus": ["fungi", "funguses"],
        "die": ["dice"],
    ]

    private static func pluralForms(ofWord word: String) -> [String] {
        if let irregular = irregularPlurals[word] { return irregular }
        guard let last = word.last, word.count > 1 else { return [] }
        let beforeLast = word.dropLast().last
        let isVowel: (Character?) -> Bool = { $0.map { "aeiou".contains($0) } ?? false }

        // glass, bus, dish, bench, box
        if word.hasSuffix("ss") || word.hasSuffix("us") || word.hasSuffix("sh")
            || word.hasSuffix("ch") || last == "x" || last == "z" {
            return [word + "es"]
        }
        // Already plural: ferns, shoes, sunglasses.
        if last == "s" { return [] }
        // berry -> berries (but toy -> toys, below)
        if last == "y", !isVowel(beforeLast) { return [String(word.dropLast()) + "ies"] }
        // knife -> knives
        if word.hasSuffix("fe") { return [String(word.dropLast(2)) + "ves"] }
        // leaf -> leaves, roof -> roofs: English does both, so offer both.
        if last == "f", beforeLast != "f" { return [String(word.dropLast()) + "ves", word + "s"] }
        // tomato -> tomatoes, piano -> pianos: likewise.
        if last == "o", !isVowel(beforeLast) { return [word + "es", word + "s"] }
        return [word + "s"]
    }

    // MARK: - Query words

    /// The words a query must all match (AND), folded like the blob.
    ///
    /// Split on spaces, and also on a `+` that sits **between two letters**,
    /// so "desk+laptop" means the same as "desk laptop" (people type `+` for
    /// "and"). A `+` next to anything else stays part of the word, which
    /// keeps "c++", "g++", "c+" and "1+1" searchable as written.
    static func queryWords(_ query: String) -> [String] {
        query
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .split(separator: " ")
            .flatMap { splitOnLetterPlus(String($0)) }
    }

    private static func splitOnLetterPlus(_ word: String) -> [String] {
        guard word.contains("+") else { return [word] }
        let characters = Array(word)
        var words: [String] = []
        var current = ""
        for (offset, character) in characters.enumerated() {
            if character == "+",
               offset > 0, offset < characters.count - 1,
               characters[offset - 1].isLetter, characters[offset + 1].isLetter {
                words.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        words.append(current)
        return words.filter { !$0.isEmpty }
    }

    // MARK: - Smart image search

    /// What the smart image search (`SemanticImageSearching`) is asked for a
    /// typed query, or nil when it should not be asked at all.
    ///
    /// Search owns *when* to ask (the engine owns what counts as a match):
    /// - Never for an empty query, and never for anything starting with `#`,
    ///   whether or not tags are shown: it is either a tag query or a literal
    ///   token (a hex colour, an issue number, a hashtag), never a description
    ///   of a picture, and a model asked about it can only add noise.
    /// - Never for a single character: one letter describes nothing, and it
    ///   is what sits in the field for a moment at the start of every query.
    ///
    /// The words are the same ones text search uses (a `+` between letters
    /// means "and", so "desk+laptop" asks about "desk laptop"), but not
    /// folded: the model has its own tokenizer, and case and accents are its
    /// business. Joining them with single spaces also makes this the
    /// identity of an answer: "woman" and "woman " are the same question, so
    /// typing a trailing space does not ask again or throw away the result.
    static func semanticQuery(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#") else { return nil }
        let words = trimmed.split(separator: " ").flatMap { splitOnLetterPlus(String($0)) }
        let key = words.joined(separator: " ")
        guard key.count > 1 else { return nil }
        return key
    }

    /// Orders the smart-search-only hits: best score first, then newest, then
    /// id, so the result is a strict weak ordering and never shuffles two
    /// equal answers between passes. A NaN score (a broken engine) sorts
    /// last instead of breaking the sort.
    ///
    /// `pinnedFirst` gives the tail the same pinned-first partition the
    /// literal hits have in All and Favorites, so with no literal hits the
    /// list reads exactly like every other Klip list - "Pinned" header,
    /// pinned rows, separator, the rest - and the default selection (first
    /// unpinned row) is the best unpinned match. Folder and trash scopes have
    /// no pinned run, so there it is pure score order.
    private static func rankSemanticHits(
        _ hits: [(item: ClipboardItem, score: Float)],
        pinnedFirst: Bool
    ) -> [ClipboardItem] {
        let ranked = hits.sorted { a, b in
            let (x, y) = (a.score.isNaN ? -.infinity : a.score, b.score.isNaN ? -.infinity : b.score)
            if x != y { return x > y }
            if a.item.timestamp != b.item.timestamp { return a.item.timestamp > b.item.timestamp }
            return a.item.id.uuidString < b.item.id.uuidString
        }.map(\.item)
        return pinnedFirst ? pinnedPartition(ranked) : ranked
    }

    /// Stable partition: pinned items first, each group in its input order.
    /// (The original used `sorted { $0.isPinned && !$1.isPinned }`, which is
    /// not a strict weak ordering and let `sort` shuffle equal elements
    /// arbitrarily.)
    private static func pinnedPartition(_ items: [ClipboardItem]) -> [ClipboardItem] {
        var pinned: [ClipboardItem] = []
        var rest: [ClipboardItem] = []
        pinned.reserveCapacity(items.count)
        rest.reserveCapacity(items.count)
        for item in items {
            if item.isPinned { pinned.append(item) } else { rest.append(item) }
        }
        return pinned + rest
    }

    /// Filter + order `items` for display.
    ///
    /// Rules:
    /// 1. Scope (sidebar section) narrows first.
    /// 2. If a tag filter is active, keep only items carrying that tag.
    /// 3. The content-kind chip narrows next (see `matches(_:chip:)`).
    /// 4. A non-empty query that does not start with `#` matches items whose
    ///    title, text content, OCR text, tag names, source app, or file
    ///    name(s) contain every word of the query, case- and
    ///    diacritic-insensitively (see `searchBlob(for:)`), or whose Vision
    ///    labels contain the word as a whole word (see `labelWords(_:)`).
    ///    Multi-word queries are AND'd across all of those fields combined,
    ///    not per-field; a `+` between two letters separates words too
    ///    (`queryWords`). An image with none of those fields set (not
    ///    analyzed yet, no tags, no matching source app) matches nothing by
    ///    text, as before. A `#…` query is tag-autocomplete mode and does not
    ///    narrow the list at all.
    /// 5. Pinned items float to the top — except in folder scope, where the
    ///    manual drag order from `folderSortIndex` replaces this step entirely,
    ///    and in trash scope (5E), where `trashSort` does.
    /// 6. Smart image search: an **image** that survived steps 1-3, did not
    ///    match step 4, and is in `semanticMatches` (the engine's answer for
    ///    this query, see `SemanticImageSearching`) is a hit too. These come
    ///    after every literal hit, best score first (`rankSemanticHits`).
    ///    They only ever join a narrowing query: with no query, or a `#`
    ///    query, `semanticMatches` is ignored. Ids that are not images in
    ///    this filtered base (text clips, files, clips another filter
    ///    removed, deleted clips) are ignored too.
    ///
    /// In trash scope the caller passes `ClipboardStore.trashedItems` rather
    /// than `items`; steps 2-4 and 6 are identical, which is the whole point
    /// — the trash is searched, tag-filtered and chip-filtered exactly like
    /// the history.
    ///
    /// The pinned-first step is a **stable partition**: pinned items keep
    /// their relative order and so do the rest (`pinnedPartition`).
    ///
    /// **Ordering.** Literal hits (step 4) get no relevance ranking,
    /// intentionally: they stay in chronological (pinned-first) order no
    /// matter which fields a query happened to match, so the user's muscle
    /// memory for row position keeps working. A literal hit is binary - the
    /// clip contains "invoice" or it does not - so recency is the only useful
    /// order among them.
    ///
    /// Smart-search hits are the opposite: a picture of a woman does not
    /// *contain* "woman", it resembles it to some degree, and the matches
    /// range from obvious to borderline. In chronological order a borderline
    /// match copied this morning would sit above the photo the user is
    /// actually picturing, so among themselves they are ranked by score.
    /// They go *below* the literal hits, not interleaved, for three reasons:
    /// - They arrive later (the engine answers after the text pass has been
    ///   drawn). Appending means the rows already on screen never move, so
    ///   nothing jumps under the pointer and the highlighted row - the one ↩
    ///   pastes - is not pushed down or swapped for another.
    /// - A clip that literally says what was typed is the stronger evidence:
    ///   someone typing "woman" who sees a note saying "woman" first is not
    ///   surprised, whereas an image ranked above it on a model's hunch
    ///   might well be.
    /// - With no literal hits (the common case for "girl at a desk") the tail
    ///   *is* the list, best match first, and ↩ pastes the best match.
    /// An image that matches both ways is a literal hit and stays in its
    /// chronological place; it is never listed twice.
    static func apply(
        _ items: [ClipboardItem],
        _ f: FilterState,
        semanticMatches: [UUID: Float] = [:]
    ) -> [ClipboardItem] {
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
        var semanticHits: [(item: ClipboardItem, score: Float)] = []
        let query = f.query.trimmingCharacters(in: .whitespaces)
        // A leading `#` means "this is a tag query, the tag filter handles it"
        // — but only while there is a tag UI. With tags hidden it is an
        // ordinary character and has to be searched for, or typing `#` would
        // silently empty the list.
        if !query.isEmpty && !(Features.tagsEnabled && query.hasPrefix("#")) {
            let words = queryWords(query)
            // One pass sorts every item into literal hit, smart-search hit or
            // miss. The dictionary lookup only runs for images that missed,
            // and not at all while there is no answer (the first pass of every
            // query), so the text-only cost is what it was.
            var literal: [ClipboardItem] = []
            for item in base {
                if matchesQuery(item, words: words) {
                    literal.append(item)
                } else if !semanticMatches.isEmpty, item.type == .image,
                          let score = semanticMatches[item.id] {
                    semanticHits.append((item, score))
                }
            }
            base = literal
        }

        let ordered: [ClipboardItem]
        let pinnedFirst: Bool
        switch f.scope {
        case .trash:
            // 5E: the trash is ordered by its own picker, and never
            // pinned-first — a pinned clip that was deleted is just a deleted
            // clip, and having it jump the queue above the deletion someone
            // came here to undo would defeat the default sort.
            ordered = f.trashSort.order(base)
            pinnedFirst = false
        case .folder:
            // 5C: inside a folder the user's own drag order wins outright —
            // including over pins. Hand-sorting a folder is how the clips
            // used most often are kept at the top, and a pinned row jumping
            // out of the position it was dragged to would defeat that. All
            // and Favorites are unaffected and stay chronological, pinned
            // first.
            ordered = ClipboardStore.folderOrder(base)
            pinnedFirst = false
        case .all, .favorites:
            ordered = pinnedPartition(base)
            pinnedFirst = true
        }
        guard !semanticHits.isEmpty else { return ordered }
        return ordered + rankSemanticHits(semanticHits, pinnedFirst: pinnedFirst)
    }
}
