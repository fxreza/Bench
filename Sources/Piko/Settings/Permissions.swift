import AppKit
import CoreBluetooth

/// The one permission bit `BenchCore` does not cover: Bluetooth.
///
/// `BenchCore.PermissionsState` tracks Accessibility and Screen Recording,
/// and `BenchCore.SystemSettingsPane` deep-links Accessibility, Screen
/// Recording and Automation. Piko additionally reports on Bluetooth (device
/// connect notices), so the check and the deep link for that one pane stay
/// here. Ported from the standalone Piko's `MenuBar/Permissions.swift`, which
/// came from Transi's `SystemSettings.swift`.
///
/// Nothing here prompts: `CBCentralManager.authorization` reads the TCC status
/// without instantiating a central manager, and `BluetoothMonitor` lets
/// CoreBluetooth raise the prompt on first use, exactly as Piko does today.
enum PikoBluetoothPermission {
    /// True when the user has granted Bluetooth. `.notDetermined` reads as
    /// not granted: the prompt has not been shown yet.
    static var isAuthorized: Bool {
        CBCentralManager.authorization == .allowedAlways
    }

    /// Opens System Settings ▸ Privacy & Security ▸ Bluetooth.
    static func openSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!
        NSWorkspace.shared.open(url)
    }
}
