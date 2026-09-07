// The Klip module of Bench. What used to be Klip's AppDelegate.swift and
// Views/StatusBarController.swift (MIT, Copyright 2026 Sam Reza), folded into
// one `BenchFeature`: the store, the pasteboard watcher, the history window,
// the global hotkey, the paste-needs-Accessibility toast, and the quit-time
// flush and sync push.

import AppKit
import SwiftUI
import Carbon.HIToolbox
import BenchCore

/// Klip's global shortcut ids, in one place so the feature, the Shortcuts
/// tab and the captions that mention the hotkey agree.
enum KlipHotkeys {
    static let featureID = "klip"
    static let toggleHistoryID = "klip.toggleHistory"

    static let toggleHistory = HotkeyAction(
        id: toggleHistoryID,
        featureID: featureID,
        title: "Open Klip",
        defaultBinding: KeyBinding(kVK_ANSI_V, [.shift, .command])
    )
}

/// Clipboard history with folders, search and iCloud Drive sync.
public final class KlipFeature: BenchFeature {
    public let id = KlipHotkeys.featureID
    public let title = "Klip"
    public let symbolName = "doc.on.clipboard"
    public let summary = "Clipboard history with folders, search and sync"
    public let requiredPermissions: [BenchPermission] = [.accessibility]
    public var hotkeyActions: [HotkeyAction] { [KlipHotkeys.toggleHistory] }

    private var store: ClipboardStore?
    private var watcher: ClipboardWatcher?
    private var historyWindowController: HistoryWindowController?
    private var accessibilityObserver: NSObjectProtocol?
    private var lastAccessibilityToastAt: Date?
    private lazy var menuTarget = KlipMenuTarget(feature: self)

    public init() {}

    // MARK: - Lifecycle

