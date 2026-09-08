import AppKit
import SwiftUI
import UniformTypeIdentifiers
import BenchCore

/// Snap's pane in the Settings window: the gap, the modifier move/resize
/// gestures, the two editable scripts, the shortcut list, and a note about
/// what did not come over from BetterTouchTool.
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

            Section("Window moving & resizing") {
                Toggle("Move and resize with modifier keys", isOn: $settings.modifierDragEnabled)
                modifierRow("Move", flags: $settings.moveModifiers)
                modifierRow("Resize", flags: $settings.resizeModifiers)
                HStack {
                    Text("Threshold")
                    TextField("", value: $settings.dragThreshold, format: .number)
                        .labelsHidden()
                        .frame(width: 60)
                        .multilineTextAlignment(.trailing)
                    Text("pt")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .disabled(!settings.modifierDragEnabled)
                Toggle("Bring the moved window to the front", isOn: $settings.bringToFront)
                    .disabled(!settings.modifierDragEnabled)
                Text("Hold the keys and move the mouse over a window, no click needed.")
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

            Section("Open apps") {
                ForEach(1...SnapSettings.launcherSlots, id: \.self) { slot in
                    HStack {
                        Text("App \(slot)")
                            .frame(width: 56, alignment: .leading)
                        Text(settings.launcherName(slot) ?? "Not set")
                            .foregroundStyle(settings.launcherName(slot) == nil ? .secondary : .primary)
                        Spacer()
                        Button("Choose…") { chooseApp(for: slot) }
                        Button("Clear") { settings.setLauncher(slot, url: nil) }
                            .disabled(settings.launcherName(slot) == nil)
                    }
                }
                Text("Three spare shortcuts that open (or bring forward) an app. They ship unbound: pick the app, then record a key in the list below. Caps Lock+⌥ plus a letter is free on this Mac, apart from ⌃⌥E and ⌃⌥T, which the two scripts use.")
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

    /// The five modifiers a gesture can be built from, in the order a Mac
    /// keyboard lays them out.
    private struct ModifierChoice: Identifiable {
        let id: Int
        let flag: NSEvent.ModifierFlags
        let label: String
    }

    private static let modifierChoices: [ModifierChoice] = [
        ModifierChoice(id: 0, flag: .shift, label: "⇧ shift"),
        ModifierChoice(id: 1, flag: .function, label: "fn"),
        ModifierChoice(id: 2, flag: .control, label: "⌃ ctrl"),
        ModifierChoice(id: 3, flag: .option, label: "⌥ opt"),
        ModifierChoice(id: 4, flag: .command, label: "⌘ cmd"),
    ]

    /// One labelled row of five checkboxes editing a modifier combination.
    /// The gesture fires on an exact match, so a checked box is a key that
    /// must be down and an unchecked one a key that must not be.
    @ViewBuilder
    private func modifierRow(_ title: String, flags: Binding<NSEvent.ModifierFlags>) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .frame(width: 56, alignment: .leading)
            ForEach(Self.modifierChoices) { choice in
                Toggle(choice.label, isOn: Binding(
                    get: { flags.wrappedValue.contains(choice.flag) },
                    set: { isOn in
                        var value = flags.wrappedValue
                        if isOn { value.insert(choice.flag) } else { value.remove(choice.flag) }
                        flags.wrappedValue = value
                    }))
                    .toggleStyle(.checkbox)
            }
            Spacer()
        }
        .disabled(!settings.modifierDragEnabled)
    }

    /// Picks a .app for launcher `slot`. Only the path is kept: a moved or
    /// deleted app just makes the slot read "Not set" again.
    private func chooseApp(for slot: Int) {
        let panel = NSOpenPanel()
        panel.title = "Choose the app for Open App \(slot)"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.setLauncher(slot, url: url)
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
