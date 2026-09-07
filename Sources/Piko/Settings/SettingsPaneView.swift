import AppKit
import BenchCore
import SwiftUI

/// Piko's pane in the Bench Settings window.
///
/// The standalone app showed this as a 300 pt popover hanging off its own
/// status item (`MenuBar/SettingsPanelView.swift`); in Bench it is a `Form` in
/// the shared Settings window, so the app-level rows the popover carried -
/// version, launch at login, check for updates, About, Quit - are gone. What
/// is left is exactly what the module owns: one switch per feature, the two
/// durations, the low-battery threshold, the visibility switches, and the two
/// permissions Piko depends on.
struct PikoSettingsView: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var permissions = PermissionsState.shared

    /// Re-read on every appearance so the Bluetooth row is current even when
    /// nothing is polling; `CBCentralManager.authorization` never prompts.
    @State private var bluetoothAuthorized = PikoBluetoothPermission.isAuthorized

    var body: some View {
        Form {
            Section("Features") {
                Toggle("Volume HUD", isOn: $settings.volumeHUDEnabled)
                Toggle("Brightness HUD", isOn: $settings.brightnessHUDEnabled)
                Toggle("Now Playing", isOn: $settings.nowPlayingEnabled)
                Toggle("Bluetooth Devices", isOn: $settings.connectivityEnabled)
                Toggle("Low Battery Warning", isOn: $settings.lowBatteryEnabled)
            }

            Section("Timing") {
                sliderRow(
                    "Volume & display HUD",
                    value: $settings.hudDuration,
                    range: Settings.hudDurationRange,
                    step: 0.1,
                    label: String(format: "%.1f s", settings.hudDuration))

                sliderRow(
                    "Other alerts",
                    value: $settings.alertDuration,
                    range: Settings.alertDurationRange,
                    step: 0.5,
                    label: String(format: "%.1f s", settings.alertDuration))

                sliderRow(
                    "Low battery at",
                    value: $settings.lowBatteryThreshold,
                    range: Settings.lowBatteryRange,
                    step: 0.05,
                    label: "\(Int((settings.lowBatteryThreshold * 100).rounded()))%")
            }

            Section("Visibility") {
                Toggle("Hide in Fullscreen", isOn: $settings.hideInFullscreen)
                Toggle("Hide in Mission Control", isOn: $settings.hideInMissionControl)
            }

            Section("Permissions") {
                accessibilityRow
                bluetoothRow
            }

            Section {
                Label {
                    Text("Quit Alcove and Glint before using Piko. All three intercept the volume and brightness keys and draw over the same notch.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            permissions.refresh()
            bluetoothAuthorized = PikoBluetoothPermission.isAuthorized
        }
    }

    // MARK: - Permission rows

    private var accessibilityRow: some View {
        permissionRow(
            title: "Accessibility",
            note: "Lets Piko swallow the volume and brightness keys, which is what replaces the macOS bezel.",
            granted: permissions.accessibilityTrusted
        ) {
            if !permissions.accessibilityTrusted {
                Button("Grant…") {
                    permissions.requestAccessibility()
                    SystemSettingsPane.accessibility.open()
                }
            }
        }
    }

    private var bluetoothRow: some View {
        permissionRow(
            title: "Bluetooth",
            note: "Needed for AirPods and other device connect notices. macOS asks the first time Piko looks for a device.",
            granted: bluetoothAuthorized
        ) {
            if !bluetoothAuthorized {
                Button("Open Settings…") { PikoBluetoothPermission.openSettings() }
            }
        }
    }

    private func permissionRow<Action: View>(
        title: String,
        note: String,
        granted: Bool,
        @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(granted ? Color.green : Color.red)
                .frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(granted ? "Granted" : note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            action()
        }
    }

    // MARK: - Rows

    private func sliderRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        label: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(label)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }
}
