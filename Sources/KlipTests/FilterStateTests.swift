import Foundation
import BenchTestKit
@testable import Klip

// Covers `Views/History/FilterState.swift` — the pure filter/order rules the
// history list uses. Extracted from HistoryContentView.computeFilteredItems in
// Phase 1A; the only intentional change is that the pinned-first step is now a
// stable partition instead of the invalid `sorted { $0.isPinned && !$1.isPinned }`.

enum FilterStateTests {
    static let tests: [(String, () throws -> Void)] = [
        ("emptyQuery_returnsAllItems_pinnedFirst_stableOrder", testEmptyQueryPinnedFirstStable),
        ("query_matchesTextItemsOnly_caseInsensitive", testQueryMatchesTextOnly),
        ("hashQuery_isTagMode_andDoesNotNarrowTheList", testHashQueryIsTagMode),
        ("tagFilter_keepsOnlyItemsCarryingTheTag", testTagFilter),
        ("tagFilterAndQuery_combine", testMixed),
        ("emptyAndWhitespaceQuery_areTreatedAsNoQuery", testWhitespaceQuery),
        ("scope_all_keepsEverythingIncludingFoldered", testScopeAll),
        ("scope_favorites_keepsBookmarkedOnly", testScopeFavorites),
        ("scope_folder_keepsThatFolderOnly", testScopeFolder),
        ("chip_all_isANoOp", testChipAll),
        ("chip_image_matchesImageTypeRegardlessOfKind", testChipImage),
        ("chip_file_matchesItemsWithAnAttachment", testChipFile),
        ("chip_text_isTheCatchAllForUndetectedText", testChipText),
        ("chip_specificKinds_requireAnExactKindMatch", testChipSpecificKinds),
        // Task 6B — Tags chip
        ("chip_tagged_matchesAnyTaggedItemRegardlessOfWhichTag", testChipTagged),
        ("chip_taggedCombinedWithScope_narrowsBoth", testChipTaggedWithScope),
        ("chip_taggedCombinedWithHashTag_narrowsToThatTagOnly", testChipTaggedWithTagFilter),
        ("scopeChipTagAndQuery_combine", testScopeChipCombine),
        ("query_matchesOCRText_onImagesWithNoTextContent", testQueryMatchesOCRText),
        ("query_matchesTagNames_withoutHashPrefix", testQueryMatchesTagNameWithoutHash),
        ("query_matchesSourceApp", testQueryMatchesSourceApp),
        ("query_matchesFileNames_originalAndAdditional", testQueryMatchesFileNames),
        ("query_multiWord_isANDedAcrossAnyField", testQueryMultiWordAND),
        ("query_isDiacriticInsensitive", testQueryDiacriticInsensitive),
        ("query_imageWithNoSearchableField_stillExcluded", testQueryImageWithNothingSearchableExcluded),
        ("query_oldTextContentBehavior_stillWorks", testQueryOldTextContentBehaviorUnchanged),
        ("apply_10kItems_staysUnderTimingBudget", testApplyTimingBudget),
        // 5A-15 — the folded search blob is cached per item.
        ("searchBlobCache_invalidatesWhenTheItemChanges", testBlobCacheInvalidation),
        ("searchBlobCache_warmQueryPassIsUnderBudget", testBlobCacheWarmPass),
    ]

    // MARK: - Fixtures

    private static func text(
        _ content: String,
        pinned: Bool = false,
        tags: [String] = [],
        bookmarked: Bool = false,
        folder: UUID? = nil,
        kind: ContentKind? = nil,
        sourceApp: String? = nil
    ) -> ClipboardItem {
        ClipboardItem(
            type: .text,
            sourceApp: sourceApp,
            textContent: content,
            isPinned: pinned,
            isBookmarked: bookmarked,
            tags: tags,
            folderID: folder,
            kind: kind
        )
    }

    private static func image(
        pinned: Bool = false,
        tags: [String] = [],
        bookmarked: Bool = false,
        folder: UUID? = nil,
        kind: ContentKind? = nil,
        sourceApp: String? = nil,
        ocrText: String? = nil
    ) -> ClipboardItem {
        ClipboardItem(
            type: .image,
            sourceApp: sourceApp,
            imageFilename: "images/\(UUID().uuidString).png",
            isPinned: pinned,
            isBookmarked: bookmarked,
            tags: tags,
            ocrText: ocrText,
            folderID: folder,
            kind: kind
        )
    }

