import Foundation
import CoreGraphics
import Accelerate
import BenchCore

/// The part of the smart-search engine `ImageAnalysisQueue` drives to keep
/// the embedding index current. A protocol so the queue's tests can use a
/// fake instead of loading a 200 MB model.
///
/// Threading contract: everything except `storeEmbedding` is called on the
/// queue's background work queue, never on the main thread (the first call
/// loads the index file, and `embeddingNeeded` stats the image).
nonisolated protocol ImageEmbedding: AnyObject, Sendable {
    /// False when there is no model (or it failed to load): the queue then
    /// never asks for embeddings.
    var canEmbed: Bool { get }
    /// Ids among `ids` with no stored embedding at all (no file access).
    func missingEmbeddings(among ids: [UUID]) -> Set<UUID>
    /// Whether `id` has no embedding for exactly these image bytes.
    func embeddingNeeded(for id: UUID, fingerprint: ImageFingerprint) -> Bool
    /// The unit-length embedding of `image`, or `nil` when the model failed
    /// (not persisted; the queue does not retry it this session). Blocking.
    func computeEmbedding(for image: CGImage) -> [Float]?
    /// Stores an embedding; `nil` records "could not be decoded" so the
    /// image is not retried until its file changes. Any thread.
    func storeEmbedding(_ embedding: [Float]?, fingerprint: ImageFingerprint, for id: UUID)
    /// Drops the embeddings of clips no longer in the history or trash.
    func retainEmbeddings(for liveIDs: Set<UUID>)
    /// Writes pending index changes now (Klip stopping).
    func flushEmbeddings()
}

