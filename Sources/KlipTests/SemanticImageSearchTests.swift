import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import BenchTestKit
@testable import Klip

// Smart image search (MobileCLIP): the tokenizer, the embedding index and
// its file, the relevance rule, query screening, the engine without a
// model, the background queue driven by a fake embedder, and - skippable -
// the real model: token ids, embeddings, a synthetic end-to-end sanity
// check that needs no personal data, and timing/memory measurements.
//
// Real-model tests use `KLIP_CLIP_MODEL_DIR`, else `Models.noindex/
// MobileCLIP` in the checkout (`scripts/fetch-clip-model.sh`); they are
// skipped when neither exists, or with `KLIP_SKIP_CLIP_TESTS=1`.

enum SemanticImageSearchTests {
    static let tests: [(String, () throws -> Void)] = [
        // Tokenizer, no model
        ("tokenizer_clean_normalizesLikeTheReference", testClean),
        ("tokenizer_syntheticVocabulary_bpeMergesByRank", testSyntheticBPE),
        ("tokenizer_contextIsExactly77_truncatesKeepingEndToken", testTokenLayout),
        // Encoder helpers, no model
        ("encoder_normalized_unitLength_zeroStaysZero", testNormalized),
        ("encoder_inputImage_centerCrop256_overWhite", testInputPixelBuffer),
        ("files_locate_prefersCompiled_needsAllFour_honorsOverride", testLocateFiles),
        // Index
        ("index_persistsAsFloat16_roundTrips", testIndexRoundTrip),
        ("index_fingerprint_changesWithTheBytes", testFingerprint),
        ("index_retainOnly_dropsDeleted_swapRemoveKeepsRowsRight", testIndexRetain),
        ("index_corruptOrForeignFile_isDiscardedAndRebuilt", testIndexCorrupt),
        ("index_scores_matchNaiveDotProducts", testIndexScores),
        // Engine without a model
        ("engine_unavailable_answersNothing", testUnavailable),
        ("engine_adjustedScores_backgroundAndTypographicPenalty", testAdjustedScores),
        ("rule_floorWindowZAndCap", testRule),
        ("query_screening_table", testVisualQuery),
        ("query_prompts_templatesUnlessMediumNamed", testPrompts),
        // Queue with a fake embedder
        ("queue_capture_isAnalyzedAndEmbedded", testQueueCaptureEmbeds),
        ("queue_backfill_embedsMissingAndStale_skipsCurrent", testQueueBackfillEmbeds),
        ("queue_followsHistory_syncArrivalEmbedded_purgedDropped", testQueueFollowsHistory),
        ("queue_encoderFailure_notStored_notRetried", testQueueEncoderFailure),
        ("queue_unavailableEmbedder_isNeverAsked", testQueueUnavailableEmbedder),
        ("queue_work_realVision_sharesOneDecodeWithTheEncoder", testWorkSharesDecode),
        // Real model
        ("real_tokenizer_matchesReferenceIDs", testRealTokenizer),
        ("real_embeddings_unitLength_andSensible", testRealEmbeddings),
        ("real_syntheticImages_endToEnd", testRealEndToEnd),
        ("real_captureThroughQueue_isFoundByMeaning", testRealThroughQueue),
        ("real_measurements", testRealMeasurements),
    ]

    // MARK: - Harness

    static var modelDirectory: URL? {
        if let override = ProcessInfo.processInfo.environment[MobileCLIPFiles.overrideEnvironmentKey], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Models.noindex/MobileCLIP", isDirectory: true)
    }

    /// The model files, or `nil` (with a note) when the real-model tests
    /// should be skipped.
    static func realFiles() -> MobileCLIPFiles? {
        if ProcessInfo.processInfo.environment["KLIP_SKIP_CLIP_TESTS"] == "1" {
            print("  [skipped] real MobileCLIP test (KLIP_SKIP_CLIP_TESTS=1)")
            return nil
        }
        guard let files = MobileCLIPFiles.locate(in: modelDirectory) else {
            print("  [skipped] real MobileCLIP test: no model (run scripts/fetch-clip-model.sh or set KLIP_CLIP_MODEL_DIR)")
            return nil
        }
        return files
    }

    /// Where the tests compile `.mlpackage`s to: kept between runs (the
    /// compile is keyed by the package), outside the user's Caches.
    static let testCompiledCache = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("KlipTests-MobileCLIP-compiled", isDirectory: true)

    nonisolated static func unitVector(seed: Int, dimension: Int = MobileCLIPEncoder.dimension) -> [Float] {
        var generator = SeededGenerator(seed: UInt64(seed))
        return MobileCLIPEncoder.normalized((0..<dimension).map { _ in Float.random(in: -1...1, using: &generator) })
    }

