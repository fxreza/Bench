import Foundation

/// Free, keyless Google Translate client using the unofficial web endpoints.
/// Both hosts are asked for `translate_a/single`, so either can return the
/// dictionary entries the popup shows:
/// Primary: translate.googleapis.com (client=gtx)
/// Fallback: clients5.google.com (client=dict-chrome-ex)
///
/// This is the former `TranslationService` reshaped into a `TranslationEngine`.
/// The cross-engine cache and warm-up moved to `TranslationCoordinator`; the
/// hedged two-endpoint fetch and the `dj=1` parser are unchanged.
struct GoogleEngine: TranslationEngine {
    let id = EngineID.google
    let capabilities: Set<EngineCapability> = [.dictionary, .spellingSuggestion]

    /// How long the primary endpoint gets on its own before the fallback is
    /// started alongside it. Short enough that a stalled primary no longer costs
    /// the full request timeout, long enough that the healthy path (~150-400ms)
    /// almost never fires a second request.
    private let hedgeDelay: Duration = .milliseconds(700)

    /// Shared across instances: connection reuse is the whole point of the
    /// warm-up, so every translate call must hit the same pool.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // A stalled request used to block the popup for the full timeout before
        // the fallback endpoint was even attempted; the hedge covers slow
        // responses, so this only bounds hard failures.
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 10
        // Fail fast instead of parking the request until the network returns.
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = [
            "User-Agent":
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
        ]
        return URLSession(configuration: config)
    }()

    /// The canonical catalog codes are Google-style, so the engine serves all
    /// of them.
    func supports(language: String) -> Bool { true }

    func isConfigured() -> Bool { true }

    /// Runs the primary endpoint and, if it hasn't answered within `hedgeDelay`,
    /// the fallback endpoint alongside it. First success wins; the loser is
    /// cancelled.
    func translate(_ text: String, to target: String, from source: String) async throws
        -> EngineResult
    {
        try await withThrowingTaskGroup(of: EngineResult.self) { group in
            group.addTask {
                try await fetchTranslation(text, to: target, from: source, via: .primary)
            }
            group.addTask {
                try await Task.sleep(for: hedgeDelay)
                return try await fetchTranslation(text, to: target, from: source, via: .fallback)
            }

            var firstError: Error?
            while let outcome = await group.nextResult() {
                switch outcome {
                case .success(let result):
                    group.cancelAll()
                    return result
                case .failure(let error):
                    // Ignore the hedge losing its sleep race on cancellation.
                    if !(error is CancellationError), firstError == nil {
                        firstError = error
                    }
                }
            }
            throw firstError ?? TranslationError.badResponse
        }
    }

    // MARK: - Endpoints

    /// The two keyless Google hosts this talks to. They differ only in host and
    /// `client`, and both answer the same `translate_a/single` shape, so one
    /// request builder and one parser cover both.
    private enum Endpoint {
        case primary
        case fallback

        var url: String {
            switch self {
            case .primary: return "https://translate.googleapis.com/translate_a/single"
            case .fallback: return "https://clients5.google.com/translate_a/single"
            }
        }

        var client: String {
            switch self {
            case .primary: return "gtx"
            case .fallback: return "dict-chrome-ex"
            }
        }
    }

    private func fetchTranslation(
        _ text: String, to target: String, from source: String, via endpoint: Endpoint
    ) async throws -> EngineResult {
        var components = URLComponents(string: endpoint.url)!
        components.queryItems = [
            URLQueryItem(name: "client", value: endpoint.client),
            URLQueryItem(name: "sl", value: LanguageCatalog.engineCode(source, for: .google)),
            URLQueryItem(name: "tl", value: LanguageCatalog.engineCode(target, for: .google)),
            URLQueryItem(name: "dt", value: "t"),  // the translation itself
            URLQueryItem(name: "dt", value: "bd"),  // the dictionary entries
            URLQueryItem(name: "dt", value: "qca"),  // spelling correction
            URLQueryItem(name: "dj", value: "1"),  // named JSON, not nested arrays
            URLQueryItem(name: "q", value: text),
        ]

        return try Self.parse(try await fetch(components.url!))
    }

    /// Parses the `dj=1` response shape both endpoints return. Internal
    /// (not `private`) so `LingoTests` can feed it sample response bodies
    /// directly — it is a pure function, the cheapest thing to unit test
    /// here.
    static func parse(_ data: Data) throws -> EngineResult {
        let object = try JSONSerialization.jsonObject(with: data)

        // A host that ignores `dj=1` answers the legacy shape instead:
        // `["translated"]` or `[["translated", "detectedLang"]]`. Losing the
        // dictionary is not worth failing the whole lookup over - take the text.
        if let legacy = object as? [Any] {
            let inner = legacy.first as? [Any]
            guard let translated = (legacy.first as? String) ?? (inner?.first as? String) else {
                throw TranslationError.badResponse
            }
            return EngineResult(
                engine: .google,
                translatedText: translated,
                detectedSourceLanguage: inner.flatMap { $0.count > 1 ? $0[1] as? String : nil },
                spellingSuggestion: nil,
                dictionary: [],
                transliteration: nil)
        }

        guard let json = object as? [String: Any] else { throw TranslationError.badResponse }

        var translated = ""
        if let sentences = json["sentences"] as? [[String: Any]] {
            for sentence in sentences {
                if let trans = sentence["trans"] as? String {
                    translated += trans
                }
            }
        }
        guard !translated.isEmpty else { throw TranslationError.badResponse }

        var spelling: String?
        if let spell = json["spell"] as? [String: Any],
           let spellRes = spell["spell_res"] as? String, !spellRes.isEmpty {
            spelling = spellRes
        }

        var dictionary = [DictionaryEntry]()
        if let dict = json["dict"] as? [[String: Any]] {
            for group in dict {
                let pos = group["pos"] as? String ?? ""
                var meanings = [DictionaryMeaning]()
                if let entries = group["entry"] as? [[String: Any]] {
                    for entry in entries {
                        guard let word = entry["word"] as? String else { continue }
                        let reverse = entry["reverse_translation"] as? [String] ?? []
                        meanings.append(
                            DictionaryMeaning(word: word, reverseTranslations: reverse))
                    }
                } else if let terms = group["terms"] as? [String] {
                    meanings = terms.map { DictionaryMeaning(word: $0, reverseTranslations: []) }
                }
                if !meanings.isEmpty {
                    dictionary.append(DictionaryEntry(partOfSpeech: pos, meanings: meanings))
                }
            }
        }

        return EngineResult(
            engine: .google,
            translatedText: translated,
            detectedSourceLanguage: json["src"] as? String,
            spellingSuggestion: spelling,
            dictionary: dictionary,
            transliteration: nil)
    }

    // MARK: - Helpers

    private func fetch(_ url: URL) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(from: url)
        } catch {
            throw TranslationError.network(error)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw TranslationError.http(http.statusCode)
        }
        return data
    }
}
