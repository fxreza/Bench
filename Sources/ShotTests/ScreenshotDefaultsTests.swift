import AppKit
import CoreGraphics
import Foundation
@testable import Shot

/// Tiny failure type so this file does not depend on Tests/TestRunner.swift.
nonisolated private struct CheckFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// Local assertion helper (private to this file on purpose).
nonisolated private func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw CheckFailure(message: message()) }
}

nonisolated private func checkEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ label: String) throws {
    if lhs != rhs { throw CheckFailure(message: "\(label): expected \(rhs), got \(lhs)") }
}

/// Solid red bitmap used by the round-trip test.
nonisolated private func makeRedImage(width: Int, height: Int) -> CGImage? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                  | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    return ctx.makeImage()
}

enum ScreenshotDefaultsTests {

    static let suite: (String, [(String, () throws -> Void)]) = ("ScreenshotDefaults & capture helpers", [

        // MARK: filename formatting

        ("filename uses the macOS pattern", {
            var comps = DateComponents()
            comps.year = 2026; comps.month = 9; comps.day = 3
            comps.hour = 10; comps.minute = 45; comps.second = 47
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone.current
            let date = cal.date(from: comps)!
            let name = ScreenshotDefaults.filename(date: date, ext: "png", includeDate: true, baseName: "Screenshot")
            try checkEqual(name, "Screenshot 2026-09-03 at 10.45.47.png", "filename")
        }),

        ("filename honours includeDate = false", {
            let name = ScreenshotDefaults.filename(date: Date(), ext: "jpg", includeDate: false, baseName: "Shot")
            try checkEqual(name, "Shot.jpg", "filename without date")
        }),

        ("filename falls back on an empty base name and extension", {
            let name = ScreenshotDefaults.filename(date: Date(), ext: "  ", includeDate: false, baseName: "   ")
            try checkEqual(name, "Screenshot.png", "filename fallbacks")
        }),

        // MARK: location expansion

        ("expand(location:) tilde-expands an existing directory", {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let url = ScreenshotDefaults.expand(location: "~")
            try checkEqual(url.standardizedFileURL.path, URL(fileURLWithPath: home).standardizedFileURL.path,
                           "tilde expansion")
        }),

        ("expand(location:) falls back to ~/Desktop", {
            let desktop = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop", isDirectory: true).standardizedFileURL.path
            try checkEqual(ScreenshotDefaults.expand(location: nil).standardizedFileURL.path, desktop, "nil location")
            try checkEqual(ScreenshotDefaults.expand(location: "   ").standardizedFileURL.path, desktop, "blank location")
            try checkEqual(ScreenshotDefaults.expand(location: "/definitely/not/here/at/all")
                            .standardizedFileURL.path, desktop, "missing location")
        }),

        ("expand(location:) rejects a file that is not a directory", {
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("snapper-not-a-dir-\(UUID().uuidString).txt")
            try Data("x".utf8).write(to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let desktop = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop", isDirectory: true).standardizedFileURL.path
            try checkEqual(ScreenshotDefaults.expand(location: tmp.path).standardizedFileURL.path, desktop,
                           "file instead of directory")
        }),

        // MARK: target + type parsing

        ("target parsing", {
            try checkEqual(ScreenshotDefaults.parse(target: "clipboard"), .clipboard, "clipboard")
            try checkEqual(ScreenshotDefaults.parse(target: " Clipboard "), .clipboard, "clipboard, padded + cased")
            try checkEqual(ScreenshotDefaults.parse(target: "file"), .file, "file")
            try checkEqual(ScreenshotDefaults.parse(target: "preview"), .file, "unknown target")
            try checkEqual(ScreenshotDefaults.parse(target: nil), .file, "unset target")
        }),

        ("file type parsing", {
            try checkEqual(ScreenshotDefaults.parse(fileType: "JPEG"), "jpg", "jpeg -> jpg")
            try checkEqual(ScreenshotDefaults.parse(fileType: "jpg"), "jpg", "jpg")
            try checkEqual(ScreenshotDefaults.parse(fileType: "heic"), "heic", "heic")
            try checkEqual(ScreenshotDefaults.parse(fileType: "tif"), "tiff", "tif -> tiff")
            try checkEqual(ScreenshotDefaults.parse(fileType: "pdf"), "pdf", "pdf")
            try checkEqual(ScreenshotDefaults.parse(fileType: "bmp"), "png", "unsupported -> png")
            try checkEqual(ScreenshotDefaults.parse(fileType: nil), "png", "unset -> png")
        }),

        ("nextFileURL de-duplicates existing names", {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("snapper-next-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let date = Date()
            let first = ScreenshotDefaults.nextFileURL(in: dir, ext: "png", date: date)
            try Data("x".utf8).write(to: first)
            let second = ScreenshotDefaults.nextFileURL(in: dir, ext: "png", date: date)
            try check(second != first, "second URL should differ from \(first.lastPathComponent)")
            try check(second.lastPathComponent.contains(" (2)"),
                      "expected a ' (2)' suffix, got \(second.lastPathComponent)")
        }),

        // MARK: window coordinate conversion

        ("toGlobalAppKit flips CGWindowList bounds", {
            // Primary screen 1000pt tall. A 200x100 window 50pt below the top
            // edge sits at AppKit y = 1000 - 50 - 100 = 850.
            let cg = CGRect(x: 120, y: 50, width: 200, height: 100)
            let appKit = WindowEnumerator.toGlobalAppKit(cgBounds: cg, primaryHeight: 1000)
            try checkEqual(appKit, CGRect(x: 120, y: 850, width: 200, height: 100), "flip")

            // A window flush with the top of the primary screen.
            let top = WindowEnumerator.toGlobalAppKit(cgBounds: CGRect(x: 0, y: 0, width: 400, height: 300),
                                                      primaryHeight: 1000)
            try checkEqual(top, CGRect(x: 0, y: 700, width: 400, height: 300), "top-aligned window")

            // A window on a display above the primary one gets a negative CG y
            // and lands above 1000 in AppKit space.
            let above = WindowEnumerator.toGlobalAppKit(cgBounds: CGRect(x: 0, y: -400, width: 100, height: 200),
                                                        primaryHeight: 1000)
            try checkEqual(above, CGRect(x: 0, y: 1200, width: 100, height: 200), "window above the primary display")

            // Round trip: converting twice returns the original bounds.
            let back = WindowEnumerator.toGlobalAppKit(cgBounds: appKit, primaryHeight: 1000)
            try checkEqual(back, cg, "round trip")
        }),

        ("window(at:in:) picks the front-most hit", {
            let back = WindowInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 500, height: 500),
                                  title: "back", ownerName: "A", ownerPID: 1, layer: 0)
            let front = WindowInfo(id: 2, frame: CGRect(x: 100, y: 100, width: 200, height: 200),
                                   title: "front", ownerName: "B", ownerPID: 2, layer: 0)
            let windows = [front, back]   // front-to-back
            try checkEqual(WindowEnumerator.window(at: CGPoint(x: 150, y: 150), in: windows)?.id, 2, "overlap")
            try checkEqual(WindowEnumerator.window(at: CGPoint(x: 20, y: 20), in: windows)?.id, 1, "back only")
            try check(WindowEnumerator.window(at: CGPoint(x: 900, y: 900), in: windows) == nil, "outside every window")
        }),

        // MARK: image export round trip

        ("PNG round trip preserves size and pixelScale via DPI", {
            guard let image = makeRedImage(width: 8, height: 6) else {
                throw CheckFailure(message: "could not build the test bitmap")
            }
            guard let png = ImageExporter.data(image, pixelScale: 2, format: .png) else {
                throw CheckFailure(message: "PNG encoding returned nil")
            }

            let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("snapper-export-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("red.png")
            try png.write(to: url)

            guard let (loaded, scale) = ImageExporter.load(url: url) else {
                throw CheckFailure(message: "loading the PNG back returned nil")
            }
            try checkEqual(loaded.width, 8, "width")
            try checkEqual(loaded.height, 6, "height")
            try checkEqual(scale, CGFloat(2), "pixelScale from DPI")

            // 1x round trip through write(_:pixelScale:to:).
            let url1x = dir.appendingPathComponent("red1x.png")
            try ImageExporter.write(image, pixelScale: 1, to: url1x)
            guard let (loaded1x, scale1x) = ImageExporter.load(url: url1x) else {
                throw CheckFailure(message: "loading the 1x PNG returned nil")
            }
            try checkEqual(loaded1x.width, 8, "1x width")
            try checkEqual(scale1x, CGFloat(1), "1x pixelScale")
        }),

        ("format(forExtension:) maps extensions, defaulting to png", {
            try checkEqual(ImageExporter.format(forExtension: "PNG"), .png, "png")
            try checkEqual(ImageExporter.format(forExtension: "jpg"), .jpeg, "jpg")
            try checkEqual(ImageExporter.format(forExtension: "jpeg"), .jpeg, "jpeg")
            try checkEqual(ImageExporter.format(forExtension: "heic"), .heic, "heic")
            try checkEqual(ImageExporter.format(forExtension: "tif"), .tiff, "tif")
            try checkEqual(ImageExporter.format(forExtension: ""), .png, "empty")
            try checkEqual(ImageExporter.format(forExtension: "webp"), .png, "unknown")
        }),

        ("pixelScale(fromDPI:) reads Retina metadata", {
            try checkEqual(ImageExporter.pixelScale(fromDPI: 72), CGFloat(1), "72 dpi")
            try checkEqual(ImageExporter.pixelScale(fromDPI: 144), CGFloat(2), "144 dpi")
            try checkEqual(ImageExporter.pixelScale(fromDPI: 216), CGFloat(3), "216 dpi")
            try checkEqual(ImageExporter.pixelScale(fromDPI: nil), CGFloat(1), "missing dpi")
            try checkEqual(ImageExporter.pixelScale(fromDPI: 0), CGFloat(1), "zero dpi")
        }),

        ("JPEG encoding produces data", {
            guard let image = makeRedImage(width: 4, height: 4) else {
                throw CheckFailure(message: "could not build the test bitmap")
            }
            guard let jpeg = ImageExporter.data(image, pixelScale: 2, format: .jpeg) else {
                throw CheckFailure(message: "JPEG encoding returned nil")
            }
            try check(jpeg.count > 0, "empty JPEG data")
            guard let (decoded, scale) = ImageExporter.decode(data: jpeg) else {
                throw CheckFailure(message: "decoding the JPEG returned nil")
            }
            try checkEqual(decoded.width, 4, "jpeg width")
            try checkEqual(scale, CGFloat(2), "jpeg pixelScale")
        }),
    ])
}
