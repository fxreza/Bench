import SwiftUI

/// Popup-only appearance controls: text size, romanization, larger controls,
/// auto-dismiss, and popup window sizing.
///
/// Ported from Transi's `AppearanceTab`, which also held the accent color
/// and light/dark pickers; those are app-wide now (`BenchCore.AppearanceSettings`,
/// set from Bench's own Settings), so this tab drops that "Theme" section
/// entirely rather than offering a second, redundant place to set them.
struct AppearanceTab: View {
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section("Popup Text Size") {
                Slider(value: $settings.popupTextSize, in: 0.8...1.6)
                Text("Sample translation")
                    .font(.system(size: 16 * settings.popupTextSize))
            }

            Section("Results") {
                Toggle("Show romanization under translations", isOn: $settings.showTransliteration)
                Text("Bing and Gemini can return a Latin-script reading of the translation — Finglish for Persian, pinyin for Chinese. Off by default; Google never returns one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Popup Window") {
                Toggle("Larger buttons and controls", isOn: $settings.largePopupControls)
                Text("Enlarges the language pickers, swap, pin, and the icons on result cards — without changing the text size above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Close automatically when the mouse moves away", isOn: $settings.autoDismissEnabled)
                if settings.autoDismissEnabled {
                    HStack {
                        Slider(value: $settings.autoDismissDelay, in: 0.5...10, step: 0.5) {
                            Text("Delay")
                        }
                        Text(String(format: "%.1f s", settings.autoDismissDelay))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                    Text("A pinned popup, an open language picker, or unsent typed text keep the window open regardless.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Reset Popup Size") { settings.resetPopupSize() }
            }
        }
        .formStyle(.grouped)
    }
}
