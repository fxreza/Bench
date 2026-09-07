import AppKit
import CoreGraphics
import Foundation
import BenchCore
@testable import Shot

/// Local failure type and helpers, private to this file so it does not depend
/// on Tests/TestRunner.swift (same convention as ScreenshotDefaultsTests).
nonisolated private struct CheckFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

nonisolated private func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw CheckFailure(message: message()) }
}

nonisolated private func checkEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ label: String) throws {
    if lhs != rhs { throw CheckFailure(message: "\(label): expected \(rhs), got \(lhs)") }
}

/// A noisy bitmap, so JPEG quality actually changes the encoded size. A flat
/// fill compresses to roughly the same handful of bytes at every quality.
nonisolated private func makeNoisyImage(width: Int, height: Int) -> CGImage? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                  | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
    var seed: UInt64 = 0x5EED
    for y in 0..<height {
        for x in 0..<width {
            // Deterministic pseudo-random so the test never flakes.
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let v = Double((seed >> 33) & 0xFF) / 255.0
            ctx.setFillColor(CGColor(red: v, green: 1 - v, blue: v * 0.5, alpha: 1))
            ctx.fill(CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1))
        }
    }
    return ctx.makeImage()
}

enum CaptureFormatTests {

    static let suite: (String, [(String, () throws -> Void)]) = ("Capture formats & variant shortcuts", [

        // MARK: format model

        ("CaptureFileFormat maps to an ImageFormat and an extension", {
            try checkEqual(CaptureFileFormat.png.imageFormat, .png, "png format")
            try checkEqual(CaptureFileFormat.jpg.imageFormat, .jpeg, "jpg format")
            try checkEqual(CaptureFileFormat.png.fileExtension, "png", "png extension")
            try checkEqual(CaptureFileFormat.jpg.fileExtension, "jpg", "jpg extension")
            try check(!CaptureFileFormat.png.isLossy, "png is lossless")
            try check(CaptureFileFormat.jpg.isLossy, "jpg is lossy")
            // The extension has to survive ScreenshotDefaults' normalisation,
            // or Save would silently fall back to png.
            try checkEqual(ScreenshotDefaults.parse(fileType: CaptureFileFormat.jpg.fileExtension), "jpg", "jpg round trip")
            try checkEqual(ScreenshotDefaults.parse(fileType: CaptureFileFormat.png.fileExtension), "png", "png round trip")
        }),

        ("main shortcuts default to PNG, variants to JPG", {
            try checkEqual(CaptureVariant.main.defaultFormat, .png, "main default")
            try checkEqual(CaptureVariant.alternate.defaultFormat, .jpg, "variant default")
        }),

        // Carbon ids are HotkeyCenter's business now; what has to stay
        // unique is the string id each shortcut is registered under.
        ("every shortcut has its own hotkey id", {
            let ids = CaptureShortcut.allCases.map(\.hotkeyID)
            let withVariants = CaptureAction.allCases.filter(\.producesImage).count
            let mainOnly = CaptureAction.allCases.count - withVariants
            try checkEqual(ids.count, withVariants * 2 + mainOnly, "shortcut count")
            try checkEqual(Set(ids).count, ids.count, "ids are unique")
            try checkEqual(CaptureShortcut(.area, .main).hotkeyID, "shot.area", "main id")
            try checkEqual(CaptureShortcut(.area, .alternate).hotkeyID, "shot.area.alt", "variant id")
            try check(ids.allSatisfy { $0.hasPrefix("shot.") }, "every id is namespaced to the module")
        }),

        ("the feature declares one rebindable action per capture action", {
            let actions = ShotFeature().hotkeyActions
            try checkEqual(actions.count, CaptureAction.allCases.count, "one row per action")
            try checkEqual(actions.map(\.id), CaptureAction.allCases.map(\.hotkeyActionID), "ids and order")
            try check(actions.allSatisfy { $0.featureID == "shot" }, "feature id")
            try check(actions.allSatisfy { $0.defaultBinding != nil }, "all ship bound")
        }),

        ("storage keys are distinct per action and variant", {
            let keys = CaptureShortcut.allCases.map(\.storageKey)
            try checkEqual(Set(keys).count, keys.count, "keys are unique")
            try checkEqual(CaptureShortcut(.window, .alternate).storageKey, "window.alternate", "composite key")
        }),

        ("text capture has no format and no variant shortcut", {
            try check(!CaptureAction.text.producesImage, "text writes no file")
            try check(CaptureAction.allCases.filter { !$0.producesImage } == [.text], "only text is image-less")
            try check(!CaptureShortcut.allCases.contains(CaptureShortcut(.text, .alternate)),
                      "no variant shortcut is registered for text")
            try check(CaptureShortcut.allCases.contains(CaptureShortcut(.text, .main)), "the main text shortcut exists")
        }),

        ("text capture defaults to ⇧⌘6 and collides with nothing else", {
            try checkEqual(CaptureAction.text.defaultBinding.display, "⇧⌘6", "default combination")
            let defaults = CaptureAction.allCases.map(\.defaultBinding)
            try checkEqual(Set(defaults).count, defaults.count, "defaults are unique")
            let ids = CaptureAction.allCases.map(\.hotkeyActionID)
            try checkEqual(Set(ids).count, ids.count, "action ids are unique")
        }),

        ("the default combinations mirror the macOS screenshot keys", {
            try checkEqual(CaptureAction.area.defaultBinding.display, "⇧⌘4", "area")
            try checkEqual(CaptureAction.window.defaultBinding.display, "⇧⌘2", "window")
            try checkEqual(CaptureAction.screen.defaultBinding.display, "⇧⌘3", "screen")
            try checkEqual(CaptureAction.scrolling.defaultBinding.display, "⇧⌘1", "scrolling")
        }),

        // MARK: variant derivation

        ("the variant is the main combination plus the variant modifier", {
            let base = KeyBinding(keyCode: 21, modifiers: [.command, .shift])
            guard let variant = SettingsManager.variantBinding(base: base, variantModifiers: .option) else {
                throw CheckFailure(message: "expected a variant for ⌘⇧4 + ⌥")
            }
            try checkEqual(variant.keyCode, base.keyCode, "same key")
            try checkEqual(variant.modifiers, [.command, .shift, .option], "modifiers")
            try checkEqual(variant.display, "⌥⇧⌘4", "display")
            try checkEqual(base.display, "⇧⌘4", "base display unchanged")
        }),

        ("an image-less action never derives a variant binding", {
            // Even asked directly, the ⌥ variant of a text shortcut is nil:
            // it would fire the same action on a second combination.
            try check(SettingsManager.shared.effectiveBinding(for: CaptureShortcut(.text, .alternate)) == nil,
                      "no ⌥ variant for text")
            try check(SettingsManager.shared.effectiveBinding(for: CaptureShortcut(.area, .alternate)) != nil,
                      "area still has one")
        }),

        ("a base that already holds the variant modifier has no variant", {
            let base = KeyBinding(keyCode: 21, modifiers: [.command, .option])
            try check(SettingsManager.variantBinding(base: base, variantModifiers: .option) == nil,
                      "⌥⌘4 cannot have an ⌥ variant")
            // Only part of a multi-modifier variant present: still derivable.
            try checkEqual(SettingsManager.variantBinding(base: base, variantModifiers: [.option, .control])?.modifiers,
                           [.command, .option, .control], "partial overlap still derives")
        }),

        ("an empty or unusable variant modifier yields no variant", {
            let base = KeyBinding(keyCode: 21, modifiers: [.command, .shift])
            try check(SettingsManager.variantBinding(base: base, variantModifiers: []) == nil, "no modifier")
            // Caps lock and friends cannot be registered with Carbon.
            try check(SettingsManager.variantBinding(base: base, variantModifiers: .capsLock) == nil, "caps lock")
            try check(SettingsManager.variantBinding(base: base, variantModifiers: [.capsLock, .control]) != nil,
                      "caps lock is dropped, control survives")
        }),

        // Snapper's "the variant keeps the base's enabled flag" is gone with
        // `HotkeyBinding.enabled`: a cleared shortcut is a nil binding in
        // `ShortcutStore` now, which `effectiveBinding` already covers.

        ("modifier symbols read in the macOS order", {
            try checkEqual(KeyModifiers([.command, .control, .shift, .option]).symbols, "⌃⌥⇧⌘", "all four")
            try checkEqual(KeyModifiers.option.symbols, "⌥", "option only")
            try checkEqual(KeyModifiers([]).symbols, "", "none")
        }),

        // MARK: quality

        ("JPG quality is clamped to 1-100", {
            try checkEqual(SettingsManager.clampQuality(70), 70, "in range")
            try checkEqual(SettingsManager.clampQuality(0), 1, "below")
            try checkEqual(SettingsManager.clampQuality(-40), 1, "far below")
            try checkEqual(SettingsManager.clampQuality(101), 100, "above")
            try checkEqual(SettingsManager.defaultJPEGQuality, 70, "default")
        }),

        ("ImageExporter clamps the quality it hands Image I/O", {
            try checkEqual(ImageExporter.clampQuality(0.7), CGFloat(0.7), "in range")
            try checkEqual(ImageExporter.clampQuality(-1), CGFloat(0), "below")
            try checkEqual(ImageExporter.clampQuality(4), CGFloat(1), "above")
        }),

        ("a lower JPG quality produces a smaller file", {
            guard let image = makeNoisyImage(width: 64, height: 64) else {
                throw CheckFailure(message: "could not build the test bitmap")
            }
            guard let low = ImageExporter.data(image, pixelScale: 1, format: .jpeg, quality: 0.1),
                  let mid = ImageExporter.data(image, pixelScale: 1, format: .jpeg, quality: 0.7),
                  let high = ImageExporter.data(image, pixelScale: 1, format: .jpeg, quality: 1.0) else {
                throw CheckFailure(message: "JPEG encoding returned nil")
            }
            try check(low.count < mid.count, "quality 10% (\(low.count) bytes) should be smaller than 70% (\(mid.count) bytes)")
            try check(mid.count < high.count, "quality 70% (\(mid.count) bytes) should be smaller than 100% (\(high.count) bytes)")

            // PNG ignores the quality argument entirely.
            let pngLow = ImageExporter.data(image, pixelScale: 1, format: .png, quality: 0.1)
            let pngHigh = ImageExporter.data(image, pixelScale: 1, format: .png, quality: 1.0)
            try checkEqual(pngLow?.count, pngHigh?.count, "png size is quality-independent")
        }),

        ("the pasteboard type follows the format", {
            // The identifiers the clipboard is written with, so a regression
            // here shows up as a failing test rather than a silent PNG paste.
            try checkEqual(CaptureFileFormat.jpg.imageFormat.utType.identifier, "public.jpeg", "jpg type")
            try checkEqual(CaptureFileFormat.png.imageFormat.utType.identifier, "public.png", "png type")
        }),

        ("write() picks the encoder from the extension and honours quality", {
            guard let image = makeNoisyImage(width: 32, height: 32) else {
                throw CheckFailure(message: "could not build the test bitmap")
            }
            let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("shot-format-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let lowURL = dir.appendingPathComponent("low.\(CaptureFileFormat.jpg.fileExtension)")
            let highURL = dir.appendingPathComponent("high.jpg")
            try ImageExporter.write(image, pixelScale: 1, to: lowURL, quality: 0.1)
            try ImageExporter.write(image, pixelScale: 1, to: highURL, quality: 1.0)

            let lowSize = try Data(contentsOf: lowURL).count
            let highSize = try Data(contentsOf: highURL).count
            try check(lowSize < highSize, "10% (\(lowSize)) should be smaller than 100% (\(highSize))")

            // It still decodes as an image of the right size.
            guard let (loaded, _) = ImageExporter.load(url: lowURL) else {
                throw CheckFailure(message: "loading the JPG back returned nil")
            }
            try checkEqual(loaded.width, 32, "width")
            try checkEqual(loaded.height, 32, "height")
        }),
    ])
}
