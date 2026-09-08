// Ported from Snapper's Services/SettingsManager.swift (MIT, Copyright 2026
// Sam Reza). Changes for Bench: every UserDefaults key carries the `shot.`
// prefix and lives in `BenchDefaults.standard`; the app-level settings
// (launch at login, menu bar icon, updates, onboarding, accent color and
// color scheme) are gone - Bench owns those; and the global hotkeys are no
// longer stored here at all. `ShortcutStore` holds the main combination of
// every `CaptureAction`, so `HotkeyBinding` is replaced by
// `BenchCore.KeyBinding` and only the derived ⌥ variant is still computed
// here.

import AppKit
import SwiftUI
import BenchCore

/// The five capture entry points that have global hotkeys.
nonisolated enum CaptureAction: String, CaseIterable, Codable, Sendable {
    case area, window, screen, scrolling, text

    var title: String {
        switch self {
        case .area: "Capture Area"
        case .window: "Capture Window"
        case .screen: "Capture Screen"
        case .scrolling: "Scrolling Capture"
        case .text: "Capture Text"
        }
    }

    var symbolName: String {
        switch self {
        case .area: "rectangle.dashed"
        case .window: "macwindow"
        case .screen: "display"
        case .scrolling: "arrow.up.and.down.square"
        case .text: "text.viewfinder"
        }
    }

    /// The `HotkeyAction` id this action is registered under, and the id of
    /// its derived ⌥ variant. Both are frozen: `ShortcutStore` persists a
    /// rebind under the first, `HotkeyCenter` reports a failure under either.
    var hotkeyActionID: String { "\(ShotFeature.featureID).\(rawValue)" }
    var variantHotkeyID: String { "\(hotkeyActionID).alt" }

    /// False for actions that never produce an image: nothing is saved, so
    /// they have no file format and no format variant of their shortcut.
    var producesImage: Bool { self != .text }

    /// Defaults mirror macOS: ⌘⇧4 area, ⌘⇧3 screen, ⌘⇧2 window, ⌘⇧1 scrolling,
    /// ⌘⇧6 text.
    var defaultBinding: KeyBinding {
        let mods: KeyModifiers = [.command, .shift]
        switch self {
        case .area: return KeyBinding(keyCode: 21, modifiers: mods)
        case .window: return KeyBinding(keyCode: 19, modifiers: mods)
        case .screen: return KeyBinding(keyCode: 20, modifiers: mods)
        case .scrolling: return KeyBinding(keyCode: 18, modifiers: mods)
        case .text: return KeyBinding(keyCode: 22, modifiers: mods)
        }
    }

    /// The line Snapper's Shortcuts tab showed under the row, now the
    /// `HotkeyAction`'s note.
    var shortcutNote: String? {
        switch self {
        case .text:
            return "Reads the text in the selection and copies it to the clipboard. No image is saved or copied."
        default:
            return nil
        }
    }
}

/// The file format a capture shortcut writes. Only the two the shortcut UI
/// offers; `ImageExporter` still handles heic/tiff for Save As and for files
/// opened from disk.
nonisolated enum CaptureFileFormat: String, CaseIterable, Codable, Sendable {
    case png, jpg

    var title: String {
        switch self {
        case .png: "PNG"
        case .jpg: "JPG"
        }
    }

    var imageFormat: ImageFormat {
        switch self {
        case .png: .png
        case .jpg: .jpeg
        }
    }

    var fileExtension: String { imageFormat.fileExtension }

    var isLossy: Bool { self == .jpg }
}

/// Every capture action has two global shortcuts: the one the user records,
/// and the same combination plus `SettingsManager.variantModifiers` (⌥ by
/// default). They differ only in the file format they save as - PNG for the
/// main shortcut, JPG for the variant, out of the box.
nonisolated enum CaptureVariant: String, CaseIterable, Codable, Sendable {
    case main, alternate

    var defaultFormat: CaptureFileFormat {
        switch self {
        case .main: .png
        case .alternate: .jpg
        }
    }
}

/// One (action, variant) pair: the unit a format is stored against and a
/// hotkey is registered for.
nonisolated struct CaptureShortcut: Hashable, Sendable {
    var action: CaptureAction
    var variant: CaptureVariant

    init(_ action: CaptureAction, _ variant: CaptureVariant = .main) {
        self.action = action
        self.variant = variant
    }

    /// Every registrable shortcut. Actions that write no file have a main
    /// shortcut only - a format variant of them would just be the same action
    /// on a second combination.
    static var allCases: [CaptureShortcut] {
        CaptureAction.allCases.flatMap { action in
            let variants: [CaptureVariant] = action.producesImage ? CaptureVariant.allCases : [.main]
            return variants.map { CaptureShortcut(action, $0) }
        }
    }

    /// Key under which this shortcut's format is persisted.
    var storageKey: String { "\(action.rawValue).\(variant.rawValue)" }

    /// The id `HotkeyCenter` registers this shortcut under: the action's own
    /// id for the main combination, the `.alt` fixed id for the variant.
    var hotkeyID: String {
        switch variant {
        case .main: action.hotkeyActionID
        case .alternate: action.variantHotkeyID
        }
    }
}