    private static func file(
        _ name: String,
        additionalNames: [String] = [],
        bookmarked: Bool = false,
        folder: UUID? = nil
    ) -> ClipboardItem {
        var item = ClipboardItem.file(attachment: FileAttachment(originalName: name, additionalNames: additionalNames, byteSize: 10))
        item.isBookmarked = bookmarked
        item.folderID = folder
        return item
    }

    private static func contents(_ items: [ClipboardItem]) -> [String] {
        items.map { item in
            if let attachment = item.fileAttachment { return attachment.originalName }
            return item.textContent ?? "<image>"
        }
    }

    // MARK: - Tests

    /// An empty query returns every item, pinned ones hoisted to the front, and
    /// both groups keep the order they had in the input.
    static func testEmptyQueryPinnedFirstStable() throws {
        let items = [
            text("a"),
            text("b", pinned: true),
            text("c"),
            text("d", pinned: true),
            text("e"),
        ]

        let result = FilterState.apply(items, FilterState())

        try expectEqual(result.count, items.count, "empty query should keep every item")
        try expectEqual(contents(result), ["b", "d", "a", "c", "e"], "pinned items first, each group in original order")
    }

    /// Images never match a text query, and matching is case-insensitive.
    static func testQueryMatchesTextOnly() throws {
        let items = [
            text("Hello World"),
            image(),
            text("goodbye"),
            text("say hello again"),
        ]

        let result = FilterState.apply(items, FilterState(query: "HELLO"))

        try expectEqual(contents(result), ["Hello World", "say hello again"], "only text items whose content contains the query, case-insensitively")

        let noMatch = FilterState.apply(items, FilterState(query: "zzz"))
        try expectEqual(noMatch.count, 0, "a query matching nothing returns an empty list")
    }

    /// What a leading `#` means depends on whether there is a tag UI behind
    /// it (`Features.tagsEnabled`).
    ///
    /// With tags on it is autocomplete mode: the bar handles the query, so
    /// the list must not be narrowed at all. With tags hidden there is no bar
    /// and no tag to complete, so `#` is an ordinary character and has to be
    /// searched for — otherwise typing one silently empties the list.
    static func testHashQueryIsTagMode() throws {
        let items = [
            text("alpha", tags: ["work"]),
            text("beta", pinned: true),
            image(tags: ["work"]),
        ]

        let result = FilterState.apply(items, FilterState(query: "#wo"))

        if Features.tagsEnabled {
            try expectEqual(result.count, 3, "a #query must not filter the list")
            try expectEqual(contents(result), ["beta", "alpha", "<image>"], "pinned-first still applies in tag mode")
        } else {
            try expectEqual(result.count, 0, "with tags hidden, '#wo' is text that nothing contains")
            let plain = FilterState.apply(items, FilterState(query: "#"))
            try expectEqual(plain.count, 0, "and a bare # is searched for, not treated as a mode switch")
        }
    }

    /// The tag filter keeps only items carrying that exact tag — images included.
    static func testTagFilter() throws {
        let items = [
            text("alpha", tags: ["work"]),
            text("beta", tags: ["home"]),
            image(tags: ["work"]),
            text("gamma"),
            text("delta", pinned: true, tags: ["work"]),
        ]

        let result = FilterState.apply(items, FilterState(tag: "work"))

        try expectEqual(contents(result), ["delta", "alpha", "<image>"], "only #work items, pinned first, otherwise in order")

        let missing = FilterState.apply(items, FilterState(tag: "nope"))
        try expectEqual(missing.count, 0, "an unknown tag filters everything out")
    }

    /// Tag filter and text query are applied together (tag first, then query).
    static func testMixed() throws {
        let items = [
            text("apple pie", tags: ["food"]),
            text("apple watch", tags: ["tech"]),
            image(tags: ["food"]),
            text("banana bread", pinned: true, tags: ["food"]),
            text("apple crumble", pinned: true, tags: ["food"]),
        ]

        let result = FilterState.apply(items, FilterState(query: "apple", tag: "food"))

        try expectEqual(contents(result), ["apple crumble", "apple pie"], "tag then query, pinned first, images dropped by the query")
    }

