// Ported from Snapper's Views/Settings/ShortcutsTab.swift (MIT, Copyright
// 2026 Sam Reza). The recorder row itself is now `BenchCore.ShortcutRow`,
// which owns the recording, the cross-module conflict check and the
// registration-failure caption; what stays here is everything Shot-specific:
// the per-shortcut format pickers, the derived ⌥ variant line, the variant
// modifier, JPG quality, and the warning about macOS's own screenshot
// shortcuts.

import SwiftUI
import AppKit
import BenchCore

/// Settings > Shortcuts: one rebindable row per `CaptureAction` with its
/// file format, the ⌥ variant of that shortcut with its own format, the
/// variant modifier and JPG quality controls, a warning when macOS's own
/// screenshot shortcuts collide, a reset button, and a read-only reference of
/// the editor's fixed single-key shortcuts.
struct ShortcutsTab: View {
    @ObservedObject private var settings = SettingsManager.shared
    @ObservedObject private var store = ShortcutStore.shared

    var body: some View {
        Form {
            Section("Capture Shortcuts") {
                ForEach(CaptureAction.allCases, id: \.self) { action in
                    CaptureShortcutRow(action: action, settings: settings)
                }

                if SystemHotkeys.systemScreenshotShortcutsEnabled() {
                    systemShortcutsWarning
                }

                HStack {
                    Spacer()
                    Button("Reset to Defaults") { settings.resetHotkeys() }
                        .buttonStyle(.bordered)
                }
            }

            Section("Format") {
                VariantModifierRow(settings: settings)
                JPEGQualityRow(settings: settings)
                Text("Every shortcut has a second combination: the same keys plus the variant modifier. Each one saves in its own format, so \(exampleText).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Editor Shortcuts") {
                Text("Fixed while a capture is open for editing; not rebindable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                editorShortcutsReference
            }
        }
        .formStyle(.grouped)
    }

    /// A live example built from the Capture Area row, e.g.
    /// "⌘⇧4 writes PNG and ⌥⌘⇧4 writes JPG".
    private var exampleText: String {
        let main = CaptureShortcut(.area, .main)
        let alternate = CaptureShortcut(.area, .alternate)
        let mainFormat = settings.format(for: main).title
        guard let mainBinding = settings.effectiveBinding(for: main),
              let alternateBinding = settings.effectiveBinding(for: alternate) else {
            return "one can write PNG while the other writes JPG"
        }
        return "\(mainBinding.display) writes \(mainFormat) and \(alternateBinding.display) writes \(settings.format(for: alternate).title)"
    }

    private var systemShortcutsWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("macOS's own screenshot shortcuts are enabled and will fire together with Shot's. Disable them under Keyboard Shortcuts > Screenshots.")
                .font(.caption)
                .foregroundStyle(.red)
            Button("Open Keyboard Shortcuts…") {
                SystemHotkeys.openKeyboardShortcutsSettings()
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }

    private var editorShortcutsReference: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(Self.editorShortcutEntries, id: \.label) { entry in
                HStack(spacing: 6) {
                    Text(entry.key)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 56, alignment: .leading)
                    Text(entry.label)
                        .font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// The tool keys come straight from `EditorTool` (order and letters
    /// match the toolbar); the rest are fixed editor-window shortcuts with
    /// no model of their own.
    private static let editorShortcutEntries: [EditorShortcutEntry] =
        EditorTool.allCases.map { EditorShortcutEntry(key: $0.shortcutKey.uppercased(), label: $0.title) } + [
            EditorShortcutEntry(key: "⌘Z", label: "Undo"),
            EditorShortcutEntry(key: "⇧⌘Z", label: "Redo"),
            EditorShortcutEntry(key: "⌘C", label: "Copy"),
            EditorShortcutEntry(key: "⌘S", label: "Save"),
            EditorShortcutEntry(key: "⇧⌘S", label: "Save As"),
            EditorShortcutEntry(key: "⌘P", label: "Pin"),
            EditorShortcutEntry(key: "⌘+ / ⌘- / ⌘0", label: "Zoom In / Out / Reset"),
            EditorShortcutEntry(key: "⌘E", label: "Open in Editor"),
            EditorShortcutEntry(key: "Esc", label: "Close"),
        ]
}

private struct EditorShortcutEntry {
    let key: String
    let label: String
}

/// One action: `BenchCore.ShortcutRow` for the recorded shortcut, with the
/// format picker as its accessory, and underneath it the derived variant with
/// its own format and its own notes.
private struct CaptureShortcutRow: View {
    let action: CaptureAction
    @ObservedObject var settings: SettingsManager
    @ObservedObject private var center = HotkeyCenter.shared
    @ObservedObject private var store = ShortcutStore.shared

    private static let recorderWidth: CGFloat = 120
    private static let recorderHeight: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let hotkeyAction = store.action(id: action.hotkeyActionID) {
                ShortcutRow(action: hotkeyAction) {
                    if action.producesImage {
                        FormatPicker(shortcut: main, settings: settings)
                    }
                }
            }

            // Text capture writes no file, so it has neither a format nor the
            // format variant of its shortcut.
            if action.producesImage {
                HStack(spacing: 12) {
                    Text(variantLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    FormatPicker(shortcut: alternate, settings: settings)
                        .disabled(variantBinding == nil)
                    // Not recordable: the variant is always the main shortcut plus
                    // the variant modifier.
                    HotkeyRecorder(display: variantBinding?.display ?? "unavailable", isRebindable: false) { _ in }
                        .frame(width: Self.recorderWidth, height: Self.recorderHeight)
                }
                variantNotes
            }
        }
        .padding(.vertical, 2)
    }

    private var main: CaptureShortcut { CaptureShortcut(action, .main) }
    private var alternate: CaptureShortcut { CaptureShortcut(action, .alternate) }

    private var mainBinding: KeyBinding? { settings.binding(for: action) }
    private var variantBinding: KeyBinding? { settings.effectiveBinding(for: alternate) }

    private var variantLabel: String {
        "with " + KeyModifiers(eventFlags: settings.variantModifiers).symbols
    }

    @ViewBuilder
    private var variantNotes: some View {
        if variantBinding == nil, mainBinding != nil {
            note("The main shortcut already uses \(KeyModifiers(eventFlags: settings.variantModifiers).symbols); pick a different variant modifier below.")
        }
        if let binding = variantBinding, let conflict = settings.conflict(for: binding, excluding: alternate) {
            note("Also assigned to \(conflict.action.title)\(conflict.variant == .alternate ? " (variant)" : "")")
        }
        if let failure = center.failureMessages[action.variantHotkeyID] {
            note(failure)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.red)
    }
}

/// PNG / JPG for one shortcut.
private struct FormatPicker: View {
    let shortcut: CaptureShortcut
    @ObservedObject var settings: SettingsManager

    var body: some View {
        Picker("", selection: binding) {
            ForEach(CaptureFileFormat.allCases, id: \.self) { format in
                Text(format.title).tag(format)
            }
        }
        // Segmented, not the default pop-up: a Form row lays a pop-up's
        // selected value out away from its own control, which reads as two
        // unrelated pieces of UI.
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 96)
    }

    private var binding: Binding<CaptureFileFormat> {
        Binding(
            get: { settings.format(for: shortcut) },
            set: { settings.setFormat($0, for: shortcut) }
        )
    }
}

/// The modifier every variant shortcut adds to its main combination. Any
/// mix of ⌃⌥⇧⌘ works; at least one must stay on.
private struct VariantModifierRow: View {
    @ObservedObject var settings: SettingsManager

