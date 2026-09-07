import BenchCore
import SwiftUI

/// The Settings window's root: a sidebar of the app's own panes plus one row
/// per registered module, and the selected pane on the right.
struct SettingsView: View {
    @ObservedObject var selection: SettingsSelection
    @ObservedObject private var registry = FeatureRegistry.shared

    /// `List` hands back nil when the user manages to deselect the row; the
    /// detail must keep showing something, so nil is ignored.
    private var paneBinding: Binding<SettingsPane?> {
        Binding(
            get: { selection.pane },
            set: { if let new = $0 { selection.pane = new } })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: paneBinding) {
                Section("Bench") {
                    row(.general, title: "General", symbol: "gearshape")
                    row(.shortcuts, title: "Shortcuts", symbol: "command")
                    row(.permissions, title: "Permissions", symbol: "lock.shield")
                    row(.about, title: "About", symbol: "info.circle")
                }

                Section("Modules") {
                    ForEach(registry.features, id: \.id) { feature in
                        row(
                            .feature(feature.id),
                            title: feature.title,
                            symbol: feature.symbolName,
                            // A switched-off module keeps its row - that is
                            // where you switch it back on - but reads as off.
                            dimmed: !registry.isEnabled(feature.id))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 680, minHeight: 460)
        .benchAppearance()
    }

    private func row(_ pane: SettingsPane, title: String, symbol: String, dimmed: Bool = false) -> some View {
        Label(title, systemImage: symbol)
            .opacity(dimmed ? 0.5 : 1)
            .tag(pane)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection.pane {
        case .general:
            GeneralPane()
        case .shortcuts:
            ShortcutsPane()
        case .permissions:
            PermissionsPane()
        case .about:
            AboutPane()
        case .feature(let id):
            if let feature = registry.feature(id: id) {
                FeaturePane(feature: feature)
            } else {
                // A module that was in the sidebar and is not in the registry
                // any more: only reachable if a destination named an id no
                // build has.
                ContentUnavailableMessage(title: "Module not available")
            }
        }
    }
}

/// One module's pane: who it is and whether it is on, then the module's own
/// settings.
private struct FeaturePane: View {
    let feature: BenchFeature
    @ObservedObject private var registry = FeatureRegistry.shared

    private var isEnabled: Bool { registry.isEnabled(feature.id) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // The module's own pane is left mounted but inert while the module
            // is off, so switching it back on does not rebuild the view from
            // scratch under the user.
            feature.makeSettingsView()
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.45)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: feature.symbolName)
                .font(.system(size: 22))
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title)
                    .font(.title3.weight(.semibold))
                Text(feature.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Toggle("", isOn: registry.enabledBinding(id: feature.id))
                .toggleStyle(.switch)
                .labelsHidden()
                .help(isEnabled ? "Turn \(feature.title) off" : "Turn \(feature.title) on")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

/// A plain centred message, for the states that should not happen but must
/// still render something.
struct ContentUnavailableMessage: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
