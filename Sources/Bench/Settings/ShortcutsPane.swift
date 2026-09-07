import BenchCore
import SwiftUI

/// Settings > Shortcuts: every module's global shortcuts in one list, so a
/// combination can be found without hunting through four panes.
///
/// The rows are `BenchCore`'s `ShortcutRow`, the same ones a module shows in
/// its own pane, so a rebind behaves identically wherever it is made.
struct ShortcutsPane: View {
    @ObservedObject private var store = ShortcutStore.shared
    @ObservedObject private var registry = FeatureRegistry.shared

    /// Only enabled modules: a switched-off module holds no hotkeys, so
    /// offering to rebind them here would be offering to rebind nothing.
    private var sections: [(feature: BenchFeature, actions: [HotkeyAction])] {
        registry.enabledFeatures.compactMap { feature in
            let actions = store.actions(featureID: feature.id)
            return actions.isEmpty ? nil : (feature, actions)
        }
    }

    var body: some View {
        Form {
            if sections.isEmpty {
                Section {
                    Text("No module with shortcuts is switched on.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(sections, id: \.feature.id) { section in
                    Section {
                        ForEach(section.actions) { action in
                            ShortcutRow(action: action)
                        }
                    } header: {
                        Label(section.feature.title, systemImage: section.feature.symbolName)
                    }
                }
            }

            Section {
                Button("Reset All to Defaults") {
                    ShortcutStore.shared.resetAll()
                }
                Text("Conflicts are checked across every module: a combination one action holds cannot be given to another, and macOS or another app may still refuse one - that is reported under the row.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
