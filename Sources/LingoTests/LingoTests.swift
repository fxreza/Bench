import Foundation
import BenchTestKit
@testable import Lingo

enum LanguageCatalogTests {
    static let tests: [TestCase] = [
        ("byCode finds a known language", {
            try expectEqual(LanguageCatalog.byCode["fa"]?.englishName, "Persian")
            try expectEqual(LanguageCatalog.byCode["en"]?.englishName, "English")
        }),
        ("normalize strips region subtags", {
            try expectEqual(LanguageCatalog.normalize("pt-BR"), "pt")
            try expectEqual(LanguageCatalog.normalize("en-US"), "en")
        }),
        ("normalize keeps Chinese's region subtag", {
            try expectEqual(LanguageCatalog.normalize("zh-Hant"), "zh-TW")
            try expectEqual(LanguageCatalog.normalize("zh-TW"), "zh-TW")
            try expectEqual(LanguageCatalog.normalize("zh-HK"), "zh-TW")
            try expectEqual(LanguageCatalog.normalize("zh"), "zh-CN")
        }),
        ("normalize maps legacy synonyms", {
            try expectEqual(LanguageCatalog.normalize("iw"), "he")
            try expectEqual(LanguageCatalog.normalize("in"), "id")
            try expectEqual(LanguageCatalog.normalize("ji"), "yi")
            try expectEqual(LanguageCatalog.normalize("fil"), "tl")
        }),
        ("normalize lowercases and trims", {
            try expectEqual(LanguageCatalog.normalize("  EN  "), "en")
        }),
        ("language(for:) normalizes before lookup", {
            try expectEqual(LanguageCatalog.language(for: "PT-br")?.code, "pt")
            try expectNil(LanguageCatalog.language(for: "not-a-real-code"))
        }),
        ("isRTL", {
            try expect(LanguageCatalog.isRTL("fa"), "Persian is RTL")
            try expect(LanguageCatalog.isRTL("ar"), "Arabic is RTL")
            try expect(!LanguageCatalog.isRTL("en"), "English is not RTL")
            try expect(!LanguageCatalog.isRTL(nil), "nil is not RTL")
        }),
        ("engineCode: Bing deviations, canonical pass-through otherwise", {
            try expectEqual(LanguageCatalog.engineCode("zh-CN", for: .bing), "zh-Hans")
            try expectEqual(LanguageCatalog.engineCode("zh-TW", for: .bing), "zh-Hant")
            try expectEqual(LanguageCatalog.engineCode("tl", for: .bing), "fil")
            try expectEqual(LanguageCatalog.engineCode("auto", for: .bing), "")
            try expectEqual(LanguageCatalog.engineCode("fr", for: .bing), "fr")
        }),
        ("engineCode: Gemini prompt wants a language name", {
            try expectEqual(LanguageCatalog.engineCode("fa", for: .geminiPrompt), "Persian (Farsi)")
            try expectEqual(LanguageCatalog.engineCode("fr", for: .geminiPrompt), "French")
        }),
        ("engineCode: Google TTS deviations", {
            try expectEqual(LanguageCatalog.engineCode("tl", for: .googleTTS), "fil")
            try expectEqual(LanguageCatalog.engineCode("fr", for: .googleTTS), "fr")
        }),
        ("engineCode: Google is always the canonical code", {
            try expectEqual(LanguageCatalog.engineCode("zh-CN", for: .google), "zh-CN")
        }),
    ]
}

enum ScriptDetectorTests {
    static let tests: [TestCase] = [
        ("detects unambiguous single-language scripts", {
            try expectEqual(ScriptDetector.detect("こんにちは世界"), "ja")
            try expectEqual(ScriptDetector.detect("안녕하세요"), "ko")
            try expectEqual(ScriptDetector.detect("สวัสดี"), "th")
            try expectEqual(ScriptDetector.detect("γειά σου"), "el")
            try expectEqual(ScriptDetector.detect("שלום"), "he")
        }),
        ("mostly-kana-and-han text is Japanese even when Han dominates", {
            try expectEqual(ScriptDetector.detect("日本語を勉強しています"), "ja")
        }),
        ("multi-language scripts defer to the caller", {
            try expectNil(ScriptDetector.detect("hello world"))
            try expectNil(ScriptDetector.detect("سلام دنیا"))
        }),
        ("too short to call", {
            try expectNil(ScriptDetector.detect("a"))
            try expectNil(ScriptDetector.detect(""))
        }),
        ("detectScriptBucket reports the multi-language bucket detect() refuses", {
            try expectEqual(ScriptDetector.detectScriptBucket("hello world"), .latin)
            try expectEqual(ScriptDetector.detectScriptBucket("سلام دنیا"), .arabic)
        }),
    ]
}

