import Foundation

// Notification names used across the module. Names are load-bearing (they
// are posted and observed from KlipFeature, the settings tabs and the
// clipboard watcher) — do not rename the string values.
extension Notification.Name {
    static let bufferIgnoreNextChange = Notification.Name("bufferIgnoreNextChange")
    static let bufferWindowDidOpen = Notification.Name("bufferWindowDidOpen")
    static let bufferHistoryLimitChanged = Notification.Name("bufferHistoryLimitChanged")
    /// Posted when the trash retention window changes (5D); `ClipboardStore`
    /// re-runs its purge against the new window straight away.
    static let bufferTrashRetentionChanged = Notification.Name("bufferTrashRetentionChanged")
    /// Posted when any `sync.*` setting changes (Phase 4A); `CloudDriveSync`
    /// observes it to start/stop watching and to re-read the size cap.
    static let klipSyncSettingsChanged = Notification.Name("klipSyncSettingsChanged")
    /// Posted by `PasteController` when a paste falls back to clipboard-only
    /// because Bench lacks Accessibility access. `KlipFeature` observes this
    /// to show `AccessibilityToast`. Load-bearing string — do not rename.
    static let klipPasteNeedsAccessibility = Notification.Name("klipPasteNeedsAccessibility")
}
