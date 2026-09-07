import Foundation

/// One rebindable global shortcut, declared by a feature.
///
/// `id` is `"<feature>.<action>"`, e.g. `"shot.area"`; it is the key under
/// which `ShortcutStore` persists a rebind and under which `HotkeyCenter`
/// reports a registration failure, so it must never change once shipped.
public struct HotkeyAction: Identifiable, Hashable, Sendable {
    public let id: String
    public let featureID: String
    public let title: String
    /// The factory combination, or nil for an action that ships unbound and
    /// only fires once the user records a shortcut for it.
    public let defaultBinding: KeyBinding?
    /// False for a display-only row (a menu key equivalent that is not a
    /// global hotkey). The Shortcuts pane shows it greyed with no recorder.
    public let isRebindable: Bool
    /// Optional one-line note shown under the row in the Shortcuts pane.
    public let note: String?

    public init(
        id: String,
        featureID: String,
        title: String,
        defaultBinding: KeyBinding?,
        isRebindable: Bool = true,
        note: String? = nil
    ) {
        self.id = id
        self.featureID = featureID
        self.title = title
        self.defaultBinding = defaultBinding
        self.isRebindable = isRebindable
        self.note = note
    }
}
