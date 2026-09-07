// Ported from Snapper's Views/Settings/AppearanceTab.swift (MIT, Copyright
// 2026 Sam Reza). Snapper owned its own accent color and light/dark choice;
// in Bench both are app-wide (`BenchCore.AppearanceSettings`), so the two
// controls are gone and what is left is the read-only statement of what the
// overlay, the editor and the scrolling-capture chrome will use.

import SwiftUI
import BenchCore

/// Settings > Editor: the appearance Shot's own windows follow.
struct AppearanceTab: View {
    @ObservedObject private var appearance = AppearanceSettings.shared

    var body: some View {
        Form {
            Section("Editor Appearance") {
                LabeledContent("Appearance") {
                    Text(appearance.colorScheme.label)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Accent color") {
                    HStack(spacing: 8) {
                        accentSwatch
                        Text(appearance.accentTheme.label)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("The capture overlay, the editor window and the scrolling-capture chrome follow Bench's appearance. Change it under Bench's Appearance settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var accentSwatch: some View {
        ZStack {
            Circle()
                .fill(appearance.accentTheme == .system
                      ? AnyShapeStyle(.gray.gradient)
                      : AnyShapeStyle(appearance.accentTheme.color.gradient))
                .frame(width: 18, height: 18)
            if appearance.accentTheme == .system {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.caption2)
                    .foregroundStyle(.white)
            }
        }
    }
}
