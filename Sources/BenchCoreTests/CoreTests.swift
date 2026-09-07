import AppKit
import Carbon.HIToolbox
import BenchTestKit
@testable import BenchCore

enum KeyBindingTests {
    static let tests: [TestCase] = [
        ("display orders modifiers ⌃⌥⇧⌘", {
            let b = KeyBinding(keyCode: 8, modifiers: [.command, .shift, .option, .control])
            try expectEqual(b.display, "⌃⌥⇧⌘C")
        }),
        ("special keys are named", {
            try expectEqual(KeyBinding(keyCode: 123, modifiers: [.control, .command]).display, "⌃⌘←")
            try expectEqual(KeyBinding(keyCode: 36, modifiers: [.control, .command]).display, "⌃⌘↩")
            try expectEqual(KeyBinding(keyCode: 51, modifiers: [.control, .command]).display, "⌃⌘⌫")
            try expectEqual(KeyBinding(keyCode: 48, modifiers: [.option]).display, "⌥⇥")
        }),
        ("event flags round-trip", {
            let mods = KeyModifiers(eventFlags: [.command, .option, .capsLock, .function])
            try expectEqual(mods, [.command, .option])
            try expectEqual(mods.eventFlags, [.command, .option])
        }),
        ("carbon mask", {
            let mods: KeyModifiers = [.command, .control]
            try expectEqual(mods.carbonMask, UInt32(cmdKey) | UInt32(controlKey))
        }),
        ("codable round-trip", {
            let b = KeyBinding(kVK_ANSI_T, [.option])
            let data = try JSONEncoder().encode(b)
            let back = try JSONDecoder().decode(KeyBinding.self, from: data)
            try expectEqual(back, b)
        }),
        ("menu key equivalents", {
            try expectEqual(KeyBinding(kVK_ANSI_C, [.command]).menuKeyEquivalent, "c")
            try expectEqual(KeyBinding(kVK_Return, [.command]).menuKeyEquivalent, "\r")
            try expectNotNil(KeyBinding(kVK_LeftArrow, [.command]).menuKeyEquivalent)
            try expectNil(KeyBinding(kVK_F1, [.command]).menuKeyEquivalent)
        }),
    ]
}

enum ShortcutStoreTests {
    @MainActor
    static func makeStore() -> (ShortcutStore, UserDefaults) {
        let name = "bench.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let store = ShortcutStore(defaults: defaults)
        store.registerActions([
            HotkeyAction(id: "a.one", featureID: "a", title: "One", defaultBinding: KeyBinding(kVK_ANSI_1, [.command, .shift])),
            HotkeyAction(id: "a.two", featureID: "a", title: "Two", defaultBinding: KeyBinding(kVK_ANSI_2, [.command, .shift])),
            HotkeyAction(id: "b.free", featureID: "b", title: "Free", defaultBinding: nil),
        ])
        return (store, defaults)
    }

    static let tests: [TestCase] = [
        ("defaults resolve", {
            let (store, _) = makeStore()
            try expectEqual(store.binding(for: "a.one")?.display, "⇧⌘1")
            try expectNil(store.binding(for: "b.free"))
            try expect(store.isDefault("a.one"), "untouched is default")
        }),
        ("conflict across features is refused", {
            let (store, _) = makeStore()
            let result = store.set(KeyBinding(kVK_ANSI_1, [.command, .shift]), for: "b.free")
            try expectEqual(result, .conflict(store.action(id: "a.one")!))
            try expectNil(store.binding(for: "b.free"))
        }),
        ("rebind persists as override only", {
            let (store, defaults) = makeStore()
            try expectEqual(store.set(KeyBinding(kVK_ANSI_9, [.command]), for: "a.one"), .ok)
            try expect(!store.isDefault("a.one"), "override recorded")
            try expectNotNil(defaults.data(forKey: "bench.shortcuts.overrides"))
            // Recording the default again drops the override.
            try expectEqual(store.set(KeyBinding(kVK_ANSI_1, [.command, .shift]), for: "a.one"), .ok)
            try expect(store.isDefault("a.one"), "default clears override")
            try expectNil(defaults.data(forKey: "bench.shortcuts.overrides"))
        }),
        ("unbinding a defaulted action sticks", {
            let (store, defaults) = makeStore()
            store.set(nil, for: "a.two")
            try expectNil(store.binding(for: "a.two"))
            try expect(!store.isDefault("a.two"), "unbound is not default")
            let reloaded = ShortcutStore(defaults: defaults)
            reloaded.registerActions(store.actions)
            try expectNil(reloaded.binding(for: "a.two"))
            reloaded.reset("a.two")
            try expectEqual(reloaded.binding(for: "a.two")?.display, "⇧⌘2")
        }),
        ("actions by feature keep order", {
            let (store, _) = makeStore()
            try expectEqual(store.actions(featureID: "a").map(\.id), ["a.one", "a.two"])
        }),
    ]
}

enum SystemHotkeysTests {
    static func entry(_ keyCode: Int, _ mask: UInt, enabled: Bool = true) -> [String: Any] {
        ["enabled": enabled, "value": ["parameters": [65535, keyCode, mask]]]
    }

    static let tests: [TestCase] = [
        ("names the macOS owner of ⇧⌘4", {
            let table: [String: Any] = ["29": entry(21, NSEvent.ModifierFlags([.shift, .command]).rawValue)]
            let match = SystemHotkeys.match(keyCode: 21, modifiers: [.shift, .command], in: table)
            try expectEqual(match?.name, "Screenshot")
            try expectEqual(SystemHotkeys.message(for: match), "Already used by macOS (Screenshot)")
        }),
        ("disabled entries never match", {
            let table: [String: Any] = ["29": entry(21, NSEvent.ModifierFlags([.shift, .command]).rawValue, enabled: false)]
            try expectNil(SystemHotkeys.match(keyCode: 21, modifiers: [.shift, .command], in: table))
        }),
        ("unknown owner message", {
            try expect(SystemHotkeys.message(for: nil).hasPrefix("Already used by another app"), "fallback wording")
        }),
    ]
}

enum RecorderOutcomeTests {
    static let tests: [TestCase] = [
        ("escape cancels", {
            try expectEqual(RecorderView.outcome(keyCode: 53, flags: [.command]), .cancel)
        }),
        ("bare delete clears", {
            try expectEqual(RecorderView.outcome(keyCode: 51, flags: []), .clear)
        }),
        ("shift alone is rejected", {
            try expectEqual(RecorderView.outcome(keyCode: 0, flags: [.shift]), .reject)
        }),
        ("command records", {
            try expectEqual(RecorderView.outcome(keyCode: 0, flags: [.command, .function]), .record(KeyBinding(keyCode: 0, modifiers: [.command])))
        }),
    ]
}
