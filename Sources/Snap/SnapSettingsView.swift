import SwiftUI
import BenchCore

/// Snap's pane in the Settings window: the gap, the title bar gesture, the
/// two editable scripts, the shortcut list, and a note about what did not
/// come over from BetterTouchTool.
struct SnapSettingsView: View {
    @ObservedObject private var settings = SnapSettings.shared
    @State private var scriptMessage: String?
    @State private var scriptMessageIsError = false

    var body: some View {
        Form {
            Section("Layout") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Gap")
                        Slider(value: $settings.gap, in: 0...40, step: 1)
                        Text("\(Int(settings.gap)) pt")
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                            .foregroundStyle(.secondary)
                    }
                    Text("Space left between a window and the screen edges, and between two windows side by side. 0 tiles flush, the way BetterTouchTool did.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Title Bar") {
                Toggle("Double-click a title bar to maximize", isOn: $settings.titleBarDoubleClick)
                Toggle("Double-click again to restore the previous size", isOn: $settings.titleBarDoubleClickRestores)
                    .disabled(!settings.titleBarDoubleClick)
                Text("Watches for a double-click on any window's title bar and fills the screen with it; the next double-click puts it back. Clicks with ⌘⌥⌃⇧ held, and clicks on buttons, tabs and text fields, are ignored. Needs Accessibility. macOS has its own \"double-click a window's title bar to\" setting in System Settings > Desktop & Dock - if that is not None, both will happen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Scripts") {
                scriptEditor(
                    title: "New Terminal Window",
                    text: $settings.terminalScript,
                    reset: { settings.resetTerminalScript() })
                Divider()
                scriptEditor(
                    title: "Open Downloads in Finder",
                    text: $settings.downloadsScript,
                    reset: { settings.resetDownloadsScript() })
                if let scriptMessage {
                    Text(scriptMessage)
                        .font(.caption)
                        .foregroundStyle(scriptMessageIsError ? .red : .secondary)
                }
                Text("AppleScript. The first run against Terminal or Finder asks for Automation permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            FeatureShortcutsSection(featureID: "snap")

            Section {
                Text("""
                    Caps Lock is remapped to Right Control on this Mac, so ⌃⌘ combinations are typed with Caps Lock. \
                    BetterTouchTool could tell the right Control key from the left one; global hot keys cannot, so \
                    either Control key triggers these.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("""
                    Two BetterTouchTool items are not part of Snap. "Unpin Focused Window To NOT Float On Top" \
                    relied on BTT's private window-level manipulation, which Accessibility does not expose. The three \
                    "Menubar Item: │" separators were cosmetic dividers in BTT's own menu bar.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func scriptEditor(title: String, text: Binding<String>, reset: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Button("Reset") { reset() }
                    .buttonStyle(.link)
                    .font(.caption)
                Button("Run") { run(text.wrappedValue, name: title) }
                    .font(.caption)
            }
            TextEditor(text: text)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 96)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.3)))
        }
    }

    private func run(_ source: String, name: String) {
        scriptMessage = "Running \(name)…"
        scriptMessageIsError = false
        ScriptRunner.run(source) { message in
            MainActor.assumeIsolated {
                scriptMessageIsError = message != nil
                scriptMessage = message ?? "\(name) ran without errors."
            }
        }
    }
}
