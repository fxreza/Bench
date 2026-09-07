import Foundation

/// Canonical language table for every engine Transi talks to (Google, Bing,
/// Gemini prompts, Google TTS).
///
/// Google, Bing, and Google's TTS endpoint each spell some language codes
/// differently (Filipino is `tl` to Google but `fil` to Bing; simplified
/// Chinese is `zh-CN` to Google but `zh-Hans` to Bing). Rather than let every
/// call site carry its own `if code == "zh-CN"` special case, the catalog
/// stores one canonical (Google-style) code per language and translates it to
/// whatever a given engine expects only at the call site, via `engineCode`.
enum LanguageCatalog {

    /// Coarse script bucket, used to pick fonts/alignment without a full
    /// per-language switch (e.g. RTL layout, or a CJK-friendly font).
    enum Script: Sendable {
        case latin, arabic, cjkHan, kana, hangul, cyrillic, devanagari, hebrew, greek, thai, other
    }

    /// A translation/speech backend whose language codes may diverge from
    /// the canonical Google-style code stored in `Language.code`.
    enum Engine: Sendable {
        case google, bing, geminiPrompt, googleTTS
    }

    struct Language: Identifiable, Hashable, Sendable {
        let code: String        // canonical, Google-style ("fa", "en", "zh-CN", "pt", "tl", ...)
        let englishName: String
        let nativeName: String
        let isRTL: Bool
        let script: Script

        var id: String { code }

        /// "Persian (فارسی)", or just "English" when the native name reads
        /// the same as the English one (English itself, and languages whose
        /// endonym happens to be an English word already).
        var displayName: String {
            englishName == nativeName ? englishName : "\(englishName) (\(nativeName))"
        }
    }

    static let autoCode = "auto"

