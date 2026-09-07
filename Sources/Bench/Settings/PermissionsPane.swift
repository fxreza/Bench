// Row visuals ported from Transi's Views/Settings/PermissionsTab.swift (MIT,
// Copyright 2026 Sam Reza), which adapted Klip's PermissionsView. Each row
// also names the modules that actually need the permission, read from
// `BenchFeature.requiredPermissions`.

import AppKit
import BenchCore
import SwiftUI

/// Settings > Permissions: what macOS has to allow before the enabled modules
/// work, and the two buttons that get it granted.
struct PermissionsPane: View {
    @ObservedObject private var permissions = PermissionsState.shared
    @ObservedObject private var registry = FeatureRegistry.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                accessibilityRow
                screenRecordingRow
                automationRow

                Text("Bench needs nothing else. Network access is used only for translation requests and update checks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Rows

    private var accessibilityRow: some View {
        PermissionRow(
            icon: "accessibility",
            title: "Accessibility",
            status: permissions.accessibilityTrusted ? .granted : .needed,
            explanation: "Needed to paste into the app you were using, read the selected text out of other apps, and move their windows.",
            users: users(of: .accessibility)
        ) {
            if !permissions.accessibilityTrusted {
                HStack(spacing: 8) {
                    Button("Grant…") { permissions.requestAccessibility() }
                        .buttonStyle(.borderedProminent)
                    Button(SystemSettingsPane.accessibility.buttonTitle) {
                        SystemSettingsPane.accessibility.open()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var screenRecordingRow: some View {
        PermissionRow(
            icon: "camera.viewfinder",
            title: "Screen Recording",
            status: permissions.screenRecordingGranted ? .granted : .needed,
            explanation: "Needed to capture the screen: screenshots, scrolling capture, and translating text out of a screenshot.",
            users: users(of: .screenRecording)
        ) {
            if !permissions.screenRecordingGranted {
                HStack(spacing: 8) {
                    Button("Grant…") { permissions.requestScreenRecording() }
                        .buttonStyle(.borderedProminent)
                    Button(SystemSettingsPane.screenRecording.buttonTitle) {
                        SystemSettingsPane.screenRecording.open()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    /// Automation has no status of its own: macOS grants it per target app,
    /// the first time Bench actually scripts that app, and there is no
    /// reliable preflight. So this row explains rather than asks.
    private var automationRow: some View {
        PermissionRow(
            icon: "applescript",
            title: "Automation",
            status: nil,
            explanation: "Granted one app at a time. macOS asks the first time Bench scripts another app - reading the selected text out of a browser, or running a scripted window action. If you refuse once, turn it back on in System Settings.",
            users: users(of: .automation)
        ) {
            Button(SystemSettingsPane.automation.buttonTitle) {
                SystemSettingsPane.automation.open()
            }
            .buttonStyle(.bordered)
        }
    }

    /// The enabled modules that declare this permission.
    private func users(of permission: BenchPermission) -> [String] {
        registry.enabledFeatures
            .filter { $0.requiredPermissions.contains(permission) }
            .map(\.title)
    }
}

// MARK: - Row

private struct PermissionRow<Actions: View>: View {
    let icon: String
    let title: String
    /// Nil for a permission with no readable status (Automation).
    let status: PermissionRowStatus?
    let explanation: String
    /// Enabled modules that need this, named so the user can see what a
    /// refusal actually costs them.
    let users: [String]
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.tint)
                    .frame(width: 20)

                Text(title)
                    .font(.body.weight(.semibold))

                Spacer()

                if let status { StatusPill(status: status) }
            }

            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(users.isEmpty
                 ? "No module that is switched on needs it right now."
                 : "Used by \(users.joined(separator: ", ")).")
                .font(.caption)
                .foregroundStyle(.tertiary)

            actions()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

// MARK: - Status pill

private enum PermissionRowStatus {
    case granted, needed

    var label: String {
        switch self {
        case .granted: return "Granted"
        case .needed: return "Needed"
        }
    }

    var color: Color {
        switch self {
        case .granted: return .green
        case .needed: return .orange
        }
    }
}

private struct StatusPill: View {
    let status: PermissionRowStatus

    var body: some View {
        Text(status.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(status.color.opacity(0.15)))
            .foregroundStyle(status.color)
    }
}
