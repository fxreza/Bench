import AppKit
import BenchCore
import SwiftUI

/// Settings > General: startup, menu bar, appearance, updates, and which
/// modules are switched on.
struct GeneralPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var appearance = AppearanceSettings.shared
    @ObservedObject private var registry = FeatureRegistry.shared
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch Bench at login", isOn: launchAtLoginBinding)
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Menu Bar") {
                Toggle("Show menu bar icon", isOn: showMenuBarIconBinding)
                if settings.hideMenuBarIcon {
                    Text("Bench keeps running with the icon hidden. To get back here, launch Bench again from Finder or Spotlight.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Appearance") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Accent color")
                    accentPicker
                }
                .padding(.vertical, 2)

                Picker("Appearance", selection: $appearance.colorScheme) {
                    ForEach(AppColorScheme.allCases) { scheme in
                        Text(scheme.label).tag(scheme)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $settings.autoCheckUpdates)
                Toggle("Include pre-releases", isOn: $settings.includePrereleases)
                Text("Pre-releases are builds marked as such on GitHub - newer, less tested.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Check Now") {
                    UpdateService.shared.checkForUpdates(silent: false)
                }
            }

            Section("Modules") {
                ForEach(registry.features, id: \.id) { feature in
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(feature.title, isOn: registry.enabledBinding(id: feature.id))
                        Text(feature.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 1)
                }
                Text("A module that is off holds no shortcuts, timers or windows at all.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Bindings

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { LaunchAtLogin.isEnabled },
            set: { launchAtLoginError = LaunchAtLogin.setEnabled($0) })
    }

    private var showMenuBarIconBinding: Binding<Bool> {
        Binding(
            get: { !settings.hideMenuBarIcon },
            set: { settings.hideMenuBarIcon = !$0 })
    }

    /// A row of tappable swatches with a ring on the selected one; `.system`
    /// shows a half-fill glyph since it has no single color of its own (it
    /// follows the macOS accent color). Ported from Transi's AppearanceTab.
    private var accentPicker: some View {
        HStack(spacing: 10) {
            ForEach(AccentTheme.allCases) { theme in
                let selected = appearance.accentTheme == theme
                Button {
                    appearance.accentTheme = theme
                } label: {
                    ZStack {
                        Circle()
                            .fill(theme == .system ? Color.gray : theme.color)
                            .frame(width: 22, height: 22)
                        if theme == .system {
                            Image(systemName: "circle.lefthalf.filled")
                                .font(.caption)
                                .foregroundStyle(.white)
                        }
                        if selected {
                            Circle()
                                .strokeBorder(Color.primary.opacity(0.85), lineWidth: 2)
                                .frame(width: 28, height: 28)
                        }
                    }
                    .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .help(theme.label)
            }
        }
    }
}
