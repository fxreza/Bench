import Foundation
import BenchTestKit
@testable import Klip

// Smart image search in the history list: when `HistoryViewModel` asks the
// engine, how the answer joins the text results (`FilterState.apply`), and
// what happens to the selection and the rest of the list when it lands.
//
// The engine itself is a separate piece behind `SemanticImageSearching`;
// these tests drive a fake one whose answers and timing they control, so
// they are fast and deterministic and do not need the model on disk.

enum SemanticSearchTests {
    static let tests: [(String, () throws -> Void)] = [
        // The async stage
        ("textResultsFirst_thenImageMatchesWhenTheEngineAnswers", testMatchesArriveAfterText),
        ("staleAnswer_toAnEarlierQuery_isIgnored", testStaleAnswerIgnored),
        ("keystroke_cancelsTheRequestInFlight", testKeystrokeCancels),
        ("trailingSpace_doesNotCancelOrAskAgain", testTrailingSpaceKeepsRequest),
        ("typedAndDeletedAgain_asksAgain", testTypedAndDeletedAsksAgain),
        ("hashQuery_emptyQuery_singleCharacter_neverAskTheEngine", testQueriesThatNeverAsk),
        ("plusBetweenLetters_isAskedAsSeparateWords", testPlusAskedAsWords),
        ("unavailableEngine_behavesExactlyLikeTextSearch", testUnavailableEngine),
        ("defaultViewModel_hasSmartSearchOff", testDefaultIsOff),
        ("answerWithNoMatches_endsPendingAndLeavesTheListAlone", testEmptyAnswer),
        // Filters
        ("scopeChipTagAndTrash_narrowImageMatchesLikeTextMatches", testFiltersRespected),
        ("nonImageAndUnknownIDs_inTheAnswer_areIgnored", testNonImageIgnored),
        ("noQuery_answerIsIgnored", testNoQueryIgnoresAnswer),
        ("chipChange_reusesTheAnswer_withoutAskingAgain", testChipReusesAnswer),
        // Ordering
        ("ordering_literalHitsFirst_thenImageMatchesByScore", testOrdering),
        ("ordering_folderScope_imageMatchesInPureScoreOrder", testOrderingInFolder),
        ("ordering_imageMatchingBothWays_isListedOnceInItsTextPlace", testNoDuplicates),
        // Selection and scrolling
        ("selection_userMovedIt_isKeptWhenMatchesArrive", testSelectionKeptWhenMoved),
        ("selection_untouchedDefault_isKeptWhenMatchesArrive", testDefaultSelectionKept),
        ("selection_pinnedOnlyTextHit_doesNotJumpToAnImage", testPinnedDefaultDoesNotJump),
        ("selection_noTextHits_selectsTheBestUnpinnedMatch", testNoTextHitsSelectsBest),
        ("emptyList_waitsForImages_onlyUnderChipsThatShowThem", testWaitOnlyWhereImagesCanShow),
        // Lifecycle
        ("reopen_withKeptQuery_asksAgain_keepingTheOldAnswerOnScreen", testReopenRefreshes),
        ("swappingInTheRealEngine_asksItAboutTheQueryOnScreen", testEngineSwap),
    ]

    // MARK: - Fake engine

    /// Answers from a table and records every question. An answer can be
    /// held back until `release(_:)`; a held answer is returned even if the
    /// asking task was cancelled meanwhile, like an engine that does not
    /// check for cancellation - which is what makes the stale-answer tests
    /// test the view model's own check, not just cancellation.
    final class FakeSemanticSearch: SemanticImageSearching {
        var isAvailable: Bool
        var answers: [String: [UUID: Float]]
        var held: Set<String> = []
        private(set) var calls: [String] = []
        private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

        init(answers: [String: [UUID: Float]] = [:], isAvailable: Bool = true) {
            self.answers = answers
            self.isAvailable = isAvailable
        }

        func matches(for query: String) async -> [UUID: Float] {
            calls.append(query)
            if held.contains(query) {
                await withCheckedContinuation { continuation in
                    waiting[query, default: []].append(continuation)
                }
            }
            return answers[query] ?? [:]
        }

        /// Lets every held request for `query` answer.
        func release(_ query: String) {
            held.remove(query)
            for continuation in waiting.removeValue(forKey: query) ?? [] {
                continuation.resume()
            }
        }

