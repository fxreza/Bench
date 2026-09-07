import Foundation

/// Free, keyless Microsoft/Bing translator using the same endpoints the
/// bing.com/translator page calls. Unlike Google's endpoint it returns a
/// transliteration for Persian (and other non-Latin targets), and its
/// dictionary endpoint provides part-of-speech + back-translations for
/// single-word lookups.
struct BingEngine: TranslationEngine {
    let id = EngineID.bing
    let capabilities: Set<EngineCapability> = [.dictionary, .transliteration]

    /// Bing's web endpoint rejects longer texts outright.
    static let maxTextLength = 1000

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["User-Agent": BingConfigStore.userAgent]
        return URLSession(configuration: config)
    }()

    /// Canonical → Bing code deviations are handled in `LanguageCatalog`;
    /// treat every catalog language as supported (Bing's coverage differences
    /// surface as a per-card error rather than a silently missing card).
    func supports(language: String) -> Bool { true }

    func isConfigured() -> Bool { true }

    func translate(_ text: String, to target: String, from source: String) async throws
        -> EngineResult
    {
        guard text.count <= Self.maxTextLength else {
            throw TranslationError.textTooLong(limit: Self.maxTextLength)
        }

        do {
            return try await performTranslate(text, to: target, from: source, isRetry: false)
        } catch TranslationError.captcha {
            // A captcha usually means the scraped session went stale/blocked,
            // not a hard IP block — rescrape once and retry. A second captcha
            // is surfaced as-is.
            await BingConfigStore.shared.invalidate()
            return try await performTranslate(text, to: target, from: source, isRetry: true)
        }
    }

    // MARK: - Requests

    private func performTranslate(
        _ text: String, to target: String, from source: String, isRetry: Bool
    ) async throws -> EngineResult {
        let config = try await BingConfigStore.shared.currentConfig()

        let bingFrom = LanguageCatalog.engineCode(source, for: .bing)
        let bingTo = LanguageCatalog.engineCode(target, for: .bing)

        var body: [String: String] = [
            // Bing's own page sends "auto-detect"; `engineCode` maps our
            // "auto" to "" meaning "omit", but ttranslatev3 wants the
            // sentinel value in `fromLang`.
            "fromLang": bingFrom.isEmpty ? "auto-detect" : bingFrom,
            "text": text,
            "token": config.token,
            "key": String(config.key),
        ]
        body["to"] = bingTo
        // Same field the website's Casual/Formal dropdown sends; omitted for
        // standard, which is also what the endpoint answers without it.
        if let tone = TranslationTone.current.bingValue {
            body["tone"] = tone
        }

        let object = try await post(path: "/ttranslatev3", config: config, body: body)

        guard let array = object as? [[String: Any]],
              let first = array.first,
              let translations = first["translations"] as? [[String: Any]],
              let primary = translations.first,
              let translated = primary["text"] as? String
        else {
            throw errorFromBody(object)
        }

        let transliteration =
            (primary["transliteration"] as? [String: Any])?["text"] as? String

        var detected: String?
        if let lang = (first["detectedLanguage"] as? [String: Any])?["language"] as? String {
            detected = Self.canonical(fromBing: lang)
        }

        // Single-word lookups also get the dictionary endpoint; it needs a
        // concrete source language, which detection has just provided.
        var dictionary: [DictionaryEntry] = []
        if isSingleWord(text), let sourceCode = detected ?? fixedSource(source) {
            dictionary = (try? await lookupDictionary(
                text, from: sourceCode, to: target, config: config)) ?? []
        }

        return EngineResult(
            engine: .bing,
            translatedText: translated,
            detectedSourceLanguage: detected,
            spellingSuggestion: nil,
            dictionary: dictionary,
            transliteration: transliteration)
    }

    private func lookupDictionary(
        _ text: String, from source: String, to target: String, config: BingConfigStore.Config
    ) async throws -> [DictionaryEntry] {
        let body: [String: String] = [
            "from": LanguageCatalog.engineCode(source, for: .bing),
            "to": LanguageCatalog.engineCode(target, for: .bing),
            "text": text,
            "token": config.token,
            "key": String(config.key),
        ]
        let object = try await post(path: "/tlookupv3", config: config, body: body)

        guard let array = object as? [[String: Any]],
              let first = array.first,
              let translations = first["translations"] as? [[String: Any]]
        else { return [] }

        // Group Bing's flat translation list by part of speech so it renders
        // through the same DictionaryEntry shape Google's dict does.
        var grouped: [String: [DictionaryMeaning]] = [:]
        var posOrder: [String] = []
        for entry in translations {
            guard let word = entry["displayTarget"] as? String else { continue }
            let pos = (entry["posTag"] as? String ?? "").lowercased()
            let reverse = (entry["backTranslations"] as? [[String: Any]])?
                .compactMap { $0["displayText"] as? String } ?? []
            if grouped[pos] == nil { posOrder.append(pos) }
            grouped[pos, default: []].append(
                DictionaryMeaning(word: word, reverseTranslations: reverse))
        }
        return posOrder.compactMap { pos in
            guard let meanings = grouped[pos], !meanings.isEmpty else { return nil }
            return DictionaryEntry(partOfSpeech: pos, meanings: meanings)
        }
    }

    private func post(
        path: String, config: BingConfigStore.Config, body: [String: String]
    ) async throws -> Any {
        var components = URLComponents(
            url: config.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "isVertical", value: "1"),
            URLQueryItem(name: "IG", value: config.ig),
            URLQueryItem(name: "IID", value: config.iid),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(
            config.baseURL.appendingPathComponent("/translator").absoluteString,
            forHTTPHeaderField: "Referer")
        request.httpBody = body
            .map { "\($0.key)=\(formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw TranslationError.network(error)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            if http.statusCode == 401 || http.statusCode == 429 {
                throw TranslationError.rateLimited
            }
            throw TranslationError.http(http.statusCode)
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: - Helpers

    /// A non-array body carries Bing's error signals. Internal (not
    /// `private`) so `LingoTests` can exercise this pure function directly.
    func errorFromBody(_ object: Any) -> TranslationError {
        guard let dict = object as? [String: Any] else { return .badResponse }
        if dict["ShowCaptcha"] as? Bool == true { return .captcha }
        if let status = dict["StatusCode"] as? Int ?? dict["statusCode"] as? Int {
            // Bing reports its rate limit as an in-body 401.
            return status == 401 ? .rateLimited : .http(status)
        }
        return .badResponse
    }

    private func isSingleWord(_ text: String) -> Bool {
        text.count < 50 && !text.contains(where: \.isWhitespace)
    }

    private func fixedSource(_ source: String) -> String? {
        source == LanguageCatalog.autoCode ? nil : source
    }

    private func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Bing detection codes → canonical catalog codes. Internal (not
    /// `private`) so `LingoTests` can exercise this pure function directly.
    static func canonical(fromBing code: String) -> String {
        let map = [
            "zh-Hans": "zh-CN", "zh-Hant": "zh-TW", "sr-Cyrl": "sr", "sr-Latn": "sr",
            "fil": "tl", "mww": "hmn", "nb": "no", "pt-PT": "pt",
        ]
        return map[code] ?? LanguageCatalog.normalize(code)
    }
}
