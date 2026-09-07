// Ported from Transi's Shortcuts/KeyBinding.swift (MIT), which came from
// Klip's Models/KeyBinding.swift, which Klip adapted from Clipfield (MIT,
// Copyright 2026 Alex Jolley). Made public and given the NSEvent / Carbon
// conversions the three apps each kept in a separate file.

import AppKit
import Carbon.HIToolbox

/// The modifier keys a `KeyBinding` can require. `RawValue == Int` is
/// `Codable`, so the compiler-synthesized `Codable` conformance round-trips
/// through a plain `{"rawValue": N}` JSON object.
public struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let shift   = KeyModifiers(rawValue: 1 << 1)
    public static let option  = KeyModifiers(rawValue: 1 << 2)
    public static let control = KeyModifiers(rawValue: 1 << 3)

    /// Builds the set from an `NSEvent`'s modifier flags. Only ⌘⇧⌥⌃ are
    /// honored; caps lock, fn and the numeric-pad flag are ignored.
    public init(eventFlags flags: NSEvent.ModifierFlags) {
        var result: KeyModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        self = result
    }

    /// The `NSEvent.ModifierFlags` equivalent, for menu key equivalents and
    /// event matching.
    public var eventFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if contains(.command) { flags.insert(.command) }
        if contains(.shift) { flags.insert(.shift) }
        if contains(.option) { flags.insert(.option) }
        if contains(.control) { flags.insert(.control) }
        return flags
    }

    /// The Carbon modifier mask `RegisterEventHotKey` wants. Pure mask math,
    /// no Carbon calls, so it is testable.
    public var carbonMask: UInt32 {
        var mask: UInt32 = 0
        if contains(.command) { mask |= UInt32(cmdKey) }
        if contains(.shift) { mask |= UInt32(shiftKey) }
        if contains(.option) { mask |= UInt32(optionKey) }
        if contains(.control) { mask |= UInt32(controlKey) }
        return mask
    }

    /// Modifier glyphs in the order macOS shows them: ⌃⌥⇧⌘.
    public var symbols: String {
        var out = ""
        if contains(.control) { out += "⌃" }
        if contains(.option) { out += "⌥" }
        if contains(.shift) { out += "⇧" }
        if contains(.command) { out += "⌘" }
        return out
    }
}

/// A single key + modifier combination, e.g. one of Bench's global hotkeys.
public struct KeyBinding: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: KeyModifiers

    public init(keyCode: UInt16, modifiers: KeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Convenience over the `NSEvent.ModifierFlags` the recorder and the
    /// ported apps speak.
    public init(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        self.init(keyCode: keyCode, modifiers: KeyModifiers(eventFlags: flags))
    }

    /// The Carbon `kVK_*` constant is an `Int`; this saves the cast at every
    /// default-binding site.
    public init(_ virtualKey: Int, _ modifiers: KeyModifiers) {
        self.init(keyCode: UInt16(virtualKey), modifiers: modifiers)
    }

    /// Glyph string for display, e.g. `"⌥⌘C"`, `"⌘⌫"`, `"↩"`, `"⇥"`, `"Esc"`.
    public var display: String {
        modifiers.symbols + Self.keyName(keyCode: keyCode)
    }

    public var eventFlags: NSEvent.ModifierFlags { modifiers.eventFlags }

    /// Whether `event` triggers this binding: exact match on key code *and*
    /// the device-independent modifier flags, so `⌘V` never matches `⌘⇧V`.
    public func matches(_ event: NSEvent) -> Bool {
        guard event.keyCode == keyCode else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return KeyModifiers(eventFlags: flags) == modifiers
    }

    /// The single character an `NSMenuItem.keyEquivalent` can carry for this
    /// key, or nil for keys (arrows, F-keys, return) a menu item cannot show
    /// that way.
    public var menuKeyEquivalent: String? {
        let name = Self.keyName(keyCode: keyCode)
        switch keyCode {
        case 36, 76: return "\r"
        case 48: return "\t"
        case 49: return " "
        case 51: return String(UnicodeScalar(NSBackspaceCharacter)!)
        case 117: return String(UnicodeScalar(NSDeleteCharacter)!)
        case 123: return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case 124: return String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case 125: return String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case 126: return String(UnicodeScalar(NSUpArrowFunctionKey)!)
        default:
            return name.count == 1 ? name.lowercased() : nil
        }
    }

    /// Display name for a raw key code: letters, digits, punctuation and
    /// space come from `keyCodeNames`; everything else (arrows, return, tab,
    /// delete, escape, F1-F12) is named here.
    public static func keyName(keyCode: UInt16) -> String {
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
        case 115:    return "Home"
        case 119:    return "End"
        case 116:    return "PgUp"
        case 121:    return "PgDn"
        default:
            return keyCodeNames[keyCode] ?? "Key\(keyCode)"
        }
    }

    /// Key codes of printable keys on the ANSI layout, mapped to display names.
    public static let keyCodeNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 10: "§", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O",
        32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K",
        41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        49: "Space", 50: "`",
    ]
}
