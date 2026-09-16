import AppKit
import BenchCore
import SwiftUI

/// Settings > General: startup, menu bar, appearance, updates, and which
/// modules are switched on.
struct GeneralPane: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var appearance = AppearanceSettings.shared
    @ObservedObject private var registry = FeatureRegistry.shared
    @ObservedObject private var sync = SettingsSync.shared
    @StateObject private var dock = DockSpacerModel()
    @State private var launchAtLoginError: String?
    @State private var now = Date()

    private let ticker = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

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

                Stepper(
                    "Menu bar divider lines: \(settings.menuBarSeparatorCount)",
                    value: $settings.menuBarSeparatorCount, in: 0...5)
                Text("Thin vertical lines you can ⌘-drag between menu bar icons. Clicking one does nothing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Dock") {
                Stepper("Dock gaps: \(dock.normal)", value: $dock.normal, in: 0...DockSpacers.maximum)
                Stepper("Half-width Dock gaps: \(dock.small)", value: $dock.small, in: 0...DockSpacers.maximum)
                Text(dock.isPending
                     ? "Applying… the Dock restarts for a moment."
                     : "macOS's own invisible gap tiles, an icon wide or half that. New ones appear at the right end of the apps; ⌘-drag them between icons. Every change restarts the Dock.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            Section("iCloud Sync") {
                Toggle("Sync settings across your Macs", isOn: $sync.isEnabled)
                    .disabled(!sync.isAvailable)

                if let reason = sync.unavailableReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Text("Every module's settings and shortcuts are mirrored into the Bench/Settings folder in iCloud Drive. Each Mac writes only its own file, and for each setting the latest change wins. Klip's clipboard history has its own switch under Klip > Sync.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Text(syncStatusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Sync Now") { sync.syncNow() }
                        .buttonStyle(.bordered)
                        .disabled(!sync.isEnabled || !sync.isAvailable || sync.isBusy)
                }

                if let error = sync.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                TextField("This Mac's name", text: $sync.deviceName)
                Text("Shown in the sync status on your other Macs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Remove This Mac's Settings from iCloud") {
                    sync.removeThisDeviceFromCloud()
                }
                .disabled(!sync.isAvailable)
                Text("Deletes only this Mac's file in the Bench/Settings folder. Nothing on this Mac changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .onReceive(ticker) { now = $0 }
        .onAppear {
            now = Date()
            dock.startWatching()
        }
        .onDisappear { dock.stopWatching() }
    }

    private var syncStatusLine: String {
        CloudSyncStatusLine.text(
            enabled: sync.isEnabled,
            available: sync.isAvailable,
            lastPush: sync.lastPush,
            lastPull: sync.lastPull,
            devices: sync.otherDevices.map { $0.name },
            now: now)
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