/// Smart image search with Apple's MobileCLIP-S2, fully on-device: finds
/// image clips by what they show ("woman", "red car", "a place for eating").
///
/// The app's instance is `MobileCLIPImageSearch.shared`; `KlipFeature` hands
/// it to `ImageAnalysisQueue`, which embeds new captures and backfills old
/// images into `index`, and search asks it through `SemanticImageSearching`.
///
/// ## How a query is answered (`matches(for:)`)
///
/// 1. `visualQuery` drops what cannot be a description of a picture:
///    blank, fewer than 3 letters, only stop words, URLs, e-mail addresses,
///    paths, file names, code, numbers, non-Latin text (the model is
///    English-only). Those return `[:]` without touching the model.
/// 2. The text is embedded with an ensemble of prompt templates ("a photo
///    of ...", "a picture of ...", "an image of ...", averaged), as CLIP
///    zero-shot classification does; a query that already names its medium
///    ("drawing of a woman", "screenshot of code") is used as typed.
/// 3. One matrix product scores every stored image against three vectors
///    (`QueryVectors`), and each image gets
///    `adjusted = cos(image, query) - cos(image, background)
///               - w * max(0, cos(image, typographic) - cos(image, query))`
///    with `w` = 2 for a query about things, fading to 0 for a query about
///    text-bearing images (`typographicWeight(textness:)`).
/// 4. `RelevanceRule` keeps the images whose adjusted score clears an
///    absolute floor, a window below the best, and (with enough images) a
///    z-score over the whole collection.
///
/// ## Why the adjustments (tuned on a real clipboard history, ~430 images)
///
/// - **Background subtraction.** Raw CLIP cosines have no fixed scale and
///   suffer from "hub" images: a blank texture, a generic file icon or a
///   tiny image scores 0.19-0.24 against *every* query, as high as a real
///   match (0.21-0.24 for "a photo of woman"). With raw scores, 6 of the top
///   15 for "woman" and 14 of the top 15 for "people" were such hubs.
///   Subtracting each image's similarity to the mean of 32 generic concept
///   prompts (`backgroundConcepts`) removes them: the same queries went to
///   14/15 and 15/15 relevant. Because it is a mean, it is one extra vector,
///   `image . (query - background)`, so it costs nothing at scan time.
/// - **Typographic penalty.** CLIP reads text: a screenshot of a document
///   containing the word "woman" matched "a photo of woman" at 0.16 raw but
///   `a screenshot of text that says "woman"` at 0.29. An image closer to the
///   "text that says" prompt than to the photo prompt is matched for its
///   words, which OCR search already covers, so the difference is
///   subtracted, twice: a synthetic page with just the word in large type
///   scored 0.28 against the photo prompt and 0.35 against the text one,
///   and a single subtraction left it above the floor. Real photos (whose
///   photo score is the higher one) are untouched; on the tuning history,
///   doubling it changed no person or object query and only removed
///   screenshots matched by their words ("desk laptop" 9 -> 5 results,
///   "asdf" 5 -> 1). For a query *about* text ("chart", "an invoice",
///   "screenshot of code") the "text that says" prompt describes exactly the
///   images wanted, so the penalty fades out there (`textnessRange`).
/// - **The rule.** After adjustment, true matches landed at 0.06-0.17 and
///   the unrelated bulk around -0.1..0.0. A floor alone lets a generic query
///   ("asdf", a partly typed word) match a broad swath of screenshots,
///   because its whole distribution sits higher (mean +0.03 vs -0.08 for
///   "woman"); the z-score cut handles that. A query naming a common kind
///   of image ("screenshot of code") passes the floor for most screenshots;
///   the window below the best keeps the ones that match best. See
///   `RelevanceRule` for the numbers.
///
/// ## Cost (M5 Pro)
///
/// Text encoding ~3 ms per prompt on the CPU (4 prompts, ~13 ms, per new
/// query; the last 32 queries are cached), the scan and rule ~5 ms for
/// 10,000 images even in a debug build. The first query of a session also
/// loads the tokenizer and text encoder (~75 ms) and the 32 background
/// prompts (~100 ms, once per process); `prepareForQueries` does that ahead
/// of time.
nonisolated final class MobileCLIPImageSearch: SemanticImageSearching, ImageEmbedding, @unchecked Sendable {
    /// The app's engine: the bundled (or `KLIP_CLIP_MODEL_DIR`) model and
    /// the index in Klip's data folder. `isAvailable == false` in a build
    /// without the model files.
    static let shared = MobileCLIPImageSearch(
        files: MobileCLIPFiles.locate(in: MobileCLIPFiles.defaultDirectory()),
        indexDirectory: BenchPaths.dataDirectory(feature: "Klip")
    )

    let index: ImageEmbeddingIndex
    let encoder: MobileCLIPEncoder?
    /// `rule` and `typographicWeight` are tuning knobs for tests and tuning
    /// harnesses: set them before the engine is used, not while it runs.
    var rule = RelevanceRule.standard
    /// How hard an image that looks more like "text that says <query>" than
    /// like a picture of it is pushed down, for a query about things (see
    /// the type's notes and `typographicWeight(textness:)`).
    var typographicWeight: Float = 2

    private let queryQueue = DispatchQueue(label: "com.fxreza.bench.klip.clip-query", qos: .userInitiated)
    private let stateLock = NSLock()
    private var modelFailed = false
    private var background: (mean: [Float], text: [Float])?
    private var queryCache: [String: QueryVectors] = [:]
    private var queryCacheOrder: [String] = []
    static let queryCacheLimit = 32

    init(files: MobileCLIPFiles?, indexDirectory: URL, compiledCache: URL = MobileCLIPEncoder.defaultCompiledCache) {
        index = ImageEmbeddingIndex(directory: indexDirectory)
        encoder = files.map { MobileCLIPEncoder(files: $0, compiledCache: compiledCache) }
        if files == nil {
            print("[Klip] Smart search unavailable: no MobileCLIP model (see scripts/fetch-clip-model.sh)")
        }
    }

    // MARK: - SemanticImageSearching

    /// True while the model files exist and have not failed to load.
    ///
    /// `nonisolated` explicitly (here and on `matches`): the module defaults
    /// to the main actor, which makes `SemanticImageSearching`'s
    /// requirements main-actor-isolated, and a witness would inherit that.
    /// This engine is thread-safe and is called from background queues.
    nonisolated var isAvailable: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return encoder != nil && !modelFailed
    }

    nonisolated func matches(for query: String) async -> [UUID: Float] {
        guard let text = Self.visualQuery(query), isAvailable, !Task.isCancelled else { return [:] }
        return await withCheckedContinuation { continuation in
            queryQueue.async {
                continuation.resume(returning: self.answer(text))
            }
        }
    }

    /// Loads the text encoder (again, if it was released for being idle) and
    /// the background vectors in the background, so the next query answers
    /// in milliseconds. Cheap to call often, e.g. every time the history
    /// panel opens or the search field gets focus.
    func prepareForQueries() {
        guard isAvailable, let encoder else { return }
        queryQueue.async {
            _ = self.backgroundVectors()
            do {
                try encoder.prepareText()
            } catch {
                self.noteFailure(error)
            }
        }
    }

    /// The synchronous core of `matches`, on `queryQueue` (tests call it
    /// directly with an already-normalized query).
    func answer(_ text: String) -> [UUID: Float] {
        guard let vectors = queryVectors(for: text) else { return [:] }
        let scored = adjustedScores(vectors)
        return rule.select(ids: scored.ids, scores: scored.scores)
    }

    /// Every indexed image's adjusted score for `vectors`, by row.
    func adjustedScores(_ vectors: QueryVectors) -> (ids: [UUID], scores: [Float]) {
        let (ids, columns) = index.scores(for: [vectors.adjusted, vectors.query, vectors.typographic])
        guard !ids.isEmpty else { return ([], []) }
        var scores = columns[0]
        let weight = vectors.typographicWeight
        if weight > 0 {
            for row in scores.indices {
                scores[row] -= weight * max(0, columns[2][row] - columns[1][row])
            }
        }
        return (ids, scores)
    }

    // MARK: - Query vectors

    /// The three vectors one query is scored with (all 512-d):
    /// - `query`: the unit-length average of the prompt-template embeddings;
    /// - `adjusted`: `query - background`, the vector the rule's scores come
    ///   from (not unit length; see the type's notes);
    /// - `typographic`: the "screenshot of text that says ..." prompt, and
    ///   `typographicWeight`, how much it counts for this query.
    struct QueryVectors {
        var query: [Float]
        var adjusted: [Float]
        var typographic: [Float]
        var typographicWeight: Float
    }

    static let templates = ["a photo of {}.", "a picture of {}.", "an image of {}."]
    static let typographicTemplate = "a screenshot of text that says \"{}\"."

    /// Generic, varied subjects a clipboard's images tend to have. Their
    /// mean embedding is the "background" every image's score is measured
    /// against; what matters is breadth, not the exact list.
    static let backgroundConcepts = [
        "a person", "a dog", "a cat", "a car", "food", "a building", "a landscape", "a flower",
        "a computer screen", "text", "a document", "a screenshot", "a logo", "an icon", "a chart",
        "a drawing", "a pattern", "a texture", "furniture", "clothing", "a phone", "a map", "code",
        "a website", "a table", "a room", "a street", "the sky", "water", "a tree", "a bird", "a toy",
    ]

    /// The background concepts that are text on a screen or a page. Their
    /// mean says how "textual" a query is (`typographicWeight(textness:)`).
    static let textConcepts: Set<String> = ["text", "a document", "a screenshot", "a website", "code", "a chart"]

    /// Cosine between a query and the text concepts below which the
    /// typographic penalty applies in full, and above which it does not
    /// apply at all (linear in between).
    ///
    /// Measured: queries about things sit at 0.73-0.82 ("flower" 0.74,
    /// "woman" 0.77, "car" 0.82, "a map" 0.82); queries about text-bearing
    /// images at 0.85-0.95 ("a receipt" 0.85, "a spreadsheet" 0.86, "chart"
    /// 0.88, "screenshot of code" 0.89, "text document" 0.95). For the
    /// latter the "text that says ..." prompt describes the very images
    /// wanted, so penalizing them only cost real matches (a third of the
    /// "chart" results), and OCR search covers their words anyway.
    static let textnessRange: ClosedRange<Float> = 0.83...0.86

    /// Full `maximum` for a query about things, fading to 0 across
    /// `textnessRange` for a query about text. Pure (tests).
    static func typographicWeight(textness: Float, maximum: Float) -> Float {
        let span = textnessRange.upperBound - textnessRange.lowerBound
        let fraction = (textnessRange.upperBound - textness) / span
        return maximum * min(1, max(0, fraction))
    }

    /// A query that already says what kind of picture it wants is used as
    /// typed: "a photo of drawing of a woman" helps nobody.
    static let mediumWords: Set<String> = [
        "photo", "photograph", "picture", "image", "screenshot", "drawing", "painting",
        "illustration", "sketch", "diagram", "render", "rendering", "poster", "cartoon",
    ]

    static func prompts(for text: String) -> [String] {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        let lead = words.first.map { ["a", "an", "the"].contains($0) } == true ? words.dropFirst().first : words.first
        if let lead, mediumWords.contains(lead) || mediumWords.contains(String(lead.dropLast())) {
            return [text]
        }
        return templates.map { $0.replacingOccurrences(of: "{}", with: text) }
    }

    func queryVectors(for text: String) -> QueryVectors? {
        let key = text.lowercased()
        stateLock.lock()
        if let cached = queryCache[key] {
            stateLock.unlock()
            return cached
        }
        stateLock.unlock()

        guard let background = backgroundVectors(),
              let embedded = embedTexts(Self.prompts(for: text) + [Self.typographicTemplate.replacingOccurrences(of: "{}", with: text)])
        else { return nil }
        let query = Self.mean(Array(embedded.dropLast()))
        var adjusted = [Float](repeating: 0, count: MobileCLIPEncoder.dimension)
        vDSP_vsub(background.mean, 1, query, 1, &adjusted, 1, vDSP_Length(adjusted.count))
        var textness: Float = 0
        vDSP_dotpr(query, 1, background.text, 1, &textness, vDSP_Length(query.count))
        let vectors = QueryVectors(
            query: query,
            adjusted: adjusted,
            typographic: embedded.last!,
            typographicWeight: Self.typographicWeight(textness: textness, maximum: typographicWeight)
        )

        stateLock.lock()
        if queryCache[key] == nil {
            queryCache[key] = vectors
            queryCacheOrder.append(key)
            if queryCacheOrder.count > Self.queryCacheLimit {
                queryCache.removeValue(forKey: queryCacheOrder.removeFirst())
            }
        }
        stateLock.unlock()
        return vectors
    }

    /// `mean`: the background concepts' unit embeddings averaged, not
    /// re-normalized (`image . mean` must equal the mean of the per-concept
    /// cosines). `text`: the unit-length mean of the `textConcepts` among
    /// them. Computed once per process; they outlive the text encoder's idle
    /// release, so a reload never repeats them.
    private func backgroundVectors() -> (mean: [Float], text: [Float])? {
        stateLock.lock()
        if let background {
            stateLock.unlock()
            return background
        }
        stateLock.unlock()
        guard let embedded = embedTexts(Self.backgroundConcepts.map { "a photo of \($0)." }) else { return nil }
        var sum = [Float](repeating: 0, count: MobileCLIPEncoder.dimension)
        for vector in embedded { vDSP_vadd(sum, 1, vector, 1, &sum, 1, vDSP_Length(sum.count)) }
        var scale = 1 / Float(embedded.count)
        vDSP_vsmul(sum, 1, &scale, &sum, 1, vDSP_Length(sum.count))
        let textual = zip(Self.backgroundConcepts, embedded).filter { Self.textConcepts.contains($0.0) }.map(\.1)
        let vectors = (mean: sum, text: Self.mean(textual))
        stateLock.lock()
        background = vectors
        stateLock.unlock()
        return vectors
    }

    private func embedTexts(_ texts: [String]) -> [[Float]]? {
        guard let encoder, isAvailable else { return nil }
        do {
            return try encoder.embed(texts: texts)
        } catch {
            noteFailure(error)
            return nil
        }
    }

    /// A model that cannot be loaded will not load on the next try either:
    /// smart search switches off for this session (search falls back to
    /// text and labels). A failed prediction on one input does not.
    private func noteFailure(_ error: Error) {
        print("[Klip] Smart search: \(error)")
        if case MobileCLIPEncoder.EncoderError.loadFailed = error {
            stateLock.lock()
            modelFailed = true
            stateLock.unlock()
        }
    }

    static func mean(_ vectors: [[Float]]) -> [Float] {
        var sum = [Float](repeating: 0, count: vectors.first?.count ?? MobileCLIPEncoder.dimension)
        for vector in vectors { vDSP_vadd(sum, 1, vector, 1, &sum, 1, vDSP_Length(sum.count)) }
        return MobileCLIPEncoder.normalized(sum)
    }

    // MARK: - What counts as a visual query

    static let stopWords: Set<String> = [
        "a", "an", "the", "of", "and", "or", "in", "on", "at", "to", "for", "with", "from", "by",
        "is", "are", "it", "its", "this", "that", "these", "those", "my", "your", "our", "me", "i",
        "some", "any", "not", "no", "as", "be", "into",
    ]

    /// The query as the model should see it, or `nil` when it cannot be a
    /// description of a picture (see the type's notes). Cheap and pure: it
    /// runs on every keystroke before anything else.
    ///
    /// `+` is Klip search's AND between words ("woman+car"), so it becomes a
    /// space; surrounding quotes are dropped.
    static func visualQuery(_ raw: String) -> String? {
        var text = raw.replacingOccurrences(of: "+", with: " ")
        text = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”‘’")))
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty, text.count <= 200 else { return nil }
        let lower = text.lowercased()

        // Addresses, handles, paths, file names, numbers with decimals.
        if lower.contains("://") || lower.hasPrefix("www.") || lower.contains("@") { return nil }
        if lower.hasPrefix("/") || lower.hasPrefix("~") || lower.hasPrefix("./") { return nil }
        if lower.range(of: #"[\p{L}\p{N}]\.[\p{L}\p{N}]"#, options: .regularExpression) != nil { return nil }
        // Code and markup.
        if text.rangeOfCharacter(from: CharacterSet(charactersIn: "{}[]<>=;$#\\|`_^*")) != nil { return nil }

        var letters = 0
        var asciiLetters = 0
        var digits = 0
        for scalar in text.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                letters += 1
                if scalar.isASCII { asciiLetters += 1 }
            } else if CharacterSet.decimalDigits.contains(scalar) {
                digits += 1
            }
        }
        // Too short to mean anything yet (the first keystrokes), mostly a
        // number, or not in a Latin script at all (MobileCLIP only learned
        // English, so such a query would match noise).
        guard letters >= 3, digits < letters, asciiLetters * 2 >= letters else { return nil }

        let words = lower.split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard words.contains(where: { !stopWords.contains($0) }) else { return nil }
        return text
    }

    // MARK: - ImageEmbedding

    var canEmbed: Bool { isAvailable }

    func missingEmbeddings(among ids: [UUID]) -> Set<UUID> {
        guard isAvailable else { return [] }
        return index.missing(among: ids)
    }

    func embeddingNeeded(for id: UUID, fingerprint: ImageFingerprint) -> Bool {
        guard isAvailable else { return false }
        return index.fingerprint(for: id) != fingerprint
    }

    func computeEmbedding(for image: CGImage) -> [Float]? {
        guard let encoder, isAvailable else { return nil }
        do {
            return try encoder.embed(image: image)
        } catch {
            noteFailure(error)
            return nil
        }
    }

    func storeEmbedding(_ embedding: [Float]?, fingerprint: ImageFingerprint, for id: UUID) {
        index.set(embedding, fingerprint: fingerprint, for: id)
    }

    func retainEmbeddings(for liveIDs: Set<UUID>) {
        let removed = index.retainOnly(liveIDs)
        if removed > 0 { print("[Klip] Smart search: dropped \(removed) embedding(s) of deleted clips") }
    }

    func flushEmbeddings() {
        index.flush()
    }
}

