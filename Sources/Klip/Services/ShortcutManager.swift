import Foundation
import AppKit
import Combine
import BenchCore

/// Every rebindable (or fixed-but-shown) in-window action, reproducing
/// today's hardcoded `Views/History/GlobalKeyMonitor.swift` switch exactly as
/// the default table. Phase 3E part 2 makes the monitor table-driven against
/// `ShortcutManager`; this enum plus the manager below are the model half.
enum ShortcutAction: String, CaseIterable, Codable {
    // Clipboard
    case paste, pastePlain, copy, copyPlain, delete, pin, star, lock, edit, addTag, saveToDisk
    case clearFilter
    /// Open the focused clip in the system Quick Look panel.
    case quickLook
    /// Name (or rename) the focused clip. Unlike `edit` this works on every
    /// kind — an image or a file has no editable body but can still be named.
    case renameClip
    /// Show the focused clip as a QR code, to scan it with a phone.
    case showQR

    // Organize
    case newFolder, renameFolder, moveToFolder

    // Window
    case toggleSidebar, togglePreview
    /// Keep Open: stop the window closing after a paste or on losing focus.
    /// Named for the window, not "pin", so it never reads as a second kind of
    /// clip pin — see `SettingsManager.keepWindowOpen`.
    case toggleKeepOpen

    // Navigation
    //
    // 3.0.1 removed `nextScope` / `previousScope` (⌘[ / ⌘]). The sidebar is
    // the only way to change scope now; a stored override for either key is
    // simply ignored when the table is decoded (see `init`).
    case moveUp, moveDown, extendUp, extendDown, tabComplete, escape

    enum Group: String, CaseIterable {
        case navigation = "Navigation"
        case clipboard = "Clipboard"
        case organize = "Organize"
        case window = "Window"
    }

    var group: Group {
        switch self {
        case .paste, .pastePlain, .copy, .copyPlain, .delete, .pin, .star, .lock, .edit,
             .addTag, .saveToDisk, .clearFilter, .renameClip, .quickLook, .showQR:
            return .clipboard
        case .newFolder, .renameFolder, .moveToFolder:
            return .organize
        case .toggleSidebar, .togglePreview, .toggleKeepOpen:
            return .window
        case .moveUp, .moveDown, .extendUp, .extendDown, .tabComplete, .escape:
            return .navigation
        }
    }

    var label: String {
        switch self {
        case .paste: return "Paste"
        case .pastePlain: return "Paste as Plain Text"
        case .copy: return "Copy"
        case .copyPlain: return "Copy as Plain Text"
        case .delete: return "Delete"
        case .pin: return "Pin"
        case .star: return "Favorite"
        case .lock: return "Lock"
        case .edit: return "Edit"
        case .addTag: return "Add Tag"
        case .saveToDisk: return "Save to Disk"
        case .clearFilter: return "Clear Tag Filter"
        case .quickLook: return "Quick Look"
        case .renameClip: return "Rename Clip"
        case .showQR: return "Show QR Code"
        case .newFolder: return "New Folder"
        case .renameFolder: return "Rename Folder"
        case .moveToFolder: return "Move to Folder"
        case .toggleSidebar: return "Toggle Sidebar"
        case .togglePreview: return "Toggle Preview Pane"
        case .toggleKeepOpen: return "Keep Window Open"
        case .moveUp: return "Move Selection Up"
        case .moveDown: return "Move Selection Down"
        case .extendUp: return "Extend Selection Up"
        case .extendDown: return "Extend Selection Down"
        case .tabComplete: return "Tab-Complete Tag Filter"
        case .escape: return "Escape / Deselect"
        }
    }

    /// Whether this action is shown in Settings ▸ Shortcuts.
    ///
    /// Only false for the tag keys while `Features.tagsEnabled` is off: their
    /// bindings still exist and are still resolved, so nothing about the
    /// table changes — they are simply not offered for rebinding when there
    /// is no tag UI for them to act on. `GlobalKeyMonitor` stands the same
    /// two actions down.
    var isUserVisible: Bool {
        switch self {
        case .addTag, .clearFilter: return Features.tagsEnabled
        default: return true
        }
    }

