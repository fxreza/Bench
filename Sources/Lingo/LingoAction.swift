import Carbon.HIToolbox
import BenchCore

// Ported from Transi's Shortcuts/TransiAction.swift (MIT). `KeyBinding`,
// `HotkeyCenter` and `ShortcutStore` are all `BenchCore` now, so this enum
// only supplies what `BenchCore` doesn't know on its own: each action's
// title and factory `KeyBinding`. Transi's fifth case, `openSettings`, was
// display-only (an `NSMenuItem` key equivalent, never a Carbon hotkey) and
// is gone entirely — ⌘, and the Settings window are the app's job now, not
// a per-feature concern.

/// Every global shortcut Lingo can bind, in `HotkeyAction` display order.
enum LingoAction: String, CaseIterable {
    case translateSelection  // ⌥T
    case captureScreenshot   // ⌥S
    case speakSelection      // ⌥R
    case translateClipboard  // ⌥C

    /// `"lingo.<case>"` — the id `HotkeyCenter` and `ShortcutStore` key on.
    var id: String { "lingo.\(rawValue)" }

    var title: String {
        switch self {
        case .translateSelection: return "Translate Selection"
        case .captureScreenshot: return "Capture Screenshot to Translate"
        case .speakSelection: return "Read Selection Aloud"
        case .translateClipboard: return "Translate Clipboard"
        }
    }

    /// The factory key + modifier combination, restored by "Reset" / "Reset
    /// All to Defaults".
    ///
    /// Same mnemonic ⌥-plus-letter family as Transi: ⌥T Translate, ⌥S
    /// Screenshot, ⌥R Read, ⌥C Clipboard.
    var defaultBinding: KeyBinding {
        switch self {
        case .translateSelection: return KeyBinding(kVK_ANSI_T, [.option])
        case .captureScreenshot: return KeyBinding(kVK_ANSI_S, [.option])
        case .speakSelection: return KeyBinding(kVK_ANSI_R, [.option])
        case .translateClipboard: return KeyBinding(kVK_ANSI_C, [.option])
        }
    }

    var hotkeyAction: HotkeyAction {
        HotkeyAction(id: id, featureID: "lingo", title: title, defaultBinding: defaultBinding)
    }
}
