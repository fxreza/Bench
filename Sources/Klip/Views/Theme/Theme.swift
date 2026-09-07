// Adapted from Clipfield (MIT, Copyright 2026 Alex Jolley)

import SwiftUI
import AppKit
import BenchCore

/// Shared visual constants and helpers for a cohesive look across Klip.
/// Mirrors Clipfield's `UI/Theme.swift` design system so Klip's row/panel/
/// prompt chrome reads as one consistent set of tokens instead of ~60
/// scattered literals.
enum Theme {
    static let panelCornerRadius: CGFloat = 18
    static let rowCornerRadius: CGFloat = 10
    static let badgeCornerRadius: CGFloat = 8
    static let promptCornerRadius: CGFloat = 16

    /// The app-wide accent Bench keeps in `AppearanceSettings` (falls back to
    /// the system accent color).
    @MainActor static var accent: Color { AppearanceSettings.shared.accentTheme.color }

    @MainActor static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [accent, accent.opacity(0.72)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Spring used for selection movement and chip/sidebar highlights.
    static let selectionSpring = Animation.spring(response: 0.28, dampingFraction: 0.82)
    /// Spring used to present/toggle inline prompts (editor, fill, new-folder, etc.).
    static let promptSpring = Animation.spring(response: 0.3, dampingFraction: 0.8)

    /// Opaque backing for the history panel.
    ///
    /// The panel used to be `.regularMaterial`, which let a dark desktop show
    /// through and made the text hard to read. Light mode uses #F5F5F5 rather
    /// than the system `windowBackgroundColor`, which read too bright; dark
    /// mode keeps the system colour, so the panel matches the Settings window.
    static let panelBackground = Color(nsColor: NSColor(name: "KlipPanelBackground") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .windowBackgroundColor
            : NSColor(srgbRed: 245 / 255, green: 245 / 255, blue: 245 / 255, alpha: 1)
    })

    /// 1pt hairline stroke for material panels.
    static let hairline = Color.white.opacity(0.12)
    /// Row background on hover.
    static let rowHover = Color.primary.opacity(0.06)
    /// Inactive filter-chip fill.
    static let chipInactive = Color.primary.opacity(0.07)
    /// Dimming scrim behind modal prompts.
    static let scrim = Color.black.opacity(0.28)
    /// Selected-row glow shadow color.
    static let selectionGlow = Color.accentColor.opacity(0.35)

    // MARK: - Row / badge chrome (Phase 2A)

    /// Font for a glyph-only control (SF Symbol) at a base point size, scaled by
    /// the list or preview font-size setting.
    ///
    /// Symbols have no `KlipFontRole` of their own, and this keeps raw
    /// `.font(.system(size:))` literals out of `Views/History/**` (see the
    /// Phase 3H sweep).
    @MainActor
    static func icon(_ base: CGFloat, weight: Font.Weight = .regular, preview: Bool = false) -> Font {
        .system(size: .klipScaled(base, preview: preview), weight: weight)
    }

    /// Fill behind an unselected kind icon badge.
    static func badgeFill(_ kind: ContentKind) -> Color { kindTint(kind).opacity(0.16) }
    /// Badge fill when the row is selected (sits on the accent gradient).
    static let badgeFillSelected = Color.white.opacity(0.18)
    /// Hairline around image thumbnails.
    static let badgeStroke = Color.white.opacity(0.15)
    /// Slightly stronger hairline around color swatches.
    static let swatchStroke = Color.white.opacity(0.25)
    /// Secondary (subtitle) text colour on a selected row.
    static let onAccentSecondary = Color.white.opacity(0.82)
    /// Opacity applied to the accent gradient for multi-selected, non-primary rows.
    static let multiSelectFillOpacity: Double = 0.6
    /// Divider/separator hairline drawn inside content (not the panel border).
    static let separator = Color.primary.opacity(0.12)
    /// Subtle `.bar`-like backing for the search bar and action bar.
    static let barBackground = Color.primary.opacity(0.04)

    /// Pin badge colour (Clipfield's rotated orange pin).
    static let pinTint = Color.orange
    /// Star / favourite badge colour.
    static let bookmarkTint = Color.yellow
    /// Lock badge colour.
    static let lockTint = Color.secondary
    /// Tint used for the multi-selection header pill.
    static let multiSelectTint = Color.purple
    /// "Large" (file-backed text) badge colour.
    static let largeBadgeTint = Color.orange
    /// Destructive action colour (inline delete confirmations).
    static let destructive = Color.red

    /// Drop shadow under inline prompt cards.
    static let promptShadow = Color.black.opacity(0.3)
    static let promptShadowRadius: CGFloat = 20
    static let promptShadowY: CGFloat = 8

    /// Accent tint for a clipboard item's semantic kind.
    static func kindTint(_ kind: ContentKind) -> Color {
        kindTint(kind.rawValue)
    }

    /// Accent tint for a clipboard item's kind. Keyed by the raw string a
    /// `ContentKind`-style enum would produce, so this compiles and is usable
    /// before that enum lands (today's `ClipboardItemType` only has
    /// "text"/"image"; the remaining cases are forward-looking).
    static func kindTint(_ rawKind: String) -> Color {
        switch rawKind {
        case "text": return .gray
        case "richText": return .indigo
        case "link": return .blue
        case "image": return .purple
        case "file": return .gray
        case "color": return .pink
        case "email": return .green
        case "phone": return .teal
        case "code": return .orange
        default: return .gray
        }
    }
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
