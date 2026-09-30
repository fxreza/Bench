import Foundation

/// Finds image clips by what their picture *means* rather than by the words
/// stored with them: "woman", "girl at a desk", "a place for eating".
///
/// The contract between the two halves of Klip's smart image search:
///
/// - The engine (`MobileCLIPImageSearch`) owns the model, the per-image
///   embeddings, their on-disk index and the background indexing of new and
///   existing images. It decides what counts as a match (thresholds live
///   there, next to the model they were tuned for).
/// - Search (`HistoryViewModel` / `FilterState`) owns *when* to ask and how
///   the answer joins the ordinary text results in the list.
///
/// Everything here is on-device. When the model files are missing (a dev
/// build without `scripts/fetch-clip-model.sh`) or fail to load, the engine
/// reports `isAvailable == false` and `matches` returns `[:]`, so search
/// quietly falls back to text, OCR and Vision labels.
protocol SemanticImageSearching: AnyObject, Sendable {
    /// Whether the model loaded and queries can be answered.
    var isAvailable: Bool { get }

    /// Image clips whose picture matches `query`, keyed by clip id, with a
    /// relevance score (higher is better; only meaningful for ordering within
    /// one answer). Only clips the engine judged relevant are returned, so
    /// the caller can show every key. Empty for an empty or unusable query,
    /// or when the engine is unavailable.
    ///
    /// Safe to call from any task; does its work off the main thread. Must be
    /// cheap enough to run on each debounced keystroke (text encoding plus a
    /// scan of every stored embedding).
    func matches(for query: String) async -> [UUID: Float]

    /// Warm the engine up ahead of a likely query (the history panel just
    /// opened), so the first search of a session answers as fast as the
    /// rest. Cheap to call often; never blocks the caller.
    func prepareForQueries()
}

extension SemanticImageSearching {
    func prepareForQueries() {}
}

/// Stand-in used when smart image search is unavailable, and in tests that
/// do not exercise it.
final class NoSemanticImageSearch: SemanticImageSearching {
    static let shared = NoSemanticImageSearch()
    var isAvailable: Bool { false }
    func matches(for query: String) async -> [UUID: Float] { [:] }
}