    /// A whitespace-only query behaves like no query at all.
    static func testWhitespaceQuery() throws {
        let items = [text("alpha"), image(), text("beta", pinned: true)]

        let blank = FilterState.apply(items, FilterState(query: "   "))
        try expectEqual(blank.count, 3, "a whitespace-only query should not filter anything")
        try expectEqual(contents(blank), ["beta", "alpha", "<image>"], "pinned-first order for a blank query")

        // Surrounding whitespace is trimmed before matching.
        let padded = FilterState.apply(items, FilterState(query: "  alpha  "))
        try expectEqual(contents(padded), ["alpha"], "query should be trimmed before matching")
    }

    // MARK: - Scope (sidebar sections)

    /// Per decision D4, a clip filed into a folder stays visible in "All".
    static func testScopeAll() throws {
        let folderID = UUID()
        let items = [
            text("loose"),
            text("filed", folder: folderID),
            text("starred", bookmarked: true),
        ]

        let result = FilterState.apply(items, FilterState(scope: .all))
        try expectEqual(contents(result), ["loose", "filed", "starred"], "All shows everything, folders included")
    }

    /// Favorites is exactly the `isBookmarked` (star) flag, across every type.
    static func testScopeFavorites() throws {
        let items = [
            text("plain"),
            text("starred", bookmarked: true),
            image(bookmarked: true),
            text("pinned but not starred", pinned: true),
            file("Doc.pdf", bookmarked: true),
        ]

        let result = FilterState.apply(items, FilterState(scope: .favorites))
        try expectEqual(contents(result), ["starred", "<image>", "Doc.pdf"], "only bookmarked items, in list order")
    }

    /// A folder scope keeps exactly that folder's members.
    static func testScopeFolder() throws {
        let a = UUID()
        let b = UUID()
        let items = [
            text("in-a", folder: a),
            text("in-b", folder: b),
            text("loose"),
            text("pinned-in-a", pinned: true, folder: a),
        ]

        let result = FilterState.apply(items, FilterState(scope: .folder(a)))
        try expectEqual(contents(result), ["pinned-in-a", "in-a"], "only folder A, pinned first")

        let empty = FilterState.apply(items, FilterState(scope: .folder(UUID())))
        try expectEqual(empty.count, 0, "an unknown folder id filters everything out")
    }

    // MARK: - Content-kind chips

    static func testChipAll() throws {
        let items = [text("a"), image(), file("F.txt")]
        let result = FilterState.apply(items, FilterState(chip: .all))
        try expectEqual(result.count, 3, "the All chip must not filter anything")
    }

    /// Image keys off the storage type, so it works before detection backfills.
    static func testChipImage() throws {
        let items = [
            text("a"),
            image(),
            image(kind: .image),
            file("F.png"),
        ]
        let result = FilterState.apply(items, FilterState(chip: .kind(.image)))
        try expectEqual(result.count, 2, "both image items, detected or not; a .file item is not an image")
    }

    /// File keys off the attachment, so it works before detection backfills.
    static func testChipFile() throws {
        let items = [text("a"), image(), file("Report.pdf"), file("Sheet.xlsx")]
        let result = FilterState.apply(items, FilterState(chip: .kind(.file)))
        try expectEqual(contents(result), ["Report.pdf", "Sheet.xlsx"], "only items carrying a file attachment")
    }

    /// Text is the catch-all for text items that have no more specific kind.
    static func testChipText() throws {
        let items = [
            text("undetected"),                  // kind == nil → Text
            text("plain", kind: .text),
            text("styled", kind: .richText),     // richText has no chip → Text
            text("https://example.com", kind: .link),
            image(),
            file("F.txt"),
        ]
        let result = FilterState.apply(items, FilterState(chip: .kind(.text)))
        try expectEqual(
            contents(result),
            ["undetected", "plain", "styled"],
            "undetected text plus explicit text/richText; links, images and files excluded"
        )
    }