    public func start() {
        guard store == nil else { return }

        KlipStandaloneImport.importIfNeeded()

        let store = ClipboardStore()
        self.store = store

        // Phase 4A: iCloud Drive sync. Attaching wires the store's mutation /
        // delete hooks; `startIfEnabled` starts watching only when the user
        // turned sync on and iCloud Drive is actually there, and keeps
        // listening for that setting changing.
        CloudDriveSync.shared.attach(store: store)
        CloudDriveSync.shared.startIfEnabled()

        let watcher = ClipboardWatcher(store: store)
        watcher.startWatching()
        self.watcher = watcher

        historyWindowController = HistoryWindowController(store: store)

        HotkeyCenter.shared.bind(KlipHotkeys.toggleHistory) { [weak self] in
            self?.toggleHistoryWindow()
        }

        accessibilityObserver = NotificationCenter.default.addObserver(
            forName: .klipPasteNeedsAccessibility,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handlePasteNeedsAccessibility() }
        }
    }

    public func stop() {
        guard let store else { return }

        HotkeyCenter.shared.unbindAll(featureID: id)
        if let accessibilityObserver {
            NotificationCenter.default.removeObserver(accessibilityObserver)
            self.accessibilityObserver = nil
        }
        AccessibilityToast.shared.dismiss()

        watcher?.stopWatching()
        watcher = nil

        historyWindowController?.close()
        historyWindowController = nil

        store.flushPendingSave()
        // Phase 4A: stop watching, then get this session's clips into iCloud
        // Drive before the process goes away (the 2 s push debounce may not
        // have fired yet).
        //
        // 5A-16: bounded to 3 s in total. `pushSynchronously` runs on the main
        // thread and its per-file copy timeout is 20 s, so an unbounded quit
        // push could beachball for minutes (and be SIGKILLed anyway) when
        // iCloud has not materialised the assets. Anything that does not fit
        // in the budget is left for the next launch — the metadata write still
        // happens, and assets are write-once so the retry is free.
        if CloudDriveSync.shared.isActive {
            CloudDriveSync.shared.stop()
            CloudDriveSync.shared.pushSynchronously(budget: 3.0)
        }
        self.store = nil
    }

    // MARK: - Status menu

    public func menuItems() -> [NSMenuItem] {
        guard store != nil, let watcher else { return [] }

        // Open the history window. The key equivalent is display only (a
        // status menu never sees the keystroke); it replaces the disabled
        // "Shortcut: ⇧⌘V" line the standalone Klip's menu carried.
        let openItem = NSMenuItem(title: "Open Klip", action: #selector(KlipMenuTarget.openHistory), keyEquivalent: "")
        openItem.target = menuTarget
        if let binding = ShortcutStore.shared.binding(for: KlipHotkeys.toggleHistoryID),
           let key = binding.menuKeyEquivalent {
            openItem.keyEquivalent = key
            openItem.keyEquivalentModifierMask = binding.eventFlags
        }

        let pauseTitle = watcher.isPaused ? "Resume Capture" : "Pause Capture"
        let pauseItem = NSMenuItem(title: pauseTitle, action: #selector(KlipMenuTarget.togglePause), keyEquivalent: "")
        pauseItem.target = menuTarget

        // 5E: "Recently Deleted" used to live here — a submenu of the last
        // 25 deletions, and the only way to reach the trash at all. The trash
        // is a scope in the history window's sidebar now, which gets search,
        // sort, filter and multi-select for free, so the submenu is gone
        // rather than left as a worse second door to the same place.
        let clearItem = NSMenuItem(title: "Clear History", action: #selector(KlipMenuTarget.clearHistory), keyEquivalent: "")
        clearItem.target = menuTarget

        return [openItem, pauseItem, clearItem]
    }

    public func makeSettingsView() -> AnyView {
        AnyView(KlipSettingsView())
    }

    // MARK: - Window

    /// The global hotkey.
    func toggleHistoryWindow() {
        if let window = historyWindowController?.window, window.isVisible {
            // Keep Open leaves the window on screen after a paste, with the
            // keyboard back in the app that was pasted into. In that state the
            // hotkey means "give Klip the keyboard again", not "close" —
            // closing a window the user can see, and asked to keep, is never
            // what they meant by summoning it. Once it *is* the key window the
            // hotkey closes it as usual.
            if !window.isKeyWindow, SettingsManager.shared.keepWindowOpen {
                historyWindowController?.refocus()
                return
            }
            historyWindowController?.close()
        } else {
            showHistoryWindow()
        }
    }

    func showHistoryWindow() {
        historyWindowController?.showWindow(nil)
    }

    func togglePause() {
        guard let watcher else { return }
        if watcher.isPaused {
            watcher.resume()
        } else {
            watcher.pause()
        }
    }

    func clearHistory() {
        guard let store else { return }
        ClearHistoryAlert.run(store: store)
    }

    /// Rate-limited (once per 60 s) so repeated paste attempts without
    /// Accessibility access don't stack HUDs on screen. The toast's button
    /// opens Bench's Permissions pane, which is where the grant lives now.
    private func handlePasteNeedsAccessibility() {
        if let last = lastAccessibilityToastAt, Date().timeIntervalSince(last) < 60 {
            return
        }
        lastAccessibilityToastAt = Date()
        AccessibilityToast.shared.show {
            BenchSettings.open(.permissions)
        }
    }
}

/// `NSMenuItem` needs an Objective-C target; the feature keeps one alive.
final class KlipMenuTarget: NSObject {
    private unowned let feature: KlipFeature

    init(feature: KlipFeature) {
        self.feature = feature
    }

    @objc func openHistory() { feature.showHistoryWindow() }
    @objc func togglePause() { feature.togglePause() }
    @objc func clearHistory() { feature.clearHistory() }
}

/// First-run, copy-only import from the standalone Klip: its preferences
/// domain into `klip.*` keys, its global hotkey into `ShortcutStore`, and
/// its Application Support folder into Bench's. The standalone app is read,
/// never written, and keeps running untouched next to Bench.
enum KlipStandaloneImport {
    static let sourceDomain = "com.fxreza.klip"
    static let flagKey = "klip.importedFromKlip"
    static let hotkeyFlagKey = "klip.importedHotkeyFromKlip"

    /// Staging keys for the two halves of Klip's global hotkey, which are
    /// not settings of this module any more but are needed once to seed the
    /// `klip.toggleHistory` override.
    static let hotkeyModifiersKey = "klip.import.hotkeyModifiers"
    static let hotkeyKeyCodeKey = "klip.import.hotkeyKeyCode"

    /// Old key -> new key, for every setting `SettingsManager` and
    /// `ShortcutManager` know plus the two hotkey halves.
    static var keyMap: [String: String] {
        var map: [String: String] = [:]
        for key in SettingsManager.standaloneKeys {
            map[key] = SettingsManager.Key.name(key)
        }
        map[ShortcutManager.standaloneStorageKey] = SettingsManager.Key.name(ShortcutManager.standaloneStorageKey)
        map["hotkeyModifiers"] = hotkeyModifiersKey
        map["hotkeyKeyCode"] = hotkeyKeyCodeKey
        return map
    }

    @MainActor
    static func importIfNeeded() {
        StandaloneImport.importDefaultsIfNeeded(sourceDomain: sourceDomain, keys: keyMap, flagKey: flagKey)
        importHotkeyIfNeeded()
        // The history, folders, trash and assets. Only when Bench's folder is
        // still empty, so this can never overwrite anything Bench has captured.
        StandaloneImport.importDirectoryIfEmpty(
            from: BenchPaths.standaloneApplicationSupport(named: "Klip"),
            to: BenchPaths.dataDirectory(feature: "Klip")
        )
    }

    /// Klip stored its hotkey as `hotkeyModifiers` (an array of
    /// "shift"/"command"/"option"/"control") and `hotkeyKeyCode` (an Int).
    /// If the imported combination differs from the default ⇧⌘V it becomes
    /// the user's override for `klip.toggleHistory`; a combination another
    /// module already owns is left alone rather than fought over.
    @MainActor
    private static func importHotkeyIfNeeded() {
        let defaults = BenchDefaults.standard
        guard !defaults.bool(forKey: hotkeyFlagKey) else { return }
        defer {
            defaults.set(true, forKey: hotkeyFlagKey)
            // The staging keys have done their job; `ShortcutStore` is the
            // only place the hotkey lives from here on.
            defaults.removeObject(forKey: hotkeyModifiersKey)
            defaults.removeObject(forKey: hotkeyKeyCodeKey)
        }
        guard let binding = importedHotkey(
            modifiers: defaults.stringArray(forKey: hotkeyModifiersKey),
            keyCode: defaults.object(forKey: hotkeyKeyCodeKey) as? Int
        ) else { return }
        guard binding != KlipHotkeys.toggleHistory.defaultBinding else { return }
        ShortcutStore.shared.set(binding, for: KlipHotkeys.toggleHistoryID)
    }

    /// Pure translation of Klip's two stored values into a `KeyBinding`;
    /// `nil` when either half is missing or the key code is not a real key.
    static func importedHotkey(modifiers: [String]?, keyCode: Int?) -> KeyBinding? {
        guard let modifiers, let keyCode, keyCode > 0, keyCode <= Int(UInt16.max) else { return nil }
        var mods: KeyModifiers = []
        if modifiers.contains("shift") { mods.insert(.shift) }
        if modifiers.contains("command") { mods.insert(.command) }
        if modifiers.contains("option") { mods.insert(.option) }
        if modifiers.contains("control") { mods.insert(.control) }
        return KeyBinding(keyCode: UInt16(keyCode), modifiers: mods)
    }
}