    static let all: [Language] = [
        Language(code: "af", englishName: "Afrikaans", nativeName: "Afrikaans", isRTL: false, script: .latin),
        Language(code: "sq", englishName: "Albanian", nativeName: "Shqip", isRTL: false, script: .latin),
        Language(code: "am", englishName: "Amharic", nativeName: "አማርኛ", isRTL: false, script: .other),
        Language(code: "ar", englishName: "Arabic", nativeName: "العربية", isRTL: true, script: .arabic),
        Language(code: "hy", englishName: "Armenian", nativeName: "Հայերեն", isRTL: false, script: .other),
        Language(code: "az", englishName: "Azerbaijani", nativeName: "Azərbaycan", isRTL: false, script: .latin),
        Language(code: "eu", englishName: "Basque", nativeName: "Euskara", isRTL: false, script: .latin),
        Language(code: "be", englishName: "Belarusian", nativeName: "Беларуская", isRTL: false, script: .cyrillic),
        Language(code: "bn", englishName: "Bengali", nativeName: "বাংলা", isRTL: false, script: .other),
        Language(code: "bs", englishName: "Bosnian", nativeName: "Bosanski", isRTL: false, script: .latin),
        Language(code: "bg", englishName: "Bulgarian", nativeName: "Български", isRTL: false, script: .cyrillic),
        Language(code: "ca", englishName: "Catalan", nativeName: "Català", isRTL: false, script: .latin),
        Language(code: "ceb", englishName: "Cebuano", nativeName: "Cebuano", isRTL: false, script: .latin),
        Language(code: "ny", englishName: "Chichewa", nativeName: "Chichewa", isRTL: false, script: .latin),
        Language(code: "zh-CN", englishName: "Chinese (Simplified)", nativeName: "中文（简体）", isRTL: false, script: .cjkHan),
        Language(code: "zh-TW", englishName: "Chinese (Traditional)", nativeName: "中文（繁體）", isRTL: false, script: .cjkHan),
        Language(code: "co", englishName: "Corsican", nativeName: "Corsu", isRTL: false, script: .latin),
        Language(code: "hr", englishName: "Croatian", nativeName: "Hrvatski", isRTL: false, script: .latin),
        Language(code: "cs", englishName: "Czech", nativeName: "Čeština", isRTL: false, script: .latin),
        Language(code: "da", englishName: "Danish", nativeName: "Dansk", isRTL: false, script: .latin),
        Language(code: "nl", englishName: "Dutch", nativeName: "Nederlands", isRTL: false, script: .latin),
        Language(code: "en", englishName: "English", nativeName: "English", isRTL: false, script: .latin),
        Language(code: "eo", englishName: "Esperanto", nativeName: "Esperanto", isRTL: false, script: .latin),
        Language(code: "et", englishName: "Estonian", nativeName: "Eesti", isRTL: false, script: .latin),
        Language(code: "tl", englishName: "Filipino", nativeName: "Filipino", isRTL: false, script: .latin),
        Language(code: "fi", englishName: "Finnish", nativeName: "Suomi", isRTL: false, script: .latin),
        Language(code: "fr", englishName: "French", nativeName: "Français", isRTL: false, script: .latin),
        Language(code: "fy", englishName: "Frisian", nativeName: "Frysk", isRTL: false, script: .latin),
        Language(code: "gl", englishName: "Galician", nativeName: "Galego", isRTL: false, script: .latin),
        Language(code: "ka", englishName: "Georgian", nativeName: "ქართული", isRTL: false, script: .other),
        Language(code: "de", englishName: "German", nativeName: "Deutsch", isRTL: false, script: .latin),
        Language(code: "el", englishName: "Greek", nativeName: "Ελληνικά", isRTL: false, script: .greek),
        Language(code: "gu", englishName: "Gujarati", nativeName: "ગુજરાતી", isRTL: false, script: .other),
        Language(code: "ht", englishName: "Haitian Creole", nativeName: "Kreyòl ayisyen", isRTL: false, script: .latin),
        Language(code: "ha", englishName: "Hausa", nativeName: "Hausa", isRTL: false, script: .latin),
        Language(code: "haw", englishName: "Hawaiian", nativeName: "ʻŌlelo Hawaiʻi", isRTL: false, script: .latin),
        Language(code: "he", englishName: "Hebrew", nativeName: "עברית", isRTL: true, script: .hebrew),
        Language(code: "hi", englishName: "Hindi", nativeName: "हिन्दी", isRTL: false, script: .devanagari),
        Language(code: "hmn", englishName: "Hmong", nativeName: "Hmoob", isRTL: false, script: .latin),
        Language(code: "hu", englishName: "Hungarian", nativeName: "Magyar", isRTL: false, script: .latin),
        Language(code: "is", englishName: "Icelandic", nativeName: "Íslenska", isRTL: false, script: .latin),
        Language(code: "ig", englishName: "Igbo", nativeName: "Igbo", isRTL: false, script: .latin),
        Language(code: "id", englishName: "Indonesian", nativeName: "Bahasa Indonesia", isRTL: false, script: .latin),
        Language(code: "ga", englishName: "Irish", nativeName: "Gaeilge", isRTL: false, script: .latin),
        Language(code: "it", englishName: "Italian", nativeName: "Italiano", isRTL: false, script: .latin),
        Language(code: "ja", englishName: "Japanese", nativeName: "日本語", isRTL: false, script: .kana),
        Language(code: "jw", englishName: "Javanese", nativeName: "Basa Jawa", isRTL: false, script: .latin),
        Language(code: "kn", englishName: "Kannada", nativeName: "ಕನ್ನಡ", isRTL: false, script: .other),
        Language(code: "kk", englishName: "Kazakh", nativeName: "Қазақ тілі", isRTL: false, script: .cyrillic),
        Language(code: "km", englishName: "Khmer", nativeName: "ខ្មែរ", isRTL: false, script: .other),
        Language(code: "rw", englishName: "Kinyarwanda", nativeName: "Ikinyarwanda", isRTL: false, script: .latin),
        Language(code: "ko", englishName: "Korean", nativeName: "한국어", isRTL: false, script: .hangul),
        Language(code: "ku", englishName: "Kurdish", nativeName: "Kurdî", isRTL: false, script: .latin),
        Language(code: "ky", englishName: "Kyrgyz", nativeName: "Кыргызча", isRTL: false, script: .cyrillic),
        Language(code: "lo", englishName: "Lao", nativeName: "ລາວ", isRTL: false, script: .other),
        Language(code: "la", englishName: "Latin", nativeName: "Latina", isRTL: false, script: .latin),
        Language(code: "lv", englishName: "Latvian", nativeName: "Latviešu", isRTL: false, script: .latin),
        Language(code: "lt", englishName: "Lithuanian", nativeName: "Lietuvių", isRTL: false, script: .latin),
        Language(code: "lb", englishName: "Luxembourgish", nativeName: "Lëtzebuergesch", isRTL: false, script: .latin),
        Language(code: "mk", englishName: "Macedonian", nativeName: "Македонски", isRTL: false, script: .cyrillic),
        Language(code: "mg", englishName: "Malagasy", nativeName: "Malagasy", isRTL: false, script: .latin),
        Language(code: "ms", englishName: "Malay", nativeName: "Bahasa Melayu", isRTL: false, script: .latin),
        Language(code: "ml", englishName: "Malayalam", nativeName: "മലയാളം", isRTL: false, script: .other),
        Language(code: "mt", englishName: "Maltese", nativeName: "Malti", isRTL: false, script: .latin),
        Language(code: "mi", englishName: "Maori", nativeName: "Māori", isRTL: false, script: .latin),
        Language(code: "mr", englishName: "Marathi", nativeName: "मराठी", isRTL: false, script: .devanagari),
        Language(code: "mn", englishName: "Mongolian", nativeName: "Монгол", isRTL: false, script: .cyrillic),
        Language(code: "my", englishName: "Myanmar (Burmese)", nativeName: "မြန်မာ", isRTL: false, script: .other),
        Language(code: "ne", englishName: "Nepali", nativeName: "नेपाली", isRTL: false, script: .devanagari),
        Language(code: "no", englishName: "Norwegian", nativeName: "Norsk", isRTL: false, script: .latin),
        Language(code: "or", englishName: "Odia (Oriya)", nativeName: "ଓଡ଼ିଆ", isRTL: false, script: .other),
        Language(code: "ps", englishName: "Pashto", nativeName: "پښتو", isRTL: true, script: .arabic),
        Language(code: "fa", englishName: "Persian", nativeName: "فارسی", isRTL: true, script: .arabic),
        Language(code: "pl", englishName: "Polish", nativeName: "Polski", isRTL: false, script: .latin),
        Language(code: "pt", englishName: "Portuguese", nativeName: "Português", isRTL: false, script: .latin),
        Language(code: "pa", englishName: "Punjabi", nativeName: "ਪੰਜਾਬੀ", isRTL: false, script: .other),
        Language(code: "ro", englishName: "Romanian", nativeName: "Română", isRTL: false, script: .latin),
        Language(code: "ru", englishName: "Russian", nativeName: "Русский", isRTL: false, script: .cyrillic),
        Language(code: "sm", englishName: "Samoan", nativeName: "Gagana Samoa", isRTL: false, script: .latin),
        Language(code: "gd", englishName: "Scots Gaelic", nativeName: "Gàidhlig", isRTL: false, script: .latin),
        Language(code: "sr", englishName: "Serbian", nativeName: "Српски", isRTL: false, script: .cyrillic),
        Language(code: "st", englishName: "Sesotho", nativeName: "Sesotho", isRTL: false, script: .latin),
        Language(code: "sn", englishName: "Shona", nativeName: "Shona", isRTL: false, script: .latin),
        Language(code: "sd", englishName: "Sindhi", nativeName: "سنڌي", isRTL: true, script: .arabic),
        Language(code: "si", englishName: "Sinhala", nativeName: "සිංහල", isRTL: false, script: .other),
        Language(code: "sk", englishName: "Slovak", nativeName: "Slovenčina", isRTL: false, script: .latin),
        Language(code: "sl", englishName: "Slovenian", nativeName: "Slovenščina", isRTL: false, script: .latin),
        Language(code: "so", englishName: "Somali", nativeName: "Soomaali", isRTL: false, script: .latin),
        Language(code: "es", englishName: "Spanish", nativeName: "Español", isRTL: false, script: .latin),
        Language(code: "su", englishName: "Sundanese", nativeName: "Basa Sunda", isRTL: false, script: .latin),
        Language(code: "sw", englishName: "Swahili", nativeName: "Kiswahili", isRTL: false, script: .latin),
        Language(code: "sv", englishName: "Swedish", nativeName: "Svenska", isRTL: false, script: .latin),
        Language(code: "tg", englishName: "Tajik", nativeName: "Тоҷикӣ", isRTL: false, script: .cyrillic),
        Language(code: "ta", englishName: "Tamil", nativeName: "தமிழ்", isRTL: false, script: .other),
        Language(code: "tt", englishName: "Tatar", nativeName: "Татар теле", isRTL: false, script: .cyrillic),
        Language(code: "te", englishName: "Telugu", nativeName: "తెలుగు", isRTL: false, script: .other),
        Language(code: "th", englishName: "Thai", nativeName: "ไทย", isRTL: false, script: .thai),
        Language(code: "tr", englishName: "Turkish", nativeName: "Türkçe", isRTL: false, script: .latin),
        Language(code: "tk", englishName: "Turkmen", nativeName: "Türkmen", isRTL: false, script: .latin),
        Language(code: "uk", englishName: "Ukrainian", nativeName: "Українська", isRTL: false, script: .cyrillic),
        Language(code: "ur", englishName: "Urdu", nativeName: "اردو", isRTL: true, script: .arabic),
        Language(code: "ug", englishName: "Uyghur", nativeName: "ئۇيغۇرچە", isRTL: true, script: .arabic),
        Language(code: "uz", englishName: "Uzbek", nativeName: "Oʻzbek", isRTL: false, script: .latin),
        Language(code: "vi", englishName: "Vietnamese", nativeName: "Tiếng Việt", isRTL: false, script: .latin),
        Language(code: "cy", englishName: "Welsh", nativeName: "Cymraeg", isRTL: false, script: .latin),
        Language(code: "xh", englishName: "Xhosa", nativeName: "isiXhosa", isRTL: false, script: .latin),
        Language(code: "yi", englishName: "Yiddish", nativeName: "ייִדיש", isRTL: true, script: .hebrew),
        Language(code: "yo", englishName: "Yoruba", nativeName: "Yorùbá", isRTL: false, script: .latin),
        Language(code: "zu", englishName: "Zulu", nativeName: "isiZulu", isRTL: false, script: .latin),
    ]

