import AppKit
import CoreGraphics
import Foundation
@testable import Shot

/// Tiny failure type so this file does not depend on the shared runner.
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

/// A window at `frame` owned by `owner`.
nonisolated private func makeWindow(_ owner: String, _ frame: CGRect, id: CGWindowID = 1, pid: pid_t = 501) -> WindowInfo {
    WindowInfo(id: id, frame: frame, title: owner, ownerName: owner, ownerPID: pid, layer: 0)
}

nonisolated private func makeImage(width: Int, height: Int) -> CGImage? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                  | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    return ctx.makeImage()
}

/// A fixed date, so the file-name tests do not depend on "now".
nonisolated private func fixedDate() -> Date {
    var comps = DateComponents()
    comps.year = 2026; comps.month = 9; comps.day = 7
    comps.hour = 14; comps.minute = 3; comps.second = 10
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone.current
    return cal.date(from: comps)!
}

/// Crediting the app a capture came from: the file name, the sanitization of
/// the app's display name, the "Where from" metadata, and the rule that picks
/// the source window under a rubber-band selection.
enum SourceAppTests {

    static let suite: (String, [(String, () throws -> Void)]) = ("Source app credit", [

        // MARK: file names

        ("a known source app becomes the file name's base", {
            let name = ScreenshotDefaults.filename(date: fixedDate(),
                                                   ext: "png",
                                                   includeDate: true,
                                                   baseName: ScreenshotDefaults.sanitized(sourceAppName: "IINA") ?? "Screenshot")
            try checkEqual(name, "IINA 2026-09-07 at 14.03.10.png", "source app filename")
        }),

        ("nextFileURL uses the source app instead of the macOS base name", {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ShotTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let url = ScreenshotDefaults.nextFileURL(in: dir, ext: "png", date: fixedDate(), sourceAppName: "Google Chrome")
            try checkEqual(url.lastPathComponent, "Google Chrome 2026-09-07 at 14.03.10.png", "nextFileURL name")
        }),

        ("nextFileURL falls back to the macOS base name without a source app", {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ShotTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let plain = ScreenshotDefaults.nextFileURL(in: dir, ext: "png", date: fixedDate(), sourceAppName: nil)
            let expected = ScreenshotDefaults.filename(date: fixedDate(),
                                                       ext: "png",
                                                       includeDate: ScreenshotDefaults.includeDate,
                                                       baseName: ScreenshotDefaults.baseName)
            try checkEqual(plain.lastPathComponent, expected, "fallback name")
        }),

        // MARK: sanitization

        ("sanitization strips separators, leading dots and whitespace", {
            try checkEqual(ScreenshotDefaults.sanitized(sourceAppName: "  IINA  "), "IINA", "trimmed")
            try checkEqual(ScreenshotDefaults.sanitized(sourceAppName: "Path/To:App"), "Path To App", "separators")
            try checkEqual(ScreenshotDefaults.sanitized(sourceAppName: "...Hidden"), "Hidden", "leading dots")
        }),

        ("sanitization caps the name at 40 characters", {
            let long = String(repeating: "A", count: 80)
            let name = ScreenshotDefaults.sanitized(sourceAppName: long)
            try checkEqual(name?.count, ScreenshotDefaults.maxSourceNameLength, "capped length")
        }),

        ("an empty or nil app name credits nothing", {
            try check(ScreenshotDefaults.sanitized(sourceAppName: nil) == nil, "nil stays nil")
            try check(ScreenshotDefaults.sanitized(sourceAppName: "   ") == nil, "blank stays nil")
            try check(ScreenshotDefaults.sanitized(sourceAppName: " . / : ") == nil, "punctuation only stays nil")
            // ... and the file name falls back to the macOS base name.
            let name = ScreenshotDefaults.filename(date: fixedDate(),
                                                   ext: "png",
                                                   includeDate: false,
                                                   baseName: ScreenshotDefaults.sanitized(sourceAppName: "   ") ?? "Screenshot")
            try checkEqual(name, "Screenshot.png", "empty name falls back")
        }),

        // MARK: area capture picks the window under the selection

        ("area capture credits the window covering most of the selection", {
            let windows = [
                makeWindow("Safari", CGRect(x: 0, y: 0, width: 100, height: 100), id: 1),
                makeWindow("IINA", CGRect(x: 50, y: 0, width: 400, height: 400), id: 2),
            ]
            // 90% of the selection sits on IINA, even though Safari is front-most.
            let picked = WindowEnumerator.sourceWindow(for: CGRect(x: 90, y: 10, width: 100, height: 50), in: windows)
            try checkEqual(picked?.ownerName, "IINA", "largest intersection wins")
        }),

        ("a selection fully inside the front-most window credits it", {
            let windows = [
                makeWindow("IINA", CGRect(x: 0, y: 0, width: 400, height: 400), id: 1),
                makeWindow("Finder", CGRect(x: 0, y: 0, width: 800, height: 800), id: 2),
            ]
            let picked = WindowEnumerator.sourceWindow(for: CGRect(x: 10, y: 10, width: 50, height: 50), in: windows)
            try checkEqual(picked?.ownerName, "IINA", "front-most on a tie")
        }),

        ("a selection over nothing credits no app", {
            let windows = [makeWindow("IINA", CGRect(x: 0, y: 0, width: 100, height: 100))]
            try check(WindowEnumerator.sourceWindow(for: CGRect(x: 400, y: 400, width: 50, height: 50), in: windows) == nil,
                      "no overlap means no source")
            try check(WindowEnumerator.sourceWindow(for: .zero, in: windows) == nil, "an empty rect means no source")
            try check(WindowEnumerator.sourceWindow(for: CGRect(x: 0, y: 0, width: 10, height: 10), in: []) == nil,
                      "no windows means no source")
        }),

        // MARK: Where from

        ("a written file carries the source app as Where from metadata", {
            guard let image = makeImage(width: 8, height: 8) else {
                throw CheckFailure(message: "could not build the test bitmap")
            }
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ShotTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let url = dir.appendingPathComponent("where-from.png")
            try ImageExporter.write(image, pixelScale: 2, to: url, sourceAppName: "IINA")

            let size = getxattr(url.path, ImageExporter.whereFromsAttribute, nil, 0, 0, 0)
            try check(size > 0, "the Where from attribute was not written")
            var bytes = [UInt8](repeating: 0, count: size)
            let read = getxattr(url.path, ImageExporter.whereFromsAttribute, &bytes, size, 0, 0)
            try checkEqual(read, size, "Where from byte count")
            let names = try PropertyListSerialization.propertyList(from: Data(bytes), options: [], format: nil) as? [String]
            try checkEqual(names ?? [], ["IINA"], "Where from value")
        }),

        ("a file written without a source app carries no Where from", {
            guard let image = makeImage(width: 8, height: 8) else {
                throw CheckFailure(message: "could not build the test bitmap")
            }
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ShotTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let url = dir.appendingPathComponent("plain.png")
            try ImageExporter.write(image, pixelScale: 1, to: url)
            try check(getxattr(url.path, ImageExporter.whereFromsAttribute, nil, 0, 0, 0) < 0,
                      "no source app must leave the file's metadata alone")
        }),

        // MARK: the document carries the credit

        ("the document keeps the source app the capture was made from", {
            guard let image = makeImage(width: 4, height: 4) else {
                throw CheckFailure(message: "could not build the test bitmap")
            }
            let result = CaptureResult(image: image, pixelScale: 2, source: .window, screenRect: nil,
                                       sourceAppName: "IINA", sourceBundleID: "com.colliderli.iina")
            let doc = AnnotationDocument(image: result.image,
                                         pixelScale: result.pixelScale,
                                         outputFormat: .png,
                                         sourceAppName: result.sourceAppName,
                                         sourceBundleID: result.sourceBundleID)
            try checkEqual(doc.sourceAppName, "IINA", "document source app")
            try checkEqual(doc.sourceBundleID, "com.colliderli.iina", "document bundle id")
        }),
    ])
}
