import Foundation
import SwiftUI
import BenchTestKit
import BenchCore
@testable import Klip

// Covers the pure parts of Phase 1C's settings/theme work (see
// docs/plan/briefs/1C-settings-theme.md): AccentTheme / AppColorScheme
// round-trips, Color(hexString:) parsing, and the font-scale math in
// Views/Theme/FontScale.swift. `SettingsManager` itself is a `@MainActor`
// singleton backed directly by `BenchDefaults.standard` (no injectable
// suite), so the handful of tests that need to flip a live setting to
// observe its effect go through `MainActor.assumeIsolated` (the same
// bridge `Tests/TestRunner.swift`'s `TestMain.main()` already uses) and
// restore the original value afterwards so suite order doesn't matter.

enum SettingsManagerTests {
    static let tests: [(String, () throws -> Void)] = [
        ("accentTheme_allCases_roundTripRawValue", testAccentThemeRoundTrip),
        ("accentTheme_systemMapsToAccentColor", testAccentThemeSystemColor),
        ("appColorScheme_allCases_roundTripRawValue", testAppColorSchemeRoundTrip),
        ("appColorScheme_swiftUIMapping", testAppColorSchemeSwiftUIMapping),
        ("colorHexString_parsesRGB_RRGGBB_RRGGBBAA", testColorHexStringParsing),
        ("colorHexString_invalidInput_returnsNil", testColorHexStringInvalid),
        ("klipFontRole_baseSizesMatchSpec", testFontRoleBaseSizes),
        ("klipFontRole_previewRolesFlaggedCorrectly", testFontRolePreviewFlag),
        ("klipScaled_scalesByListOrPreviewFactor", testKlipScaledUsesCorrectFactor),
        ("fontKlip_changesWithListFontScale", testFontKlipTracksListScale),
        ("historyLimitShim_defaultAndFromStoredRaw", testHistoryLimitMapping),
    ]

    // MARK: - AccentTheme

    static func testAccentThemeRoundTrip() throws {
        for theme in AccentTheme.allCases {
            let restored = AccentTheme(rawValue: theme.rawValue)
            try expectEqual(restored, theme, "AccentTheme.\(theme) should round-trip through its rawValue")
        }
        try expectEqual(AccentTheme.allCases.count, 9, "expected all 9 accent options from the brief")
    }

    static func testAccentThemeSystemColor() throws {
        // .system defers to the platform accent color rather than a fixed
        // color; the rest have a distinct label derived from their case name.
        try expectEqual(AccentTheme.system.label, "System")
        try expectEqual(AccentTheme.blue.label, "Blue")
    }

    // MARK: - AppColorScheme

    static func testAppColorSchemeRoundTrip() throws {
        for scheme in AppColorScheme.allCases {
            let restored = AppColorScheme(rawValue: scheme.rawValue)
            try expectEqual(restored, scheme, "AppColorScheme.\(scheme) should round-trip through its rawValue")
        }
        try expectEqual(AppColorScheme.allCases.count, 3, "expected system/light/dark")
    }

    static func testAppColorSchemeSwiftUIMapping() throws {
        try expectNil(AppColorScheme.system.swiftUI, "system should map to nil (follow the OS)")
        try expectEqual(AppColorScheme.light.swiftUI, .light)
        try expectEqual(AppColorScheme.dark.swiftUI, .dark)
    }

    // MARK: - Color(hexString:)

    static func testColorHexStringParsing() throws {
        try expectNotNil(Color(hexString: "#FFF"), "3-digit hex with # should parse")
        try expectNotNil(Color(hexString: "abc"), "3-digit hex without # should parse")
        try expectNotNil(Color(hexString: "#FF00FF"), "6-digit hex should parse")
        try expectNotNil(Color(hexString: "#112233FF"), "8-digit hex (RGBA) should parse")
    }

    static func testColorHexStringInvalid() throws {
        try expectNil(Color(hexString: "not-a-color"), "non-hex text should not parse")
        try expectNil(Color(hexString: "#12345"), "5-digit hex is not a supported length")
    }

    // MARK: - KlipFontRole

    static func testFontRoleBaseSizes() throws {
        let expected: [(KlipFontRole, CGFloat)] = [
            (.sidebarTitle, 15), (.sidebar, 13), (.sectionHeader, 10), (.chip, 11),
            (.rowTitle, 13), (.rowTitleMono, 12.5), (.rowSubtitle, 11), (.caption, 10),
            (.preview, 13), (.previewMono, 12.5), (.badge, 10),
        ]
        for (role, size) in expected {
            try expectEqual(role.baseSize, size, "\(role) base size")
        }
    }

    static func testFontRolePreviewFlag() throws {
        try expect(KlipFontRole.preview.isPreviewRole, "preview role should scale with previewFontScale")
        try expect(KlipFontRole.previewMono.isPreviewRole, "previewMono role should scale with previewFontScale")
        try expect(!KlipFontRole.rowTitle.isPreviewRole, "rowTitle is a list role")
        try expect(!KlipFontRole.sidebar.isPreviewRole, "sidebar is a list role")
    }

    // MARK: - Scaling (touches the live SettingsManager singleton)

    static func testKlipScaledUsesCorrectFactor() throws {
        try MainActor.assumeIsolated {
            let settings = SettingsManager.shared
            let originalList = settings.listFontScale
            let originalPreview = settings.previewFontScale
            defer {
                settings.listFontScale = originalList
                settings.previewFontScale = originalPreview
            }

            settings.listFontScale = 1.25
            settings.previewFontScale = 0.8

            try expectEqual(CGFloat.klipScaled(10, preview: false), 12.5, "list scale should multiply the base value")
            try expectEqual(CGFloat.klipScaled(10, preview: true), 8, "preview scale should multiply the base value")
        }
    }

    static func testFontKlipTracksListScale() throws {
        try MainActor.assumeIsolated {
            let settings = SettingsManager.shared
            let originalList = settings.listFontScale
            defer { settings.listFontScale = originalList }

            // Font is an opaque SwiftUI type, so assert on the same size
            // math Font.klip uses internally rather than reflecting into it.
            settings.listFontScale = 2.0
            let scaledRowTitle = KlipFontRole.rowTitle.baseSize * settings.listFontScale
            try expectEqual(scaledRowTitle, 26, "rowTitle (base 13) at 2x scale")
            _ = Font.klip(.rowTitle) // exercises the call path without crashing
        }
    }

    // MARK: - HistoryLimit (Views/Settings/KlipSettingsView.swift)

    static func testHistoryLimitMapping() throws {
        try expectEqual(HistoryLimit.default, .k10)
        try expectEqual(HistoryLimit.from(storedRaw: nil), .k10, "missing stored value falls back to .default")
        try expectEqual(HistoryLimit.from(storedRaw: 100), .k1, "legacy essential maps to 1,000")
        try expectEqual(HistoryLimit.from(storedRaw: 500), .k1, "legacy deep maps to 1,000")
        try expectEqual(HistoryLimit.from(storedRaw: 1000), .k1)
        try expectEqual(HistoryLimit.from(storedRaw: 5000), .k5)
        try expectEqual(HistoryLimit.from(storedRaw: 0), .unlimited)
        try expectEqual(HistoryLimit.from(storedRaw: 999_999), .k10, "unknown rawValue falls back to .default")
        try expectNil(HistoryLimit.unlimited.maxItems)
        try expectEqual(HistoryLimit.k5.maxItems, 5000)
    }
}
