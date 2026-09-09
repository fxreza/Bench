import SwiftUI
import BenchCore

/// Tap's pane: the two triggers, what each one means, and the two things that
/// can stop the module working (no Accessibility, no multitouch device).
struct TapSettingsView: View {
    @ObservedObject private var settings = TapSettings.shared
    @ObservedObject private var status = TapStatus.shared

    var body: some View {
        Form {
            Section("Middle click") {
                Picker("Three fingers", selection: $settings.mode) {
                    ForEach(TapSettings.MiddleClickMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .disabled(!status.isAvailable)

                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Hold fn and click", isOn: $settings.fnClickEnabled)

                Text(fnExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let reason = status.unavailableReason {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if status.accessibilityMissing {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(
                            "Tap needs Accessibility to change a click into a middle click.",
                            systemImage: "lock")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Open Permissions") { BenchSettings.open(.permissions) }
                            .font(.caption)
                    }
                }
            }

            Section {
                Text("""
                    A middle click can be dragged: hold the click - three fingers or fn - and move, and the \
                    drag arrives as a middle-button drag even after the fingers come off the pad.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var fnExplanation: String {
        settings.fnClickEnabled
            ? "Hold fn and click normally, with one finger. Nothing is counted, so this works "
                + "whenever the three-finger gesture does not. fn is free to use: ⌘, ⇧, ⌥ and ⌃ "
                + "all mean something else on a click already."
            : "fn and a click are left alone."
    }

    private var explanation: String {
        switch settings.mode {
        case .off:
            return settings.fnClickEnabled
                ? "Three-finger gestures are left to macOS; fn and a click still send a middle click."
                : "Three-finger gestures are left to macOS."
        case .click:
            return "Press the trackpad down with three fingers on it. The left click is replaced, not added to."
        case .tap:
            return "Touch the pad with three fingers and lift within a quarter of a second, without pressing or sliding."
        case .both:
            return "Either a three-finger press or a quick three-finger tap sends a middle click."
        }
    }
}
