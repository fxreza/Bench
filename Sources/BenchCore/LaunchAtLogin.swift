// From Transi's LaunchAtLogin.swift (MIT, Copyright 2026 Sam Reza).

import Foundation
import ServiceManagement

/// Thin wrapper around `SMAppService.mainApp` for the "Launch at Login"
/// toggle.
///
/// `SMAppService` registers whatever bundle is currently running. Under
/// `swift run` there is no signed, installed bundle for launchd to point
/// at, so `register()` throws there; this only behaves correctly against the
/// app `scripts/build-app.sh` installs.
public enum LaunchAtLogin {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters, guarded by the current status so a call
    /// that matches the existing state is a no-op. Returns an error message
    /// to show, or nil on success.
    public static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                guard SMAppService.mainApp.status != .enabled else { return nil }
                try SMAppService.mainApp.register()
            } else {
                guard SMAppService.mainApp.status != .notRegistered else { return nil }
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
