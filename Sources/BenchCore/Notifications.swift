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