enum LingoActionTests {
    static let tests: [TestCase] = [
        ("ids are namespaced under lingo.", {
            for action in LingoAction.allCases {
                try expect(action.id.hasPrefix("lingo."), "\(action.id) missing prefix")
                try expectEqual(action.id, "lingo.\(action.rawValue)")
            }
        }),
        ("default bindings are ⌥ + mnemonic letter", {
            try expectEqual(LingoAction.translateSelection.defaultBinding.display, "⌥T")
            try expectEqual(LingoAction.captureScreenshot.defaultBinding.display, "⌥S")
            try expectEqual(LingoAction.speakSelection.defaultBinding.display, "⌥R")
            try expectEqual(LingoAction.translateClipboard.defaultBinding.display, "⌥C")
        }),
        ("every action produces a rebindable HotkeyAction under the lingo feature", {
            for action in LingoAction.allCases {
                let hotkey = action.hotkeyAction
                try expectEqual(hotkey.featureID, "lingo")
                try expectEqual(hotkey.id, action.id)
                try expect(hotkey.isRebindable, "\(action.id) should be rebindable")
                try expectNotNil(hotkey.defaultBinding)
            }
        }),
        ("four actions, in the order the module contract specifies", {
            try expectEqual(LingoAction.allCases.map(\.rawValue), [
                "translateSelection", "captureScreenshot", "speakSelection", "translateClipboard",
            ])
        }),
    ]
}

@MainActor
enum SettingsStoreTests {
    static func makeStore() -> (SettingsStore, UserDefaults) {
        let name = "lingo.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (SettingsStore(defaults: defaults), defaults)
    }

    static let tests: [TestCase] = [
        ("English-anchored pair: English input goes to the other language", {
            let (store, _) = makeStore()
            store.targetLanguage = "fa"
            store.secondaryLanguage = "en"
            try expectEqual(store.defaultTarget(forSource: "en"), "fa")
        }),
        ("English-anchored pair: anything else, including the pair's own language, goes to English", {
            let (store, _) = makeStore()
            store.targetLanguage = "fa"
            store.secondaryLanguage = "en"
            try expectEqual(store.defaultTarget(forSource: "fa"), "en")
            try expectEqual(store.defaultTarget(forSource: "fr"), "en")
        }),
        ("English-anchored pair: undetermined source is assumed English", {
            let (store, _) = makeStore()
            store.targetLanguage = "fa"
            store.secondaryLanguage = "en"
            try expectEqual(store.defaultTarget(forSource: nil), "fa")
        }),
        ("pair without English: plain flip between the two members", {
            let (store, _) = makeStore()
            store.targetLanguage = "fr"
            store.secondaryLanguage = "de"
            try expectEqual(store.defaultTarget(forSource: "fr"), "de")
            try expectEqual(store.defaultTarget(forSource: "de"), "fr")
            try expectEqual(store.defaultTarget(forSource: "es"), "fr")
        }),
        ("pair without English: undetermined source provisionally targets the configured target", {
            let (store, _) = makeStore()
            store.targetLanguage = "fr"
            store.secondaryLanguage = "de"
            try expectEqual(store.defaultTarget(forSource: nil), "fr")
        }),
        ("enabledLanguages always includes target and secondary", {
            let (store, _) = makeStore()
            store.targetLanguage = "fa"
            store.secondaryLanguage = "en"
            store.enabledLanguageCodes = []
            try expect(store.enabledLanguages.contains("fa"), "target missing")
            try expect(store.enabledLanguages.contains("en"), "secondary missing")
        }),
        ("settings persist into the injected suite under the lingo. prefix", {
            let (store, defaults) = makeStore()
            store.targetLanguage = "de"
            try expectEqual(defaults.string(forKey: "lingo.targetLanguage"), "de")
        }),
        ("a fresh store reloads what an earlier store in the same suite saved", {
            let (store, defaults) = makeStore()
            store.targetLanguage = "fa"
            store.secondaryLanguage = "en"
            store.enabledLanguageCodes = ["fa", "en", "fr"]

            let reloaded = SettingsStore(defaults: defaults)
            try expectEqual(reloaded.targetLanguage, "fa")
            try expectEqual(reloaded.secondaryLanguage, "en")
            try expectEqual(reloaded.enabledLanguageCodes, ["fa", "en", "fr"])
        }),
    ]
}

