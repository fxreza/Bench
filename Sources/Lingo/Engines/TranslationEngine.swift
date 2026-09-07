import Foundation
import BenchCore

struct DictionaryMeaning: Sendable {
    let word: String
    let reverseTranslations: [String]
}

struct DictionaryEntry: Sendable {
    let partOfSpeech: String
    let meanings: [DictionaryMeaning]
}

/// The translation engines Transi can query. Raw values are persisted in
/// UserDefaults (engine order / enabled set), so they must stay stable.
enum EngineID: String, CaseIterable, Codable, Identifiable, Sendable {
    case google, bing, gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .google: return "Google"
        case .bing: return "Bing"
        case .gemini: return "Gemini"
        }
    }

    /// Only Gemini needs a user-supplied API key; Google and Bing use the
    /// same keyless web endpoints their translator sites use.
    var requiresKey: Bool { self == .gemini }
}

/// Translation register for the engines that support one. Bing's endpoint
/// takes it as a literal `tone` form field (the same control the website's
/// tone dropdown drives); Gemini takes it as a prompt instruction. Google's
/// endpoint has no tone support and always answers standard.
enum TranslationTone: String, CaseIterable, Codable, Identifiable {
    case standard, casual, formal

    var id: String { rawValue }
    var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// Value for Bing's `tone` body field; nil means omit the field.
    var bingValue: String? {
        switch self {
        case .standard: return nil
        case .casual: return "Casual"
        case .formal: return "Formal"
        }
    }

    /// Extra sentence for Gemini's system prompt; nil for standard.
    var geminiClause: String? {
        switch self {
        case .standard: return nil
        case .casual: return "Use a casual, colloquial, spoken register."
        case .formal: return "Use a formal, polite register."
        }
    }

    /// Read from UserDefaults directly so Sendable engines running off the
    /// main actor don't have to touch SettingsStore.
    static var current: TranslationTone {
        TranslationTone(rawValue: BenchDefaults.standard.string(forKey: "lingo.translationTone") ?? "")
            ?? .standard
    }
}

/// How much invisible reasoning Gemini may spend before it answers.
///
/// It is a latency control, not a quality one: measured against the current
/// prompt, `low` matched the default on accuracy (idioms, lexical ambiguity)
/// for a fraction of the thinking tokens, and it is the only setting that
/// never made the model ramble inside the JSON response — `off` once returned
/// a 3,000-character "transliteration" with the response JSON nested inside
/// itself, and `medium` once looped until it hit the output limit. Hence the
/// `low` default.
enum GeminiThinking: String, CaseIterable, Codable, Identifiable, Sendable {
    case off, low, medium, high

    var id: String { rawValue }
    var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// The `generationConfig.thinkingConfig` object for this level. "Off" is
    /// a token budget of zero rather than a level — the API has no `minimal`
    /// level for these models (it rejects it by name).
    var thinkingConfig: [String: Any] {
        switch self {
        case .off: return ["thinkingBudget": 0]
        case .low, .medium, .high: return ["thinkingLevel": rawValue]
        }
    }

    /// Read straight from UserDefaults so `Sendable` engines running off the
    /// main actor don't have to touch `SettingsStore` — same pattern as
    /// `TranslationTone.current`.
    static var current: GeminiThinking {
        GeminiThinking(rawValue: BenchDefaults.standard.string(forKey: "lingo.geminiThinking") ?? "")
            ?? .low
    }
}

/// What an engine can return beyond the bare translation. The popup uses this
/// to decide which affordances a result card gets.
enum EngineCapability: Sendable {
    case dictionary
    case transliteration
    case spellingSuggestion
}

/// One engine's complete answer for one lookup. Extends the fields the old
/// single-engine `TranslationResult` carried with the engine that produced it
/// and the transliteration Bing/Gemini can provide (Google's endpoint cannot).
struct EngineResult: Sendable {
    let engine: EngineID
    let translatedText: String
    let detectedSourceLanguage: String?
    let spellingSuggestion: String?
    let dictionary: [DictionaryEntry]
    let transliteration: String?
}

enum TranslationError: LocalizedError {
    case badResponse
    case http(Int)
    case network(Error)
    case textTooLong(limit: Int)
    /// Engine enabled but missing its API key (Gemini before setup).
    case notConfigured
    case invalidAPIKey
    case quotaExceeded
    /// Bing flagged the session for captcha; retried once already.
    case captcha
    case rateLimited
    /// The provider has no capacity for this specific model right now
    /// (Gemini's HTTP 503). Nothing is wrong with the key, the quota, or the
    /// request — another model usually answers immediately.
    case modelBusy(String)

    var errorDescription: String? {
        switch self {
        case .badResponse: return "Unexpected response from translation service."
        case .http(let code): return "Translation service returned HTTP \(code)."
        case .network(let err): return "Network error: \(err.localizedDescription)"
        case .textTooLong(let limit): return "Text is too long for this engine (limit \(limit) characters)."
        case .notConfigured: return "Add an API key in Settings to use this engine."
        case .invalidAPIKey: return "Invalid API key — check Settings."
        case .quotaExceeded: return "Free quota exceeded. Try again later."
        case .captcha: return "Temporarily unavailable (rate limited). Try again in a minute."
        case .rateLimited: return "Rate limited. Try again in a minute."
        case .modelBusy(let model):
            return "\(model) is busy right now. Pick another model in Settings → Engines."
        }
    }
}

/// One translation backend. Implementations are stateless value types (any
/// mutable shared state, like Bing's scraped token, lives in its own actor)
/// so the coordinator can fire them concurrently without ceremony.
protocol TranslationEngine: Sendable {
    var id: EngineID { get }
    var capabilities: Set<EngineCapability> { get }

    /// Whether this engine can serve `language` (canonical catalog code).
    func supports(language: String) -> Bool

    /// Cheap readiness check the coordinator uses to skip an engine before
    /// spending a task-group slot on it (e.g. Gemini with no Keychain key).
    func isConfigured() -> Bool

    /// `source` is a canonical code or "auto"; each engine maps codes through
    /// `LanguageCatalog.engineCode(_:for:)` itself.
    func translate(_ text: String, to target: String, from source: String) async throws -> EngineResult

    /// Anything besides the text and languages that changes what this engine
    /// returns, folded into the coordinator's cache key. Without it, switching
    /// Gemini's model or thinking level would replay the previous answer from
    /// cache instead of re-running — the same trap tone already avoids.
    var cacheVariant: String { get }
}

extension TranslationEngine {
    var displayName: String { id.displayName }

    /// Most engines have nothing to vary on.
    var cacheVariant: String { "" }
}

extension EngineCapability: Hashable {}