        var waitingCount: Int { waiting.values.reduce(0) { $0 + $1.count } }
    }

    // MARK: - Harness

    static func image(
        at seconds: TimeInterval,
        pinned: Bool = false,
        bookmarked: Bool = false,
        tags: [String] = [],
        folder: UUID? = nil,
        labels: [String]? = nil,
        deleted: Bool = false
    ) -> ClipboardItem {
        ClipboardItem(
            type: .image,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
            imageFilename: "\(UUID().uuidString).png",
            isPinned: pinned,
            isBookmarked: bookmarked,
            tags: tags,
            ocrText: labels == nil ? nil : "",
            folderID: folder,
            kind: .image,
            deletedAt: deleted ? Date(timeIntervalSince1970: 1_700_100_000 + seconds) : nil,
            imageLabels: labels
        )
    }

    static func text(_ content: String, at seconds: TimeInterval, pinned: Bool = false, folder: UUID? = nil) -> ClipboardItem {
        ClipboardItem(
            type: .text,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + seconds),
            textContent: content,
            isPinned: pinned,
            folderID: folder
        )
    }

    /// A view model over a store holding `items` (oldest first in the
    /// argument, so the store lists them newest first, as captures would).
    static func withViewModel(
        _ items: [ClipboardItem],
        engine: SemanticImageSearching,
        _ body: (HistoryViewModel) throws -> Void
    ) throws {
        try ClipboardStoreTests.withStore { store, _ in
            for item in items { store.add(item) }
            let viewModel = HistoryViewModel(store: store, semanticSearch: engine)
            viewModel.applyFilters(resetSelection: .defaultItem)
            defer { viewModel.cancelSemanticSearch() }
            try body(viewModel)
        }
    }

    static func pump(until condition: () -> Bool, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        return condition()
    }

    static func pump(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }

    static func ids(_ viewModel: HistoryViewModel) -> [UUID] {
        viewModel.filteredItems.map(\.id)
    }

    /// Past the view model's 200 ms search debounce.
    static let debounce: TimeInterval = 0.3

    // MARK: - The async stage

    static func testMatchesArriveAfterText() throws {
        let note = text("a woman at the station", at: 1)
        let older = image(at: 2)
        let newer = image(at: 3)
        let unrelated = text("grocery list", at: 4)
        let engine = FakeSemanticSearch(answers: ["woman": [older.id: 0.31, newer.id: 0.27]])
        engine.held = ["woman"]

        try withViewModel([note, older, newer, unrelated], engine: engine) { vm in
            vm.debouncedSearchText = "woman"
            try expectEqual(ids(vm), [note.id], "the text result is on screen at once, before the engine answers")
            try expect(vm.isSemanticSearchPending, "and the image matches are known to be coming")
            try expectEqual(vm.selectedID, note.id, "the text hit is selected straight away")

            try expect(pump { engine.calls == ["woman"] }, "the engine is asked, once")
            try expectEqual(ids(vm), [note.id], "nothing changes while it is thinking")

            engine.release("woman")
            try expect(pump { !vm.isSemanticSearchPending }, "the answer lands")
            try expectEqual(ids(vm), [note.id, older.id, newer.id],
                            "image matches join below the text hit, best score first")
            try expectEqual(engine.calls, ["woman"], "and nothing asked twice")
        }
    }

    static func testStaleAnswerIgnored() throws {
        let cat = image(at: 1)
        let dog = image(at: 2)
        let engine = FakeSemanticSearch(answers: ["cat": [cat.id: 0.5], "dog": [dog.id: 0.5]])
        engine.held = ["cat"]

        try withViewModel([cat, dog], engine: engine) { vm in
            vm.debouncedSearchText = "cat"
            try expect(pump { engine.calls == ["cat"] }, "asked about cat")

            vm.debouncedSearchText = "dog"
            try expect(pump { !vm.isSemanticSearchPending && ids(vm) == [dog.id] }, "dog's answer shows")

            // The engine finally answers "cat", ignoring the cancellation.
            engine.release("cat")
            pump(for: 0.1)
            try expectEqual(engine.waitingCount, 0, "the held request did return")
            try expectEqual(ids(vm), [dog.id], "a late answer to an earlier query never replaces the current one")
            try expectEqual(vm.semanticAnswer?.query, "dog")

            // And should one reach the view model anyway (a task that missed
            // its cancellation), the view model's own check drops it.
            vm.receiveSemanticMatches([cat.id: 0.9], for: "cat")
            try expectEqual(ids(vm), [dog.id], "an answer for a query no longer on screen is dropped")
            try expectEqual(vm.semanticAnswer?.query, "dog")
        }
    }

    static func testKeystrokeCancels() throws {
        let cat = image(at: 1)
        let engine = FakeSemanticSearch(answers: ["cat": [cat.id: 0.5]])
        engine.held = ["cat"]

        try withViewModel([cat], engine: engine) { vm in
            vm.searchText = "cat"
            try expect(pump { engine.calls == ["cat"] }, "asked after the debounce")
            try expectNotNil(vm.semanticTask)

            vm.searchText = "cats"
            try expectNil(vm.semanticTask, "the next keystroke cancels the request at once, not after the debounce")
            try expectNil(vm.semanticTaskQuery)
            try expect(vm.isSemanticSearchPending,
                       "but the empty list keeps waiting (a new request follows the debounce), rather than flash No matches")

            engine.release("cat")
            pump(for: 0.05)
            try expectNil(vm.semanticAnswer, "the cancelled request's answer is dropped")

            try expect(pump { engine.calls == ["cat", "cats"] }, "the new query is asked after the debounce")
            try expect(pump { !vm.isSemanticSearchPending }, "and settles")
            try expectEqual(ids(vm), [], "cats matches nothing")
        }
    }

    static func testTrailingSpaceKeepsRequest() throws {
        let cat = image(at: 1)
        let engine = FakeSemanticSearch(answers: ["cat": [cat.id: 0.5]])
        engine.held = ["cat"]

        try withViewModel([cat], engine: engine) { vm in
            vm.searchText = "cat"
            try expect(pump { engine.calls == ["cat"] }, "asked")
            vm.searchText = "cat "
            try expectNotNil(vm.semanticTask, "same words, same question: the request keeps running")
            pump(for: debounce)
            try expectEqual(engine.calls, ["cat"], "and is not asked again after the debounce")

            engine.release("cat")
            try expect(pump { ids(vm) == [cat.id] }, "its answer applies to 'cat ' too")
        }
    }

    static func testTypedAndDeletedAsksAgain() throws {
        let cat = image(at: 1)
        let engine = FakeSemanticSearch(answers: ["cat": [cat.id: 0.5]])
        engine.held = ["cat"]

        try withViewModel([cat], engine: engine) { vm in
            vm.searchText = "cat"
            try expect(pump { engine.calls == ["cat"] }, "asked")
            // A letter typed and deleted inside the debounce: the debounced
            // text never changes, but the keystroke cancelled the request.
            vm.searchText = "catx"
            vm.searchText = "cat"
            try expect(pump { engine.calls == ["cat", "cat"] }, "so the debounce asks again")
            engine.release("cat")
            try expect(pump { ids(vm) == [cat.id] && !vm.isSemanticSearchPending }, "and the answer shows")
        }
    }

    static func testQueriesThatNeverAsk() throws {
        let tagged = image(at: 1, tags: ["work"])
        let engine = FakeSemanticSearch(answers: [
            "#work": [tagged.id: 0.9], "w": [tagged.id: 0.9], "#": [tagged.id: 0.9],
        ])

        try withViewModel([tagged], engine: engine) { vm in
            // A `#` query is a tag query (or, with tags hidden, a literal
            // token like a hex colour) either way - never a picture.
            vm.debouncedSearchText = "#work"
            pump(for: 0.05)
            vm.debouncedSearchText = "#"
            pump(for: 0.05)
            vm.debouncedSearchText = "w"
            pump(for: 0.05)
            vm.debouncedSearchText = ""
            pump(for: 0.05)
            try expectEqual(engine.calls, [], "#tag, bare #, one letter and empty never reach the engine")
            try expect(!vm.isSemanticSearchPending, "and nothing is left waiting")
        }

        try expectNil(FilterState.semanticQuery("  #work "))
        try expectNil(FilterState.semanticQuery("x"))
        try expectNil(FilterState.semanticQuery("   "))
        try expectEqual(FilterState.semanticQuery("tv"), "tv")
        try expectEqual(FilterState.semanticQuery("  girl at   a desk "), "girl at a desk", "whitespace normalized")
    }

    static func testPlusAskedAsWords() throws {
        let engine = FakeSemanticSearch()
        try withViewModel([image(at: 1)], engine: engine) { vm in
            vm.debouncedSearchText = "Desk+Laptop"
            try expect(pump { engine.calls.count == 1 }, "asked")
            try expectEqual(engine.calls, ["Desk Laptop"], "'+' between letters is 'and', like text search; case left to the model")
        }
        try expectEqual(FilterState.semanticQuery("c++"), "c++", "a '+' that is not between letters stays")
    }

    static func testUnavailableEngine() throws {
        let note = text("a woman at the station", at: 1)
        let photo = image(at: 2)
        let labelled = image(at: 3, labels: ["woman"])
        let engine = FakeSemanticSearch(answers: ["woman": [photo.id: 0.9]], isAvailable: false)

        try withViewModel([note, photo, labelled], engine: engine) { vm in
            vm.debouncedSearchText = "woman"
            try expect(!vm.isSemanticSearchPending, "nothing is pending when there is no model")
            pump(for: 0.05)
            try expectEqual(engine.calls, [], "and the engine is never asked")
            try expectEqual(ids(vm), FilterState.apply(vm.store.items, FilterState(query: "woman")).map(\.id),
                            "the list is exactly the text search")
            try expectEqual(ids(vm), [labelled.id, note.id])
        }
    }

    static func testDefaultIsOff() throws {
        try ClipboardStoreTests.withStore { store, _ in
            let vm = HistoryViewModel(store: store)
            try expect(vm.semanticSearch is NoSemanticImageSearch, "the stand-in until the app hands over the engine")
            try expect(!vm.semanticSearch.isAvailable, "which is never available")
            vm.debouncedSearchText = "woman"
            try expect(!vm.isSemanticSearchPending, "so a query never waits for it")
            try expectNil(vm.semanticTask)
        }
    }

    static func testEmptyAnswer() throws {
        let note = text("woman", at: 1)
        let engine = FakeSemanticSearch()
        try withViewModel([note, image(at: 2)], engine: engine) { vm in
            vm.debouncedSearchText = "woman"
            try expect(pump { !vm.isSemanticSearchPending }, "an empty answer still ends the wait")
            try expectEqual(ids(vm), [note.id])
            try expectEqual(vm.semanticAnswer?.query, "woman", "and is remembered, so it is not asked again")
            vm.chipFilter = .kind(.text)
            vm.chipFilter = .all
            pump(for: 0.05)
            try expectEqual(engine.calls, ["woman"])
        }
    }

    // MARK: - Filters

    static func testFiltersRespected() throws {
        let folder = UUID()
        let inFolder = image(at: 1, bookmarked: true, tags: ["work"], folder: folder)
        let loose = image(at: 2)
        let note = text("unrelated", at: 3)
        let items = [note, loose, inFolder]
        let matches: [UUID: Float] = [inFolder.id: 0.5, loose.id: 0.4]
        func apply(_ f: FilterState) -> [UUID] {
            FilterState.apply(items, f, semanticMatches: matches).map(\.id)
        }

        try expectEqual(apply(FilterState(query: "woman")), [inFolder.id, loose.id], "All: both, by score")
        try expectEqual(apply(FilterState(query: "woman", scope: .folder(folder))), [inFolder.id], "a folder narrows them")
        try expectEqual(apply(FilterState(query: "woman", scope: .favorites)), [inFolder.id], "Favorites too")
        try expectEqual(apply(FilterState(query: "woman", chip: .kind(.text))), [], "the Text chip excludes images")
        try expectEqual(apply(FilterState(query: "woman", chip: .kind(.link))), [], "and so does any other non-image chip")
        try expectEqual(apply(FilterState(query: "woman", chip: .kind(.image))), [inFolder.id, loose.id], "the Images chip keeps them")
        try expectEqual(apply(FilterState(query: "woman", tag: "work")), [inFolder.id], "a tag filter narrows them")

        // Trash: the caller hands in the trash; an answer naming a live clip
        // cannot pull it in.
        let trashed = image(at: 4, deleted: true)
        let inTrash = FilterState.apply(
            [trashed],
            FilterState(query: "woman", scope: .trash),
            semanticMatches: [trashed.id: 0.3, inFolder.id: 0.9]
        )
        try expectEqual(inTrash.map(\.id), [trashed.id], "only what is in the trash")
    }

    static func testNonImageIgnored() throws {
        let photo = image(at: 1)
        let note = text("unrelated", at: 2)
        let file = ClipboardItem.file(attachment: FileAttachment(originalName: "Report.pdf", additionalNames: [], byteSize: 10))
        let result = FilterState.apply(
            [file, note, photo],
            FilterState(query: "woman"),
            semanticMatches: [note.id: 0.9, file.id: 0.9, UUID(): 0.9, photo.id: 0.1]
        )
        try expectEqual(result.map(\.id), [photo.id], "text clips, files and unknown ids in the answer are ignored")
    }

    static func testNoQueryIgnoresAnswer() throws {
        let photo = image(at: 1)
        let note = text("note", at: 2)
        let items = [note, photo]
        let all = FilterState.apply(items, FilterState(), semanticMatches: [photo.id: 0.9])
        try expectEqual(all.map(\.id), [note.id, photo.id], "no query: the plain list, nothing duplicated or reordered")

        // With tags on, a `#` query does not narrow; with them off it is
        // text. Either way the view model never passes an answer for it
        // (`FilterState.semanticQuery` is nil), which is what matters.
        try expectNil(FilterState.semanticQuery("#note"))
    }

    static func testChipReusesAnswer() throws {
        let note = text("woman", at: 1)
        let photo = image(at: 2)
        let engine = FakeSemanticSearch(answers: ["woman": [photo.id: 0.5]])
        try withViewModel([note, photo], engine: engine) { vm in
            vm.debouncedSearchText = "woman"
            try expect(pump { ids(vm) == [note.id, photo.id] }, "answer in")

            vm.chipFilter = .kind(.text)
            try expectEqual(ids(vm), [note.id], "the Text chip hides the image match")
            vm.chipFilter = .kind(.image)
            try expectEqual(ids(vm), [photo.id], "the Images chip shows only it")
            vm.chipFilter = .all
            try expectEqual(ids(vm), [note.id, photo.id], "and All brings everything back")
            pump(for: 0.05)
            try expectEqual(engine.calls, ["woman"], "the same answer is re-filtered, the engine is not asked again")
        }
    }

    // MARK: - Ordering

    static func testOrdering() throws {
        let oldNote = text("woman's day", at: 0)
        let oldPhoto = image(at: 1)
        let labelled = image(at: 2, labels: ["woman"])
        let pinnedPhoto = image(at: 3, pinned: true)
        let newPhoto = image(at: 4)
        let newNote = text("the woman who called", at: 5)
        let pinnedNote = text("woman pinned", at: -1, pinned: true)
        let items = [newNote, newPhoto, pinnedPhoto, labelled, oldPhoto, oldNote, pinnedNote]
        let matches: [UUID: Float] = [
            newPhoto.id: 0.20, pinnedPhoto.id: 0.25, oldPhoto.id: 0.35, labelled.id: 0.9,
        ]

        let result = FilterState.apply(items, FilterState(query: "woman"), semanticMatches: matches).map(\.id)
        try expectEqual(result, [
            // Literal hits: pinned first, then newest first, as always.
            pinnedNote.id, newNote.id, labelled.id, oldNote.id,
            // Image matches: pinned first, then best score first - the old
            // photo scored higher than the new one, so it leads.
            pinnedPhoto.id, oldPhoto.id, newPhoto.id,
        ])

        let tied = image(at: 6)
        let tiedResult = FilterState.apply(
            [tied, oldPhoto],
            FilterState(query: "woman"),
            semanticMatches: [tied.id: 0.3, oldPhoto.id: 0.3]
        ).map(\.id)
        try expectEqual(tiedResult, [tied.id, oldPhoto.id], "equal scores: newest first")

        let broken = FilterState.apply(
            [newPhoto, oldPhoto],
            FilterState(query: "woman"),
            semanticMatches: [newPhoto.id: .nan, oldPhoto.id: 0.1]
        ).map(\.id)
        try expectEqual(broken, [oldPhoto.id, newPhoto.id], "a NaN score sorts last instead of breaking the sort")
    }

    static func testOrderingInFolder() throws {
        let folder = UUID()
        let note = text("woman", at: 5, folder: folder)
        let pinned = image(at: 4, pinned: true, folder: folder)
        let best = image(at: 1, folder: folder)
        let worst = image(at: 3, folder: folder)
        let items = [note, pinned, worst, best]
        let result = FilterState.apply(
            items,
            FilterState(query: "woman", scope: .folder(folder)),
            semanticMatches: [pinned.id: 0.3, best.id: 0.5, worst.id: 0.1]
        ).map(\.id)
        try expectEqual(result, [note.id, best.id, pinned.id, worst.id],
                        "folders have no pinned run, so image matches are in pure score order")
    }

    static func testNoDuplicates() throws {
        let labelled = image(at: 1, labels: ["woman"])
        let newer = text("woman", at: 2)
        let result = FilterState.apply(
            [newer, labelled],
            FilterState(query: "woman"),
            semanticMatches: [labelled.id: 0.99]
        ).map(\.id)
        try expectEqual(result, [newer.id, labelled.id], "a literal hit keeps its place and is not listed again")
    }

    // MARK: - Selection and scrolling

    static func testSelectionKeptWhenMoved() throws {
        let first = text("woman one", at: 1)
        let second = text("woman two", at: 2)
        let photo = image(at: 3)
        let engine = FakeSemanticSearch(answers: ["woman": [photo.id: 0.5]])
        engine.held = ["woman"]

        try withViewModel([first, second, photo], engine: engine) { vm in
            vm.debouncedSearchText = "woman"
            try expectEqual(ids(vm), [second.id, first.id])
            try expectEqual(vm.selectedID, second.id, "default: the first text hit")

            vm.keyDown()
            try expectEqual(vm.selectedID, first.id, "the user moves down a row")

            try expect(pump { engine.calls.count == 1 }, "asked")
            engine.release("woman")
            try expect(pump { ids(vm) == [second.id, first.id, photo.id] }, "the image joins below")
            try expectEqual(vm.selectedID, first.id, "the user's selection is kept")
            try expectEqual(vm.selectedIndex, 1, "on the same row")
            try expectEqual(vm.selectedIDs, [first.id])
            try expect(vm.semanticRowsAppended, "ClipList is told not to scroll for the appended rows")

            vm.applyFilters(resetSelection: .preserve)
            try expect(!vm.semanticRowsAppended, "any other recompute is an ordinary list change again")
        }
    }

    static func testDefaultSelectionKept() throws {
        let note = text("woman", at: 1)
        let photo = image(at: 2)   // newer than the note
        let engine = FakeSemanticSearch(answers: ["woman": [photo.id: 0.9]])
        engine.held = ["woman"]

        try withViewModel([note, photo], engine: engine) { vm in
            vm.debouncedSearchText = "woman"
            try expectEqual(vm.selectedID, note.id)
            try expect(pump { engine.calls.count == 1 }, "asked")
            engine.release("woman")
            try expect(pump { ids(vm) == [note.id, photo.id] }, "answer in")
            try expectEqual(vm.selectedID, note.id, "the highlighted row - what ↩ pastes - does not change under the user")
        }
    }

    static func testPinnedDefaultDoesNotJump() throws {
        let pinnedNote = text("woman pinned", at: 1, pinned: true)
        let photo = image(at: 2)
        let engine = FakeSemanticSearch(answers: ["woman": [photo.id: 0.9]])
        engine.held = ["woman"]

        try withViewModel([pinnedNote, photo], engine: engine) { vm in
            vm.debouncedSearchText = "woman"
            try expectEqual(vm.selectedID, pinnedNote.id, "all text hits pinned: the default falls back to the pinned one")
            try expect(pump { engine.calls.count == 1 }, "asked")
            engine.release("woman")
            try expect(pump { ids(vm) == [pinnedNote.id, photo.id] }, "answer in")
            try expectEqual(vm.selectedID, pinnedNote.id,
                            "re-running 'first unpinned' would jump to the image; the selection stays put instead")
        }
    }

    static func testNoTextHitsSelectsBest() throws {
        let pinnedBest = image(at: 1, pinned: true)
        let good = image(at: 2)
        let better = image(at: 3)
        let engine = FakeSemanticSearch(answers: ["girl at a desk": [pinnedBest.id: 0.9, good.id: 0.3, better.id: 0.6]])
        engine.held = ["girl at a desk"]

        try withViewModel([pinnedBest, good, better], engine: engine) { vm in
            vm.debouncedSearchText = "girl at a desk"
            try expectEqual(ids(vm), [], "no text hits")
            try expectNil(vm.selectedID)
            try expect(vm.isSemanticSearchPending, "the empty list waits instead of saying No matches")

            try expect(pump { engine.calls.count == 1 }, "asked")
            engine.release("girl at a desk")
            try expect(pump { !vm.isSemanticSearchPending }, "answer in")
            try expectEqual(ids(vm), [pinnedBest.id, better.id, good.id], "pinned first, then by score")
            try expectEqual(vm.selectedID, better.id, "the default rule: the best unpinned match")
            try expect(!vm.semanticRowsAppended, "a new selection scrolls to itself as usual")
        }
    }

    static func testWaitOnlyWhereImagesCanShow() throws {
        let photo = image(at: 1)
        let engine = FakeSemanticSearch(answers: ["woman": [photo.id: 0.5]])
        engine.held = ["woman"]

        try withViewModel([photo], engine: engine) { vm in
            vm.debouncedSearchText = "woman"
            try expect(vm.mayStillShowImageMatches, "All: the empty list waits for the pictures")
            vm.chipFilter = .kind(.image)
            try expect(vm.mayStillShowImageMatches, "Images: so does this one")
            vm.chipFilter = .kind(.text)
            try expect(vm.isSemanticSearchPending, "the engine is still working")
            try expect(!vm.mayStillShowImageMatches, "but under Text no answer can add a row, so No matches shows at once")
            vm.chipFilter = .all
            try expect(pump { engine.calls.count == 1 }, "asked")
            engine.release("woman")
            try expect(pump { !vm.mayStillShowImageMatches }, "and the wait ends with the answer")
            try expectEqual(ids(vm), [photo.id])
        }
    }

    // MARK: - Lifecycle

    static func testReopenRefreshes() throws {
        let photo = image(at: 1)
        let engine = FakeSemanticSearch(answers: ["woman": [photo.id: 0.5]])

        try withViewModel([photo], engine: engine) { vm in
            vm.searchText = "woman"
            // (The list shows everything until the debounce, so wait for the
            // answer itself, not just for the photo to be listed.)
            try expect(pump { vm.semanticAnswer?.query == "woman" }, "answer in")
            try expectEqual(ids(vm), [photo.id])
            vm.selectSingle(photo.id)

            engine.held = ["woman"]
            vm.shouldResetOnOpen = false
            vm.handleWindowDidOpen()
            try expectEqual(ids(vm), [photo.id], "the kept answer is on screen straight away")
            try expectEqual(vm.selectedID, photo.id, "and the selection on it is restored")
            try expect(!vm.isSemanticSearchPending, "refreshing an answer on screen is not 'waiting'")
            try expect(pump { engine.calls == ["woman", "woman"] }, "the engine is asked again: it may know newer images")
            engine.release("woman")
            pump(for: 0.05)
            try expectEqual(ids(vm), [photo.id])

            vm.shouldResetOnOpen = true
            vm.handleWindowDidOpen()
            try expectNil(vm.semanticAnswer, "a reset field drops the answer")
            try expectNil(vm.semanticTask)
        }
    }

    static func testEngineSwap() throws {
        let photo = image(at: 1)
        try withViewModel([photo], engine: NoSemanticImageSearch.shared) { vm in
            vm.debouncedSearchText = "woman"
            try expectEqual(ids(vm), [], "no engine, no image matches")

            let engine = FakeSemanticSearch(answers: ["woman": [photo.id: 0.5]])
            vm.semanticSearch = engine
            try expect(pump { ids(vm) == [photo.id] }, "the new engine is asked about the query on screen")
            try expectEqual(engine.calls, ["woman"])

            vm.semanticSearch = NoSemanticImageSearch.shared
            try expectEqual(ids(vm), [], "and its matches leave with it")
        }
    }
}
