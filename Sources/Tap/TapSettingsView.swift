import SwiftUI
import BenchCore

/// Tap's pane: the mode picker, what each mode means, and the two things that
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
                    If BetterTouchTool is still running with its own "3 finger click → middle click" trigger, \
                    turn that trigger off. Both would fire and the app under the pointer would get two middle \
                    clicks.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("""
                    A middle click can be dragged: hold the three-finger click and move, and the drag arrives \
                    as a middle-button drag even after fingers come off the pad.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var explanation: String {
        switch settings.mode {
        case .off:
            return "Three-finger gestures are left to macOS."
        case .click:
            return "Press the trackpad down with three fingers on it. The left click is replaced, not added to."
        case .tap:
            return "Touch the pad with three fingers and lift within a quarter of a second, without pressing or sliding."
        case .both:
            return "Either a three-finger press or a quick three-finger tap sends a middle click."
        }
    }
}
