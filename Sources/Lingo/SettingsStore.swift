import AppKit
import Combine
import BenchCore

/// App settings persisted in UserDefaults. Grown from the old `Settings`
/// class into an `ObservableObject` so the Settings tabs and the popup can
/// bind to it directly; non-SwiftUI callers keep the same synchronous
/// property access they had before.
///
/// Every `@Published` property writes UserDefaults from its `didSet`, gated
/// on `isLoaded` so loading stored values during `init` doesn't write them
/// straight back. Every key carries the `lingo.` prefix and lives in
/// `BenchDefaults.standard` — Bench's four modules share one preferences
/// domain, so a bare `"targetLanguage"` (Transi's own key) would collide
/// with another module's key of the same name.
///
/// Accent color, light/dark, and update-channel are app-wide now
/// (`BenchCore.AppearanceSettings`, `Bench`'s own updater), so this store,
/// unlike Transi's, does not carry `accentTheme`, `colorScheme`, or
/// `includePrereleases`.
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private let defaults: UserDefaults
    private var isLoaded = false

    // MARK: - Languages

    /// Canonical catalog code of the default translate-to language.
    /// The UserDefaults key is unchanged (aside from the `lingo.` prefix)
    /// from the shipped two-language version, so upgrades keep whatever pair
    /// the user already had; only the *first-run* value changed (it used to
    /// be hardcoded "fa" — see `Self.systemDefaultPair`).
    @Published var targetLanguage: String = SettingsStore.systemDefaultPair.target {
        didSet { if isLoaded { defaults.set(targetLanguage, forKey: "lingo.targetLanguage") } }
    }

    /// The other half of the user's working pair. See `defaultTarget(for:)`
    /// for how the two combine to pick a direction.
    @Published var secondaryLanguage: String = SettingsStore.systemDefaultPair.secondary {
        didSet { if isLoaded { defaults.set(secondaryLanguage, forKey: "lingo.secondaryLanguage") } }
    }

    /// Languages offered in the popup pickers and the menu. Always kept a
    /// superset of {target, secondary} — see `enabledLanguages`.
    @Published var enabledLanguageCodes: [String] = [] {
        didSet { if isLoaded { defaults.set(enabledLanguageCodes, forKey: "lingo.enabledLanguages") } }
    }

    /// "auto" or a fixed canonical code.
    @Published var sourceLanguage: String = LanguageCatalog.autoCode {
        didSet { if isLoaded { defaults.set(sourceLanguage, forKey: "lingo.sourceLanguage") } }
    }

    /// The enabled set with the target/secondary guarantee applied, in stored
    /// order. UI iterates this, never `enabledLanguageCodes` directly.
    var enabledLanguages: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for code in enabledLanguageCodes + [targetLanguage, secondaryLanguage]
        where LanguageCatalog.byCode[code] != nil && seen.insert(code).inserted {
            out.append(code)
        }
        return out
    }

    // MARK: - Engines

    /// All engines in display/failover order. Order is meaningful even for
    /// disabled engines so toggling one off and on doesn't lose its place.
    @Published var engineOrder: [EngineID] = [.google, .bing, .gemini] {
        didSet { if isLoaded { defaults.set(engineOrder.map(\.rawValue), forKey: "lingo.engineOrder") } }
    }

    /// Gemini stays off until the user adds a key.
    @Published var enabledEngines: Set<EngineID> = [.google, .bing] {
        didSet { if isLoaded { defaults.set(enabledEngines.map(\.rawValue).sorted(), forKey: "lingo.enabledEngines") } }
    }

    /// Per-target-language primary-engine override (canonical code → engine).
    @Published var perLanguageEngineOverride: [String: EngineID] = [:] {
        didSet {
            if isLoaded {
                defaults.set(perLanguageEngineOverride.mapValues(\.rawValue), forKey: "lingo.perLanguageEngineOverride")
            }
        }
    }

    /// Register for engines that support one (Bing, Gemini). The popup's
    /// tone control and the Engines tab both bind here.
    @Published var tone: TranslationTone = .standard {
        didSet { if isLoaded { defaults.set(tone.rawValue, forKey: "lingo.translationTone") } }
    }

    @Published var geminiModel: String = GeminiEngine.defaultModel {
        didSet { if isLoaded { defaults.set(geminiModel, forKey: "lingo.geminiModel") } }
    }

    /// How much reasoning Gemini may do before answering. Defaults to `.low`
    /// — see `GeminiThinking` for the measurements behind that choice.
    @Published var geminiThinking: GeminiThinking = .low {
        didSet { if isLoaded { defaults.set(geminiThinking.rawValue, forKey: "lingo.geminiThinking") } }
    }

    @Published var hasAcknowledgedGeminiPrivacyNote: Bool = false {
        didSet { if isLoaded { defaults.set(hasAcknowledgedGeminiPrivacyNote, forKey: "lingo.geminiPrivacyNoteAcknowledged") } }
    }

    /// Enabled engines in failover order. First entry is the default primary.
    var orderedEnabledEngines: [EngineID] {
        engineOrder.filter { enabledEngines.contains($0) }
    }

    /// The engine whose result is "primary" (reserved top card, copy target)
    /// for a given target language: per-language override first, then the
    /// first enabled engine in order.
    func primaryEngine(forTarget code: String) -> EngineID? {
        if let override = perLanguageEngineOverride[code], enabledEngines.contains(override) {
            return override
        }
        return orderedEnabledEngines.first
    }

    /// For UI gating only — the key itself lives in the key-file store.
    var hasGeminiKey: Bool { KeychainStore.read(.geminiAPIKey) != nil }

    // MARK: - Popup text / controls

    /// Multiplier on the popup's base text sizes (0.8...1.6).
    @Published var popupTextSize: Double = 1.0 {
        didSet { if isLoaded { defaults.set(popupTextSize, forKey: "lingo.popupTextSize") } }
    }

    /// Show the Latin-script romanization Bing and Gemini return under a
    /// non-Latin translation ("Finglish" for Persian, pinyin for Chinese).
    /// Off by default: for readers of the target script it is a second line
    /// of noise under every result.
    @Published var showTransliteration: Bool = false {
        didSet { if isLoaded { defaults.set(showTransliteration, forKey: "lingo.showTransliteration") } }
    }

    /// Renders the popup's controls (language pickers, swap/pin/close, card
    /// action icons) ~35% larger. Separate from `popupTextSize`, which only
    /// scales the text being read.
    @Published var largePopupControls: Bool = false {
        didSet { if isLoaded { defaults.set(largePopupControls, forKey: "lingo.largePopupControls") } }
    }

    // MARK: - Popup window

    /// Close the popup on its own once the pointer has stayed away from the
    /// window for `autoDismissDelay` seconds. Pin, an open picker, and
    /// composing with a draft all suspend it.
    @Published var autoDismissEnabled: Bool = true {
        didSet { if isLoaded { defaults.set(autoDismissEnabled, forKey: "lingo.autoDismissEnabled") } }
    }

    @Published var autoDismissDelay: Double = 2.0 {
        didSet { if isLoaded { defaults.set(autoDismissDelay, forKey: "lingo.autoDismissDelay") } }
    }

    static let minPopupSize = NSSize(width: 380, height: 280)
    static let defaultPopupSize = NSSize(width: 480, height: 420)

    /// Popup window size, remembered across launches once the user resizes it.
    var popupSize: NSSize {
        get {
            let width = defaults.object(forKey: "lingo.popupWidth") as? CGFloat
                ?? Self.defaultPopupSize.width
            let height = defaults.object(forKey: "lingo.popupHeight") as? CGFloat
                ?? Self.defaultPopupSize.height
            return NSSize(
                width: max(width, Self.minPopupSize.width),
                height: max(height, Self.minPopupSize.height))
        }
        set {
            defaults.set(newValue.width, forKey: "lingo.popupWidth")
            defaults.set(newValue.height, forKey: "lingo.popupHeight")
        }
    }

    func resetPopupSize() {
        defaults.removeObject(forKey: "lingo.popupWidth")
        defaults.removeObject(forKey: "lingo.popupHeight")
    }

    // MARK: - Init / load

    /// `defaults` defaults to the shared `BenchDefaults.standard`; a test
    /// passes its own private `UserDefaults(suiteName:)` so the pair/direction
    /// logic below can be exercised without touching real preferences — same
    /// pattern as `BenchCore.ShortcutStore`.
    init(defaults: UserDefaults = BenchDefaults.standard) {
        self.defaults = defaults
        Self.importFromTransiIfNeeded()

        if let raw = defaults.string(forKey: "lingo.targetLanguage"), LanguageCatalog.byCode[raw] != nil {
            targetLanguage = raw
        }
        if let raw = defaults.string(forKey: "lingo.secondaryLanguage"), LanguageCatalog.byCode[raw] != nil {
            secondaryLanguage = raw
        } else {
            // No stored secondary: pair whatever target we ended up with
            // against the system-derived partner.
            secondaryLanguage = Self.partnerForFirstRun(of: targetLanguage)
        }
        if let stored = defaults.array(forKey: "lingo.enabledLanguages") as? [String] {
            enabledLanguageCodes = stored.filter { LanguageCatalog.byCode[$0] != nil }
        }
        if enabledLanguageCodes.isEmpty {
            enabledLanguageCodes = [targetLanguage, secondaryLanguage]
        }
        // One-time repair: the popup's source picker used to write every pick
        // straight into this setting, so a stored fixed source is far more
        // likely to be an accident from that than a deliberate choice — and a
        // wrong one silently defeats the whole direction rule (a fixed
        // "English" makes Persian text translate English→Persian, which the
        // engines return unchanged). Popup picks are session-scoped now, so
        // this can only happen once.
        if !defaults.bool(forKey: "lingo.didResetStickySourceLanguage") {
            defaults.set(true, forKey: "lingo.didResetStickySourceLanguage")
            defaults.removeObject(forKey: "lingo.sourceLanguage")
        }
        if let raw = defaults.string(forKey: "lingo.sourceLanguage"),
           raw == LanguageCatalog.autoCode || LanguageCatalog.byCode[raw] != nil {
            sourceLanguage = raw
        }

        if let stored = defaults.array(forKey: "lingo.engineOrder") as? [String] {
            let decoded = stored.compactMap(EngineID.init(rawValue:))
            // Engines added in later versions append at the end rather than
            // vanishing from the order.
            if !decoded.isEmpty {
                engineOrder = decoded + EngineID.allCases.filter { !decoded.contains($0) }
            }
        }
        if let stored = defaults.array(forKey: "lingo.enabledEngines") as? [String] {
            enabledEngines = Set(stored.compactMap(EngineID.init(rawValue:)))
            if enabledEngines.isEmpty { enabledEngines = [.google] }
        }
        if let stored = defaults.dictionary(forKey: "lingo.perLanguageEngineOverride") as? [String: String] {
            perLanguageEngineOverride = stored.compactMapValues(EngineID.init(rawValue:))
        }
        if let raw = defaults.string(forKey: "lingo.translationTone"), let stored = TranslationTone(rawValue: raw) {
            tone = stored
        }
        if let raw = defaults.string(forKey: "lingo.geminiModel"), !raw.isEmpty {
            geminiModel = raw
        }
        if let raw = defaults.string(forKey: "lingo.geminiThinking"),
           let stored = GeminiThinking(rawValue: raw) {
            geminiThinking = stored
        }
        hasAcknowledgedGeminiPrivacyNote = defaults.bool(forKey: "lingo.geminiPrivacyNoteAcknowledged")

        let storedTextSize = defaults.double(forKey: "lingo.popupTextSize")
        if storedTextSize > 0 { popupTextSize = min(max(storedTextSize, 0.8), 1.6) }

        largePopupControls = defaults.bool(forKey: "lingo.largePopupControls")
        showTransliteration = defaults.bool(forKey: "lingo.showTransliteration")
        if defaults.object(forKey: "lingo.autoDismissEnabled") != nil {
            autoDismissEnabled = defaults.bool(forKey: "lingo.autoDismissEnabled")
        }
        let storedDelay = defaults.double(forKey: "lingo.autoDismissDelay")
        if storedDelay > 0 { autoDismissDelay = min(max(storedDelay, 0.5), 10) }

        isLoaded = true
    }

    // MARK: - Language pair helpers

    /// The "other" language of the user's default pair, used by auto-flip:
    /// translating into `target` when the text already IS `target` flips here.
    /// A manually picked third language flips back to the secondary.
    func partner(of target: String) -> String {
        target == secondaryLanguage ? targetLanguage : secondaryLanguage
    }

    /// The non-English half of the configured pair, or nil when the pair has
    /// no English in it at all.
    var nonEnglishOfPair: String? {
        if targetLanguage != Self.englishCode { return targetLanguage }
        if secondaryLanguage != Self.englishCode { return secondaryLanguage }
        return nil
    }

    /// True when English is one of the two configured languages — the
    /// condition under which the English-anchored rule below applies.
    var pairIncludesEnglish: Bool {
        targetLanguage == Self.englishCode || secondaryLanguage == Self.englishCode
    }

    /// The default target for a capture whose source language is `source`
    /// (canonical code, already normalized; nil = not determined yet).
    ///
    /// English-anchored, per the requested behaviour: when English is one of
    /// the configured pair, English input goes to the pair's other language
    /// and *everything else* — including the pair's own non-English half —
    /// goes to English. When the pair has no English in it (say French +
    /// German), that rule would ignore the user's settings entirely, so the
    /// plain pair flip applies instead: source == target flips to the
    /// secondary, anything else goes to the target.
    ///
    /// A nil `source` returns the configured target as a provisional answer;
    /// the caller re-runs once an engine reports the detected language.
    func defaultTarget(forSource source: String?) -> String {
        guard pairIncludesEnglish, let other = nonEnglishOfPair else {
            guard let source else { return targetLanguage }
            return source == targetLanguage ? partner(of: targetLanguage) : targetLanguage
        }
        // An undetermined source is assumed English: it is the anchor of this
        // rule and by far the likeliest input, so the common case resolves in
        // one request whichever way round the pair is configured. The caller
        // still checks the engine's own detection and re-runs if it disagrees.
        guard let source else { return other }
        return source == Self.englishCode ? other : Self.englishCode
    }

    // MARK: - First-run defaults

    static let englishCode = "en"

    /// First-run language pair, derived from the Mac's own language list so
    /// nothing ships hardcoded to the author's languages. Target is the
    /// system UI language when the catalog knows it, English otherwise;
    /// the secondary is English, or the next preferred system language when
    /// the system language already IS English.
    static let systemDefaultPair: (target: String, secondary: String) = {
        let preferred = Locale.preferredLanguages
            .map { LanguageCatalog.normalize($0) }
            .filter { LanguageCatalog.byCode[$0] != nil }
        let target = preferred.first ?? englishCode
        return (target, partnerForFirstRun(of: target))
    }()

    /// English for any non-English target; for an English target, the next
    /// distinct system language, falling back to Spanish (the most common
    /// second language among macOS installs) so the pair is never degenerate.
    static func partnerForFirstRun(of target: String) -> String {
        guard target == englishCode else { return englishCode }
        let next = Locale.preferredLanguages
            .map { LanguageCatalog.normalize($0) }
            .first { LanguageCatalog.byCode[$0] != nil && $0 != englishCode }
        return next ?? "es"
    }

    // MARK: - Standalone import

    /// Every UserDefaults key this store knows, old (Transi) name to new
    /// (`lingo.`-prefixed) name. Copy-only, once — see
    /// `StandaloneImport.importDefaultsIfNeeded`.
    private static func importFromTransiIfNeeded() {
        StandaloneImport.importDefaultsIfNeeded(
            sourceDomain: "com.fxreza.transi",
            keys: [
                "targetLanguage": "lingo.targetLanguage",
                "secondaryLanguage": "lingo.secondaryLanguage",
                "enabledLanguages": "lingo.enabledLanguages",
                "sourceLanguage": "lingo.sourceLanguage",
                "engineOrder": "lingo.engineOrder",
                "enabledEngines": "lingo.enabledEngines",
                "perLanguageEngineOverride": "lingo.perLanguageEngineOverride",
                "translationTone": "lingo.translationTone",
                "geminiModel": "lingo.geminiModel",
                "geminiThinking": "lingo.geminiThinking",
                "geminiPrivacyNoteAcknowledged": "lingo.geminiPrivacyNoteAcknowledged",
                "popupTextSize": "lingo.popupTextSize",
                "showTransliteration": "lingo.showTransliteration",
                "largePopupControls": "lingo.largePopupControls",
                "autoDismissEnabled": "lingo.autoDismissEnabled",
                "autoDismissDelay": "lingo.autoDismissDelay",
                "popupWidth": "lingo.popupWidth",
                "popupHeight": "lingo.popupHeight",
            ],
            flagKey: "lingo.importedFromTransi")
    }

    /// If Transi had rebound shortcuts (its `shortcuts.bindings` key: a JSON
    /// `[TransiAction.rawValue: KeyBinding]` dictionary — `KeyBinding` there
    /// and `BenchCore.KeyBinding` here are structurally identical, so it
    /// decodes directly), turn them into `ShortcutStore` overrides for the
    /// matching `lingo.*` action ids.
    ///
    /// Called from `LingoController.start()` rather than from `init()`
    /// above: `ShortcutStore.set(_:for:)` silently no-ops for an
    /// unregistered action id, and Lingo's actions are only registered once
    /// `FeatureRegistry.register(_:)` runs — guaranteed to have happened
    /// by the time any feature starts, not guaranteed by the time
    /// `SettingsStore.shared` is first touched.
    static func importShortcutOverridesFromTransiIfNeeded() {
        guard !BenchDefaults.isTestInstance else { return }
        let flagKey = "lingo.importedShortcutsFromTransi"
        guard !BenchDefaults.standard.bool(forKey: flagKey) else { return }
        BenchDefaults.standard.set(true, forKey: flagKey)

        guard let source = UserDefaults.standard.persistentDomain(forName: "com.fxreza.transi"),
              let data = source["shortcuts.bindings"] as? Data,
              let overrides = try? JSONDecoder().decode([String: KeyBinding].self, from: data)
        else { return }

        let idsByOldName: [String: String] = [
            "translateSelection": "lingo.translateSelection",
            "captureScreenshot": "lingo.captureScreenshot",
            "speakSelection": "lingo.speakSelection",
            "translateClipboard": "lingo.translateClipboard",
        ]
        for (oldName, binding) in overrides {
            guard let id = idsByOldName[oldName] else { continue }
            ShortcutStore.shared.set(binding, for: id)
        }
    }
}
