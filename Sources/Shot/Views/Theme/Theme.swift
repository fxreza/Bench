// Ported from Klip (MIT, Copyright 2026 Sam Reza): Views/Theme/Theme.swift,
// itself adapted from Clipfield (MIT, Copyright 2026 Alex Jolley). Klip's
// version was clipboard-history specific (row/badge chrome keyed by
// `ContentKind`, pin/favorite/lock/multi-select tints, a `.klipScaled`
// font-size setting) — all of that is stripped, leaving the generic panel /
// prompt / hairline tokens and the hex-color parser that annotation and
// settings UI can reuse. In Bench the accent is app-wide, so
// `accent`/`accentGradient` read `BenchCore.AppearanceSettings.shared`.

import SwiftUI
import AppKit
import BenchCore

/// Shared visual constants and helpers for a cohesive look across Shot.
enum Theme {
    static let panelCornerRadius: CGFloat = 18
    static let rowCornerRadius: CGFloat = 10
    static let badgeCornerRadius: CGFloat = 8
    static let promptCornerRadius: CGFloat = 16

    /// The user's chosen accent, app-wide (falls back to the system accent
    /// color, which is what `AccentTheme.system` resolves to).
    @MainActor static var accent: Color {
        AppearanceSettings.shared.accentTheme.color
    }

    /// The same choice as an `NSColor`, for the AppKit chrome (toolbar
    /// buttons, the marching-ants border, the overlay).
    @MainActor static var accentNSColor: NSColor {
        AppearanceSettings.shared.accentTheme.nsColor
    }

    @MainActor static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accent, accent.opacity(0.72)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Spring used for selection movement (handle drags, snap animations).
    static let selectionSpring = Animation.spring(response: 0.28, dampingFraction: 0.82)
    /// Spring used to present/toggle inline prompts (properties panel, tool
    /// popovers, etc.).
    static let promptSpring = Animation.spring(response: 0.3, dampingFraction: 0.8)

    /// Opaque backing for a chrome panel (toolbars, properties panel).
    static let panelBackground = Color(nsColor: NSColor(name: "ShotPanelBackground") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .windowBackgroundColor
            : NSColor(srgbRed: 245 / 255, green: 245 / 255, blue: 245 / 255, alpha: 1)
    })

    /// 1pt hairline stroke for material panels.
    static let hairline = Color.white.opacity(0.12)
    /// Row/control background on hover.
    static let rowHover = Color.primary.opacity(0.06)
    /// Inactive toggle/chip fill.
    static let chipInactive = Color.primary.opacity(0.07)
    /// Dimming scrim behind modal prompts.
    static let scrim = Color.black.opacity(0.28)
    /// Selected-element glow shadow color.
    static let selectionGlow = Color.accentColor.opacity(0.35)
    /// Divider/separator hairline drawn inside content (not the panel border).
    static let separator = Color.primary.opacity(0.12)
    /// Subtle `.bar`-like backing for a toolbar or action strip.
    static let barBackground = Color.primary.opacity(0.04)

    /// Destructive action colour (delete confirmations).
    static let destructive = Color.red

    /// Drop shadow under inline prompt cards.
    static let promptShadow = Color.black.opacity(0.3)
    static let promptShadowRadius: CGFloat = 20
    static let promptShadowY: CGFloat = 8
}

extension Color {
    /// Parses `#RGB`, `#RRGGBB`, or `#RRGGBBAA` (with or without leading `#`).
    init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard let value = UInt64(hex, radix: 16) else { return nil }

        let r, g, b, a: Double
        switch hex.count {
        case 3:
            r = Double((value >> 8) & 0xF) / 15
            g = Double((value >> 4) & 0xF) / 15
            b = Double(value & 0xF) / 15
            a = 1
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        case 8:
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        default:
            return nil
        }
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
