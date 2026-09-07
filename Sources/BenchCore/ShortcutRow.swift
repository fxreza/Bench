import SwiftUI

/// One row of a Shortcuts list: the action's title, a `HotkeyRecorder`
/// backed by `ShortcutStore`, a conflict or registration-failure caption in
/// red, and a Reset link when the binding is not the default.
///
/// Every module's settings pane and the app's Shortcuts pane use this, so a
/// rebind behaves identically everywhere: the store refuses a combination
/// another action holds, `HotkeyCenter` re-registers on success, and a
/// combination macOS refuses shows its owner underneath.
public struct ShortcutRow: View {
    public let action: HotkeyAction
    /// Extra content to the left of the recorder (Shot uses it for a format
    /// picker). Optional.
    private let accessory: AnyView?

    @ObservedObject private var store = ShortcutStore.shared
    @ObservedObject private var center = HotkeyCenter.shared
    @State private var conflict: HotkeyAction?

    public init(action: HotkeyAction) {
        self.action = action
        self.accessory = nil
    }

    public init<A: View>(action: HotkeyAction, @ViewBuilder accessory: () -> A) {
        self.action = action
        self.accessory = AnyView(accessory())
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(action.title)
                    .foregroundStyle(action.isRebindable ? .primary : .secondary)
                Spacer()
                if let accessory { accessory }
                if !store.isDefault(action.id) && action.isRebindable {
                    Button("Reset") {
                        store.reset(action.id)
                        conflict = nil
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                HotkeyRecorder(
                    display: store.displayString(for: action.id),
                    isRebindable: action.isRebindable,
                    onRecord: { binding in record(binding) },
                    onClear: { store.set(nil, for: action.id); conflict = nil }
                )
                .frame(width: 120, height: 24)
            }

            if let conflict {
                Text("Already used by \(conflict.title)")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let failure = center.failureMessages[action.id] {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let note = action.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if !store.isDefault(action.id) {
                Button("Reset to Default") {
                    store.reset(action.id)
                    conflict = nil
                }
            }
            if store.binding(for: action.id) != nil {
                Button("Remove Shortcut") {
                    store.set(nil, for: action.id)
                    conflict = nil
                }
            }
        }
    }

    private func record(_ binding: KeyBinding) {
        switch store.set(binding, for: action.id) {
        case .ok:
            conflict = nil
        case .conflict(let other):
            conflict = other
        }
    }
}

/// A grouped Form section listing every action of one feature, for a
/// module's own settings pane.
public struct FeatureShortcutsSection: View {
    public let featureID: String
    public let header: String
    @ObservedObject private var store = ShortcutStore.shared

    public init(featureID: String, header: String = "Shortcuts") {
        self.featureID = featureID
        self.header = header
    }

    public var body: some View {
        Section(header) {
            ForEach(store.actions(featureID: featureID)) { action in
                ShortcutRow(action: action)
            }
        }
    }
}