    /// Every other chip is an exact `kind` match, so it stays empty until
    /// Phase 3C's detector backfills `kind`.
    static func testChipSpecificKinds() throws {
        let items = [
            text("https://example.com"),                          // undetected
            text("https://example.org", kind: .link),
            text("me@example.com", kind: .email),
            text("#ff6600", kind: .color),
            text("let x = 1", kind: .code),
            text("+1 555 0100", kind: .phone),
        ]

        try expectEqual(contents(FilterState.apply(items, FilterState(chip: .kind(.link)))), ["https://example.org"], "Link")
        try expectEqual(contents(FilterState.apply(items, FilterState(chip: .kind(.email)))), ["me@example.com"], "Email")
        try expectEqual(contents(FilterState.apply(items, FilterState(chip: .kind(.color)))), ["#ff6600"], "Color")
        try expectEqual(contents(FilterState.apply(items, FilterState(chip: .kind(.code)))), ["let x = 1"], "Code")
        try expectEqual(contents(FilterState.apply(items, FilterState(chip: .kind(.phone)))), ["+1 555 0100"], "Phone")

        let undetectedOnly = [text("https://example.com")]
        try expectEqual(
            FilterState.apply(undetectedOnly, FilterState(chip: .kind(.link))).count,
            0,
            "an item with kind == nil never matches a specific-kind chip"
        )
    }

    // MARK: - Tags chip (task 6B)

    /// `.tagged` keeps any item carrying at least one tag, regardless of
    /// which — it does not narrow to a specific tag (that's `FilterState.tag`).
    static func testChipTagged() throws {
        let items = [
            text("has a work tag", tags: ["work"]),
            text("has a home tag", tags: ["home"]),
            image(tags: ["work"]),
            text("untagged"),
            file("Untagged.pdf"),
        ]

        let result = FilterState.apply(items, FilterState(chip: .tagged))
        try expectEqual(contents(result), ["has a work tag", "has a home tag", "<image>"], "any tagged item, any tag")

        let untaggedOnly = [text("a"), text("b"), file("c.txt")]
        try expectEqual(FilterState.apply(untaggedOnly, FilterState(chip: .tagged)).count, 0, "no tagged items means an empty list")
    }

    /// The Tags chip narrows within a scope like every other chip.
    static func testChipTaggedWithScope() throws {
        let folderID = UUID()
        let items = [
            text("tagged in folder", tags: ["work"], folder: folderID),
            text("tagged elsewhere", tags: ["work"]),
            text("untagged in folder", folder: folderID),
        ]

        let result = FilterState.apply(items, FilterState(scope: .folder(folderID), chip: .tagged))
        try expectEqual(contents(result), ["tagged in folder"], "only the tagged item that is also in scope")
    }

    /// Combining the Tags chip with an exact `#tag` filter (`FilterState.tag`)
    /// narrows further, to just that tag — the chip alone would have let the
    /// other tagged item through too.
    static func testChipTaggedWithTagFilter() throws {
        let items = [
            text("work item", tags: ["work"]),
            text("home item", tags: ["home"]),
            text("untagged"),
        ]

        let result = FilterState.apply(items, FilterState(tag: "work", chip: .tagged))
        try expectEqual(contents(result), ["work item"], "chip plus exact tag narrows to that one tag")
    }

    /// Scope → tag → chip → query, all four at once.
    static func testScopeChipCombine() throws {
        let folderID = UUID()
        let items = [
            text("apple link", tags: ["work"], folder: folderID, kind: .link),
            text("apple link elsewhere", tags: ["work"], kind: .link),          // wrong scope
            text("apple link untagged", folder: folderID, kind: .link),         // wrong tag
            text("apple plain", tags: ["work"], folder: folderID, kind: .text), // wrong chip
            text("banana link", tags: ["work"], folder: folderID, kind: .link), // wrong query
        ]

        let result = FilterState.apply(
            items,
            FilterState(query: "apple", tag: "work", scope: .folder(folderID), chip: .kind(.link))
        )
        try expectEqual(contents(result), ["apple link"], "every predicate must hold")
    }

    // MARK: - Search upgrade (OCR / tags / source app / file names)

    /// An image with recognized OCR text and no `textContent` is now found by
    /// a plain-text query.
    static func testQueryMatchesOCRText() throws {
        let items = [
            text("unrelated note"),
            image(ocrText: "Invoice #4471 - Total Due"),
            image(ocrText: "just a screenshot"),
        ]

        let result = FilterState.apply(items, FilterState(query: "invoice"))
        try expectEqual(result.count, 1, "only the image whose OCR text contains the query")
        try expectNil(result.first?.textContent, "the match is the image, not the text item")

        let noMatch = FilterState.apply(items, FilterState(query: "zzz"))
        try expectEqual(noMatch.count, 0, "an OCR query matching nothing returns an empty list")
    }

