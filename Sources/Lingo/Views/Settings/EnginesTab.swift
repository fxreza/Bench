import Foundation
import SwiftUI

/// Engine order/enable state, the Gemini API key, and per-language primary
/// overrides.
struct EnginesTab: View {
    @ObservedObject private var settings = SettingsStore.shared

    @State private var draftKey: String = ""
    @State private var keyVisible = false

    /// Model ids Gemini accepts, paired with a short display label. Kept
    /// here rather than on `SettingsStore` since it's UI-only — the store
    /// just holds whichever raw id was picked.
    private static let geminiModels: [(id: String, label: String)] = [
        ("gemini-3.7-flash", "3.7 Flash"),
        ("gemini-3.6-flash", "3.6 Flash"),
        ("gemini-3.5-flash", "3.5 Flash"),
        ("gemini-3.5-flash-lite", "3.5 Flash-Lite"),
    ]

    var body: some View {
        Form {
            Section("Engines (drag to set order — first is primary)") {
                List {
                    ForEach(settings.engineOrder) { engine in
                        engineRow(engine)
                    }
                    .onMove { indices, newOffset in
                        settings.engineOrder.move(fromOffsets: indices, toOffset: newOffset)
                    }
                }
                .frame(height: CGFloat(settings.engineOrder.count) * 36 + 16)
            }

            Section("Tone") {
                Picker("Translation tone", selection: $settings.tone) {
                    ForEach(TranslationTone.allCases) { tone in
                        Text(tone.label).tag(tone)
                    }
                }
                .pickerStyle(.segmented)
                Text("Casual and Formal apply to Bing and Gemini — the same control the Bing website's tone dropdown drives. Google doesn't support tone and always answers standard. Also switchable from the popup header.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Gemini") {
                geminiKeyField

                if !settings.hasAcknowledgedGeminiPrivacyNote {
                    privacyBanner
                }

                Text(settings.hasGeminiKey
                     ? "Key saved"
                     : "No key set — Gemini stays off until one is added")
                    .font(.caption)
                    .foregroundStyle(settings.hasGeminiKey ? Color.secondary : Color.orange)

                Link("Get a free key", destination: URL(string: "https://aistudio.google.com/apikey")!)

                Picker("Model", selection: $settings.geminiModel) {
                    ForEach(Self.geminiModels, id: \.id) { model in
                        Text(model.label).tag(model.id)
                    }
                }

                Picker("Thinking", selection: $settings.geminiThinking) {
                    ForEach(GeminiThinking.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                Text(thinkingHint)
                    .font(.caption)
                    .foregroundStyle(settings.geminiThinking == .medium ? .orange : .secondary)
            }

            Section("Per-Language Primary Engine") {
                ForEach(settings.enabledLanguages, id: \.self) { code in
                    perLanguageRow(code)
                }
                Text("Overrides which engine's result is primary (the reserved top card) when translating into that language.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { draftKey = KeychainStore.read(.geminiAPIKey) ?? "" }
    }

    /// Gemini reasons silently before it writes anything, so this is a speed
    /// control first. The per-level notes are what testing actually showed,
    /// not guesses.
    private var thinkingHint: String {
        switch settings.geminiThinking {
        case .off:
            return "Answers immediately. Fastest on short text, but the model "
                + "sometimes pads the romanization instead of thinking."
        case .low:
            return "Recommended. Scales with the text — matched the slower "
                + "levels on idioms and ambiguous wording, in a fraction of the time."
        case .medium:
            return "Slowest by far, and seen looping until it hit the output "
                + "limit. Kept for completeness; Low or High are the safer picks."
        case .high:
            return "The old behaviour. Slightly more idiomatic phrasing on "
                + "figures of speech, several seconds slower per translation."
        }
    }

    // MARK: - Engine row

    private func engineRow(_ engine: EngineID) -> some View {
        let keyMissing = engine == .gemini && !settings.hasGeminiKey
        return VStack(alignment: .leading, spacing: 2) {
            Toggle(engine.displayName, isOn: enabledBinding(for: engine))
                .disabled(keyMissing)
            if keyMissing {
                Text("Add an API key below first")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func enabledBinding(for engine: EngineID) -> Binding<Bool> {
        Binding(
            get: { settings.enabledEngines.contains(engine) },
            set: { include in
                if include {
                    settings.enabledEngines.insert(engine)
                } else {
                    settings.enabledEngines.remove(engine)
                }
            }
        )
    }

    // MARK: - Gemini key

    private var geminiKeyField: some View {
        HStack {
            Group {
                if keyVisible {
                    TextField("API Key", text: $draftKey)
                } else {
                    SecureField("API Key", text: $draftKey)
                }
            }
            .onSubmit { commitKey() }

            Button {
                keyVisible.toggle()
            } label: {
                Image(systemName: keyVisible ? "eye.slash" : "eye")
            }
            .buttonStyle(.plain)

            Button("Save") { commitKey() }
        }
    }

    /// Empty field clears the key — and turns Gemini off, since it can no
    /// longer be configured; non-empty saves it to the Keychain.
    private func commitKey() {
        let trimmed = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainStore.delete(.geminiAPIKey)
            settings.enabledEngines.remove(.gemini)
        } else {
            KeychainStore.save(trimmed, for: .geminiAPIKey)
        }
        // The key lives in the Keychain, not a `@Published` property, so
        // `hasGeminiKey`'s consumers need an explicit nudge to re-read it.
        settings.objectWillChange.send()
    }

    private var privacyBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("Google's free tier may use text you submit to improve its products.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Got It") { settings.hasAcknowledgedGeminiPrivacyNote = true }
        }
    }

    // MARK: - Per-language override

    private func perLanguageRow(_ code: String) -> some View {
        HStack {
            Text(LanguageCatalog.language(for: code)?.displayName ?? code)
            Spacer()
            Picker("", selection: perLanguageBinding(for: code)) {
                Text("Default").tag(Optional<EngineID>.none)
                ForEach(settings.orderedEnabledEngines) { engine in
                    Text(engine.displayName).tag(Optional(engine))
                }
            }
            .labelsHidden()
            .frame(width: 140)
        }
    }

    private func perLanguageBinding(for code: String) -> Binding<EngineID?> {
        Binding(
            get: { settings.perLanguageEngineOverride[code] },
            set: { settings.perLanguageEngineOverride[code] = $0 }
        )
    }
}