enum GoogleEngineParserTests {
    static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    static let tests: [TestCase] = [
        ("parses the dj=1 shape with sentences and a detected language", {
            let data = json([
                "sentences": [["trans": "Bonjour"], ["trans": " le monde"]],
                "src": "en",
            ])
            let result = try GoogleEngine.parse(data)
            try expectEqual(result.translatedText, "Bonjour le monde")
            try expectEqual(result.detectedSourceLanguage, "en")
            try expectEqual(result.engine, .google)
        }),
        ("parses a spelling suggestion and dictionary entries", {
            let data = json([
                "sentences": [["trans": "hello"]],
                "src": "en",
                "spell": ["spell_res": "did you mean"],
                "dict": [
                    ["pos": "noun", "entry": [["word": "salut", "reverse_translation": ["hi", "hey"]]]],
                ],
            ])
            let result = try GoogleEngine.parse(data)
            try expectEqual(result.spellingSuggestion, "did you mean")
            try expectEqual(result.dictionary.count, 1)
            try expectEqual(result.dictionary[0].partOfSpeech, "noun")
            try expectEqual(result.dictionary[0].meanings.first?.word, "salut")
        }),
        ("falls back to the legacy array shape", {
            let data = json([["translated", "en"]])
            let result = try GoogleEngine.parse(data)
            try expectEqual(result.translatedText, "translated")
            try expectEqual(result.detectedSourceLanguage, "en")
        }),
        ("throws on a body with no translation", {
            let data = json(["sentences": [] as [Any]])
            var threw = false
            do { _ = try GoogleEngine.parse(data) } catch { threw = true }
            try expect(threw, "empty sentences should fail to parse")
        }),
    ]
}

enum BingEngineParserTests {
    static let tests: [TestCase] = [
        ("errorFromBody recognizes a captcha flag", {
            let engine = BingEngine()
            let error = engine.errorFromBody(["ShowCaptcha": true])
            guard case .captcha = error else { try expect(false, "expected .captcha, got \(error)"); return }
        }),
        ("errorFromBody maps a 401 status to rate limiting", {
            let engine = BingEngine()
            let error = engine.errorFromBody(["StatusCode": 401])
            guard case .rateLimited = error else { try expect(false, "expected .rateLimited, got \(error)"); return }
        }),
        ("errorFromBody passes other statuses through as http errors", {
            let engine = BingEngine()
            let error = engine.errorFromBody(["statusCode": 500])
            guard case .http(500) = error else { try expect(false, "expected .http(500), got \(error)"); return }
        }),
        ("errorFromBody falls back to badResponse", {
            let engine = BingEngine()
            let error = engine.errorFromBody("not a dictionary")
            guard case .badResponse = error else { try expect(false, "expected .badResponse, got \(error)"); return }
        }),
        ("canonical(fromBing:) maps Bing's detection codes to canonical ones", {
            try expectEqual(BingEngine.canonical(fromBing: "zh-Hans"), "zh-CN")
            try expectEqual(BingEngine.canonical(fromBing: "zh-Hant"), "zh-TW")
            try expectEqual(BingEngine.canonical(fromBing: "fil"), "tl")
            try expectEqual(BingEngine.canonical(fromBing: "pt-PT"), "pt")
            try expectEqual(BingEngine.canonical(fromBing: "fr"), "fr")
        }),
    ]
}