    /// A plain (non-`#`) query now also matches a tag name directly, in
    /// addition to the existing `#tag` chip-filter path.
    static func testQueryMatchesTagNameWithoutHash() throws {
        let items = [
            text("alpha", tags: ["urgent"]),
            text("beta", tags: ["later"]),
            image(tags: ["urgent"]),
        ]

        let result = FilterState.apply(items, FilterState(query: "urgent"))
        try expectEqual(contents(result), ["alpha", "<image>"], "tag name match reaches text and image items alike")
    }

    /// The app the clip was copied from is now searchable.
    static func testQueryMatchesSourceApp() throws {
        let items = [
            text("alpha", sourceApp: "Xcode"),
            text("beta", sourceApp: "Safari"),
            image(sourceApp: "Xcode"),
        ]

        let result = FilterState.apply(items, FilterState(query: "xcode"))
        try expectEqual(contents(result), ["alpha", "<image>"], "source-app match, case-insensitive")
    }

    /// File clip names, including the additional names of a multi-file copy,
    /// are searchable.
    static func testQueryMatchesFileNames() throws {
        let items = [
            file("Invoice.pdf"),
            file("Report.pdf", additionalNames: ["Appendix-Invoice.pdf", "Notes.txt"]),
            file("Photo.png"),
        ]

        let result = FilterState.apply(items, FilterState(query: "invoice"))
        try expectEqual(contents(result), ["Invoice.pdf", "Report.pdf"], "matches the primary name or any additional name")
    }

    /// Multi-word queries AND across words, but each word may land in a
    /// different field (text, tag, source app, OCR, file name, ...).
    static func testQueryMultiWordAND() throws {
        let items = [
            text("release notes", tags: ["urgent"], sourceApp: "Notes"),
            text("release notes", tags: ["someday"], sourceApp: "Notes"),
            text("release notes", tags: ["urgent"], sourceApp: "Safari"),
        ]

        let result = FilterState.apply(items, FilterState(query: "urgent notes"))
        try expectEqual(result.count, 2, "\"urgent\" (tag) AND \"notes\" (text) must both be present somewhere on the item")

        let none = FilterState.apply(items, FilterState(query: "urgent xylophone"))
        try expectEqual(none.count, 0, "a word with no match anywhere excludes the item")
    }

    /// Matching ignores accents/diacritics as well as case.
    static func testQueryDiacriticInsensitive() throws {
        let items = [
            text("café society"),
            text("plain coffee"),
        ]

        let result = FilterState.apply(items, FilterState(query: "cafe"))
        try expectEqual(contents(result), ["café society"], "an unaccented query still finds the accented content")

        let reverse = FilterState.apply(items, FilterState(query: "café"))
        try expectEqual(contents(reverse), ["café society"], "and vice versa")
    }

    /// An image with no OCR text, no tags and no matching source app still
    /// matches nothing — the pre-upgrade "images excluded" behavior holds
    /// whenever none of the new fields are populated.
    static func testQueryImageWithNothingSearchableExcluded() throws {
        let items = [text("hello"), image()]
        let result = FilterState.apply(items, FilterState(query: "hello"))
        try expectEqual(contents(result), ["hello"], "the bare image never matches a text query")
    }

    /// The original `textContent` substring match (case-insensitive, images
    /// excluded when they carry none of the new fields) still works
    /// unchanged after the additive rewrite.
    static func testQueryOldTextContentBehaviorUnchanged() throws {
        let items = [
            text("Hello World"),
            image(),
            text("goodbye"),
            text("say hello again"),
        ]

        let result = FilterState.apply(items, FilterState(query: "HELLO"))
        try expectEqual(contents(result), ["Hello World", "say hello again"], "unchanged: case-insensitive textContent match, bare image excluded")
    }

