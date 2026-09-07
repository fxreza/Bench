import Foundation
import AppKit

/// The modifier keys a `ClipKeyBinding` can require. This is the `OptionSet`
/// the per-action in-window shortcut table (`Services/ShortcutManager.swift`)
/// is built on. `RawValue == Int` is `Codable`, so this struct's
/// compiler-synthesized `Codable` conformance round-trips through a plain
/// `{"rawValue": N}` JSON object.
///
/// Named `ClipKeyModifiers` (and `ClipKeyBinding` below) inside Bench so the
/// bare `KeyModifiers` / `KeyBinding` always mean BenchCore's types, which
/// back the *global* hotkeys. The two are deliberately kept apart: this one
/// stays exactly what Klip persisted under `shortcuts.bindings`, so a user's
/// in-window rebinds decode unchanged.
struct ClipKeyModifiers: OptionSet, Codable, Hashable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    static let command = ClipKeyModifiers(rawValue: 1 << 0)
    static let shift   = ClipKeyModifiers(rawValue: 1 << 1)
    static let option  = ClipKeyModifiers(rawValue: 1 << 2)
    static let control = ClipKeyModifiers(rawValue: 1 << 3)

    /// Builds the set from an `NSEvent`'s modifier flags. Callers that care
    /// about exact-match semantics (see `ClipKeyBinding.matches(_:)`) should
    /// intersect with `.deviceIndependentFlagsMask` first.
    init(eventFlags flags: NSEvent.ModifierFlags) {
        var result: ClipKeyModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        self = result
    }
}

/// A single key + modifier combination bound to a `ShortcutAction`.
///
/// Ordering in `display` follows the `⌃⌥⇧⌘` convention macOS uses, so every
/// action row in the Shortcuts tab reads consistently with the global row
/// BenchCore draws (e.g. the paste-as-plain-text default is `⌥⌘C`, matching
/// real macOS menu conventions like `⇧⌘4`).
struct ClipKeyBinding: Codable, Equatable, Hashable {
    var keyCode: UInt16
    var modifiers: ClipKeyModifiers

    init(keyCode: UInt16, modifiers: ClipKeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Glyph string for display, e.g. `"⌥⌘C"`, `"⌘⌫"`, `"↩"`, `"⇥"`, `"Esc"`.
    var display: String {
        var out = ""
        if modifiers.contains(.control) { out += "⌃" }
        if modifiers.contains(.option) { out += "⌥" }
        if modifiers.contains(.shift) { out += "⇧" }
        if modifiers.contains(.command) { out += "⌘" }
        out += Self.keyName(keyCode: keyCode)
        return out
    }

    /// Whether `event` triggers this binding — exact match on key code *and*
    /// the device-independent modifier flags, so `⌘V` never matches `⌘⇧V`
    /// (or vice versa).
    func matches(_ event: NSEvent) -> Bool {
        guard event.keyCode == keyCode else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return ClipKeyModifiers(eventFlags: flags) == modifiers
    }

    /// Display name for a raw key code: letters, digits, punctuation and
    /// space come from the `clipKeyCodeNames` table below; everything else
    /// (arrows, return, tab, delete/forward-delete, escape, F1–F12) is named
    /// here.
    static func keyName(keyCode: UInt16) -> String {
        switch keyCode {
        case 36, 76: return "↩"   // Return / keypad enter
        case 48:     return "⇥"   // Tab
        case 51:     return "⌫"   // Delete (backspace)
        case 117:    return "⌦"   // Forward delete
        case 53:     return "Esc" // Escape
        case 123:    return "←"
        case 124:    return "→"
        case 125:    return "↓"
        case 126:    return "↑"
        case 122:    return "F1"
        case 120:    return "F2"
        case 99:     return "F3"
        case 118:    return "F4"
        case 96:     return "F5"
        case 97:     return "F6"
        case 98:     return "F7"
        case 100:    return "F8"
        case 101:    return "F9"
        case 109:    return "F10"
        case 103:    return "F11"
        case 111:    return "F12"
        default:
            return clipKeyCodeNames[keyCode] ?? "Key\(keyCode)"
        }
    }
}

/// Map key codes to display names. Lived in `Services/SettingsManager.swift`
/// next to the global hotkey it used to describe; that hotkey is BenchCore's
/// now, so the table moved here with the only remaining reader.
let clipKeyCodeNames: [UInt16: String] = [
    0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
    8: "C", 9: "V", 10: "§", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
    16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
    24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O",
    32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K",
    41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
    49: "Space", 50: "`"
]
