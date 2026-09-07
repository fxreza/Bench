import AppKit
import SwiftUI

/// A macOS permission a feature depends on, listed so the Permissions pane
/// can say which module needs what.
public enum BenchPermission: String, CaseIterable, Sendable {
    case accessibility
    case screenRecording
    /// Apple Events to other apps (AppleScript), granted per target app.
    case automation

    public var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .screenRecording: return "Screen Recording"
        case .automation: return "Automation"
        }
    }
}

/// One module of Bench: Shot, Klip, Lingo or Snap.
///
/// A feature is a long-lived object owned by `FeatureRegistry`. `start()` is
/// called at launch when the feature is enabled and again whenever the user
/// switches it on; `stop()` when it is switched off and at quit. A stopped
/// feature holds no hotkeys, no event taps, no timers and no windows.
///
/// Global shortcuts are never registered by the feature itself: it declares
/// them as `hotkeyActions` and binds handlers through `HotkeyCenter`, which
/// owns the Carbon registrations, persists rebinds through `ShortcutStore`,
/// and reports conflicts across every module in one place.
@MainActor
public protocol BenchFeature: AnyObject {
    /// Stable lowercase identifier, e.g. `"shot"`. Prefixes every
    /// preferences key and every hotkey action id of the module.
    var id: String { get }
    /// Display name, e.g. `"Shot"`.
    var title: String { get }
    /// SF Symbol for the Settings sidebar and the status menu.
    var symbolName: String { get }
    /// One line for the General pane, e.g. "Screenshots and annotation".
    var summary: String { get }
    /// What the module needs from System Settings to work fully.
    var requiredPermissions: [BenchPermission] { get }
    /// Every rebindable global shortcut the module offers, in display order.
    var hotkeyActions: [HotkeyAction] { get }

    func start()
    func stop()

    /// Items for the module's section of the status bar menu. Called on
    /// every menu open, so items can reflect current state. Return an empty
    /// array for no section.
    func menuItems() -> [NSMenuItem]

    /// The module's pane in the Settings window. Bench wraps it in the
    /// sidebar and adds the enable toggle above it.
    func makeSettingsView() -> AnyView
}

/// Owns the features, their enabled flags, and the start/stop lifecycle.
@MainActor
public final class FeatureRegistry: ObservableObject {
    public static let shared = FeatureRegistry()

    @Published public private(set) var features: [BenchFeature] = []
    @Published public private(set) var enabledIDs: Set<String> = []
    private var started: Set<String> = []

    private init() {}

    private func enabledKey(_ id: String) -> String { "bench.feature.\(id).enabled" }

    /// Adds the features in display order. Call once at launch, before
    /// `startEnabled()`.
    public func register(_ features: [BenchFeature]) {
        self.features = features
        var enabled: Set<String> = []
        for feature in features {
            let key = enabledKey(feature.id)
            // Default on: a fresh install gets every module.
            if BenchDefaults.standard.object(forKey: key) == nil || BenchDefaults.standard.bool(forKey: key) {
                enabled.insert(feature.id)
            }
            ShortcutStore.shared.registerActions(feature.hotkeyActions)
        }
        enabledIDs = enabled
    }

    public func feature(id: String) -> BenchFeature? {
        features.first { $0.id == id }
    }

    public func isEnabled(_ id: String) -> Bool { enabledIDs.contains(id) }

    /// Features currently enabled, in registration order.
    public var enabledFeatures: [BenchFeature] {
        features.filter { enabledIDs.contains($0.id) }
    }

    /// Starts every enabled feature. Safe to call once.
    public func startEnabled() {
        for feature in enabledFeatures where !started.contains(feature.id) {
            feature.start()
            started.insert(feature.id)
        }
    }

    public func stopAll() {
        for feature in features where started.contains(feature.id) {
            feature.stop()
            started.remove(feature.id)
        }
    }

    /// Switches a feature on or off, persisting the choice and starting or
    /// stopping it immediately.
    public func setEnabled(_ enabled: Bool, id: String) {
        guard let feature = feature(id: id), isEnabled(id) != enabled else { return }
        BenchDefaults.standard.set(enabled, forKey: enabledKey(id))
        if enabled {
            enabledIDs.insert(id)
            if !started.contains(id) {
                feature.start()
                started.insert(id)
            }
        } else {
            enabledIDs.remove(id)
            if started.contains(id) {
                feature.stop()
                started.remove(id)
            }
        }
        NotificationCenter.default.post(name: .benchFeatureEnabledChanged, object: nil, userInfo: ["featureID": id])
    }

    /// A `Binding` for a toggle in Settings.
    public func enabledBinding(id: String) -> Binding<Bool> {
        Binding(
            get: { [weak self] in self?.isEnabled(id) ?? false },
            set: { [weak self] in self?.setEnabled($0, id: id) }
        )
    }
}
