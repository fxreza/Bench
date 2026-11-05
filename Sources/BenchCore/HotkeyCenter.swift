// Adapted from Snapper's Services/HotkeyManager.swift and Transi's
// HotkeyManager.swift (both MIT, Copyright 2026 Sam Reza), which trace back
// to Klip. One Carbon event handler for the whole app; string ids instead of
// per-app enums; bindings come from `ShortcutStore` and follow rebinds
// automatically.

import AppKit
import Carbon.HIToolbox
import os

/// Registers Bench's global keyboard shortcuts with the Carbon Event Manager
/// (`RegisterEventHotKey`): no Input Monitoring permission, works from an
/// `LSUIElement` app with no windows.
///
/// Two ways in:
///
/// - `bind(_:handler:)` for a declared `HotkeyAction`. The combination is
///   whatever `ShortcutStore` says (default or the user's rebind), and the
///   registration is redone automatically when that changes.
/// - `bindFixed(id:binding:handler:)` for a derived combination that is not
///   itself rebindable, such as Shot's "same keys plus ⌥" format variants.
///   The caller re-binds when its source changes.
///
/// A refused registration (macOS or another app already holds the
/// combination) leaves a message in `failureMessages[id]` for the Shortcuts
/// pane, cleared on the next success for that id.
@MainActor
public final class HotkeyCenter: ObservableObject {
    public static let shared = HotkeyCenter()

    @Published public private(set) var failureMessages: [String: String] = [:]

    private struct Entry {
        let carbonID: UInt32
        var binding: KeyBinding?
        var ref: EventHotKeyRef?
        let handler: @MainActor () -> Void
        /// True when the combination follows `ShortcutStore`.
        let followsStore: Bool
    }

    private var entries: [String: Entry] = [:]
    private var idsByCarbonID: [UInt32: String] = [:]
    private var nextCarbonID: UInt32 = 1
    private var eventHandler: EventHandlerRef?
    private var storeObserver: NSObjectProtocol?

    /// 'BNCH' - Bench's four-byte Carbon signature.
    private static let signature = OSType(0x424E_4348)

    private init() {
        storeObserver = NotificationCenter.default.addObserver(
            forName: .benchShortcutsChanged, object: nil, queue: .main
        ) { [weak self] note in
            let id = note.userInfo?["actionID"] as? String
            MainActor.assumeIsolated { self?.storeChanged(actionID: id) }
        }
        observeMainRunLoopWakes()
    }

    // MARK: - Binding

    /// Binds `action` to `handler`, registering whatever combination
    /// `ShortcutStore` currently holds for it. Rebinding the same id
    /// replaces the earlier handler.
    public func bind(_ action: HotkeyAction, handler: @escaping @MainActor () -> Void) {
        unbind(action.id)
        let binding = ShortcutStore.shared.binding(for: action.id)
        install(id: action.id, binding: binding, handler: handler, followsStore: true)
    }

    /// Binds a fixed combination under `id` (not persisted, not shown as a
    /// recorder row). Passing nil registers nothing but remembers the
    /// handler, so a later non-nil `bindFixed` for the same id works.
    public func bindFixed(id: String, binding: KeyBinding?, handler: @escaping @MainActor () -> Void) {
        unbind(id)
        install(id: id, binding: binding, handler: handler, followsStore: false)
    }

    public func unbind(_ id: String) {
        guard var entry = entries[id] else { return }
        if let ref = entry.ref {
            UnregisterEventHotKey(ref)
            entry.ref = nil
        }
        idsByCarbonID.removeValue(forKey: entry.carbonID)
        entries.removeValue(forKey: id)
        failureMessages.removeValue(forKey: id)
    }

    /// Unbinds every id with the prefix `"<featureID>."` - what a feature
    /// calls from `stop()`.
    public func unbindAll(featureID: String) {
        for id in entries.keys where id.hasPrefix(featureID + ".") {
            unbind(id)
        }
    }

    public func isBound(_ id: String) -> Bool {
        entries[id]?.ref != nil
    }

    public func failureMessage(for id: String) -> String? {
        failureMessages[id]
    }

    // MARK: - Carbon

