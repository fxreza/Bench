import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers
import BenchTestKit
@testable import Klip

// Image clips searchable by the text in them and by what they show:
// the model fields and their migration, the store's write paths, the sync
// merge rules, search (labels, plurals, `+`), the pure halves of
// `ImageAnalysisService`, one real Vision pass on a generated image, and the
// background queue (driven by a fake analyzer, so its tests are fast and
// deterministic).

enum ImageAnalysisTests {
    static let tests: [(String, () throws -> Void)] = [
        // Model
        ("imageLabels_roundTripsThroughCodable", testLabelsRoundTrip),
        ("legacyRecord_withoutImageLabels_decodesAsNotAnalyzed", testLegacyDecode),
        ("legacySentinel_decodesAsEmptyText", testSentinelDecodesAsEmpty),
        ("legacySentinel_inHistoryFile_isMigratedAtLoad", testSentinelMigratedAtLoad),
        ("equality_includesImageLabels", testEqualityIncludesLabels),
        ("needsImageAnalysis_rules", testNeedsImageAnalysis),
        // Store
        ("setImageAnalysis_setsBothFields_oneWrite_noUpdatedAtBump", testSetImageAnalysis),
        ("setOCRText_legacySentinel_isStoredAsEmpty", testSetOCRTextSentinel),
        ("applyImageAnalyses_fillsOnlyMissing_ignoresDeleted_persists", testApplyImageAnalyses),
        ("add_newImage_callsAnalysisHookAfterInsert", testAddCallsHook),
        ("add_textClip_doesNotCallAnalysisHook", testAddTextSkipsHook),
        // Sync
        ("merge_newerCopyWithoutLabels_keepsItsEditsAndGainsLabels", testMergeFillsFromLosingCopy),
        ("merge_emptyAnalysis_givesWayToRealResult", testMergeEmptyLosesToContent),
        ("merge_bothAnalyzed_keepsOwnAndConverges", testMergeBothAnalyzedConverges),
        ("merge_contentDedupe_carriesLabels", testMergeDedupeCarriesLabels),
        // Search
        ("search_findsImageByLabel", testSearchByLabel),
        ("search_pluralQuery_findsSingularLabel", testSearchPlural),
        ("pluralForms_table", testPluralFormsTable),
        ("search_plusBetweenLetters_isAnd", testSearchPlusIsAnd),
        ("queryWords_plusOnlySplitsBetweenLetters", testQueryWordsPlus),
        ("search_cPlusPlus_stillMatches", testSearchCPlusPlus),
        ("search_blobCache_seesAnalysisWithoutUpdatedAtChange", testBlobCacheSeesAnalysis),
        ("search_emptyOCRText_matchesNothing", testEmptyOCRMatchesNothing),
        // Service, pure
        ("service_targetSize_capsShortSideNotLongSide", testTargetSize),
        ("service_selectLabels_floorOrderNormalizeDedupeCap", testSelectLabels),
        ("service_normalizedLabel", testNormalizedLabel),
        ("service_joinedText_dropsBlankLines", testJoinedText),
        ("service_missingOrNonImageFile_isUnreadable", testUnreadable),
        // Service, real Vision
        ("service_realVision_readsDrawnTextAndClassifies", testRealVision),
        ("service_realVision_screenshotTiming", testScreenshotTiming),
        // Queue
        ("queue_capture_isAnalyzed_withoutReorderOrUpdatedAtBump", testQueueCapture),
        ("queue_backfill_skipsAnalyzed_marksMissingFileEmpty", testQueueBackfill),
        ("queue_itemDeletedMidQueue_isSkippedAndItsResultDropped", testQueueDeletedMidQueue),
        ("queue_visionFailure_notPersisted_notRetriedThisSession", testQueueFailure),
        ("queue_stop_appliesBufferedResults_dropsInFlight", testQueueStopFlushes),
        ("queue_backfill_batchesSaves_andNotifiesSyncOnce", testQueueSyncNotifiedOnce),
        ("queue_deferredBackfill_stillAnalyzesCapturesAndRequests", testQueueDeferred),
    ]

    // MARK: - Harness

    static func image(
        id: UUID = UUID(),
        at seconds: TimeInterval = 1_700_000_000,
        filename: String? = nil,
        ocrText: String? = nil,
        labels: [String]? = nil,
        updated: TimeInterval? = nil,
        pinned: Bool = false
    ) -> ClipboardItem {
        ClipboardItem(
            id: id,
            type: .image,
            timestamp: Date(timeIntervalSince1970: seconds),
            imageFilename: filename ?? "\(UUID().uuidString).png",
            isPinned: pinned,
            ocrText: ocrText,
            kind: .image,
            updatedAt: updated.map { Date(timeIntervalSince1970: $0) },
            imageLabels: labels
        )
    }