extension Notification.Name {
    /// Posted when the variant modifier changes, so `ShotFeature` can
    /// re-derive the fixed ⌥ hotkeys. (The main combinations travel on
    /// BenchCore's `.benchShortcutsChanged` instead.)
    static let shotVariantModifiersChanged = Notification.Name("shot.variantModifiersChanged")
}

/// Single source of truth for Shot's own preferences, backed by
/// `BenchDefaults.standard` under the `shot.` prefix.
@MainActor
final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    private let defaults = BenchDefaults.standard

    /// Bare key names, as Snapper wrote them. `Key.x` prefixes each with
    /// `shot.`; the bare names are what the one-time Snapper import reads.
    enum Key {
        static let prefix = "shot."

        static let dimensionsInPixels = "dimensionsInPixels"
        static let includeWindowShadow = "includeWindowShadow"
        static let hotkeys = "hotkeys"
        static let captureFormats = "captureFormats"
        static let jpegQuality = "jpegQuality"
        static let variantModifiers = "variantModifiers"
        static let toolStyle = "toolStyle"
        static let lastTool = "lastTool"
        static let keepToolActive = "keepToolActive"
        static let rememberLastTool = "rememberLastTool"
        static let playSound = "playCaptureSound"
        static let copyOnClose = "copyOnClose"
        static let nameFilesAfterSourceApp = "nameFilesAfterSourceApp"

        /// Every key above, bare, in the order the Settings pane uses them.
        static let all: [String] = [
            dimensionsInPixels, includeWindowShadow, hotkeys, captureFormats, jpegQuality,
            variantModifiers, toolStyle, lastTool, keepToolActive, rememberLastTool,
            playSound, copyOnClose, nameFilesAfterSourceApp,
        ]

        static func namespaced(_ key: String) -> String { prefix + key }
    }

    private func key(_ bare: String) -> String { Key.namespaced(bare) }

    /// Show sizes in physical pixels (true, default) or logical points.
    @Published var dimensionsInPixels: Bool { didSet { defaults.set(dimensionsInPixels, forKey: key(Key.dimensionsInPixels)) } }
    @Published var includeWindowShadow: Bool { didSet { defaults.set(includeWindowShadow, forKey: key(Key.includeWindowShadow)) } }
    /// File format per capture shortcut, keyed by `CaptureShortcut.storageKey`.
    /// A missing entry means the variant's default (PNG for main, JPG for the
    /// ⌥ variant).
    @Published var captureFormats: [String: CaptureFileFormat] {
        didSet {
            if let data = try? JSONEncoder().encode(captureFormats) { defaults.set(data, forKey: key(Key.captureFormats)) }
        }
    }
    /// JPG compression, 1-100, shared by every shortcut set to JPG.
    @Published var jpegQuality: Int {
        didSet {
            let clamped = Self.clampQuality(jpegQuality)
            if clamped != jpegQuality { jpegQuality = clamped; return }
            defaults.set(jpegQuality, forKey: key(Key.jpegQuality))
        }
    }
    /// Modifiers added to every main shortcut to form its variant. ⌥ by
    /// default; any combination of ⌃⌥⇧⌘ works.
    @Published var variantModifiers: NSEvent.ModifierFlags {
        didSet {
            defaults.set(variantModifiers.rawValue, forKey: key(Key.variantModifiers))
            NotificationCenter.default.post(name: .shotVariantModifiersChanged, object: nil)
        }
    }
    /// Last-used per-tool style; new annotations start from this.
    @Published var toolStyle: ToolStyle {
        didSet { if let data = try? JSONEncoder().encode(toolStyle) { defaults.set(data, forKey: key(Key.toolStyle)) } }
    }
    @Published var lastTool: EditorTool { didSet { defaults.set(lastTool.rawValue, forKey: key(Key.lastTool)) } }
    /// Keep the drawing tool active after placing a shape (Shottr behaviour).
    @Published var keepToolActive: Bool { didSet { defaults.set(keepToolActive, forKey: key(Key.keepToolActive)) } }
    /// Start a new capture with the tool from the previous one; when off, every
    /// capture starts on the Select tool.
    @Published var rememberLastTool: Bool { didSet { defaults.set(rememberLastTool, forKey: key(Key.rememberLastTool)) } }
    @Published var playCaptureSound: Bool { didSet { defaults.set(playCaptureSound, forKey: key(Key.playSound)) } }
    /// Copy the image to the clipboard when the overlay is closed with Escape (Shottr's copyOnEsc).
    @Published var copyOnClose: Bool { didSet { defaults.set(copyOnClose, forKey: key(Key.copyOnClose)) } }
    /// Name saved files after the app that was captured ("IINA 2026-09-07 at
    /// 14.03.10.png") instead of the macOS base name. On by default; only
    /// affects files, never the clipboard credit.
    @Published var nameFilesAfterSourceApp: Bool { didSet { defaults.set(nameFilesAfterSourceApp, forKey: key(Key.nameFilesAfterSourceApp)) } }

    private init() {
        let defaults = self.defaults
        func k(_ bare: String) -> String { Key.namespaced(bare) }

        dimensionsInPixels = defaults.object(forKey: k(Key.dimensionsInPixels)) as? Bool ?? true
        includeWindowShadow = defaults.object(forKey: k(Key.includeWindowShadow)) as? Bool ?? !ScreenshotDefaults.disableShadow
        if let data = defaults.data(forKey: k(Key.captureFormats)),
           let stored = try? JSONDecoder().decode([String: CaptureFileFormat].self, from: data) {
            captureFormats = stored
        } else {
            captureFormats = [:]
        }
        jpegQuality = Self.clampQuality(defaults.object(forKey: k(Key.jpegQuality)) as? Int ?? Self.defaultJPEGQuality)
        if let raw = defaults.object(forKey: k(Key.variantModifiers)) as? UInt {
            let flags = NSEvent.ModifierFlags(rawValue: raw).intersection(Self.allowedVariantModifiers)
            variantModifiers = flags.isEmpty ? Self.defaultVariantModifiers : flags
        } else {
            variantModifiers = Self.defaultVariantModifiers
        }
        if let data = defaults.data(forKey: k(Key.toolStyle)), let s = try? JSONDecoder().decode(ToolStyle.self, from: data) { toolStyle = s } else { toolStyle = ToolStyle() }
        lastTool = EditorTool(rawValue: defaults.string(forKey: k(Key.lastTool)) ?? "") ?? .arrow
        keepToolActive = defaults.object(forKey: k(Key.keepToolActive)) as? Bool ?? false
        rememberLastTool = defaults.object(forKey: k(Key.rememberLastTool)) as? Bool ?? false
        playCaptureSound = defaults.object(forKey: k(Key.playSound)) as? Bool ?? true
        copyOnClose = defaults.object(forKey: k(Key.copyOnClose)) as? Bool ?? false
        nameFilesAfterSourceApp = defaults.object(forKey: k(Key.nameFilesAfterSourceApp)) as? Bool ?? true
    }

    // MARK: - Snapper import

    /// The preferences domain of the standalone app, read once and never
    /// written.
    static let snapperDomain = "com.fxreza.snapper"
    static let importFlagKey = "shot.importedFromSnapper"

    /// Copies the standalone Snapper's preferences into the `shot.` keys on
    /// first run, then translates its stored hotkey bindings into
    /// `ShortcutStore` overrides.
    ///
    /// Call this before `SettingsManager.shared` is first touched - the
    /// singleton reads `defaults` in its initializer, so a copy made
    /// afterwards would not be seen until the next launch.
    static func importFromSnapperIfNeeded() {
        let alreadyImported = BenchDefaults.standard.bool(forKey: importFlagKey)
        var map: [String: String] = [:]
        for bare in Key.all { map[bare] = Key.namespaced(bare) }
        StandaloneImport.importDefaultsIfNeeded(
            sourceDomain: snapperDomain, keys: map, flagKey: importFlagKey)
        guard !alreadyImported else { return }
        importHotkeyOverrides()
    }

    /// Snapper stored its bindings as a JSON `[actionRawValue: HotkeyBinding]`
    /// blob under `hotkeys`, where `enabled == false` meant "the user cleared
    /// this shortcut". Anything that differs from Bench's default becomes a
    /// `ShortcutStore` override; anything equal to it is left alone, so a
    /// later change of default still reaches the user.
    private static func importHotkeyOverrides() {
        guard let data = BenchDefaults.standard.data(forKey: Key.namespaced(Key.hotkeys)),
              let stored = try? JSONDecoder().decode([String: SnapperHotkeyBinding].self, from: data)
        else { return }
        for (rawAction, legacy) in stored {
            guard let action = CaptureAction(rawValue: rawAction) else { continue }
            let binding: KeyBinding? = legacy.enabled ? legacy.keyBinding : nil
            guard binding != action.defaultBinding else { continue }
            // A combination another Bench module already owns is refused; the
            // action keeps its default and the user rebinds it in Settings.
            if case .conflict(let other) = ShortcutStore.shared.set(binding, for: action.hotkeyActionID) {
                NSLog("[Shot] not importing \(action.rawValue) = \(binding?.display ?? "none"): already used by \(other.title)")
            }
        }
    }

    /// Snapper's on-disk hotkey record, for decoding only.
    nonisolated struct SnapperHotkeyBinding: Codable {
        var keyCode: UInt16
        var modifiersRaw: UInt
        var enabled: Bool = true

        var keyBinding: KeyBinding {
            KeyBinding(
                keyCode: keyCode,
                flags: NSEvent.ModifierFlags(rawValue: modifiersRaw).intersection(.deviceIndependentFlagsMask))
        }
    }

    // MARK: - hotkeys

    nonisolated static let defaultVariantModifiers: NSEvent.ModifierFlags = .option
    /// Modifiers a variant may be built from. `.deviceIndependentFlagsMask`
    /// also carries caps lock, function and the numeric-pad flag, none of
    /// which `RegisterEventHotKey` can express.
    nonisolated static let allowedVariantModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    /// The main combination, straight from the app-wide store: the user's
    /// rebind, the default, or nil when they cleared it.
    func binding(for action: CaptureAction) -> KeyBinding? {
        ShortcutStore.shared.binding(for: action.hotkeyActionID)
    }

    /// The combination that actually fires `shortcut`, or nil when it cannot
    /// be registered: the main hotkey is off, or - for a variant - the main
    /// combination already contains every variant modifier, which would make
    /// the two identical.
    func effectiveBinding(for shortcut: CaptureShortcut) -> KeyBinding? {
        guard let base = binding(for: shortcut.action) else { return nil }
        switch shortcut.variant {
        case .main:
            return base
        case .alternate:
            guard shortcut.action.producesImage else { return nil }
            return Self.variantBinding(base: base, variantModifiers: variantModifiers)
        }
    }

    /// Pure form of the variant derivation, so the rule - "base plus the
    /// variant modifiers, unless base already has them all" - is testable.
    nonisolated static func variantBinding(base: KeyBinding, variantModifiers: NSEvent.ModifierFlags) -> KeyBinding? {
        let extra = KeyModifiers(eventFlags: variantModifiers.intersection(allowedVariantModifiers))
        guard !extra.isEmpty, !base.modifiers.contains(extra) else { return nil }
        return KeyBinding(keyCode: base.keyCode, modifiers: base.modifiers.union(extra))
    }

    /// Resets everything the Shortcuts tab owns: bindings, per-shortcut
    /// formats, the variant modifier and the JPG quality.
    func resetHotkeys() {
        for action in CaptureAction.allCases { ShortcutStore.shared.reset(action.hotkeyActionID) }
        captureFormats = [:]
        variantModifiers = Self.defaultVariantModifiers
        jpegQuality = Self.defaultJPEGQuality
    }

    /// Another Shot shortcut - main or variant - already firing on this
    /// combination, if any. `ShortcutStore` refuses a collision between two
    /// main shortcuts anywhere in Bench; this catches the derived variants,
    /// which it knows nothing about.
    func conflict(for binding: KeyBinding, excluding shortcut: CaptureShortcut) -> CaptureShortcut? {
        CaptureShortcut.allCases.first { other in
            guard other != shortcut, let b = effectiveBinding(for: other) else { return false }
            return b == binding
        }
    }

    // MARK: capture formats

    nonisolated static let defaultJPEGQuality = 70
    nonisolated static let jpegQualityRange = 1...100

    nonisolated static func clampQuality(_ value: Int) -> Int {
        min(max(value, jpegQualityRange.lowerBound), jpegQualityRange.upperBound)
    }

    /// `jpegQuality` as the 0-1 fraction Image I/O wants.
    var jpegQualityFraction: CGFloat { CGFloat(jpegQuality) / 100 }

    func format(for shortcut: CaptureShortcut) -> CaptureFileFormat {
        captureFormats[shortcut.storageKey] ?? shortcut.variant.defaultFormat
    }

    func setFormat(_ format: CaptureFileFormat, for shortcut: CaptureShortcut) {
        captureFormats[shortcut.storageKey] = format
    }
}
