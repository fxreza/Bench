// Adapted from Transi's Shortcuts/ShortcutManager.swift (MIT), itself
// adapted from Klip's Services/ShortcutManager.swift: overrides-only
// persistence resolved against each action's default. Generalized to hold
// every module's actions at once so a conflict check spans the whole app.

import Foundation
import Combine

/// Owns the effective binding of every `HotkeyAction` in the app: a stored
/// override where the user rebound one (or unbound it), the factory default
/// otherwise. Persists only the overrides, so a future change to a default
/// applies to anyone who never touched that action.
@MainActor
public final class ShortcutStore: ObservableObject {
    public static let shared = ShortcutStore()

    public enum ConflictResult: Equatable {
        case ok
        case conflict(HotkeyAction)
    }

    private static let overridesKey = "bench.shortcuts.overrides"
    private static let unboundKey = "bench.shortcuts.unbound"

    private let defaults: UserDefaults

    /// Every registered action, in registration order, keyed for lookup.
    @Published public private(set) var actions: [HotkeyAction] = []
    private var actionsByID: [String: HotkeyAction] = [:]

    /// Rebinds the user made: action id -> combination.
    @Published private(set) var overrides: [String: KeyBinding] = [:]
    /// Actions the user explicitly cleared.
    @Published private(set) var unbound: Set<String> = []

    /// Bumped on every change, so views observing the store re-render even
    /// when they only read through `binding(for:)`.
    @Published public private(set) var version = 0

    public init(defaults: UserDefaults = BenchDefaults.standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.overridesKey),
           let stored = try? JSONDecoder().decode([String: KeyBinding].self, from: data) {
            overrides = stored
        }
        if let stored = defaults.stringArray(forKey: Self.unboundKey) {
            unbound = Set(stored)
        }
    }

    // MARK: - Registration

    /// Adds a feature's actions. Re-registering an id replaces the earlier
    /// declaration (its default may have changed), keeping any override.
    public func registerActions(_ newActions: [HotkeyAction]) {
        for action in newActions {
            if actionsByID[action.id] != nil {
                actions.removeAll { $0.id == action.id }
            }
            actionsByID[action.id] = action
            actions.append(action)
        }
        version += 1
    }

    public func action(id: String) -> HotkeyAction? { actionsByID[id] }

    public func actions(featureID: String) -> [HotkeyAction] {
        actions.filter { $0.featureID == featureID }
    }

    // MARK: - Lookup

    /// The effective binding: override, or default, or nil when unbound.
    public func binding(for id: String) -> KeyBinding? {
        if unbound.contains(id) { return nil }
        if let override = overrides[id] { return override }
        return actionsByID[id]?.defaultBinding
    }

    public func binding(for action: HotkeyAction) -> KeyBinding? { binding(for: action.id) }

    public func displayString(for id: String) -> String {
        binding(for: id)?.display ?? ""
    }

    public func isDefault(_ id: String) -> Bool {
        overrides[id] == nil && !unbound.contains(id)
    }

    /// The registered action, other than `excluding`, that currently owns
    /// `binding`, if any.
    public func owner(of binding: KeyBinding, excluding id: String? = nil) -> HotkeyAction? {
        actions.first { $0.id != id && self.binding(for: $0.id) == binding }
    }

    // MARK: - Mutation

    /// Attempts to bind `binding` to the action. Refused (with the
    /// conflicting action returned) when another action already uses the
    /// identical combination. Passing nil clears the shortcut.
    @discardableResult
    public func set(_ binding: KeyBinding?, for id: String) -> ConflictResult {
        guard let action = actionsByID[id] else { return .ok }
        if let binding, let other = owner(of: binding, excluding: id) {
            return .conflict(other)
        }
        if let binding {
            unbound.remove(id)
            if binding == action.defaultBinding {
                overrides.removeValue(forKey: id)
            } else {
                overrides[id] = binding
            }
        } else {
            overrides.removeValue(forKey: id)
            if action.defaultBinding != nil { unbound.insert(id) }
        }
        persist()
        notify(id)
        return .ok
    }

    public func reset(_ id: String) {
        overrides.removeValue(forKey: id)
        unbound.remove(id)
        persist()
        notify(id)
    }

    public func resetAll() {
        overrides = [:]
        unbound = []
        persist()
        notify(nil)
    }

    private func persist() {
        if overrides.isEmpty {
            defaults.removeObject(forKey: Self.overridesKey)
        } else if let data = try? JSONEncoder().encode(overrides) {
            defaults.set(data, forKey: Self.overridesKey)
        }
        if unbound.isEmpty {
            defaults.removeObject(forKey: Self.unboundKey)
        } else {
            defaults.set(Array(unbound).sorted(), forKey: Self.unboundKey)
        }
    }

    private func notify(_ id: String?) {
        version += 1
        var info: [String: Any] = [:]
        if let id { info["actionID"] = id }
        NotificationCenter.default.post(name: .benchShortcutsChanged, object: self, userInfo: info)
    }
}