    static func pump(until condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    static func item(_ id: UUID, in store: ClipboardStore) -> ClipboardItem? {
        store.items.first { $0.id == id }
    }

    /// Writes placeholder bytes as an image asset and returns an unanalyzed
    /// image clip pointing at it. The fake analyzer never reads them.
    static func storedImage(_ store: ClipboardStore, at seconds: TimeInterval) throws -> ClipboardItem {
        guard let filename = store.saveImage(Data([0x89, 0x50, 0x4E, 0x47]), fileExtension: "png") else {
            throw TestFailure(message: "saveImage failed", file: #file, line: #line)
        }
        return image(at: seconds, filename: filename)
    }

    /// Records every URL it is asked about and answers from a table.
    /// `nonisolated` because the queue calls it on its utility queue.
    nonisolated final class AnalyzerSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [URL] = []
        private var gates: [String: DispatchSemaphore] = [:]
        private var outcomes: [String: ImageAnalysisService.Outcome] = [:]
        private let fallback: ImageAnalysisService.Outcome

        init(_ fallback: ImageAnalysisService.Outcome = .analyzed(ImageAnalysis(text: "hello world", labels: ["flower", "plant"]))) {
            self.fallback = fallback
        }

        var urls: [URL] {
            lock.lock(); defer { lock.unlock() }
            return calls
        }

        func set(_ outcome: ImageAnalysisService.Outcome, for filename: String) {
            lock.lock(); defer { lock.unlock() }
            outcomes[filename] = outcome
        }

        /// The call for `filename` blocks until `release(filename)`.
        func hold(_ filename: String) {
            lock.lock(); defer { lock.unlock() }
            gates[filename] = DispatchSemaphore(value: 0)
        }

        func release(_ filename: String) {
            lock.lock()
            let gate = gates[filename]
            lock.unlock()
            gate?.signal()
        }

        func analyze(_ url: URL) -> ImageAnalysisService.Outcome {
            lock.lock()
            calls.append(url)
            let gate = gates[url.lastPathComponent]
            let outcome = outcomes[url.lastPathComponent] ?? fallback
            lock.unlock()
            gate?.wait()
            return outcome
        }
    }

    static let fastTiming = ImageAnalysisQueue.Timing(
        backfillDelay: 0,
        backfillPause: 0,
        flushBatchSize: 100,
        flushInterval: 1_000,
        deferRetry: 1_000
    )

    static func makeQueue(
        _ store: ClipboardStore,
        spy: AnalyzerSpy,
        timing: ImageAnalysisQueue.Timing = fastTiming,
        deferBackfill: Bool = false
    ) -> ImageAnalysisQueue {
        ImageAnalysisQueue(
            store: store,
            timing: timing,
            analyzer: { spy.analyze($0) },
            shouldDeferBackfill: { deferBackfill }
        )
    }

    // MARK: - Model

    static func testLabelsRoundTrip() throws {
        let original = image(ocrText: "Invoice 4471", labels: ["flower", "computer keyboard"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ClipboardItem.self, from: data)
        try expectEqual(decoded.imageLabels, ["flower", "computer keyboard"], "labels round-trip in order")
        try expectEqual(decoded.ocrText, "Invoice 4471")
        try expectEqual(decoded, original, "the whole record round-trips")

        let empty = image(ocrText: "", labels: [])
        let emptyDecoded = try JSONDecoder().decode(ClipboardItem.self, from: JSONEncoder().encode(empty))
        try expectEqual(emptyDecoded.imageLabels, [], "analyzed-and-empty stays [] (not nil)")
        try expectEqual(emptyDecoded.ocrText, "", "read-no-text stays \"\" (not nil)")

        let unanalyzed = image()
        let json = String(decoding: try JSONEncoder().encode(unanalyzed), as: UTF8.self)
        try expect(!json.contains("imageLabels"), "nil labels are omitted from the JSON, like ocrText")
    }

    static func testLegacyDecode() throws {
        let json = """
        {"id": "\(UUID().uuidString)", "type": "image", "timestamp": 1700000000,
         "imageFilename": "a.png", "ocrText": "old manual extract"}
        """
        let decoded = try JSONDecoder().decode(ClipboardItem.self, from: Data(json.utf8))
        try expectNil(decoded.imageLabels, "a record from before the field is 'not analyzed'")
        try expectEqual(decoded.ocrText, "old manual extract")
        try expect(decoded.needsImageAnalysis, "text alone is not a full analysis; labels are still missing")
    }

    static func testSentinelDecodesAsEmpty() throws {
        let json = """
        {"id": "\(UUID().uuidString)", "type": "image", "timestamp": 1700000000,
         "imageFilename": "a.png", "ocrText": "\(ClipboardItem.legacyNoTextSentinel)"}
        """
        let decoded = try JSONDecoder().decode(ClipboardItem.self, from: Data(json.utf8))
        try expectEqual(decoded.ocrText, "", "the old 'No text found' sentinel means read-no-text")
    }

    static func testSentinelMigratedAtLoad() throws {
        let legacy = image(ocrText: ClipboardItem.legacyNoTextSentinel)   // init does not normalize
        let other = image(at: 1_600_000_000, ocrText: "real text")
        try ClipboardStoreTests.withStore(seed: { dir in
            struct File: Encodable { let version: Int; let items: [ClipboardItem] }
            try JSONEncoder().encode(File(version: 2, items: [legacy, other]))
                .write(to: dir.appendingPathComponent("history.json"))
        }) { store, dir in
            try expectEqual(item(legacy.id, in: store)?.ocrText, "", "migrated in memory at load")
            try expectEqual(item(other.id, in: store)?.ocrText, "real text", "other text untouched")

            store.togglePin(for: other)   // any mutation rewrites the file
            store.flushPendingSave()
            let raw = String(decoding: try Data(contentsOf: dir.appendingPathComponent("history.json")), as: UTF8.self)
            try expect(!raw.contains(ClipboardItem.legacyNoTextSentinel), "the sentinel never goes back to disk")
        }
    }

    static func testEqualityIncludesLabels() throws {
        let a = image(labels: ["flower"])
        var b = a
        b.imageLabels = ["tree"]
        try expect(a != b, "different labels, different items")
        b.imageLabels = nil
        try expect(a != b, "labels vs not analyzed, different items")
        b.imageLabels = ["flower"]
        try expect(a == b, "same labels, equal")
    }

    static func testNeedsImageAnalysis() throws {
        try expect(!ClipboardItem.text("hi").needsImageAnalysis, "text clips are never analyzed")
        try expect(image().needsImageAnalysis, "fresh image")
        try expect(image(ocrText: "x").needsImageAnalysis, "labels missing")
        try expect(image(labels: ["x"]).needsImageAnalysis, "text missing")
        try expect(!image(ocrText: "", labels: []).needsImageAnalysis, "read, empty: done")
        try expect(!image(ocrText: "a", labels: ["b"]).needsImageAnalysis, "read: done")
    }

    // MARK: - Store

    static func testSetImageAnalysis() throws {
        try ClipboardStoreTests.withStore { store, _ in
            let clip = image(updated: 1_700_000_100)
            store.add(clip)
            let before = try unwrap(item(clip.id, in: store))

            var publishes = 0
            let subscription = store.objectWillChange.sink { publishes += 1 }
            store.setImageAnalysis(ocrText: "Total due", labels: ["receipt", "document"], for: clip)
            subscription.cancel()

            let after = try unwrap(item(clip.id, in: store))
            try expectEqual(after.ocrText, "Total due")
            try expectEqual(after.imageLabels, ["receipt", "document"])
            try expectEqual(publishes, 1, "both fields land in one published write")
            try expectEqual(after.updatedAt, before.updatedAt, "analysis is not an edit: updatedAt is untouched")
            try expectEqual(after.timestamp, before.timestamp, "and the clip's date does not move")

            store.setImageAnalysis(ocrText: ClipboardItem.legacyNoTextSentinel, labels: [], for: clip)
            try expectEqual(item(clip.id, in: store)?.ocrText, "", "the sentinel is never stored")
        }
    }

    static func testSetOCRTextSentinel() throws {
        try ClipboardStoreTests.withStore { store, _ in
            let clip = image()
            store.add(clip)
            store.setOCRText(ClipboardItem.legacyNoTextSentinel, for: clip)
            try expectEqual(item(clip.id, in: store)?.ocrText, "", "the old UI path cannot bring the sentinel back")
            store.setOCRText("Hello", for: clip)
            try expectEqual(item(clip.id, in: store)?.ocrText, "Hello")
        }
    }

    static func testApplyImageAnalyses() throws {
        try ClipboardStoreTests.withStore { store, dir in
            let fresh = image(at: 1)
            let hasText = image(at: 2, ocrText: "manual text")
            let done = image(at: 3, ocrText: "kept", labels: ["kept"])
            [fresh, hasText, done].forEach { store.add($0) }
            let ghost = UUID()

            let result = ImageAnalysis(text: "new text", labels: ["new"])
            let changed = store.applyImageAnalyses([fresh.id: result, hasText.id: result, done.id: result, ghost: result])

            try expectEqual(changed, 2, "only clips missing something change")
            try expectEqual(item(fresh.id, in: store)?.ocrText, "new text")
            try expectEqual(item(fresh.id, in: store)?.imageLabels, ["new"])
            try expectEqual(item(hasText.id, in: store)?.ocrText, "manual text", "text the user has seen is kept")
            try expectEqual(item(hasText.id, in: store)?.imageLabels, ["new"], "but the missing labels are filled")
            try expectEqual(item(done.id, in: store)?.imageLabels, ["kept"], "a finished clip is not rewritten")
            try expectEqual(store.items.count, 3, "an unknown id adds nothing")

            store.flushPendingSave()
            let onDisk = try ClipboardStoreTests.readHistoryFile(dir).items
            try expectEqual(onDisk.first { $0.id == fresh.id }?.imageLabels, ["new"], "persisted")
        }
    }

    static func testAddCallsHook() throws {
        try ClipboardStoreTests.withStore { store, _ in
            var seen: [UUID] = []
            var wasInList = false
            store.onImageNeedsAnalysis = { id in
                seen.append(id)
                wasInList = store.items.contains { $0.id == id }
            }
            let clip = image()
            store.add(clip)
            try expectEqual(seen, [clip.id], "a new image asks for analysis once")
            try expect(wasInList, "only after it is in the list")

            store.add(image(ocrText: "", labels: []))
            try expectEqual(seen.count, 1, "an already analyzed image (e.g. restored) does not")
        }
    }

    static func testAddTextSkipsHook() throws {
        try ClipboardStoreTests.withStore { store, _ in
            var calls = 0
            store.onImageNeedsAnalysis = { _ in calls += 1 }
            store.add(ClipboardItem.text("plain"))
            try expectEqual(calls, 0)
        }
    }

    // MARK: - Sync

    static func testMergeFillsFromLosingCopy() throws {
        let id = UUID()
        // This Mac analyzed the clip (no updatedAt bump); the other Mac pinned
        // it later without having the labels.
        let mine = image(id: id, ocrText: "Total due", labels: ["receipt"], updated: 1_700_000_000)
        var theirs = mine
        theirs.ocrText = nil
        theirs.imageLabels = nil
        theirs.isPinned = true
        theirs.updatedAt = Date(timeIntervalSince1970: 1_700_000_500)

        let here = SyncMergeTests.merge(local: [mine], remotes: [SyncMergeTests.remote(items: [theirs])])
        let merged = try unwrap(here.items.first)
        try expect(merged.isPinned, "the newer edit from the other Mac wins")
        try expectEqual(merged.ocrText, "Total due", "and keeps this Mac's text")
        try expectEqual(merged.imageLabels, ["receipt"], "and this Mac's labels")

        // The other Mac's view of the same merge: it gains the labels.
        let there = SyncMergeTests.merge(local: [theirs], remotes: [SyncMergeTests.remote("device-A", items: [mine])])
        try expectEqual(there.items.first?.imageLabels, ["receipt"], "the other Mac picks the labels up")
        try expect(there.changed, "which is a change it applies")
    }

    static func testMergeEmptyLosesToContent() throws {
        let id = UUID()
        // This Mac read the clip before its bytes had arrived: empty result.
        let mine = image(id: id, ocrText: "", labels: [], updated: 1_700_000_000)
        let theirs = image(id: id, ocrText: "Invoice", labels: ["document"], updated: 1_700_000_000)
        let result = SyncMergeTests.merge(local: [mine], remotes: [SyncMergeTests.remote(items: [theirs])])
        try expectEqual(result.items.first?.ocrText, "Invoice")
        try expectEqual(result.items.first?.imageLabels, ["document"])
    }

    static func testMergeBothAnalyzedConverges() throws {
        let id = UUID()
        let mine = image(id: id, ocrText: "mine", labels: ["a"], updated: 1_700_000_000)
        let theirs = image(id: id, ocrText: "theirs", labels: ["b"], updated: 1_700_000_000)
        let result = SyncMergeTests.merge(local: [mine], remotes: [SyncMergeTests.remote(items: [theirs])])
        try expectEqual(result.items.first?.ocrText, "mine", "an analyzed winner keeps its own result")
        try expectEqual(result.items.first?.imageLabels, ["a"])
        try expect(!result.changed, "no change, so no apply/push ping-pong")
    }

    static func testMergeDedupeCarriesLabels() throws {
        // Same bytes captured under two ids on two Macs fold into the older
        // record; the labels come along from the newer one.
        let older = image(at: 1_700_000_000, filename: "same.png", updated: 1_700_000_000)
        let newer = image(at: 1_700_000_100, filename: "same.png", ocrText: "x", labels: ["flower"], updated: 1_700_000_100)
        let result = SyncMergeTests.merge(local: [older], remotes: [SyncMergeTests.remote(items: [newer])])
        try expectEqual(result.items.count, 1, "folded")
        try expectEqual(result.items.first?.id, older.id, "into the older record")
        try expectEqual(result.items.first?.imageLabels, ["flower"], "which gains the labels")
        try expectEqual(result.items.first?.ocrText, "x")
    }

    // MARK: - Search

    static func search(_ query: String, in items: [ClipboardItem]) -> [ClipboardItem] {
        FilterState.apply(items, FilterState(query: query))
    }

    static func testSearchByLabel() throws {
        let flower = image(ocrText: "", labels: ["flower", "plant"])
        let keyboard = image(ocrText: "", labels: ["computer keyboard", "consumer electronics"])
        let unread = image()
        let items = [flower, keyboard, unread]
        try expectEqual(search("flower", in: items).map(\.id), [flower.id])
        try expectEqual(search("KEYBOARD", in: items).map(\.id), [keyboard.id], "substring, case-insensitive")
        try expectEqual(search("computer keyboard", in: items).map(\.id), [keyboard.id])
        try expectEqual(search("tulip", in: items).count, 0)
    }

    static func testSearchPlural() throws {
        let flower = image(ocrText: "", labels: ["flower"])
        let berry = image(ocrText: "", labels: ["strawberry"])
        let knife = image(ocrText: "", labels: ["knife"])
        let box = image(ocrText: "", labels: ["cardboard box"])
        let person = image(ocrText: "", labels: ["person"])
        let items = [flower, berry, knife, box, person]
        try expectEqual(search("flowers", in: items).map(\.id), [flower.id], "plural query, singular label")
        try expectEqual(search("strawberries", in: items).map(\.id), [berry.id])
        try expectEqual(search("knives", in: items).map(\.id), [knife.id])
        try expectEqual(search("boxes", in: items).map(\.id), [box.id], "multi-word label: last word inflected")
        try expectEqual(search("people", in: items).map(\.id), [person.id], "irregular")
        try expectEqual(search("flower", in: items).map(\.id), [flower.id], "singular still works")
    }

    static func testPluralFormsTable() throws {
        let cases: [(String, [String])] = [
            ("flower", ["flowers"]),
            ("glass", ["glasses"]),
            ("bus", ["buses"]),
            ("bench", ["benches"]),
            ("dish", ["dishes"]),
            ("fox", ["foxes"]),
            ("berry", ["berries"]),
            ("toy", ["toys"]),
            ("knife", ["knives"]),
            ("leaf", ["leaves", "leafs"]),
            ("cliff", ["cliffs"]),
            ("tomato", ["tomatoes", "tomatos"]),
            ("radio", ["radios"]),
            ("ferns", []),
            ("mouse", ["mice"]),
            ("golf ball", ["golf balls"]),
            ("blue sky", ["blue skies"]),
        ]
        for (label, expected) in cases {
            try expectEqual(FilterState.pluralForms(of: label), expected, label)
        }
        try expectEqual(
            FilterState.labelSearchTerms(["flower", "sunglasses"]),
            ["flower", "flowers", "sunglasses"],
            "label first, then its plural; already-plural labels add nothing"
        )
    }

    static func testSearchPlusIsAnd() throws {
        let both = image(ocrText: "", labels: ["desk", "laptop"])
        let deskOnly = image(ocrText: "", labels: ["desk"])
        let mixed = image(ocrText: "my laptop on the table", labels: ["desk"])
        let items = [both, deskOnly, mixed]
        try expectEqual(search("desk+laptop", in: items).map(\.id), [both.id, mixed.id], "+ is AND, across labels and text")
        try expectEqual(search("desk+laptop", in: items).map(\.id), search("desk laptop", in: items).map(\.id), "same as a space")
    }

    static func testQueryWordsPlus() throws {
        try expectEqual(FilterState.queryWords("desk+laptop"), ["desk", "laptop"])
        try expectEqual(FilterState.queryWords("Desk+Laptop+Cup"), ["desk", "laptop", "cup"], "folded, any number of parts")
        try expectEqual(FilterState.queryWords("c++"), ["c++"])
        try expectEqual(FilterState.queryWords("g++ build"), ["g++", "build"])
        try expectEqual(FilterState.queryWords("c+"), ["c+"])
        try expectEqual(FilterState.queryWords("1+1"), ["1+1"], "digits are not letters")
        try expectEqual(FilterState.queryWords("+desk"), ["+desk"])
        try expectEqual(FilterState.queryWords("desk+"), ["desk+"])
        try expectEqual(FilterState.queryWords("c++x"), ["c++x"], "a + next to another + never splits")
        try expectEqual(FilterState.queryWords("café+thé"), ["cafe", "the"], "letters beyond ASCII count")
    }

    static func testSearchCPlusPlus() throws {
        let cpp = ClipboardItem.text("I write c++ at work")
        let c = ClipboardItem.text("I write c at work")
        try expectEqual(search("c++", in: [cpp, c]).map(\.id), [cpp.id], "c++ is searched as written")
    }

    static func testBlobCacheSeesAnalysis() throws {
        var clip = image(updated: 1_700_000_000)
        try expectEqual(search("sunflower", in: [clip]).count, 0, "nothing yet (and the blob is now cached)")
        clip.ocrText = ""
        clip.imageLabels = ["sunflower", "flower"]   // same id, same updatedAt
        try expectEqual(search("sunflower", in: [clip]).map(\.id), [clip.id], "the cache notices the labels")
        clip.ocrText = "Harvest festival"
        try expectEqual(search("festival", in: [clip]).map(\.id), [clip.id], "and the text")
    }

    static func testEmptyOCRMatchesNothing() throws {
        let migrated = try JSONDecoder().decode(ClipboardItem.self, from: Data("""
        {"id": "\(UUID().uuidString)", "type": "image", "timestamp": 1700000000,
         "imageFilename": "a.png", "ocrText": "\(ClipboardItem.legacyNoTextSentinel)"}
        """.utf8))
        try expectEqual(search("found", in: [migrated]).count, 0, "the sentinel's words are no longer searchable")
    }

    // MARK: - Service, pure

    static func testTargetSize() throws {
        let cases: [(Int, Int, Int, String)] = [
            (2880, 1800, 2400, "Retina screenshot: short side 1800 -> 1500"),
            (3456, 2234, 2321, "16-inch screenshot"),
            (5120, 2880, 2667, "5K screenshot"),
            (1600, 12000, 11250, "scrolling capture keeps its length"),
            (1000, 800, 1000, "small image: never upscaled"),
            (1200, 40000, 12000, "absurdly long: long side capped"),
            (4032, 3024, 2000, "iPhone photo"),
        ]
        for (w, h, expected, note) in cases {
            try expectEqual(ImageAnalysisService.targetMaxPixelSize(width: w, height: h), expected, note)
        }
    }

    static func testSelectLabels() throws {
        let picked = ImageAnalysisService.selectLabels([
            ("plant", 0.6), ("flower", 0.9), ("sunflower", 0.9),
            ("insect", 0.098), ("blue_sky", 0.1),
            ("celestial_body", 0.3), ("celestial_body_other", 0.2),
        ])
        try expectEqual(
            picked,
            ["flower", "sunflower", "plant", "celestial body", "blue sky"],
            "floor 0.1 inclusive, most confident first, ties by identifier, normalized, deduped"
        )
        let many = (0..<30).map { (identifier: "label\($0)", confidence: Float(0.5)) }
        try expectEqual(ImageAnalysisService.selectLabels(many).count, ImageAnalysisService.maxLabels, "capped")
    }

    static func testNormalizedLabel() throws {
        try expectEqual(ImageAnalysisService.normalizedLabel("computer_keyboard"), "computer keyboard")
        try expectEqual(ImageAnalysisService.normalizedLabel("chair_other"), "chair")
        try expectEqual(ImageAnalysisService.normalizedLabel("Blue_Sky"), "blue sky")
        try expectEqual(ImageAnalysisService.normalizedLabel("other"), "other", "a lone 'other' is kept")
        try expectEqual(ImageAnalysisService.normalizedLabel("balloon_hotair"), "balloon hotair")
    }

    static func testJoinedText() throws {
        try expectEqual(ImageAnalysisService.joinedText([" Invoice ", "", "  ", "Total"]), "Invoice\nTotal")
        try expectEqual(ImageAnalysisService.joinedText([]), "", "no lines: read, no text")
    }

    static func testUnreadable() throws {
        try withTempDir { dir in
            let missing = dir.appendingPathComponent("gone.png")
            try expectEqual(ImageAnalysisService.analyze(imageAt: missing), .unreadable)
            let bogus = dir.appendingPathComponent("bogus.png")
            try Data("not an image".utf8).write(to: bogus)
            try expectEqual(ImageAnalysisService.analyze(imageAt: bogus), .unreadable)
        }
    }

    // MARK: - Service, real Vision

    /// White canvas with black system-font lines, written as PNG. Drawn
    /// through an explicit bitmap context, so it needs no window or screen.
    static func renderTextImage(width: Int, height: Int, lines: [String], fontSize: CGFloat, to url: URL) throws {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw TestFailure(message: "no bitmap context", file: #file, line: #line) }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.black,
        ]
        var y = CGFloat(height) - fontSize * 2
        for line in lines where y > 0 {
            (line as NSString).draw(at: CGPoint(x: fontSize, y: y), withAttributes: attributes)
            y -= fontSize * 1.6
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw TestFailure(message: "could not encode PNG", file: #file, line: #line) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw TestFailure(message: "could not write PNG", file: #file, line: #line)
        }
    }

    /// Vision prepares its accurate text model once per *binary*: the first
    /// run of a freshly linked `KlipTests` spends ~23 s in the first real
    /// analysis (later runs of the same binary: ~0.2 s). Set
    /// `KLIP_SKIP_VISION_TESTS=1` to skip the two real-Vision tests while
    /// iterating on something else.
    static var skipRealVision: Bool {
        if ProcessInfo.processInfo.environment["KLIP_SKIP_VISION_TESTS"] == "1" {
            print("  [skipped] real Vision test (KLIP_SKIP_VISION_TESTS=1)")
            return true
        }
        return false
    }

    static func testRealVision() throws {
        if skipRealVision { return }
        try withTempDir { dir in
            let url = dir.appendingPathComponent("text.png")
            try renderTextImage(width: 1400, height: 500, lines: ["Invoice 4471", "Quarterly revenue report"], fontSize: 72, to: url)
            let started = Date()
            let outcome = ImageAnalysisService.analyze(imageAt: url)
            print("  [timing] first real analysis in this run: \(Int(Date().timeIntervalSince(started) * 1000)) ms (includes Vision's one-time model preparation when cold)")
            guard case .analyzed(let analysis) = outcome else {
                throw TestFailure(message: "expected .analyzed, got \(outcome)", file: #file, line: #line)
            }
            let text = analysis.text.lowercased()
            try expect(text.contains("invoice"), "OCR reads the drawn text (got \(analysis.text.debugDescription))")
            try expect(text.contains("quarterly"), "second line too (got \(analysis.text.debugDescription))")
            for label in analysis.labels {
                try expect(label == label.lowercased() && !label.contains("_"), "labels are normalized: \(label)")
            }
            print("  [labels] text image: \(analysis.labels)")
        }
    }

    /// Rough timing of one analysis of a screenshot-sized image (2880x1800,
    /// 40 lines of 13 pt Retina text). Prints, and only fails on something
    /// pathological, so a busy machine cannot make the suite flaky.
    static func testScreenshotTiming() throws {
        if skipRealVision { return }
        try withTempDir { dir in
            let url = dir.appendingPathComponent("screenshot.png")
            let words = ["invoice", "total", "meeting", "agenda", "project", "deadline", "budget", "customer", "shipping", "laptop"]
            let lines = (1...40).map { n in "Line \(n): " + (0..<8).map { words[(n * 3 + $0) % words.count] }.joined(separator: " ") }
            try renderTextImage(width: 2880, height: 1800, lines: lines, fontSize: 26, to: url)

            var timings: [Int] = []
            var last: ImageAnalysisService.Outcome = .failed
            for _ in 0..<3 {
                let started = Date()
                last = ImageAnalysisService.analyze(imageAt: url)
                timings.append(Int(Date().timeIntervalSince(started) * 1000))
            }
            guard case .analyzed(let analysis) = last else {
                throw TestFailure(message: "expected .analyzed, got \(last)", file: #file, line: #line)
            }
            let lineCount = analysis.text.split(separator: "\n").count
            print("  [timing] 2880x1800 screenshot, decode + OCR + classify: \(timings.map { "\($0) ms" }.joined(separator: ", ")); \(lineCount) lines; labels \(analysis.labels)")
            try expect(lineCount >= 30, "reads most of the 40 lines (got \(lineCount))")
            try expect(timings.last! < 5_000, "a warm analysis stays well under a few seconds (got \(timings.last!) ms)")
        }
    }

    // MARK: - Queue

    static func testQueueCapture() throws {
        try ClipboardStoreTests.withStore { store, _ in
            let spy = AnalyzerSpy()
            let queue = makeQueue(store, spy: spy, timing: .init(backfillDelay: 1_000))
            queue.start()
            defer { queue.stop() }

            store.add(ClipboardItem.text("older text"))
            let clip = try storedImage(store, at: Date().timeIntervalSince1970)
            store.add(clip)
            // `add` returned before any analysis ran.
            try expect(spy.urls.isEmpty, "the capture never waits on analysis")
            let orderBefore = store.items.map(\.id)
            let before = try unwrap(item(clip.id, in: store))

            try expect(pump { item(clip.id, in: store)?.imageLabels != nil }, "analyzed shortly after capture")
            let after = try unwrap(item(clip.id, in: store))
            try expectEqual(after.ocrText, "hello world")
            try expectEqual(after.imageLabels, ["flower", "plant"])
            try expectEqual(store.items.map(\.id), orderBefore, "the history is not reordered")
            try expectEqual(after.updatedAt, before.updatedAt, "and the clip does not look edited")
            try expectEqual(after.timestamp, before.timestamp)
            try expectEqual(spy.urls.map(\.lastPathComponent), [clip.imageFilename!], "one Vision pass")
        }
    }

    static func testQueueBackfill() throws {
        try ClipboardStoreTests.withStore { store, _ in
            let done = image(at: 4, ocrText: "done", labels: ["done"])
            let todo = try storedImage(store, at: 3)
            let missing = image(at: 2, filename: "missing.png")
            let text = ClipboardItem.text("not an image")
            [done, todo, missing, text].forEach { store.add($0) }

            let spy = AnalyzerSpy()
            let queue = makeQueue(store, spy: spy)
            var idle = 0
            queue.onIdle = { idle += 1 }
            queue.start()
            defer { queue.stop() }

            try expect(pump { idle > 0 }, "the backfill runs dry")
            try expectEqual(spy.urls.map(\.lastPathComponent), [todo.imageFilename!], "only the unanalyzed clip with a file goes to Vision")
            try expectEqual(item(todo.id, in: store)?.imageLabels, ["flower", "plant"])
            try expectEqual(item(missing.id, in: store)?.ocrText, "", "missing file: read, nothing there")
            try expectEqual(item(missing.id, in: store)?.imageLabels, [], "so it is not retried every launch")
            try expectEqual(item(done.id, in: store)?.imageLabels, ["done"], "an analyzed clip is left alone")
            try expectNil(item(text.id, in: store)?.imageLabels, "text clips are not touched")

            // A second backfill finds nothing to do.
            queue.enqueueBackfill()
            let calls = spy.urls.count
            try expect(pump { idle > 1 }, "second pass goes idle")
            try expectEqual(spy.urls.count, calls, "nothing analyzed twice")
        }
    }

    static func testQueueDeletedMidQueue() throws {
        try ClipboardStoreTests.withStore { store, _ in
            let third = try storedImage(store, at: 1)
            let second = try storedImage(store, at: 2)
            let first = try storedImage(store, at: 3)
            [third, second, first].forEach { store.add($0) }   // newest (first) ends up on top

            let spy = AnalyzerSpy()
            spy.hold(first.imageFilename!)
            let queue = makeQueue(store, spy: spy)
            var idle = false
            queue.onIdle = { idle = true }
            queue.start()
            defer { queue.stop() }

            try expect(pump { spy.urls.count == 1 }, "the first clip is in flight")
            store.delete(second)   // waiting in the queue
            store.delete(first)    // in flight
            spy.release(first.imageFilename!)

            try expect(pump { idle }, "the queue runs dry")
            try expectEqual(spy.urls.map(\.lastPathComponent), [first.imageFilename!, third.imageFilename!], "the deleted waiting clip is skipped")
            try expectEqual(item(third.id, in: store)?.imageLabels, ["flower", "plant"])
            try expect(store.trashedItems.allSatisfy { $0.imageLabels == nil }, "a result for a deleted clip is dropped, not applied to the trash")
        }
    }

    static func testQueueFailure() throws {
        try ClipboardStoreTests.withStore { store, _ in
            let clip = try storedImage(store, at: 1)
            store.add(clip)
            let spy = AnalyzerSpy(.failed)
            let queue = makeQueue(store, spy: spy)
            var idle = 0
            queue.onIdle = { idle += 1 }
            queue.start()
            defer { queue.stop() }

            try expect(pump { idle > 0 }, "idle after the failure")
            try expectNil(item(clip.id, in: store)?.imageLabels, "a Vision failure records nothing: next launch tries again")
            try expectNil(item(clip.id, in: store)?.ocrText)

            store.requestImageAnalysis(for: clip)
            queue.enqueueBackfill()
            _ = pump(until: { idle > 1 }, timeout: 0.5)
            try expectEqual(spy.urls.count, 1, "but not again this session, so a persistent failure cannot spin")
        }
    }

    static func testQueueStopFlushes() throws {
        try ClipboardStoreTests.withStore { store, dir in
            let second = try storedImage(store, at: 1)
            let first = try storedImage(store, at: 2)
            [second, first].forEach { store.add($0) }

            let spy = AnalyzerSpy()
            spy.hold(second.imageFilename!)
            let queue = makeQueue(store, spy: spy)   // batch 100, interval 1000 s: nothing flushes on its own
            queue.start()

            try expect(pump { spy.urls.count == 2 }, "first done (buffered), second in flight")
            try expectNil(item(first.id, in: store)?.imageLabels, "backfill results wait in the buffer")

            queue.stop()
            try expectEqual(item(first.id, in: store)?.imageLabels, ["flower", "plant"], "stop applies the buffer")
            store.flushPendingSave()
            try expectEqual(
                try ClipboardStoreTests.readHistoryFile(dir).items.first { $0.id == first.id }?.imageLabels,
                ["flower", "plant"],
                "and it reaches disk with the quit-time flush"
            )

            spy.release(second.imageFilename!)
            _ = pump(until: { false }, timeout: 0.3)
            try expectNil(item(second.id, in: store)?.imageLabels, "the in-flight result after stop is dropped")
        }
    }

    static func testQueueSyncNotifiedOnce() throws {
        try ClipboardStoreTests.withStore { store, dir in
            let clips = try (1...5).map { try storedImage(store, at: TimeInterval($0)) }
            clips.forEach { store.add($0) }

            var pushes = 0
            store.onLocalMutation = { pushes += 1 }
            var timing = fastTiming
            timing.flushBatchSize = 2
            let spy = AnalyzerSpy()
            let queue = makeQueue(store, spy: spy, timing: timing)
            var idle = false
            queue.onIdle = { idle = true }
            queue.start()
            defer { queue.stop() }

            try expect(pump { idle }, "backfill finishes")
            try expect(store.items.allSatisfy { !$0.needsImageAnalysis }, "all five analyzed")
            try expectEqual(pushes, 1, "three batches, one sync notification")
            store.flushPendingSave()
            try expect(
                try ClipboardStoreTests.readHistoryFile(dir).items.allSatisfy { $0.imageLabels == ["flower", "plant"] },
                "every batch was saved locally"
            )
        }
    }

    static func testQueueDeferred() throws {
        try ClipboardStoreTests.withStore { store, _ in
            let old = try storedImage(store, at: 1)
            store.add(old)
            let spy = AnalyzerSpy()
            let queue = makeQueue(store, spy: spy, deferBackfill: true)
            queue.start()
            defer { queue.stop() }

            _ = pump(until: { false }, timeout: 0.3)
            try expect(spy.urls.isEmpty, "a hot Mac / Low Power Mode holds the backfill")

            let fresh = try storedImage(store, at: 2)
            store.add(fresh)
            try expect(pump { item(fresh.id, in: store)?.imageLabels != nil }, "a capture is still read")

            store.requestImageAnalysis(for: old)
            try expect(pump { item(old.id, in: store)?.imageLabels != nil }, "and so is an explicit request")
        }
    }

    // MARK: - Helpers

    static func unwrap<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) throws -> T {
        guard let value else { throw TestFailure(message: "unexpected nil", file: file, line: line) }
        return value
    }
}