    /// Perf budget: 10,000 items, several fields populated on each, must
    /// filter well within the 150ms CI-safe ceiling (observed ~single-digit
    /// ms on a dev machine for this size).
    static func testApplyTimingBudget() throws {
        var items: [ClipboardItem] = []
        items.reserveCapacity(10_000)
        for i in 0..<10_000 {
            switch i % 4 {
            case 0:
                items.append(text("Some clipboard text number \(i) about coffee and code", tags: ["tag\(i % 50)"], sourceApp: "App\(i % 10)"))
            case 1:
                items.append(image(tags: ["tag\(i % 50)"], sourceApp: "App\(i % 10)", ocrText: "Recognized text block \(i) invoice total"))
            case 2:
                items.append(file("File-\(i).pdf", additionalNames: ["Extra-\(i).txt"]))
            default:
                items.append(text("plain entry \(i)", pinned: i % 37 == 0))
            }
        }

        let start = Date()
        let result = FilterState.apply(items, FilterState(query: "invoice code"))
        let elapsedMs = Date().timeIntervalSince(start) * 1000

        try expect(elapsedMs < 150, "apply() over 10,000 items took \(elapsedMs) ms, want < 150 ms")
        try expect(result.count >= 0, "sanity: apply must return without crashing")
        print("FilterState.apply timing over 10,000 items: \(String(format: "%.2f", elapsedMs)) ms")
    }

    // MARK: - 5A-15: cached search blobs

    /// The cache is keyed on `(id, updatedAt)`, and every store mutation
    /// stamps `updatedAt` — so an edited clip must be re-blobbed, never
    /// matched against its old text.
    static func testBlobCacheInvalidation() throws {
        let original = ClipboardItem(type: .text, textContent: "alpha invoice")
        try expectEqual(FilterState.apply([original], FilterState(query: "alpha")).count, 1,
                        "the original text should match")

        // Same id, new content, newer stamp — exactly what an edit produces.
        let edited = ClipboardItem(
            id: original.id,
            type: .text,
            timestamp: original.timestamp,
            textContent: "beta receipt",
            updatedAt: original.updatedAt.addingTimeInterval(1)
        )
        try expectEqual(FilterState.apply([edited], FilterState(query: "alpha")).count, 0,
                        "a stale cached blob must not keep matching the old text")
        try expectEqual(FilterState.apply([edited], FilterState(query: "receipt")).count, 1,
                        "the new text should match")

        // Tags and OCR text feed the same blob, and are stamped the same way.
        let tagged = ClipboardItem(
            id: original.id,
            type: .text,
            timestamp: original.timestamp,
            textContent: "beta receipt",
            tags: ["quarterly"],
            updatedAt: original.updatedAt.addingTimeInterval(2)
        )
        try expectEqual(FilterState.apply([tagged], FilterState(query: "quarterly")).count, 1,
                        "a newly added tag must be visible to search")
    }

    /// The keystroke cost this cache exists for. The uncached pass rebuilt
    /// and folded a String per item on every keystroke (measured at 35.6 ms
    /// for a no-match query over 10,000 items).
    static func testBlobCacheWarmPass() throws {
        var items: [ClipboardItem] = []
        items.reserveCapacity(10_000)
        for i in 0..<10_000 {
            items.append(text("Some clipboard text number \(i) about coffee and code",
                              tags: ["tag\(i % 50)"], sourceApp: "App\(i % 10)"))
        }

        FilterState.resetSearchBlobCache()
        let coldStart = Date()
        _ = FilterState.apply(items, FilterState(query: "zzzznotamatch"))
        let coldMs = Date().timeIntervalSince(coldStart) * 1000

        let warmStart = Date()
        let warm = FilterState.apply(items, FilterState(query: "zzzznotamatch"))
        let warmMs = Date().timeIntervalSince(warmStart) * 1000

        print("FilterState.apply worst-case query over 10,000 items: cold \(String(format: "%.2f", coldMs)) ms, warm \(String(format: "%.2f", warmMs)) ms")
        try expectEqual(warm.count, 0, "the query matches nothing — the whole list is scanned")
        // The budget here is generous because `scripts/run_tests.sh` builds
        // the runner unoptimised; the same pass measures 7.4 ms under `-O`
        // (the build the app actually ships), against the 35.6 ms the review
        // measured for the uncached version.
        try expect(warmMs < 20, "a warm no-match pass took \(warmMs) ms, want < 20 ms")
        try expect(warmMs < coldMs, "the warm pass must be cheaper than the cold one")
    }
}