// MARK: - Relevance rule

/// Which images count as matches, given every indexed image's adjusted
/// score for one query (see `MobileCLIPImageSearch`).
///
/// An image is kept when its score is at least all of:
/// - `floor`: an absolute minimum. Across the tuning queries, true matches
///   scored 0.06-0.17 after adjustment and a query with nothing to find
///   ("dog", "giraffe", "sky" on a history with none) topped out at
///   0.03-0.05, so 0.06 lets nothing through for those.
/// - `best - window`: CLIP's scale varies by query (the best "woman" photo
///   scored 0.165, the best "man" 0.12), so the rest are measured from the
///   best. 0.10 kept all ~15 photos of women for "woman" (0.07 kept only 7,
///   dropping true matches at 0.07-0.09), while limiting "screenshot of
///   code" to the screenshots that look most like code.
/// - with at least `zMinimumCount` images, `mean + minimumZ * sd` of all
///   scores, but never more than `best - zWindowCap`. A generic or
///   nonsense query ("asdf") shifts the whole distribution up (mean +0.03
///   against -0.08 for "woman") and would otherwise pass the floor for a
///   broad swath of screenshots; at z >= 2 it keeps a handful. The cap keeps
///   a collection that is mostly one kind of image (where the best match is
///   not an outlier) from returning nothing.
///
/// At most `maxResults` are returned, best first.
nonisolated struct RelevanceRule: Equatable, Sendable {
    var floor: Float = 0.06
    var window: Float = 0.10
    var minimumZ: Float = 2.0
    var zMinimumCount = 30
    var zWindowCap: Float = 0.03
    var maxResults = 60

    static let standard = RelevanceRule()

    /// The score an image needs, for this set of `scores`; `nil` when
    /// nothing can match (no scores, or even the best is under the floor).
    func cutoff(for scores: [Float]) -> Float? {
        guard !scores.isEmpty else { return nil }
        var best: Float = 0
        vDSP_maxv(scores, 1, &best, vDSP_Length(scores.count))
        guard best >= floor else { return nil }
        var cutoff = max(floor, best - window)
        if scores.count >= zMinimumCount {
            var mean: Float = 0
            var deviation: Float = 0
            vDSP_normalize(scores, 1, nil, 1, &mean, &deviation, vDSP_Length(scores.count))
            if deviation.isFinite, deviation > 0 {
                cutoff = max(cutoff, min(mean + minimumZ * deviation, best - zWindowCap))
            }
        }
        return cutoff
    }

    func select(ids: [UUID], scores: [Float]) -> [UUID: Float] {
        precondition(ids.count == scores.count, "one score per id")
        guard let cutoff = cutoff(for: scores) else { return [:] }
        let kept = scores.indices
            .filter { scores[$0] >= cutoff }
            .sorted { scores[$0] > scores[$1] }
            .prefix(maxResults)
        var result: [UUID: Float] = [:]
        result.reserveCapacity(kept.count)
        for row in kept { result[ids[row]] = scores[row] }
        return result
    }
}