    static let byCode: [String: Language] = Dictionary(uniqueKeysWithValues: all.map { ($0.code, $0) })

    static func language(for code: String) -> Language? {
        byCode[normalize(code)]
    }

    /// nil/unknown code -> false, so callers can pass an optional detector
    /// result straight through without an extra unwrap.
    static func isRTL(_ code: String?) -> Bool {
        guard let code else { return false }
        return language(for: code)?.isRTL ?? false
    }

    static func englishName(for code: String) -> String {
        language(for: code)?.englishName ?? code
    }

    static func nativeName(for code: String) -> String {
        language(for: code)?.nativeName ?? code
    }

    static func script(for code: String) -> Script? {
        language(for: code)?.script
    }

    /// Normalizes a raw code from a detector or a server response to the
    /// canonical form stored in `all`: strips region subtags (`pt-BR` -> `pt`)
    /// except where the canonical code itself carries one (`zh-CN`, `zh-TW`),
    /// and maps legacy synonyms some services still emit (`iw` -> `he`,
    /// `in` -> `id`, `ji` -> `yi`, `fil` -> `tl`).
    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return trimmed }
        let lower = trimmed.lowercased()

        switch lower {
        case "iw": return "he"
        case "in": return "id"
        case "ji": return "yi"
        case "fil": return "tl"
        default: break
        }

        // Chinese is the one canonical family that keeps its region subtag,
        // so it needs its own branch instead of the generic strip below.
        if lower.hasPrefix("zh") {
            if lower.contains("hant") || lower.contains("tw") || lower.contains("hk") {
                return "zh-TW"
            }
            return "zh-CN"
        }

        if let dash = lower.firstIndex(of: "-") {
            return String(lower[lower.startIndex..<dash])
        }
        return lower
    }

    /// Replaces old `.hasPrefix` checks: does a raw detected code refer to
    /// canonical `code`?
    static func matchesLanguage(_ detectedRaw: String, _ code: String) -> Bool {
        normalize(detectedRaw) == code
    }

    // Bing spells a handful of codes differently from Google; everything not
    // listed here is passed through unchanged. "auto" maps to "" because
    // Bing expects the `from` param omitted entirely for auto-detect.
    private static let bingCodes: [String: String] = [
        "zh-CN": "zh-Hans",
        "zh-TW": "zh-Hant",
        "sr": "sr-Cyrl",
        "tl": "fil",
        "hmn": "mww",
        "no": "nb",
        "he": "he",
        "auto": "",
    ]

    // Google's TTS endpoint mostly matches the translate endpoint, but wants
    // Chinese written out in full and Filipino under its old `fil` code.
    private static let googleTTSCodes: [String: String] = [
        "zh-CN": "zh-CN",
        "zh-TW": "zh-TW",
        "tl": "fil",
    ]

    /// Per-engine code mapping. Overrides live ONLY here in these small
    /// per-engine dictionaries; the catalog rows above store only canonical
    /// codes.
    static func engineCode(_ canonical: String, for engine: Engine) -> String {
        switch engine {
        case .google:
            return canonical
        case .bing:
            return bingCodes[canonical] ?? canonical
        case .geminiPrompt:
            // An LLM prompt wants a language name ("Persian"), not a code.
            // Persian gets its common alias spelled out since "Farsi" is
            // what most people search for.
            if canonical == "fa" { return "Persian (Farsi)" }
            return englishName(for: canonical)
        case .googleTTS:
            return googleTTSCodes[canonical] ?? canonical
        }
    }
}