    /// `false` for the handful of keys that are structural to list navigation
    /// (arrows, return, escape, tab) — the Shortcuts tab shows these rows
    /// greyed out with no recorder rather than letting them be rebound.
    var isRebindable: Bool {
        switch self {
        case .paste, .pastePlain, .moveUp, .moveDown, .extendUp, .extendDown, .tabComplete, .escape:
            return false
        default:
            return true
        }
    }

    /// Reproduces today's hardcoded keys exactly (see
    /// `Views/History/GlobalKeyMonitor.swift` and `docs/analysis/buffer.md` §3).
    var defaultBinding: ClipKeyBinding {
        switch self {
        case .paste:          return ClipKeyBinding(keyCode: 36, modifiers: [])            // ↩
        case .pastePlain:     return ClipKeyBinding(keyCode: 36, modifiers: [.option])     // ⌥↩
        case .copy:           return ClipKeyBinding(keyCode: 8,  modifiers: [.command])    // ⌘C
        case .copyPlain:      return ClipKeyBinding(keyCode: 8,  modifiers: [.command, .option]) // ⌥⌘C
        case .delete:         return ClipKeyBinding(keyCode: 51, modifiers: [.command])    // ⌘⌫
        case .pin:            return ClipKeyBinding(keyCode: 35, modifiers: [.command])    // ⌘P
        case .star:           return ClipKeyBinding(keyCode: 3,  modifiers: [.command])    // ⌘F (was ⌘B before 3.0.1)
        case .lock:           return ClipKeyBinding(keyCode: 37, modifiers: [.command])    // ⌘L
        case .edit:           return ClipKeyBinding(keyCode: 14, modifiers: [.command])    // ⌘E
        case .addTag:         return ClipKeyBinding(keyCode: 17, modifiers: [.command])    // ⌘T
        case .saveToDisk:     return ClipKeyBinding(keyCode: 1,  modifiers: [.command])    // ⌘S
        case .clearFilter:    return ClipKeyBinding(keyCode: 51, modifiers: [])            // ⌫ (only when search is empty)
        case .renameClip:     return ClipKeyBinding(keyCode: 120, modifiers: [])           // F2 (Finder / Ditto convention)
        // Space, Finder's Quick Look key. The search field owns the keyboard
        // while the panel is open, so `GlobalKeyMonitor` only acts on a *bare*
        // Space when there is no search text for it to be a character of; ⌘Y
        // (Finder's other Quick Look key) is the unambiguous way in and is
        // handled there as a fixed fallback.
        case .quickLook:      return ClipKeyBinding(keyCode: 49, modifiers: [])            // Space
        // ⌘K. Free: the only other K binding is Keep Open's ⌥⌘K.
        case .showQR:         return ClipKeyBinding(keyCode: 40, modifiers: [.command])    // ⌘K
        case .newFolder:      return ClipKeyBinding(keyCode: 45, modifiers: [.command])    // ⌘N
        case .renameFolder:   return ClipKeyBinding(keyCode: 15, modifiers: [.command])    // ⌘R
        case .moveToFolder:   return ClipKeyBinding(keyCode: 46, modifiers: [.command])    // ⌘M
        case .toggleSidebar:  return ClipKeyBinding(keyCode: 1,  modifiers: [.command, .option]) // ⌥⌘S
        case .togglePreview:  return ClipKeyBinding(keyCode: 35, modifiers: [.command, .option]) // ⌥⌘P
        case .toggleKeepOpen: return ClipKeyBinding(keyCode: 40, modifiers: [.command, .option]) // ⌥⌘K
        case .moveUp:         return ClipKeyBinding(keyCode: 126, modifiers: [])           // ↑
        case .moveDown:       return ClipKeyBinding(keyCode: 125, modifiers: [])           // ↓
        case .extendUp:       return ClipKeyBinding(keyCode: 126, modifiers: [.shift])     // ⇧↑
        case .extendDown:     return ClipKeyBinding(keyCode: 125, modifiers: [.shift])     // ⇧↓
        case .tabComplete:    return ClipKeyBinding(keyCode: 48, modifiers: [])            // ⇥
        case .escape:         return ClipKeyBinding(keyCode: 53, modifiers: [])            // Esc
        }
    }
}

