import AppKit
import Foundation
import BenchTestKit
@testable import Klip

// Covers `Views/History/ImageDimensions.swift` — the pixel-size readout behind
// the preview pane's `Dimensions` row (3.1.0).
//
// The whole point of this type is that it reports *pixels*, not points. The
// first test is the one that matters: an `NSImage` built from a 2x bitmap rep
// reports half its real size through `NSImage.size`, and the naive
// implementation would quietly under-report every Retina screenshot by half in
// each axis. That bug is invisible unless something asserts on it.

enum ImageDimensionsTests {
    static let tests: [(String, () throws -> Void)] = [
        ("image_reportsPixelsNotPoints_forA2xBitmapRep", testRetinaRepReportsPixels),
        ("image_picksTheLargestRep_whenSeveralArePresent", testLargestRepWins),
        ("image_returnsNilForAZeroSizedImage", testEmptyImage),
        ("file_readsDimensionsFromAPNGHeader", testPNGHeaderRead),
        ("file_returnsNilForANonImageFile", testNonImageFile),
        ("file_returnsNilForAMissingFile", testMissingFile),
        ("displayString_usesTheMultiplicationSignAndPxSuffix", testDisplayString),
    ]

    // MARK: - Helpers

    /// A bitmap rep of `pixels` real samples, tagged as `points` logical size —
    /// which is exactly how AppKit represents a Retina capture.
    private static func rep(pixels: (Int, Int), points: (Int, Int)) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels.0,
            pixelsHigh: pixels.1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = NSSize(width: points.0, height: points.1)
        return rep
    }

    // MARK: - NSImage path

    private static func testRetinaRepReportsPixels() throws {
        let image = NSImage(size: NSSize(width: 1500, height: 1000))
        image.addRepresentation(rep(pixels: (3000, 2000), points: (1500, 1000)))

        // Guard the premise: if this ever stops being true the test below is
        // no longer proving anything.
        try expectEqual(Int(image.size.width), 1500, "NSImage.size is in points, as assumed")

        let dims = PixelDimensions(image: image)
        try expectNotNil(dims)
        try expectEqual(dims?.width, 3000, "reports real pixels, not the 1500pt logical width")
        try expectEqual(dims?.height, 2000)
    }

    private static func testLargestRepWins() throws {
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.addRepresentation(rep(pixels: (32, 32), points: (32, 32)))
        image.addRepresentation(rep(pixels: (512, 512), points: (512, 512)))
        image.addRepresentation(rep(pixels: (128, 128), points: (128, 128)))

        let dims = PixelDimensions(image: image)
        try expectEqual(dims?.width, 512, "the full-resolution rep is the one the user copied")
        try expectEqual(dims?.height, 512)
    }

    private static func testEmptyImage() throws {
        // No reps and a zero size: nothing truthful to report, so no row.
        try expectNil(PixelDimensions(image: NSImage(size: .zero)))
    }

    // MARK: - File path

    private static func testPNGHeaderRead() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("probe.png")
            let source = rep(pixels: (640, 480), points: (640, 480))
            guard let data = source.representation(using: .png, properties: [:]) else {
                throw TestFailure(message: "could not encode a PNG fixture", file: #file, line: #line)
            }
            try data.write(to: url)

            let dims = PixelDimensions.read(contentsOf: url)
            try expectNotNil(dims, "PNG header should be readable")
            try expectEqual(dims?.width, 640)
            try expectEqual(dims?.height, 480)
        }
    }

    /// Non-images get no `Dimensions` row at all — this nil is what suppresses
    /// it for PDFs, archives and plain files.
    private static func testNonImageFile() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("notes.txt")
            try "not an image".write(to: url, atomically: true, encoding: .utf8)
            try expectNil(PixelDimensions.read(contentsOf: url))
        }
    }

    private static func testMissingFile() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("gone.png")
            try expectNil(PixelDimensions.read(contentsOf: url), "a missing file must not crash")
        }
    }

    // MARK: - Formatting

    private static func testDisplayString() throws {
        let image = NSImage(size: NSSize(width: 300, height: 400))
        image.addRepresentation(rep(pixels: (300, 400), points: (300, 400)))
        let dims = PixelDimensions(image: image)
        try expectEqual(dims?.displayString, "300 × 400 px")
        // Check the separator specifically — a naive `contains("x")` would
        // match the "x" in the "px" suffix and always pass.
        try expect(
            dims?.displayString.contains("\u{00D7}") == true,
            "separator must be U+00D7 MULTIPLICATION SIGN"
        )
        try expect(
            dims?.displayString.contains(" x ") != true,
            "separator must not be the letter x"
        )
    }
}
