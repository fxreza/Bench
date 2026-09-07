// Ported from Snapper's Views/Settings/GeneralTab.swift (MIT, Copyright 2026
// Sam Reza). The Startup and Menu Bar sections are gone: launch at login and
// the status item belong to Bench, not to one module.

import SwiftUI
import AppKit

/// Settings > General: capture behavior, and a read-only summary of the macOS
/// screenshot defaults (`com.apple.screencapture`) that Shot's Save/Enter
/// follow.
struct GeneralTab: View {
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        Form {
            Section("Capture") {
                Toggle("Keep tool active after drawing", isOn: $settings.keepToolActive)
                Toggle("Remember last used tool for the next capture", isOn: $settings.rememberLastTool)
                Toggle("Play capture sound", isOn: $settings.playCaptureSound)
                Toggle("Include window shadow when capturing windows", isOn: $settings.includeWindowShadow)
                Toggle("Copy image to clipboard when closing with Escape", isOn: $settings.copyOnClose)
                Picker("Show sizes in", selection: dimensionsBinding) {
                    Text("Pixels").tag(true)
                    Text("Points").tag(false)
                }
            }

            Section("macOS Screenshot Defaults") {
                screenshotDefaultsBox
            }
        }
        .formStyle(.grouped)
    }

    private var dimensionsBinding: Binding<Bool> {
        Binding(
            get: { settings.dimensionsInPixels },
            set: { settings.dimensionsInPixels = $0 }
        )
    }

    private var screenshotDefaultsBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Save to")
                Spacer()
                Text(ScreenshotDefaults.target == .clipboard ? "Clipboard" : "File")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Folder")
                Spacer()
                Text(ScreenshotDefaults.saveDirectory.path)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack {
                Text("File type")
                Spacer()
                Text(ScreenshotDefaults.fileType.uppercased())
                    .foregroundStyle(.tertiary)
                Text("not used")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Text("Shot's Save and Enter follow the destination, folder and file name above. The file type comes from the capture shortcut instead - set it per shortcut under Shortcuts.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open Folder") {
                NSWorkspace.shared.open(ScreenshotDefaults.saveDirectory)
            }
            .padding(.top, 2)
        }
    }
}