    nonisolated struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static func fingerprint(_ n: Int) -> ImageFingerprint {
        ImageFingerprint(nameHash: UInt64(n), size: Int64(n * 10), modifiedMilliseconds: Int64(n * 100))
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    /// A `width` x `height` image drawn by `draw` over `background`.
    static func makeImage(width: Int, height: Int, background: NSColor = .white, draw: (CGContext) -> Void = { _ in }) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(background.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(context)
        return context.makeImage()!
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw TestFailure(message: "no PNG destination", file: #file, line: #line)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw TestFailure(message: "could not write PNG", file: #file, line: #line)
        }
    }

    /// An analyzed (or not) image clip whose asset is a real PNG.
    static func storedPNG(
        _ store: ClipboardStore,
        at seconds: TimeInterval,
        width: Int = 900,
        height: Int = 600,
        color: NSColor = .systemTeal,
        analyzed: Bool = false
    ) throws -> ClipboardItem {
        let image = makeImage(width: width, height: height, background: color)
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        guard let filename = store.saveImage(data as Data, fileExtension: "png") else {
            throw TestFailure(message: "saveImage failed", file: #file, line: #line)
        }
        return ImageAnalysisTests.image(
            at: seconds, filename: filename,
            ocrText: analyzed ? "" : nil, labels: analyzed ? [] : nil
        )
    }

    /// Runs `operation` off the main actor and pumps the run loop until it
    /// finishes (the tests run on the main thread).
    static func awaitResult<T: Sendable>(_ operation: @escaping @Sendable () async -> T, timeout: TimeInterval = 30) -> T? {
        let box = Box<T>()
        Task.detached { box.set(await operation()) }
        _ = ImageAnalysisTests.pump(until: { box.get() != nil }, timeout: timeout)
        return box.get()
    }

    nonisolated final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T?
        func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
        func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// An `ImageEmbedding` over a real index, with a deterministic "model":
    /// the vector depends on the image's size, so tests can tell which
    /// decode it was given.
    nonisolated final class FakeEmbedder: ImageEmbedding, @unchecked Sendable {
        let index: ImageEmbeddingIndex
        private let lock = NSLock()
        private var sizes: [(width: Int, height: Int)] = []
        private var available: Bool
        private var failing = false

        init(directory: URL, available: Bool = true) {
            index = ImageEmbeddingIndex(directory: directory)
            index.saveDelay = 0.05
            self.available = available
        }

        var computedSizes: [(width: Int, height: Int)] {
            lock.lock(); defer { lock.unlock() }
            return sizes
        }

        func setFailing(_ value: Bool) { lock.lock(); failing = value; lock.unlock() }

        var canEmbed: Bool { lock.lock(); defer { lock.unlock() }; return available }
        func missingEmbeddings(among ids: [UUID]) -> Set<UUID> { index.missing(among: ids) }
        func embeddingNeeded(for id: UUID, fingerprint: ImageFingerprint) -> Bool {
            index.fingerprint(for: id) != fingerprint
        }
        func computeEmbedding(for image: CGImage) -> [Float]? {
            lock.lock()
            sizes.append((image.width, image.height))
            let fail = failing
            lock.unlock()
            return fail ? nil : SemanticImageSearchTests.unitVector(seed: image.width)
        }
        func storeEmbedding(_ embedding: [Float]?, fingerprint: ImageFingerprint, for id: UUID) {
            index.set(embedding, fingerprint: fingerprint, for: id)
        }
        func retainEmbeddings(for liveIDs: Set<UUID>) { index.retainOnly(liveIDs) }
        func flushEmbeddings() { index.flush() }
    }

    static let fastTiming = ImageAnalysisQueue.Timing(
        backfillDelay: 0, backfillPause: 0, flushBatchSize: 100, flushInterval: 1_000,
        deferRetry: 1_000, reconcileDelay: 0.05
    )

    // MARK: - Tokenizer, no model

    static func testClean() throws {
        try expectEqual(CLIPTokenizer.clean("  A Photo \n\t of   a DOG  "), "a photo of a dog", "whitespace collapsed, trimmed, lowercased")
        try expectEqual(CLIPTokenizer.clean("man\u{2019}s \u{201C}car\u{201D}"), "man's \"car\"", "curly quotes straightened, as ftfy does")
        try expectEqual(CLIPTokenizer.clean("cafe\u{0301}"), "caf\u{00E9}", "NFC")
        try expectEqual(CLIPTokenizer.clean("a<|endoftext|>b <|STARTOFTEXT|>"), "a b", "special-token strings typed by the user are removed")
        try expectEqual(CLIPTokenizer.clean("bell\u{0007}ring"), "bell ring", "control characters act as spaces")
        try expectEqual(CLIPTokenizer.clean(" \n "), "", "blank")
    }

    /// A tiny merges file where every merge is visible, so the BPE loop is
    /// checked independently of the real 49k-merge file. Merge rank `r` is
    /// token `512 + r`: "l o" 512, "lo w" 513, "e r</w>" 514, "low er</w>"
    /// 515, "lo w</w>" 516, "n e" 517, "ne w" 518, "e s" 519, "es t</w>"
    /// 520, "new est</w>" 521, "! !</w>" 522. No final newline, on purpose.
    static func withSyntheticTokenizer(_ body: (CLIPTokenizer) throws -> Void) throws {
        try withTempDir { dir in
            let merges = ["#version: 0.2", "l o", "lo w", "e r</w>", "low er</w>", "lo w</w>", "n e", "ne w", "e s", "es t</w>", "new est</w>", "! !</w>"]
            let url = dir.appendingPathComponent("merges.txt")
            try merges.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            try body(try CLIPTokenizer(mergesURL: url, mergeLimit: merges.count - 1))

            try (merges + ["x y"]).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            _ = try CLIPTokenizer(mergesURL: url, mergeLimit: merges.count - 1)   // extra lines are ignored
            do {
                _ = try CLIPTokenizer(mergesURL: url, mergeLimit: 50)
                throw TestFailure(message: "too few merges must throw", file: #file, line: #line)
            } catch is CLIPTokenizer.LoadError {}
            try (merges.prefix(3) + ["zz qq"]).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            do {
                _ = try CLIPTokenizer(mergesURL: url, mergeLimit: 3)
                throw TestFailure(message: "a merge of unknown tokens must throw", file: #file, line: #line)
            } catch is CLIPTokenizer.LoadError {}
        }
    }

    static func testSyntheticBPE() throws {
        try withSyntheticTokenizer { tokenizer in
            func bpe(_ word: String) -> [Int32] { tokenizer.bpe(Array(word.utf8)) }
            try expectEqual(bpe("lower"), [515], "merges applied by rank until none applies")
            try expectEqual(bpe("low"), [516], "low</w>")
            try expectEqual(bpe("newest"), [521])
            try expectEqual(bpe("lowest"), [513, 520], "\"low\" + \"est</w>\": stops when no adjacent pair is a known merge")
            let vocabulary = tokenizer.vocabulary()
            try expectEqual(vocabulary["lower</w>"], 515, "derived vocabulary")
            try expectEqual(vocabulary["est</w>"], 520)
            try expectEqual(vocabulary["!"], 0, "the first byte token")
            try expectEqual(bpe("t"), [try unwrap(vocabulary["t</w>"])], "a single character is its end-of-word form")
            try expectEqual(vocabulary.count, 512 + 11 + 2)
            try expectEqual(tokenizer.encode("Lower  NEWEST!!"), [515, 521, 522], "lowercased, split into words and punctuation runs")
        }
    }

    static func testTokenLayout() throws {
        try withSyntheticTokenizer { tokenizer in
            let empty = tokenizer.tokenIDs(for: "")
            try expectEqual(empty.count, 77)
            try expectEqual(Array(empty.prefix(3)), [49_406, 49_407, 0], "start, end, zero padding")
            let long = tokenizer.tokenIDs(for: Array(repeating: "lower", count: 200).joined(separator: " "))
            try expectEqual(long.count, 77, "always exactly the context length")
            try expectEqual(long.first, 49_406)
            try expectEqual(long.last, 49_407, "the end token survives truncation, as in open_clip")
            try expect(!long.contains(0), "no padding when full")
        }
    }

    // MARK: - Encoder helpers

    static func testNormalized() throws {
        let vector = MobileCLIPEncoder.normalized([3, 4])
        try expect(abs(vector[0] - 0.6) < 1e-6 && abs(vector[1] - 0.8) < 1e-6, "3-4-5")
        try expectEqual(MobileCLIPEncoder.normalized([0, 0, 0]), [0, 0, 0], "zero stays zero, no NaN")
        let random = unitVector(seed: 7)
        try expect(abs(dot(random, random) - 1) < 1e-5, "unit length")
    }

    static func testInputPixelBuffer() throws {
        try expectEqual(MobileCLIPEncoder.centerSquare(width: 1000, height: 400), CGRect(x: 300, y: 0, width: 400, height: 400))
        try expectEqual(MobileCLIPEncoder.centerSquare(width: 300, height: 900), CGRect(x: 0, y: 300, width: 300, height: 300))

        // Left third red, middle third green, right third blue, 900x300:
        // the centered square is the green third only.
        let striped = makeImage(width: 900, height: 300) { context in
            context.setFillColor(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
            context.setFillColor(NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1).cgColor)
            context.fill(CGRect(x: 300, y: 0, width: 300, height: 300))
            context.setFillColor(NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1).cgColor)
            context.fill(CGRect(x: 600, y: 0, width: 300, height: 300))
        }
        guard let buffer = MobileCLIPEncoder.inputPixelBuffer(for: striped) else {
            throw TestFailure(message: "no pixel buffer", file: #file, line: #line)
        }
        try expectEqual(CVPixelBufferGetWidth(buffer), 256)
        try expectEqual(CVPixelBufferGetHeight(buffer), 256)
        try expectEqual(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_32BGRA)
        func pixel(_ x: Int, _ y: Int, in buffer: CVPixelBuffer) -> (b: UInt8, g: UInt8, r: UInt8) {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
            return (base[offset], base[offset + 1], base[offset + 2])
        }
        for (x, y) in [(5, 5), (128, 128), (250, 250)] {
            let p = pixel(x, y, in: buffer)
            try expect(p.g > 200 && p.r < 40 && p.b < 40, "only the green middle is kept (\(x),\(y): \(p))")
        }

        // Fully transparent input: composited over white, not left black.
        let clear = makeImage(width: 64, height: 64, background: .clear)
        let p = pixel(10, 10, in: MobileCLIPEncoder.inputPixelBuffer(for: clear)!)
        try expect(p.r > 250 && p.g > 250 && p.b > 250, "transparent pixels become white (\(p))")
    }

    static func testLocateFiles() throws {
        try withTempDir { dir in
            try expectNil(MobileCLIPFiles.locate(in: dir), "empty folder: unavailable")
            try expectNil(MobileCLIPFiles.locate(in: nil))
            let manager = FileManager.default
            for name in ["mobileclip_s2_image.mlpackage", "mobileclip_s2_text.mlpackage", "mobileclip_s2_text.mlmodelc"] {
                try manager.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            try expectNil(MobileCLIPFiles.locate(in: dir), "merges missing: unavailable")
            try Data("#version".utf8).write(to: dir.appendingPathComponent("clip-merges.txt"))
            let files = try unwrap(MobileCLIPFiles.locate(in: dir))
            try expectEqual(files.imageEncoder.lastPathComponent, "mobileclip_s2_image.mlpackage")
            try expectEqual(files.textEncoder.lastPathComponent, "mobileclip_s2_text.mlmodelc", "a compiled model wins over a package")

            try expectEqual(
                MobileCLIPFiles.defaultDirectory(environment: ["KLIP_CLIP_MODEL_DIR": dir.path])?.standardizedFileURL,
                dir.standardizedFileURL,
                "the dev/test override"
            )
            try expectEqual(
                MobileCLIPFiles.defaultDirectory(environment: [:], bundle: .main)?.lastPathComponent,
                "MobileCLIP",
                "otherwise Contents/Resources/MobileCLIP of the app"
            )
        }
    }

    // MARK: - Index

    static func testIndexRoundTrip() throws {
        try withTempDir { dir in
            let index = ImageEmbeddingIndex(directory: dir)
            let ids = (0..<3).map { _ in UUID() }
            for (n, id) in ids.enumerated() { index.set(unitVector(seed: n), fingerprint: fingerprint(n), for: id) }
            index.set(nil, fingerprint: fingerprint(9), for: ids[2])   // replaced by the unreadable marker
            index.flush()

            let file = dir.appendingPathComponent(ImageEmbeddingIndex.fileName)
            let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int
            try expectEqual(size, ImageEmbeddingIndex.headerSize + 3 * ImageEmbeddingIndex.recordSize + 8, "Float16 records: ~1 KB per image")

            let reloaded = ImageEmbeddingIndex(directory: dir)
            try expectEqual(reloaded.count, 3)
            try expectNil(reloaded.lastLoadProblem)
            for n in 0..<2 {
                let vector = try unwrap(reloaded.embedding(for: ids[n]))
                let original = unitVector(seed: n)
                let worst = zip(vector, original).map { abs($0 - $1) }.max() ?? 1
                try expect(worst < 1e-3, "Float16 precision (worst \(worst))")
                try expect(abs(dot(vector, original) - 1) < 1e-3, "cosine with the original ~1")
                try expectEqual(reloaded.fingerprint(for: ids[n]), fingerprint(n))
            }
            try expectEqual(reloaded.embedding(for: ids[2]), [Float](repeating: 0, count: 512), "the unreadable marker is a zero vector")
            try expectEqual(reloaded.fingerprint(for: ids[2]), fingerprint(9))
        }
    }

    static func testFingerprint() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("a.png")
            try expectNil(ImageFingerprint.of(fileAt: url), "missing file: no fingerprint")
            try Data([1, 2, 3]).write(to: url)
            let first = try unwrap(ImageFingerprint.of(fileAt: url))
            try expectEqual(ImageFingerprint.of(fileAt: url), first, "stable")
            try Data([1, 2, 3, 4]).write(to: url)
            try expect(ImageFingerprint.of(fileAt: url) != first, "new bytes, new fingerprint")
            try expectEqual(ImageFingerprint.nameHash("a.png"), ImageFingerprint.nameHash("a.png"), "stable across calls (not Hasher)")
            try expect(ImageFingerprint.nameHash("a.png") != ImageFingerprint.nameHash("b.png"), "names differ")

            let engine = MobileCLIPImageSearch(files: nil, indexDirectory: dir)
            let fake = FakeEmbedder(directory: dir.appendingPathComponent("fake"))
            let id = UUID()
            let current = try unwrap(ImageFingerprint.of(fileAt: url))
            try expect(fake.embeddingNeeded(for: id, fingerprint: current), "no entry: needed")
            fake.storeEmbedding(unitVector(seed: 1), fingerprint: current, for: id)
            try expect(!fake.embeddingNeeded(for: id, fingerprint: current), "same bytes: current")
            try expect(fake.embeddingNeeded(for: id, fingerprint: fingerprint(1)), "other bytes: stale")
            try expect(!engine.embeddingNeeded(for: id, fingerprint: current), "without a model nothing is ever needed")
        }
    }

    static func testIndexRetain() throws {
        try withTempDir { dir in
            let index = ImageEmbeddingIndex(directory: dir)
            let ids = (0..<5).map { _ in UUID() }
            for (n, id) in ids.enumerated() { index.set(unitVector(seed: n), fingerprint: fingerprint(n), for: id) }
            let removed = index.retainOnly([ids[1], ids[4]])
            try expectEqual(removed, 3)
            try expectEqual(index.count, 2)
            try expectEqual(index.missing(among: ids), [ids[0], ids[2], ids[3]])
            // ids[4] was the last row and moved into a hole: still its own vector.
            try expect(abs(dot(try unwrap(index.embedding(for: ids[4])), unitVector(seed: 4)) - 1) < 1e-5, "moved row keeps its vector")
            try expectEqual(index.fingerprint(for: ids[4]), fingerprint(4), "and its fingerprint")
            try expectEqual(index.retainOnly([ids[1], ids[4]]), 0, "nothing more to drop")
            index.flush()
            try expectEqual(ImageEmbeddingIndex(directory: dir).count, 2, "the drop is saved")
        }
    }

    static func testIndexCorrupt() throws {
        try withTempDir { dir in
            let file = dir.appendingPathComponent(ImageEmbeddingIndex.fileName)
            func writeValid() throws -> Data {
                let index = ImageEmbeddingIndex(directory: dir)
                index.retainOnly([])
                for n in 0..<4 { index.set(unitVector(seed: n), fingerprint: fingerprint(n), for: UUID()) }
                index.flush()
                return try Data(contentsOf: file)
            }
            let valid = try writeValid()
            try expectEqual(ImageEmbeddingIndex(directory: dir).count, 4, "sanity: a valid file loads")

            var cases: [(String, Data)] = [
                ("garbage", Data("definitely not an index".utf8)),
                ("empty", Data()),
                ("truncated", valid.prefix(valid.count - 100)),
            ]
            var flipped = valid
            flipped[ImageEmbeddingIndex.headerSize + 60] ^= 0xFF
            cases.append(("a flipped byte", flipped))
            var foreign = valid
            foreign[12] ^= 0x01   // model tag
            cases.append(("another model's tag", foreign))
            var future = valid
            future[4] = 99   // version
            cases.append(("an unknown version", future))

            for (name, bytes) in cases {
                try bytes.write(to: file)
                let index = ImageEmbeddingIndex(directory: dir)
                try expectEqual(index.count, 0, "\(name): starts empty")
                try expectNotNil(index.lastLoadProblem, "\(name): the problem is noted")
                try expect(!FileManager.default.fileExists(atPath: file.path), "\(name): the bad file is removed")
                // ...and the index works and saves normally afterwards.
                let id = UUID()
                index.set(unitVector(seed: 3), fingerprint: fingerprint(3), for: id)
                index.flush()
                let reloaded = ImageEmbeddingIndex(directory: dir)
                try expectEqual(reloaded.count, 1, "\(name): rebuilt")
                try expect(reloaded.contains(id), "\(name): the new entry is there")
            }
        }
    }

    static func testIndexScores() throws {
        try withTempDir { dir in
            let index = ImageEmbeddingIndex(directory: dir)
            let ids = (0..<20).map { _ in UUID() }
            for (n, id) in ids.enumerated() { index.set(unitVector(seed: n), fingerprint: fingerprint(n), for: id) }
            let queries = [unitVector(seed: 100), unitVector(seed: 101), unitVector(seed: 102)]
            let (rows, scores) = index.scores(for: queries)
            try expectEqual(rows.count, 20)
            for (q, query) in queries.enumerated() {
                for (row, id) in rows.enumerated() {
                    let expected = dot(try unwrap(index.embedding(for: id)), query)
                    try expect(abs(scores[q][row] - expected) < 1e-5, "vDSP matches a naive dot product")
                }
            }
            let (noRows, noScores) = ImageEmbeddingIndex(directory: dir.appendingPathComponent("empty")).scores(for: queries)
            try expect(noRows.isEmpty && noScores.allSatisfy(\.isEmpty), "empty index: empty scores")
        }
    }

    // MARK: - Engine without a model

    static func testUnavailable() throws {
        try withTempDir { dir in
            let engine = MobileCLIPImageSearch(files: nil, indexDirectory: dir)
            try expect(!engine.isAvailable, "no model files: unavailable")
            try expect(!engine.canEmbed, "and the queue is told not to embed")
            engine.index.set(unitVector(seed: 1), fingerprint: fingerprint(1), for: UUID())
            try expectEqual(engine.missingEmbeddings(among: [UUID()]), [], "asks for nothing")
            try expectNil(engine.computeEmbedding(for: makeImage(width: 10, height: 10)))
            let answer = awaitResult { await engine.matches(for: "woman") }
            try expectEqual(answer, [:], "matches is empty")
            try expectEqual(awaitResult { await NoSemanticImageSearch.shared.matches(for: "woman") }, [:])
        }
    }

    static func testAdjustedScores() throws {
        try withTempDir { dir in
            let engine = MobileCLIPImageSearch(files: nil, indexDirectory: dir)
            // Axis-aligned vectors make every cosine obvious.
            func axis(_ values: [Int: Float]) -> [Float] {
                var v = [Float](repeating: 0, count: 512)
                for (i, x) in values { v[i] = x }
                return v
            }
            let photo = UUID(), textShot = UUID(), hub = UUID()
            engine.index.set(MobileCLIPEncoder.normalized(axis([0: 0.3, 3: 1])), fingerprint: fingerprint(1), for: photo)
            engine.index.set(MobileCLIPEncoder.normalized(axis([0: 0.2, 1: 0.4, 3: 1])), fingerprint: fingerprint(2), for: textShot)
            engine.index.set(MobileCLIPEncoder.normalized(axis([0: 0.3, 2: 0.3, 3: 1])), fingerprint: fingerprint(3), for: hub)
            let query = axis([0: 1])
            let background = axis([2: 1])
            let vectors = MobileCLIPImageSearch.QueryVectors(
                query: query,
                adjusted: zip(query, background).map { $0 - $1 },
                typographic: axis([1: 1]),
                typographicWeight: 2
            )
            let (ids, scores) = engine.adjustedScores(vectors)
            var byID: [UUID: Float] = [:]
            for (row, id) in ids.enumerated() { byID[id] = scores[row] }
            let photoRaw = MobileCLIPEncoder.normalized(axis([0: 0.3, 3: 1]))[0]
            try expect(abs(byID[photo]! - photoRaw) < 1e-5, "a photo: its raw score, no penalty")
            try expect(byID[textShot]! < 0, "an image closer to 'text that says ...' than to the query is pushed below zero (weight 2)")
            try expect(byID[hub]! < byID[photo]!, "an image close to the background is pushed down")

            var noPenalty = vectors
            noPenalty.typographicWeight = 0
            let (ids2, plain) = engine.adjustedScores(noPenalty)
            let textRow = try unwrap(ids2.firstIndex(of: textShot))
            try expect(plain[textRow] > 0, "a text-like query (weight 0) leaves text images alone")

            // The weight fades from full to nothing across the textness range.
            let range = MobileCLIPImageSearch.textnessRange
            try expectEqual(MobileCLIPImageSearch.typographicWeight(textness: 0.77, maximum: 2), 2, "'woman'-like query: full")
            try expectEqual(MobileCLIPImageSearch.typographicWeight(textness: range.lowerBound, maximum: 2), 2)
            let middle = MobileCLIPImageSearch.typographicWeight(textness: (range.lowerBound + range.upperBound) / 2, maximum: 2)
            try expect(abs(middle - 1) < 1e-4, "halfway: half (\(middle))")
            try expectEqual(MobileCLIPImageSearch.typographicWeight(textness: range.upperBound, maximum: 2), 0)
            try expectEqual(MobileCLIPImageSearch.typographicWeight(textness: 0.95, maximum: 2), 0, "'text document'-like query: none")
        }
    }

    static func testRule() throws {
        let rule = RelevanceRule.standard
        func ids(_ n: Int) -> [UUID] { (0..<n).map { _ in UUID() } }
        func kept(_ scores: [Float], _ rule: RelevanceRule = .standard) -> [Float] {
            let identifiers = ids(scores.count)
            let result = rule.select(ids: identifiers, scores: scores)
            return result.values.sorted(by: >)
        }

        try expectEqual(kept([]), [], "no images")
        try expectEqual(kept([0.05, 0.04, -0.1]), [], "nothing reaches the floor: nothing (a query with nothing to find)")
        try expectEqual(kept([0.20, 0.15, 0.11, 0.09, 0.02]), [0.20, 0.15, 0.11], "few images: floor + window below the best")
        try expectEqual(kept([0.07, 0.061, 0.059]), [0.07, 0.061], "the floor is inclusive-ish: 0.06 and up")

        // A true-match query: ~15 matches well above a bulk around -0.08.
        var generator = SeededGenerator(seed: 1)
        var bulk = (0..<400).map { _ in Float.random(in: -0.18...0.02, using: &generator) }
        let matches: [Float] = [0.165, 0.14, 0.137, 0.13, 0.12, 0.118, 0.104, 0.095, 0.094, 0.09, 0.088, 0.083, 0.073, 0.07, 0.066]
        let woman = kept(bulk + matches)
        try expectEqual(woman, matches, "every match kept, none of the bulk")

        // A generic query: the whole distribution sits higher; the z cut
        // keeps only the outliers although many clear the floor and window.
        bulk = (0..<400).map { _ in Float.random(in: -0.04...0.10, using: &generator) }
        let generic = kept(bulk + [0.15, 0.13])
        try expect(generic.count <= 12, "a generic query keeps a handful (kept \(generic.count))")
        try expect(generic.first == 0.15, "best first")
        var noZ = rule
        noZ.zMinimumCount = .max
        try expect(kept(bulk + [0.15, 0.13], noZ).count > 30, "sanity: without the z cut it would flood")

        // A collection that is mostly the query's kind: the best is not an
        // outlier, and the cap on the z cut still returns the top cluster.
        let bimodal = [Float](repeating: 0.1, count: 40) + [Float](repeating: -0.1, count: 40)
        try expectEqual(kept(bimodal).count, 40, "not nothing")

        // Cap.
        let many = [Float](repeating: 0.2, count: 20) + (0..<100).map { 0.199 - Float($0) * 0.0001 }
        try expectEqual(kept(many).count, rule.maxResults, "at most maxResults")
        try expectEqual(kept(many).first, 0.2, "the best ones")
    }

    static func testVisualQuery() throws {
        let visual: [(String, String)] = [
            ("woman", "woman"), ("  red   car ", "red car"), ("a place for eating", "a place for eating"),
            ("woman+car", "woman car"), ("\"man at a desk\"", "man at a desk"), ("café", "café"),
            ("screenshot of code", "screenshot of code"), ("dog 2", "dog 2"), ("wom", "wom"),
        ]
        for (input, expected) in visual {
            try expectEqual(MobileCLIPImageSearch.visualQuery(input), expected, "visual: \(input)")
        }
        let notVisual = [
            "", "   ", "a", "ab", "12345", "3.14", "12:30 pm 2024", "the", "of the", "a an the",
            "https://example.com/x", "www.example.com", "example.com", "report.pdf", "me@example.com", "@handle",
            "/Users/sam/Desktop", "~/Downloads", "func main() {}", "let x = 1;", "#hashtag", "snake_case_name",
            "猫猫猫", "ありがとう", String(repeating: "long text ", count: 30),
        ]
        for input in notVisual {
            try expectNil(MobileCLIPImageSearch.visualQuery(input), "not visual: \(input.prefix(30))")
        }
    }

    static func testPrompts() throws {
        try expectEqual(
            MobileCLIPImageSearch.prompts(for: "red car"),
            ["a photo of red car.", "a picture of red car.", "an image of red car."]
        )
        try expectEqual(MobileCLIPImageSearch.prompts(for: "drawing of a woman"), ["drawing of a woman"], "medium named: as typed")
        try expectEqual(MobileCLIPImageSearch.prompts(for: "a screenshot of code"), ["a screenshot of code"])
        try expectEqual(MobileCLIPImageSearch.prompts(for: "photos of dogs"), ["photos of dogs"], "plural medium")
        try expectEqual(MobileCLIPImageSearch.prompts(for: "photographer").count, 3, "a word that merely starts like one is not a medium")
    }

    // MARK: - Queue with a fake embedder

    static func makeQueue(_ store: ClipboardStore, embedder: ImageEmbedding, spy: ImageAnalysisTests.AnalyzerSpy) -> ImageAnalysisQueue {
        ImageAnalysisQueue(
            store: store, timing: fastTiming,
            analyzer: { spy.analyze($0) }, embedder: embedder,
            shouldDeferBackfill: { false }
        )
    }

    static func testQueueCaptureEmbeds() throws {
        try ClipboardStoreTests.withStore { store, dir in
            let embedder = FakeEmbedder(directory: dir)
            let spy = ImageAnalysisTests.AnalyzerSpy()
            var timing = fastTiming
            timing.backfillDelay = 1_000
            let queue = ImageAnalysisQueue(store: store, timing: timing, analyzer: { spy.analyze($0) }, embedder: embedder, shouldDeferBackfill: { false })
            queue.start()
            defer { queue.stop() }

            let clip = try storedPNG(store, at: Date().timeIntervalSince1970, width: 3000, height: 2000)
            store.add(clip)
            try expect(embedder.computedSizes.isEmpty, "the capture never waits on the encoder")
            try expect(ImageAnalysisTests.pump { embedder.index.contains(clip.id) && ImageAnalysisTests.item(clip.id, in: store)?.imageLabels != nil }, "analyzed and embedded shortly after capture")
            try expectEqual(spy.urls.count, 1, "one analysis")
            try expectEqual(embedder.computedSizes.count, 1, "one embedding")
            let size = embedder.computedSizes[0]
            try expectEqual(min(size.width, size.height), MobileCLIPEncoder.decodeShortSide, "the encoder gets a small decode, not the full 3000x2000")
            let url = try unwrap(store.imageURL(for: clip))
            try expectEqual(embedder.index.fingerprint(for: clip.id), ImageFingerprint.of(fileAt: url), "stored with the file's fingerprint")
        }
    }

    static func testQueueBackfillEmbeds() throws {
        try ClipboardStoreTests.withStore { store, dir in
            let embedder = FakeEmbedder(directory: dir)
            let missing = try storedPNG(store, at: 5, width: 700, analyzed: true)
            let current = try storedPNG(store, at: 4, width: 710, analyzed: true)
            let stale = try storedPNG(store, at: 3, width: 720, analyzed: true)
            let gone = ImageAnalysisTests.image(at: 2, filename: "not-there.png", ocrText: "", labels: [])
            let broken = try ImageAnalysisTests.storedImage(store, at: 1)   // 4 bytes, not an image
            [missing, current, stale, gone, broken].forEach { store.add($0) }
            store.applyImageAnalyses([broken.id: .empty])

            let currentPrint = try unwrap(ImageFingerprint.of(fileAt: try unwrap(store.imageURL(for: current))))
            embedder.storeEmbedding(unitVector(seed: 1), fingerprint: currentPrint, for: current.id)
            embedder.storeEmbedding(unitVector(seed: 2), fingerprint: fingerprint(99), for: stale.id)

            let spy = ImageAnalysisTests.AnalyzerSpy()
            let queue = makeQueue(store, embedder: embedder, spy: spy)
            queue.start()
            defer { queue.stop() }

            try expect(ImageAnalysisTests.pump { embedder.index.contains(missing.id) && embedder.index.contains(broken.id) && embedder.index.fingerprint(for: stale.id) != fingerprint(99) }, "the backfill embeds what is missing or stale")
            _ = ImageAnalysisTests.pump(until: { queue.isIdle }, timeout: 2)
            try expect(spy.urls.isEmpty, "already-analyzed clips are not re-read by Vision")
            try expectEqual(embedder.computedSizes.map(\.width).sorted(), [
                Int((700.0 * Double(MobileCLIPEncoder.decodeShortSide) / 600).rounded()),
                Int((720.0 * Double(MobileCLIPEncoder.decodeShortSide) / 600).rounded()),
            ].sorted(), "missing and stale embedded; the current one is not recomputed")
            try expectEqual(embedder.index.embedding(for: current.id).map { dot($0, unitVector(seed: 1)) }.map { $0 > 0.999 }, true, "current left alone")
            try expectEqual(embedder.index.embedding(for: broken.id), [Float](repeating: 0, count: 512), "undecodable: the empty marker, so it is not retried")
            try expect(!embedder.index.contains(gone.id), "a missing file: nothing stored")
        }
    }

    static func testQueueFollowsHistory() throws {
        try ClipboardStoreTests.withStore { store, dir in
            let embedder = FakeEmbedder(directory: dir)
            let first = try storedPNG(store, at: 2, width: 650, analyzed: true)
            let second = try storedPNG(store, at: 1, width: 660, analyzed: true)
            [first, second].forEach { store.add($0) }
            let spy = ImageAnalysisTests.AnalyzerSpy()
            let queue = makeQueue(store, embedder: embedder, spy: spy)
            queue.start()
            defer { queue.stop() }
            try expect(ImageAnalysisTests.pump { embedder.index.count == 2 }, "backfill")

            // Arrives analyzed, as a sync pull does: the capture hook never
            // fires for it, the history observer does.
            let synced = try storedPNG(store, at: 3, width: 670, analyzed: true)
            store.add(synced)
            try expect(ImageAnalysisTests.pump { embedder.index.contains(synced.id) }, "an image clip that arrives analyzed still gets embedded")

            store.delete(first)
            _ = ImageAnalysisTests.pump(until: { false }, timeout: 0.3)
            try expect(embedder.index.contains(first.id), "a trashed clip keeps its embedding (it can be restored)")
            store.purgeFromTrash(ids: [first.id])
            try expect(ImageAnalysisTests.pump { !embedder.index.contains(first.id) }, "purged: its embedding is dropped")
            try expect(embedder.index.contains(second.id) && embedder.index.contains(synced.id), "the others stay")

            queue.stop()
            let saved = ImageEmbeddingIndex(directory: dir)
            try expectEqual(saved.count, 2, "stop writes the index")
        }
    }

    static func testQueueEncoderFailure() throws {
        try ClipboardStoreTests.withStore { store, dir in
            let embedder = FakeEmbedder(directory: dir)
            embedder.setFailing(true)
            let clip = try storedPNG(store, at: 1, analyzed: true)
            store.add(clip)
            let spy = ImageAnalysisTests.AnalyzerSpy()
            let queue = makeQueue(store, embedder: embedder, spy: spy)
            queue.start()
            defer { queue.stop() }

            try expect(ImageAnalysisTests.pump { embedder.computedSizes.count == 1 }, "tried once")
            _ = ImageAnalysisTests.pump(until: { false }, timeout: 0.2)
            try expect(!embedder.index.contains(clip.id), "a failure stores nothing: next launch tries again")
            embedder.setFailing(false)
            queue.enqueueBackfill()
            queue.reconcile()
            _ = ImageAnalysisTests.pump(until: { false }, timeout: 0.4)
            try expectEqual(embedder.computedSizes.count, 1, "but not again this session")
        }
    }

    static func testQueueUnavailableEmbedder() throws {
        try ClipboardStoreTests.withStore { store, dir in
            let embedder = FakeEmbedder(directory: dir, available: false)
            let clip = try storedPNG(store, at: 1)
            store.add(clip)
            let spy = ImageAnalysisTests.AnalyzerSpy()
            let queue = makeQueue(store, embedder: embedder, spy: spy)
            var idle = false
            queue.onIdle = { idle = true }
            queue.start()
            defer { queue.stop() }

            try expect(ImageAnalysisTests.pump { idle && ImageAnalysisTests.item(clip.id, in: store)?.imageLabels != nil }, "analysis still runs")
            try expect(embedder.computedSizes.isEmpty, "no model: the encoder is never asked")
            try expectEqual(embedder.index.count, 0)
        }
    }

    /// The app's job path (no injected analyzer): Vision and the encoder get
    /// the same decoded bitmap. Runs real Vision, so it follows
    /// `KLIP_SKIP_VISION_TESTS` like the other real-Vision tests.
    static func testWorkSharesDecode() throws {
        if ImageAnalysisTests.skipRealVision { return }
        try withTempDir { dir in
            let url = dir.appendingPathComponent("page.png")
            try ImageAnalysisTests.renderTextImage(width: 2000, height: 1200, lines: ["Quarterly report", "Revenue"], fontSize: 60, to: url)
            let embedder = FakeEmbedder(directory: dir)
            let result = ImageAnalysisQueue.work(id: UUID(), url: url, analyze: true, analyzed: nil, embedder: embedder)
            guard case .analyzed(let analysis)? = result.analysis else {
                throw TestFailure(message: "expected an analysis, got \(String(describing: result.analysis))", file: #file, line: #line)
            }
            try expect(analysis.text.lowercased().contains("quarterly"), "Vision read the page")
            try expectEqual(embedder.computedSizes.map { "\($0.width)x\($0.height)" }, ["2000x1200"], "the encoder got Vision's decode (short side under 1500: full size), not a second one")
            guard case .embedded(_, let fingerprint)? = result.embedding else {
                throw TestFailure(message: "expected an embedding", file: #file, line: #line)
            }
            try expectEqual(fingerprint, ImageFingerprint.of(fileAt: url))

            let again = ImageAnalysisQueue.work(id: UUID(), url: url, analyze: false, analyzed: nil, embedder: nil)
            try expect(again.analysis == nil && again.embedding == nil, "nothing asked, nothing done")
        }
    }

    // MARK: - Real model

    static func testRealTokenizer() throws {
        guard let files = realFiles() else { return }
        let tokenizer = try CLIPTokenizer(mergesURL: files.merges)
        // The derived vocabulary is exactly the published one.
        let published = files.merges.deletingLastPathComponent().appendingPathComponent("clip-vocab.json")
        if let data = try? Data(contentsOf: published) {
            let vocabulary = try JSONDecoder().decode([String: Int32].self, from: data)
            try expectEqual(vocabulary.count, 49_408)
            try expect(tokenizer.vocabulary() == vocabulary, "vocabulary derived from the merges == clip-vocab.json")
        } else {
            print("  [note] clip-vocab.json not found next to the merges; derived vocabulary not cross-checked")
        }
        // Expected ids from OpenAI CLIP's reference BPE (simple_tokenizer.py
        // logic, 48,894 merges) over the same vocabulary.
        let cases: [(String, [Int32])] = [
            ("a photo of a dog", [320, 1125, 539, 320, 1929]),
            ("A Photo   of a DOG", [320, 1125, 539, 320, 1929]),
            ("hello world", [3306, 1002]),
            ("a man's red car!!", [320, 786, 568, 736, 1615, 748]),
            ("a man\u{2019}s red car!!", [320, 786, 568, 736, 1615, 748]),
            ("screenshot of python code", [12646, 539, 13370, 3217]),
            ("naïve café", [1097, 35689, 563, 15304]),
            ("2024 is 42", [273, 271, 273, 275, 533, 275, 273]),
            ("Don't stop", [847, 713, 1691]),
            ("a place for eating", [320, 1445, 556, 4371]),
            ("supercalifragilisticexpialidocious", [1642, 2857, 13093, 2076, 5868, 26850, 835, 639, 38466]),
            ("a photo of a 🐶", [320, 1125, 539, 320, 10631]),
            ("@user #tag", [287, 7031, 258, 3640]),
            // Apple's demo tokenizer (all 262k merges) encodes these to
            // nothing or to a fragment; the truncated table gets them right.
            ("clipboard", [39712, 1972]),
            ("wireframe", [7558, 6481]),
            ("mobileclip", [9451, 944, 8546]),
        ]
        for (text, body) in cases {
            let expected = [CLIPTokenizer.startToken] + body + [CLIPTokenizer.endToken]
                + [Int32](repeating: 0, count: CLIPTokenizer.contextLength - body.count - 2)
            try expectEqual(tokenizer.tokenIDs(for: text), expected, text)
        }
    }

    static func realEngine(_ dir: URL, files: MobileCLIPFiles) -> MobileCLIPImageSearch {
        MobileCLIPImageSearch(files: files, indexDirectory: dir, compiledCache: testCompiledCache)
    }

    static func testRealEmbeddings() throws {
        guard let files = realFiles() else { return }
        let encoder = MobileCLIPEncoder(files: files, compiledCache: testCompiledCache)
        let texts = try encoder.embed(texts: ["a photo of a dog.", "a photo of a puppy.", "a screenshot of source code."])
        for vector in texts {
            try expectEqual(vector.count, 512)
            try expect(abs(dot(vector, vector) - 1) < 1e-4, "text embeddings are unit length")
        }
        try expect(dot(texts[0], texts[1]) > dot(texts[0], texts[2]) + 0.1, "dog ~ puppy, far from code")

        let red = makeImage(width: 800, height: 600) { context in
            context.setFillColor(NSColor(srgbRed: 0.9, green: 0.05, blue: 0.05, alpha: 1).cgColor)
            context.fillEllipse(in: CGRect(x: 250, y: 150, width: 300, height: 300))
        }
        let first = try encoder.embed(image: red)
        let second = try encoder.embed(image: red)
        try expectEqual(first.count, 512)
        try expect(abs(dot(first, first) - 1) < 1e-4, "image embeddings are unit length")
        try expect(dot(first, second) > 0.999, "deterministic")

        try expectEqual(encoder.releaseIdleModels(force: true).image, false, "release frees the image model")
        try expectEqual(encoder.loadedModels.text, false, "and the text model")
        try expect(dot(try encoder.embed(image: red), first) > 0.999, "and it reloads on demand")
    }

    /// Five synthetic pictures, no personal data: a red circle, a blue
    /// square, a yellow star-ish triangle, and two screenshots of text, one
    /// of which says "woman". Checks the whole query path end to end.
    static func testRealEndToEnd() throws {
        guard let files = realFiles() else { return }
        try withTempDir { dir in
            let engine = realEngine(dir, files: files)
            func shape(_ color: NSColor, _ draw: @escaping (CGContext) -> Void) -> CGImage {
                makeImage(width: 900, height: 700) { context in
                    context.setFillColor(color.cgColor)
                    draw(context)
                }
            }
            let circle = shape(NSColor(srgbRed: 0.9, green: 0.05, blue: 0.05, alpha: 1)) { $0.fillEllipse(in: CGRect(x: 250, y: 150, width: 400, height: 400)) }
            let square = shape(NSColor(srgbRed: 0.05, green: 0.2, blue: 0.9, alpha: 1)) { $0.fill(CGRect(x: 250, y: 150, width: 400, height: 400)) }
            let triangle = shape(NSColor(srgbRed: 0.95, green: 0.8, blue: 0.1, alpha: 1)) { context in
                context.move(to: CGPoint(x: 450, y: 600)); context.addLine(to: CGPoint(x: 200, y: 100)); context.addLine(to: CGPoint(x: 700, y: 100))
                context.closePath(); context.fillPath()
            }
            let wordURL = dir.appendingPathComponent("word.png")
            try ImageAnalysisTests.renderTextImage(width: 1400, height: 900, lines: ["Notes", "woman", "The woman in the story", "woman woman"], fontSize: 64, to: wordURL)
            let otherURL = dir.appendingPathComponent("other.png")
            try ImageAnalysisTests.renderTextImage(width: 1400, height: 900, lines: ["Invoice 4471", "Total due", "Payment terms"], fontSize: 64, to: otherURL)
            let words = try unwrap(ImageAnalysisService.downsampledImage(at: wordURL, maxShortSide: MobileCLIPEncoder.decodeShortSide))
            let invoice = try unwrap(ImageAnalysisService.downsampledImage(at: otherURL, maxShortSide: MobileCLIPEncoder.decodeShortSide))

            var names: [UUID: String] = [:]
            for (n, (name, image)) in [("circle", circle), ("square", square), ("triangle", triangle), ("woman-text", words), ("invoice-text", invoice)].enumerated() {
                let id = UUID()
                names[id] = name
                engine.storeEmbedding(try unwrap(engine.computeEmbedding(for: image)), fingerprint: fingerprint(n), for: id)
            }

            func ranked(_ query: String) throws -> [String] {
                let vectors = try unwrap(engine.queryVectors(for: query))
                let (ids, scores) = engine.adjustedScores(vectors)
                return ids.indices.sorted { scores[$0] > scores[$1] }.map { names[ids[$0]]! }
            }
            func answer(_ query: String) -> [String] {
                let result = awaitResult { await engine.matches(for: query) } ?? [:]
                return result.sorted { $0.value > $1.value }.map { names[$0.key]! }
            }

            try expectEqual(try ranked("red circle").first, "circle", "shape and color")
            try expectEqual(try ranked("blue square").first, "square")
            try expectEqual(try ranked("yellow triangle").first, "triangle")
            for query in ["woman", "red circle", "an invoice", "geometric shapes"] {
                print("  [synthetic] \(query): ranked \(try ranked(query)), matches \(answer(query))")
            }
            try expectEqual(try ranked("a screenshot of text").prefix(2).sorted(), ["invoice-text", "woman-text"], "text screenshots rank above shapes")
            let woman = answer("woman")
            try expect(!woman.contains("woman-text"), "a screenshot that merely says 'woman' is not returned for 'woman'")
            try expect(answer("red circle").first == "circle", "the rule keeps the red circle for 'red circle'")
            try expectEqual(answer("https://example.com"), [], "not a visual query")
        }
    }

    /// The app's wiring with the real engine: clips captured into a store are
    /// embedded by the queue and found by what they show; the index is on
    /// disk in the store's folder after `stop()`.
    static func testRealThroughQueue() throws {
        guard let files = realFiles() else { return }
        try ClipboardStoreTests.withStore { store, dir in
            let engine = realEngine(dir, files: files)
            let spy = ImageAnalysisTests.AnalyzerSpy(.analyzed(ImageAnalysis(text: "", labels: [])))
            var timing = fastTiming
            timing.backfillDelay = 1_000
            let queue = ImageAnalysisQueue(store: store, timing: timing, analyzer: { spy.analyze($0) }, embedder: engine, shouldDeferBackfill: { false })
            queue.start()
            defer { queue.stop() }

            func png(_ draw: @escaping (CGContext) -> Void) throws -> ClipboardItem {
                let image = makeImage(width: 1200, height: 900, draw: draw)
                let data = NSMutableData()
                let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
                let filename = try unwrap(store.saveImage(data as Data, fileExtension: "png"))
                return ImageAnalysisTests.image(at: Date().timeIntervalSince1970, filename: filename)
            }
            let circle = try png { context in
                context.setFillColor(NSColor(srgbRed: 0.9, green: 0.05, blue: 0.05, alpha: 1).cgColor)
                context.fillEllipse(in: CGRect(x: 350, y: 200, width: 500, height: 500))
            }
            let square = try png { context in
                context.setFillColor(NSColor(srgbRed: 0.05, green: 0.2, blue: 0.9, alpha: 1).cgColor)
                context.fill(CGRect(x: 350, y: 200, width: 500, height: 500))
            }
            store.add(circle)
            store.add(square)
            try expect(ImageAnalysisTests.pump(until: { engine.index.count == 2 }, timeout: 30), "both captures embedded in the background")

            let found = awaitResult { await engine.matches(for: "red circle") } ?? [:]
            try expect(found[circle.id] != nil, "found by meaning (got \(found.count) match(es))")
            try expectNil(found[square.id], "the blue square is not a red circle")

            queue.stop()
            try expectEqual(ImageEmbeddingIndex(directory: dir).count, 2, "the index is saved next to the history")

            let encoder = try unwrap(engine.encoder)
            encoder.releaseIdleModels(force: true)
            try expect(!encoder.loadedModels.text, "released")
            engine.prepareForQueries()
            try expect(ImageAnalysisTests.pump(until: { encoder.loadedModels.text }, timeout: 10), "prepareForQueries reloads the text encoder ahead of the next query")
        }
    }

    /// Timing and memory, printed for the record (`[measure]` lines). Fails
    /// only on something pathological, so a busy machine cannot make the
    /// suite flaky.
    static func testRealMeasurements() throws {
        guard let files = realFiles() else { return }
        try withTempDir { dir in
            let before = footprintMB()
            let engine = realEngine(dir, files: files)
            let encoder = try unwrap(engine.encoder)

            // Image: load, then decode + embed of screenshot-sized PNGs.
            let screenshotURL = dir.appendingPathComponent("shot.png")
            try ImageAnalysisTests.renderTextImage(width: 2880, height: 1800, lines: (1...30).map { "Line \($0) of a long document" }, fontSize: 26, to: screenshotURL)
            var started = Date()
            _ = try encoder.embed(image: makeImage(width: 64, height: 64))
            let imageLoad = Date().timeIntervalSince(started)
            let afterImage = footprintMB()
            var decode: [Double] = []
            var embed: [Double] = []
            for _ in 0..<10 {
                started = Date()
                let image = try unwrap(ImageAnalysisService.downsampledImage(at: screenshotURL, maxShortSide: MobileCLIPEncoder.decodeShortSide))
                let decoded = Date()
                _ = try encoder.embed(image: image)
                decode.append(decoded.timeIntervalSince(started) * 1000)
                embed.append(Date().timeIntervalSince(decoded) * 1000)
            }

            // Text: first query (load + background prompts), then a new
            // query, then a cached one.
            started = Date()
            _ = engine.answer("a warm up query")
            let firstQuery = Date().timeIntervalSince(started)
            let afterText = footprintMB()
            started = Date()
            _ = engine.queryVectors(for: "woman with a red umbrella")
            let newQuery = Date().timeIntervalSince(started) * 1000

            // Measured before the big fake indexes below allocate anything.
            let released = encoder.releaseIdleModels(force: true)
            let afterRelease = footprintMB()

            // Scan + rule over 1k and 10k fake embeddings.
            var scans: [Int: Double] = [:]
            for count in [1_000, 10_000] {
                let big = MobileCLIPImageSearch(files: files, indexDirectory: dir.appendingPathComponent("scan\(count)"), compiledCache: testCompiledCache)
                for n in 0..<count { big.index.set(unitVector(seed: n), fingerprint: fingerprint(n), for: UUID()) }
                let vectors = try unwrap(engine.queryVectors(for: "woman with a red umbrella"))
                started = Date()
                let rounds = 5
                for _ in 0..<rounds {
                    let (ids, scores) = big.adjustedScores(vectors)
                    _ = big.rule.select(ids: ids, scores: scores)
                }
                scans[count] = Date().timeIntervalSince(started) * 1000 / Double(rounds)
            }

            func median(_ values: [Double]) -> Int { Int(values.sorted()[values.count / 2].rounded()) }
            print("  [measure] image encoder first load \(Int(imageLoad * 1000)) ms; 2880x1800 PNG decode \(median(decode)) ms + embed \(median(embed)) ms (median of 10)")
            print("  [measure] first query (text encoder load + 32 background prompts + 4 prompts + scan) \(Int(firstQuery * 1000)) ms; a new query's text encoding \(Int(newQuery)) ms")
            print("  [measure] scan + rule, debug build: 1k images \(String(format: "%.2f", scans[1_000]!)) ms, 10k images \(String(format: "%.2f", scans[10_000]!)) ms")
            print("  [measure] footprint: start \(Int(before)) MB, +image encoder \(Int(afterImage)) MB, +text encoder \(Int(afterText)) MB, after release \(Int(afterRelease)) MB (still loaded: \(released))")
            try expect(scans[10_000]! < 200, "10k-image scan stays far from a keystroke's budget even in debug")
            try expect(median(embed) < 1_000, "an embed is well under a second")
        }
    }

    /// `phys_footprint` of this process in MB: what Activity Monitor calls
    /// Memory.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    static func unwrap<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) throws -> T {
        guard let value else { throw TestFailure(message: "unexpected nil", file: file, line: line) }
        return value
    }
}
