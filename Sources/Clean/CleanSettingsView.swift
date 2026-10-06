import SwiftUI
import BenchCore

/// Clean's pane: the start button and the three choices.
struct CleanSettingsView: View {
    @ObservedObject private var settings = CleanSettings.shared
    @ObservedObject private var permissions = PermissionsState.shared

    var body: some View {
        Form {
            Section {
                Button {
                    CleanCommands.start?()
                } label: {
                    Label("Start Cleaning Mode", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)

                Text("Locks immediately. Unlock by pressing & holding a trackpad / mouse button for \(settings.holdSeconds) s.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !permissions.accessibilityTrusted {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(
                            "Clean needs Accessibility to block the keyboard, trackpad and mouse.",
                            systemImage: "lock")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Open Permissions") { BenchSettings.open(.permissions) }
                            .font(.caption)
                    }
                }
            }

            Section("Screen") {
                LabeledContent("Darken all screens") {
                    HStack {
                        Slider(value: $settings.darkness, in: 0...1)
                        Text("\(Int((settings.darkness * 100).rounded())) %")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }

                Toggle("Show unlock indicator while locked", isOn: $settings.showIndicator)

                Text(settings.showIndicator
                    ? "The hold-to-unlock square stays in the middle of the screen for the whole lock."
                    : "The screen stays dark; the hold-to-unlock square appears only while you hold a button.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Unlocking") {
                Stepper(value: $settings.holdSeconds, in: CleanSettings.holdSecondsRange) {
                    LabeledContent("Press & hold any trackpad / mouse button to unlock for:") {
                        Text("\(settings.holdSeconds) s").monospacedDigit()
                    }
                }
            }

            Section {
                Text("""
                    While locked, every key is blocked (media, function and modifier keys too), and so are \
                    trackpad and mouse clicks, movement, scrolling and gestures. The display stays awake and \
                    the screensaver does not start.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("""
                    There is deliberately no keyboard shortcut to unlock - wiping the keyboard would hit it. \
                    Quitting Bench always unlocks everything.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