/// Owns the per-action key bindings: resolves each action's effective
/// `ClipKeyBinding` (a stored override, or its default), persists only the
/// overrides, and detects conflicts before accepting a rebind.
///
/// The global open-Klip hotkey is *not* managed here — inside Bench it is a
/// `HotkeyAction` (`klip.toggleHistory`) resolved by BenchCore's
/// `ShortcutStore`; the Shortcuts tab shows it first through
/// `FeatureShortcutsSection`.
@MainActor
final class ShortcutManager: ObservableObject {
    static let shared = ShortcutManager()

    enum ConflictResult: Equatable {
        case ok
        case conflict(ShortcutAction)
    }

    /// The unprefixed key the standalone Klip used, for the first-run import.
    static let standaloneStorageKey = "shortcuts.bindings"
    /// The prefixed key Bench stores the overrides under.
    static let storageKey = SettingsManager.Key.name(standaloneStorageKey)
    private let defaults: UserDefaults

    /// Every action resolved to its effective binding: a stored override
    /// where one exists, `defaultBinding` otherwise. UserDefaults only ever
    /// stores the overrides (see `persist()`), so a future change to a
    /// default automatically applies to anyone who never rebound that action.
    @Published var bindings: [ShortcutAction: ClipKeyBinding]

    init(defaults: UserDefaults = BenchDefaults.standard) {
        self.defaults = defaults
        var resolved: [ShortcutAction: ClipKeyBinding] = [:]
        for action in ShortcutAction.allCases {
            resolved[action] = action.defaultBinding
        }
        if let data = defaults.data(forKey: Self.storageKey),
           let overrides = try? JSONDecoder().decode([String: ClipKeyBinding].self, from: data) {
            for (rawKey, binding) in overrides {
                // Unknown keys are skipped rather than treated as corruption,
                // so an override stored for an action that no longer exists
                // (`nextScope` / `previousScope`, removed in 3.0.1) does not
                // throw away the rest of the user's rebinds.
                if let action = ShortcutAction(rawValue: rawKey) {
                    resolved[action] = binding
                }
            }
        }
        self.bindings = resolved
    }

    func binding(for action: ShortcutAction) -> ClipKeyBinding {
        bindings[action] ?? action.defaultBinding
    }

    func displayString(for action: ShortcutAction) -> String {
        binding(for: action).display
    }

    /// Attempts to bind `binding` to `action`. Refused (with the conflicting
    /// action returned) when another action already uses the identical key +
    /// modifier combination.
    @discardableResult
    func set(_ binding: ClipKeyBinding, for action: ShortcutAction) -> ConflictResult {
        if let conflict = ShortcutAction.allCases.first(where: { $0 != action && self.binding(for: $0) == binding }) {
            return .conflict(conflict)
        }
        bindings[action] = binding
        persist()
        return .ok
    }

    func reset(action: ShortcutAction) {
        bindings[action] = action.defaultBinding
        persist()
    }

    func resetAll() {
        for action in ShortcutAction.allCases {
            bindings[action] = action.defaultBinding
        }
        persist()
    }

    /// First action whose binding matches `event`, in `ShortcutAction.allCases`
    /// order. The monitor (part 2) will call this instead of its hardcoded
    /// keycode switch.
    func action(for event: NSEvent) -> ShortcutAction? {
        ShortcutAction.allCases.first { binding(for: $0).matches(event) }
    }

    private func persist() {
        var overrides: [String: ClipKeyBinding] = [:]
        for action in ShortcutAction.allCases {
            let current = bindings[action] ?? action.defaultBinding
            if current != action.defaultBinding {
                overrides[action.rawValue] = current
            }
        }
        if overrides.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
        } else if let data = try? JSONEncoder().encode(overrides) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
