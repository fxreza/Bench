import Foundation

/// Scrapes and caches the session tokens the keyless Bing endpoints require.
///
/// bing.com/translator embeds three values in its page: `IG` (session id),
/// `data-iid` (instrumentation id), and `params_AbusePreventionHelper`, a
/// `[key, token, expiryMs]` array where `key` doubles as the token's issue
/// timestamp. `ttranslatev3`/`tlookupv3` accept POSTs carrying all of them.
/// Tokens live ~1h; a stale or blocked session answers with `ShowCaptcha`.
///
/// Everything Bing-page-specific is isolated here and in `BingEngine` so a
/// markup change on Bing's side has a two-file blast radius.
actor BingConfigStore {
    static let shared = BingConfigStore()

    struct Config: Sendable {
        let ig: String
        let iid: String
        let key: Int
        let token: String
        let expiresAt: Date
        /// Host the page actually served from (bing.com redirects by region,
        /// e.g. to cn.bing.com); requests must go back to the same host.
        let baseURL: URL
    }

    static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
        + "Chrome/150.0.0.0 Safari/537.36 Edg/151.0.4129.59"

    private var cached: Config?
    /// Single-flight guard: concurrent translate + dictionary calls (and the
    /// stacked fan-out) await one in-flight scrape instead of each fetching
    /// the page. A bare expiry check without this double-scrapes under
    /// concurrency, which is wasteful and raises captcha risk.
    private var fetchTask: Task<Config, Error>?

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        session = URLSession(configuration: config)
    }

    func currentConfig() async throws -> Config {
        if let cached, cached.expiresAt > Date() { return cached }
        if let fetchTask { return try await fetchTask.value }

        let task = Task<Config, Error> { try await fetchConfig() }
        fetchTask = task
        defer { fetchTask = nil }
        let config = try await task.value
        cached = config
        return config
    }

    /// Called when a request comes back flagged (`ShowCaptcha`) — forces the
    /// next `currentConfig` to rescrape rather than trusting the expiry clock.
    func invalidate() {
        cached = nil
    }

    // MARK: - Scrape

    private func fetchConfig() async throws -> Config {
        let pageURL = URL(string: "https://www.bing.com/translator")!
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: pageURL)
        } catch {
            throw TranslationError.network(error)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw TranslationError.badResponse
        }

        guard let ig = firstMatch(#"IG:"([^"]+)""#, in: html),
              let iid = firstMatch(#"data-iid="([^"]+)""#, in: html),
              let helper = firstMatch(#"params_AbusePreventionHelper\s?=\s?([^\]]+\])"#, in: html),
              let helperData = helper.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: helperData) as? [Any],
              array.count >= 3,
              let key = array[0] as? Int,
              let token = array[1] as? String,
              let expiryMs = array[2] as? Int
        else {
            // The page rendered but the markers are gone — most likely Bing
            // changed its markup, or served a captcha interstitial.
            throw TranslationError.badResponse
        }

        var base = URL(string: "https://www.bing.com")!
        if let host = (response as? HTTPURLResponse)?.url?.host {
            base = URL(string: "https://\(host)") ?? base
        }

        return Config(
            ig: ig,
            iid: iid,
            key: key,
            token: token,
            // `key` is the issue timestamp in ms; shave a minute off so we
            // rescrape before Bing actually rejects the token.
            expiresAt: Date(timeIntervalSince1970: TimeInterval(key + expiryMs - 60_000) / 1000),
            baseURL: base)
    }

    private nonisolated func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}