    private static let options: [(flag: NSEvent.ModifierFlags, symbol: String, name: String)] = [
        (.control, "⌃", "Control"),
        (.option, "⌥", "Option"),
        (.shift, "⇧", "Shift"),
        (.command, "⌘", "Command"),
    ]

    var body: some View {
        HStack {
            Text("Variant modifier")
            Spacer()
            ForEach(Self.options, id: \.symbol) { option in
                Toggle(option.symbol, isOn: toggle(for: option.flag))
                    .toggleStyle(.button)
                    .help(option.name)
            }
        }
    }

    private func toggle(for flag: NSEvent.ModifierFlags) -> Binding<Bool> {
        Binding(
            get: { settings.variantModifiers.contains(flag) },
            set: { isOn in
                var flags = settings.variantModifiers
                if isOn {
                    flags.insert(flag)
                } else {
                    flags.remove(flag)
                    // Never leave the variants with no modifier of their own:
                    // they would be identical to the main shortcuts.
                    guard !flags.isEmpty else { return }
                }
                settings.variantModifiers = flags
            }
        )
    }
}

/// The one JPG compression value every JPG shortcut writes with.
private struct JPEGQualityRow: View {
    @ObservedObject var settings: SettingsManager

    var body: some View {
        HStack {
            Text("JPG quality")
            Slider(
                value: Binding(
                    get: { Double(settings.jpegQuality) },
                    set: { settings.jpegQuality = Int($0.rounded()) }
                ),
                in: Double(SettingsManager.jpegQualityRange.lowerBound)...Double(SettingsManager.jpegQualityRange.upperBound)
            )
            .frame(minWidth: 120)
            Text("\(settings.jpegQuality)%")
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}
