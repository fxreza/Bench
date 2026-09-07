import Foundation

public extension Notification.Name {
    /// Posted by `ShortcutStore` after any binding changes. `userInfo["actionID"]`
    /// carries the action id, or is absent for "Reset All".
    static let benchShortcutsChanged = Notification.Name("bench.shortcutsChanged")

    /// Posted by `FeatureRegistry` after a feature is switched on or off.
    /// `userInfo["featureID"]` carries the feature id.
    static let benchFeatureEnabledChanged = Notification.Name("bench.featureEnabledChanged")

    /// Posted by `AppearanceSettings` after the accent or color scheme changes.
    static let benchAppearanceChanged = Notification.Name("bench.appearanceChanged")
}

public extension Notification.Name {
    /// Posted by `BenchSettings.open(_:)`. The app observes it and shows the
    /// Settings window at the requested destination
    /// (`userInfo["destination"]` is a `BenchSettingsDestination`).
    static let benchOpenSettings = Notification.Name("bench.openSettings")
}

/// Where in the Settings window a module wants the user taken.
public enum BenchSettingsDestination: Equatable, Sendable {
    case general
    case shortcuts
    case permissions
    case about
    /// A module's own pane, by feature id.
    case feature(String)
}

/// The one way a module opens Settings: it never owns the window.
public enum BenchSettings {
    @MainActor
    public static func open(_ destination: BenchSettingsDestination = .general) {
        NotificationCenter.default.post(
            name: .benchOpenSettings, object: nil, userInfo: ["destination": destination])
    }
}
