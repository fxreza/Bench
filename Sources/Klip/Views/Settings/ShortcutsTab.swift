import SwiftUI
import AppKit
import BenchCore

/// Settings > Shortcuts: the global open-Klip hotkey (BenchCore's
/// `FeatureShortcutsSection`, backed by `ShortcutStore` and re-registered by
/// `HotkeyCenter` on every rebind) followed by every in-window
/// `ShortcutAction`, grouped the same way `ShortcutAction.Group` orders them.
/// Wired into the `TabView` in `Views/Settings/KlipSettingsView.swift`.
struct ShortcutsTab: View {
    @ObservedObject private var shortcuts = ShortcutManager.shared
    @ObservedObject private var store = ShortcutStore.shared

    var body: some View {
        Form {
            FeatureShortcutsSection(featureID: KlipHotkeys.featureID, header: "Global")

            Section {
                if let conflict = globalHotkeyConflict {
                    Text("Also bound in-window to \(conflict.label) — while Bench is the frontmost app, whichever handler runs first wins.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("Opens or hides the Klip window from anywhere, even while another app is focused.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(ShortcutAction.Group.allCases, id: \.self) { group in
                Section(group.rawValue) {
                    ForEach(actions(in: group), id: \.self) { action in
                        ClipShortcutRow(action: action)
                    }
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset All to Defaults") {
                        shortcuts.resetAll()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func actions(in group: ShortcutAction.Group) -> [ShortcutAction] {
        ShortcutAction.allCases.filter { $0.group == group && $0.isUserVisible }
    }

    /// The in-window action, if any, that currently shares the global
    /// open-Klip hotkey's exact key + modifier combination. The global
    /// hotkey is a system-wide Carbon registration, so a collision does not
    /// stop either handler from firing — this is purely an informational
    /// note in the tab, not an enforced conflict like
    /// `ShortcutManager.set(_:for:)`'s in-window check.
    private var globalHotkeyConflict: ShortcutAction? {
        guard let global = store.binding(for: KlipHotkeys.toggleHistoryID) else { return nil }
        let globalBinding = ClipKeyBinding(keyCode: global.keyCode, modifiers: ClipKeyModifiers(eventFlags: global.eventFlags))
        return ShortcutAction.allCases.first { shortcuts.binding(for: $0) == globalBinding }
    }
}

/// One rebindable-or-fixed in-window action row: label, recorder, conflict
/// note, Reset. Named apart from BenchCore's `ShortcutRow`, which draws the
/// global rows.
private struct ClipShortcutRow: View {
    let action: ShortcutAction
    @ObservedObject private var shortcuts = ShortcutManager.shared
    @State private var conflict: ShortcutAction?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(action.label)
                    .foregroundStyle(action.isRebindable ? .primary : .secondary)
                Spacer()
                if isNonDefault {
                    Button("Reset") {
                        shortcuts.reset(action: action)
                        conflict = nil
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                HotkeyRecorder(
                    display: shortcuts.displayString(for: action),
                    isRebindable: action.isRebindable
                ) { binding in
                    record(binding)
                }
                .frame(width: 120, height: 24)
            }

            if let conflict {
                Text("Already used by \(conflict.label)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    private var isNonDefault: Bool {
        action.isRebindable && shortcuts.binding(for: action) != action.defaultBinding
    }

    /// BenchCore's recorder hands back its own `KeyBinding`; the in-window
    /// table stores `ClipKeyBinding`, so translate at the boundary.
    private func record(_ binding: KeyBinding) {
        let clipBinding = ClipKeyBinding(keyCode: binding.keyCode, modifiers: ClipKeyModifiers(eventFlags: binding.eventFlags))
        switch shortcuts.set(clipBinding, for: action) {
        case .ok:
            conflict = nil
        case .conflict(let other):
            conflict = other
        }
    }
}
