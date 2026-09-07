import AppKit
import BenchCore
import SwiftUI

/// Settings > About: what this build is, how to update it, and where it came
/// from. Ported from Snapper's AboutTab, with the "Built from" list added -
/// Bench is three apps in a trench coat and says so.
struct AboutPane: View {
    @ObservedObject private var settings = AppSettings.shared

    private struct Origin: Identifiable {
        let name: String
        let role: String
        let url: URL
        var id: String { name }
    }

    private let origins: [Origin] = [
        Origin(name: "Snapper", role: "Shot - screenshots and annotation",
               url: URL(string: "https://github.com/fxreza/Snapper")!),
        Origin(name: "Klip", role: "Klip - clipboard history",
               url: URL(string: "https://github.com/fxreza/Klip")!),
        Origin(name: "Transi", role: "Lingo - translation",
               url: URL(string: "https://github.com/fxreza/Transi")!),
        Origin(name: "Piko", role: "Piko - Dynamic Island for the notch",
               url: URL(string: "https://github.com/fxreza/Piko")!),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable()
                    .frame(width: 96, height: 96)

                VStack(spacing: 2) {
                    Text(BenchInfo.appName)
                        .font(.title2.bold())
                    Text("Version \(BenchInfo.shortVersion) (\(BenchInfo.buildNumber))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 10) {
                    Button("Check for Updates…") {
                        UpdateService.shared.checkForUpdates(silent: false)
                    }
                    .buttonStyle(.borderedProminent)

                    Toggle("Check for updates automatically", isOn: $settings.autoCheckUpdates)

                    Button("What's New") {
                        UpdateService.shared.showChangelogWindow()
                    }
                    .buttonStyle(.link)
                }

                Divider()
                    .padding(.horizontal, 40)

                builtFrom

                HStack(spacing: 8) {
                    Link("GitHub", destination: BenchInfo.repositoryURL)
                    Text("·").foregroundStyle(.secondary)
                    Link("Report an Issue",
                         destination: BenchInfo.repositoryURL.appendingPathComponent("issues"))
                }
                .font(.caption)
                .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    private var builtFrom: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Built from")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(.secondary)

            ForEach(origins) { origin in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Link(origin.name, destination: origin.url)
                        .frame(width: 70, alignment: .leading)
                    Text(origin.role)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }

            Text("Snap is new here - it replaces the window-management triggers Bench's author used to keep in BetterTouchTool.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 420, alignment: .leading)
    }
}
