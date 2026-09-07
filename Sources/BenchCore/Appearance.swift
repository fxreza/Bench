// Ported from Snapper's Views/Theme/Appearance.swift (MIT, Copyright 2026 Sam
// Reza), itself from Klip, itself adapted from Clipfield (MIT, Copyright 2026
// Alex Jolley). One app-wide accent and color scheme instead of one per app.

import AppKit
import SwiftUI

/// Selectable accent colors. `system` follows the macOS accent color.
public enum AccentTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, blue, purple, indigo, pink, red, orange, green, teal

    public var id: String { rawValue }

    public var color: Color {
        switch self {
        case .system: return .accentColor
        case .blue: return .blue
        case .purple: return .purple
        case .indigo: return .indigo
        case .pink: return .pink
        case .red: return .red
        case .orange: return .orange
        case .green: return .green
        case .teal: return .teal
        }
    }

    public var nsColor: NSColor {
        switch self {
        case .system: return .controlAccentColor
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .indigo: return .systemIndigo
        case .pink: return .systemPink
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .green: return .systemGreen
        case .teal: return .systemTeal
        }
    }

    public var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// Light / Dark / follow-system appearance.
public enum AppColorScheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    public var id: String { rawValue }
    public var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// `nil` means "follow the system", matching `View.preferredColorScheme`.
    public var swiftUI: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// The AppKit counterpart, for windows that set `NSWindow.appearance`
    /// directly. `nil` means "follow the system".
    public var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// The app-wide accent and color scheme, persisted under `bench.appearance.*`.
/// `apply()` sets `NSApp.appearance`, which every window inherits unless it
/// overrides its own.
@MainActor
public final class AppearanceSettings: ObservableObject {
    public static let shared = AppearanceSettings()

    private let defaults = BenchDefaults.standard
    private static let accentKey = "bench.appearance.accent"
    private static let schemeKey = "bench.appearance.colorScheme"

    @Published public var accentTheme: AccentTheme {
        didSet {
            defaults.set(accentTheme.rawValue, forKey: Self.accentKey)
            NotificationCenter.default.post(name: .benchAppearanceChanged, object: nil)
        }
    }

    @Published public var colorScheme: AppColorScheme {
        didSet {
            defaults.set(colorScheme.rawValue, forKey: Self.schemeKey)
            apply()
            NotificationCenter.default.post(name: .benchAppearanceChanged, object: nil)
        }
    }

    private init() {
        accentTheme = AccentTheme(rawValue: defaults.string(forKey: Self.accentKey) ?? "") ?? .system
        colorScheme = AppColorScheme(rawValue: defaults.string(forKey: Self.schemeKey) ?? "") ?? .system
    }

    public func apply() {
        NSApp.appearance = colorScheme.nsAppearance
    }
}

public extension View {
    /// Applies the app accent and color scheme to a SwiftUI root view.
    func benchAppearance() -> some View {
        modifier(BenchAppearanceModifier())
    }
}

private struct BenchAppearanceModifier: ViewModifier {
    @ObservedObject private var appearance = AppearanceSettings.shared

    func body(content: Content) -> some View {
        content
            .tint(appearance.accentTheme.color)
            .preferredColorScheme(appearance.colorScheme.swiftUI)
    }
}