    private func install(id: String, binding: KeyBinding?, handler: @escaping @MainActor () -> Void, followsStore: Bool) {
        let carbonID = nextCarbonID
        nextCarbonID += 1
        var entry = Entry(carbonID: carbonID, binding: binding, ref: nil, handler: handler, followsStore: followsStore)
        idsByCarbonID[carbonID] = id
        if let binding {
            entry.ref = register(binding: binding, carbonID: carbonID, id: id)
        } else {
            failureMessages.removeValue(forKey: id)
        }
        entries[id] = entry
    }

    private func register(binding: KeyBinding, carbonID: UInt32, id: String) -> EventHotKeyRef? {
        ensureEventHandlerInstalled()
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: carbonID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(binding.keyCode), binding.modifiers.carbonMask, hotKeyID,
            GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            failureMessages.removeValue(forKey: id)
            return ref
        }
        // Carbon only ever says "exists"; SystemHotkeys names the owner when
        // it is macOS itself.
        let match = SystemHotkeys.systemMatch(keyCode: binding.keyCode, modifiers: binding.eventFlags)
        failureMessages[id] = SystemHotkeys.message(for: match)
        NSLog("[HotkeyCenter] refused \(id) = \(binding.display): \(status)")
        return nil
    }

    private func storeChanged(actionID: String?) {
        let ids = actionID.map { [$0] } ?? Array(entries.keys)
        for id in ids {
            guard var entry = entries[id], entry.followsStore else { continue }
            let newBinding = ShortcutStore.shared.binding(for: id)
            guard newBinding != entry.binding || (newBinding != nil && entry.ref == nil) else { continue }
            if let ref = entry.ref {
                UnregisterEventHotKey(ref)
                entry.ref = nil
            }
            entry.binding = newBinding
            if let newBinding {
                entry.ref = register(binding: newBinding, carbonID: entry.carbonID, id: id)
            } else {
                failureMessages.removeValue(forKey: id)
            }
            entries[id] = entry
        }
    }

    private func ensureEventHandlerInstalled() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData, let event else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                guard status == noErr else { return noErr }
                let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
                let carbonID = hotKeyID.id
                // Carbon delivers this on the main run loop; the C function
                // pointer cannot be declared @MainActor, so assert it.
                MainActor.assumeIsolated {
                    center.fire(carbonID: carbonID)
                }
                return noErr
            },
            1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler)
    }

    private func fire(carbonID: UInt32) {
        guard let id = idsByCarbonID[carbonID], let entry = entries[id] else { return }
        let busyFor = ProcessInfo.processInfo.systemUptime - lastMainWake
        guard !Self.isStale(mainThreadBusyFor: busyFor) else {
            Self.log.notice("dropped stale shortcut \(id, privacy: .public): main thread busy for \(busyFor, format: .fixed(precision: 1))s")
            return
        }
        entry.handler()
    }

    /// A shortcut is handled on the main thread, so one pressed while the
    /// main thread is blocked waits in the queue and fires late, together
    /// with every other one pressed meanwhile (2026-10-07: a two-minute
    /// freeze ended with a dozen Finder windows at once).
    ///
    /// The test is how long the main run loop has gone without waking from
    /// idle: a fresh press wakes it, so it is handled milliseconds after the
    /// wake; one queued behind a freeze is handled after the whole freeze.
    /// Not the window server's "seconds since last key-down": since macOS
    /// 27.2 that skips the key-down of a global hot key, so it measured the
    /// time since the last ordinary keystroke and dropped fresh presses
    /// (2026-11-05). Carbon's own event time is when the event is handled,
    /// so it cannot tell either. Needs no permission, and App Nap does not
    /// affect it (an input event wakes a napping app at once).
    static let staleShortcutAge: TimeInterval = 2.0

    static func isStale(mainThreadBusyFor seconds: TimeInterval) -> Bool {
        seconds > staleShortcutAge
    }

    /// `systemUptime` of the main run loop's last wake from idle, in every
    /// common mode (default, menu tracking, modal panels).
    private var lastMainWake = ProcessInfo.processInfo.systemUptime
    private var wakeObserver: CFRunLoopObserver?

    private func observeMainRunLoopWakes() {
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.afterWaiting.rawValue, true, 0
        ) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.lastMainWake = ProcessInfo.processInfo.systemUptime
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        wakeObserver = observer
    }

    private static let log = Logger(subsystem: "com.fxreza.bench", category: "hotkeys")
}
