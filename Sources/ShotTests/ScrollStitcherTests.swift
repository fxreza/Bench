import CoreGraphics
import Foundation
@testable import Shot

// MARK: - Local check helpers (no dependency on Tests/TestRunner.swift)

private nonisolated struct StitchCheckFailure: Error, CustomStringConvertible {
    let description: String
}

private nonisolated func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
    if !condition { throw StitchCheckFailure(description: message()) }
}

private nonisolated func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) throws {
    if actual != expected {
        throw StitchCheckFailure(description: "\(label): expected \(expected), got \(actual)")
    }
}

// MARK: - Synthetic bitmaps

/// Straight RGBA8 (premultiplied, sRGB, alpha 255) bitmap, the exact layout ScrollStitcher uses.
private nonisolated struct RawBitmap {
    var width: Int
    var height: Int
    var bytes: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.bytes = [UInt8](repeating: 255, count: width * height * 4)
    }

    var bytesPerRow: Int { width * 4 }

    func rows(_ offset: Int, _ count: Int) -> RawBitmap {
        var out = RawBitmap(width: width, height: count)
        let start = offset * bytesPerRow
        out.bytes.replaceSubrange(0..<(count * bytesPerRow),
                                  with: bytes[start..<(start + count * bytesPerRow)])
        return out
    }

    /// Vertically concatenates bitmaps of equal width.
    static func stacked(_ parts: [RawBitmap]) -> RawBitmap {
        let w = parts[0].width
        var out = RawBitmap(width: w, height: parts.reduce(0) { $0 + $1.height })
        var cursor = 0
        for p in parts {
            out.bytes.replaceSubrange(cursor..<(cursor + p.bytes.count), with: p.bytes)
            cursor += p.bytes.count
        }
        return out
    }

    func cgImage() -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width,
                       height: height,
                       bitsPerComponent: 8,
                       bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow,
                       space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)!
    }
}

private nonisolated func mix(_ x: UInt64) -> UInt64 {
    var z = x &+ 0x9E37_79B9_7F4A_7C15
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
}

/// A deterministic, non-repeating "document": 20x10 pseudo-random colored blocks plus a vertical
/// gradient, with the row index encoded into pixel 0 so no two rows can ever be byte-equal.
private nonisolated func makeDocument(width: Int, height: Int, seed: UInt64 = 0x5EED) -> RawBitmap {
    var bmp = RawBitmap(width: width, height: height)
    bmp.bytes.withUnsafeMutableBufferPointer { buf in
        for y in 0..<height {
            let by = UInt64(y / 10)
            let grad = UInt8(truncatingIfNeeded: y / 12)
            for x in 0..<width {
                let bx = UInt64(x / 20)
                let h = mix(bx &* 0x9E37_79B9 ^ (by &<< 21) ^ seed)
                let i = (y * width + x) * 4
                if x == 0 {
                    buf[i] = UInt8(truncatingIfNeeded: y)
                    buf[i + 1] = UInt8(truncatingIfNeeded: y >> 8)
                    buf[i + 2] = UInt8(truncatingIfNeeded: y >> 16)
                } else {
                    buf[i] = UInt8(truncatingIfNeeded: h)
                    buf[i + 1] = UInt8(truncatingIfNeeded: h >> 8) &+ grad
                    buf[i + 2] = UInt8(truncatingIfNeeded: h >> 16)
                }
                buf[i + 3] = 255
            }
        }
    }
    return bmp
}

/// Flat colour bitmap, optionally with one small block whose colour is toggled per frame.
private nonisolated func makeBlank(width: Int, height: Int, level: UInt8, blink: Bool = false) -> RawBitmap {
    var bmp = RawBitmap(width: width, height: height)
    bmp.bytes.withUnsafeMutableBufferPointer { buf in
        for i in stride(from: 0, to: width * height * 4, by: 4) {
            buf[i] = level; buf[i + 1] = level; buf[i + 2] = level; buf[i + 3] = 255
        }
        if blink {
            for y in 10..<20 {
                for x in 200..<210 {
                    let i = (y * width + x) * 4
                    buf[i] = 0; buf[i + 1] = 0; buf[i + 2] = 0
                }
            }
        }
    }
    return bmp
}

/// Renders any CGImage back into the canonical RGBA8 layout so results can be memcmp'd.
private nonisolated func rawBytes(of image: CGImage) -> [UInt8] {
    let w = image.width, h = image.height
    var out = [UInt8](repeating: 0, count: w * h * 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    out.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress,
                            width: w,
                            height: h,
                            bitsPerComponent: 8,
                            bytesPerRow: w * 4,
                            space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setBlendMode(.copy)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return out
}

/// First differing row between two RGBA8 buffers of the same width, or nil.
private nonisolated func firstDifferingRow(_ a: [UInt8], _ b: [UInt8], width: Int) -> Int? {
    let bpr = width * 4
    let rows = min(a.count, b.count) / bpr
    for y in 0..<rows {
        if !a[(y * bpr)..<((y + 1) * bpr)].elementsEqual(b[(y * bpr)..<((y + 1) * bpr)]) { return y }
    }
    return nil
}

private nonisolated func compareImage(_ img: CGImage, _ expected: RawBitmap, _ label: String) throws {
    try checkEqual(img.width, expected.width, "\(label) width")
    try checkEqual(img.height, expected.height, "\(label) height")
    let got = rawBytes(of: img)
    if let row = firstDifferingRow(got, expected.bytes, width: expected.width) {
        throw StitchCheckFailure(description: "\(label): pixels differ starting at row \(row)")
    }
}

/// Compares both the live preview and the finished image against `expected`, and asserts the two
/// agree with each other.
private nonisolated func compareCanvas(_ stitcher: ScrollStitcher, _ expected: RawBitmap, _ label: String) throws {
    try compareImage(stitcher.image, expected, "\(label) [image]")
    try compareImage(stitcher.finish(), expected, "\(label) [finish]")
    if rawBytes(of: stitcher.image) != rawBytes(of: stitcher.finish()) {
        throw StitchCheckFailure(description: "\(label): image and finish() disagree")
    }
}

// MARK: - Suite

nonisolated enum ScrollStitcherTests {

    nonisolated(unsafe) static let suite: (String, [(String, () throws -> Void)]) = (
        "ScrollStitcher",
        [
            ("scrolls down and stitches the document exactly", testScrollDown),
            ("back-scrolling re-covers without duplicating rows", testScrollDownUpDown),
            ("scrolling up grows the canvas upward", testScrollUp),
            ("sticky header is kept once at the top", testStickyHeader),
            ("sticky footer is kept once at the very bottom", testStickyFooter),
            ("sticky header survives scrolling above the start", testStickyHeaderScrollUp),
            ("finish() equals image when nothing is sticky", testFinishWithoutSticky),
            ("identical frame is reported as identical", testIdenticalFrame),
            ("unrelated frame is unaligned", testUnalignedFrame),
            ("mismatched frame size is unaligned", testSizeMismatch),
            ("blank region never overgrows the canvas", testBlankRegion),
            ("maxHeight guard reports limitReached", testMaxHeight),
            ("irregular manual scroll steps register exactly", testIrregularSteps),
            ("an over-large jump is rejected instead of leaving a gap", testOverLargeJump),
            ("25 frames stitch in well under a second", testPerformance),
        ]
    )

    // MARK: (a) plain scroll down

    private nonisolated static func testScrollDown() throws {
        let doc = makeDocument(width: 400, height: 3000)
        let view = 500, step = 120
        var offsets: [Int] = []
        var o = 0
        while o + view <= doc.height { offsets.append(o); o += step }
        if offsets.last! + view < doc.height { offsets.append(doc.height - view) }

        let stitcher = ScrollStitcher(firstFrame: doc.rows(offsets[0], view).cgImage())
        for k in 1..<offsets.count {
            let r = stitcher.append(doc.rows(offsets[k], view).cgImage())
            let expectedDY = offsets[k] - offsets[k - 1]
            guard case .aligned(let dy, let newRows) = r else {
                throw StitchCheckFailure(description: "frame \(k) at \(offsets[k]): expected .aligned, got \(r)")
            }
            try checkEqual(dy, expectedDY, "frame \(k) dy")
            try checkEqual(newRows, expectedDY, "frame \(k) newRows")
        }
        try checkEqual(stitcher.coveredHeight, doc.height, "coveredHeight")
        try checkEqual(stitcher.frameCount, offsets.count, "frameCount")
        try checkEqual(stitcher.stickyTop, 0, "stickyTop")
        try checkEqual(stitcher.stickyBottom, 0, "stickyBottom")
        try compareCanvas(stitcher, doc, "scroll down")
    }

    // MARK: (b) down, up, down again

    private nonisolated static func testScrollDownUpDown() throws {
        let doc = makeDocument(width: 400, height: 3000, seed: 0xA11CE)
        let view = 500

        var offsets: [Int] = []
        var o = 0
        while o <= 1200 { offsets.append(o); o += 120 }        // down to 1200
        o = 1100
        while o >= 900 { offsets.append(o); o -= 100 }         // back up 300px
        o = 1020
        while o + view <= doc.height { offsets.append(o); o += 120 }  // down again to the end

        let stitcher = ScrollStitcher(firstFrame: doc.rows(offsets[0], view).cgImage())
        var lo = offsets[0], hi = offsets[0] + view
        var reCoveredFrames = 0

        for k in 1..<offsets.count {
            let r = stitcher.append(doc.rows(offsets[k], view).cgImage())
            guard case .aligned(let dy, let newRows) = r else {
                throw StitchCheckFailure(description: "frame \(k) at \(offsets[k]): expected .aligned, got \(r)")
            }
            try checkEqual(dy, offsets[k] - offsets[k - 1], "frame \(k) dy")

            let top = offsets[k], bottom = offsets[k] + view
            let expectedNew = max(0, lo - top) + max(0, bottom - hi)
            try checkEqual(newRows, expectedNew, "frame \(k) newRows")
            if expectedNew == 0 { reCoveredFrames += 1 }
            lo = min(lo, top); hi = max(hi, bottom)
        }

        try check(reCoveredFrames >= 4, "expected several fully re-covered frames, got \(reCoveredFrames)")
        try checkEqual(stitcher.coveredHeight, hi - lo, "coveredHeight")
        try compareCanvas(stitcher, doc.rows(lo, hi - lo), "down-up-down")
    }

    // MARK: (c) start in the middle, scroll up

    private nonisolated static func testScrollUp() throws {
        let doc = makeDocument(width: 400, height: 3000, seed: 0xB0B)
        let view = 500, step = 120
        var offsets: [Int] = []
        var o = 1500
        while o > 0 { offsets.append(o); o -= step }
        offsets.append(0)

        let stitcher = ScrollStitcher(firstFrame: doc.rows(offsets[0], view).cgImage())
        for k in 1..<offsets.count {
            let r = stitcher.append(doc.rows(offsets[k], view).cgImage())
            guard case .aligned(let dy, let newRows) = r else {
                throw StitchCheckFailure(description: "frame \(k) at \(offsets[k]): expected .aligned, got \(r)")
            }
            try checkEqual(dy, offsets[k] - offsets[k - 1], "frame \(k) dy")
            try checkEqual(newRows, offsets[k - 1] - offsets[k], "frame \(k) newRows")
        }
        try checkEqual(stitcher.coveredHeight, 1500 + view, "coveredHeight")
        try compareCanvas(stitcher, doc.rows(0, 1500 + view), "scroll up")
    }

    // MARK: (d) sticky header

    private nonisolated static func testStickyHeader() throws {
        let width = 400, view = 500, headerRows = 60, step = 120
        let contentRows = view - headerRows
        let doc = makeDocument(width: width, height: 3000, seed: 0xC0FFEE)
        let header = makeDocument(width: width, height: headerRows, seed: 0x4EAD)

        func frame(_ offset: Int) -> CGImage {
            RawBitmap.stacked([header, doc.rows(offset, contentRows)]).cgImage()
        }

        var offsets: [Int] = []
        var o = 0
        while o + contentRows <= doc.height { offsets.append(o); o += step }
        if offsets.last! + contentRows < doc.height { offsets.append(doc.height - contentRows) }

        let stitcher = ScrollStitcher(firstFrame: frame(offsets[0]))
        for k in 1..<offsets.count {
            let r = stitcher.append(frame(offsets[k]))
            guard case .aligned(let dy, _) = r else {
                throw StitchCheckFailure(description: "frame \(k) at \(offsets[k]): expected .aligned, got \(r)")
            }
            try checkEqual(dy, offsets[k] - offsets[k - 1], "frame \(k) dy")
        }
        try checkEqual(stitcher.stickyTop, headerRows, "stickyTop")
        try checkEqual(stitcher.stickyBottom, 0, "stickyBottom")
        // The header rows the first frame wrote were retracted, so the covered range is pure
        // content and the header is re-attached once by finish().
        try checkEqual(stitcher.coveredHeight, doc.height, "coveredHeight")
        try compareCanvas(stitcher, RawBitmap.stacked([header, doc]), "sticky header")
    }

    // MARK: sticky footer

    private nonisolated static func testStickyFooter() throws {
        let width = 400, view = 500, footerRows = 40, step = 120
        let contentRows = view - footerRows
        let doc = makeDocument(width: width, height: 3000, seed: 0xF007E4)
        let footer = makeDocument(width: width, height: footerRows, seed: 0xBA5E)

        func frame(_ offset: Int) -> CGImage {
            RawBitmap.stacked([doc.rows(offset, contentRows), footer]).cgImage()
        }

        var offsets: [Int] = []
        var o = 0
        while o + contentRows <= doc.height { offsets.append(o); o += step }
        if offsets.last! + contentRows < doc.height { offsets.append(doc.height - contentRows) }

        let stitcher = ScrollStitcher(firstFrame: frame(offsets[0]))
        for k in 1..<offsets.count {
            let r = stitcher.append(frame(offsets[k]))
            guard case .aligned(let dy, _) = r else {
                throw StitchCheckFailure(description: "frame \(k) at \(offsets[k]): expected .aligned, got \(r)")
            }
            try checkEqual(dy, offsets[k] - offsets[k - 1], "frame \(k) dy")
        }
        try checkEqual(stitcher.stickyTop, 0, "stickyTop")
        try checkEqual(stitcher.stickyBottom, footerRows, "stickyBottom")
        // Covered rows are exactly the document, with no footer strip buried inside it: every
        // document row is present exactly once, and the footer sits once at the very bottom.
        try checkEqual(stitcher.coveredHeight, doc.height, "coveredHeight")
        try compareImage(stitcher.image, RawBitmap.stacked([doc, footer]), "sticky footer [image]")
        try compareImage(stitcher.finish(), RawBitmap.stacked([doc, footer]), "sticky footer [finish]")
    }

    // MARK: sticky header while scrolling up past the start

    private nonisolated static func testStickyHeaderScrollUp() throws {
        let width = 400, view = 500, headerRows = 60, step = 120
        let contentRows = view - headerRows
        let doc = makeDocument(width: width, height: 3000, seed: 0x5C40)
        let header = makeDocument(width: width, height: headerRows, seed: 0x1EAD)

        func frame(_ offset: Int) -> CGImage {
            RawBitmap.stacked([header, doc.rows(offset, contentRows)]).cgImage()
        }

        // Start in the middle and scroll up past the first frame, so the canvas grows upward while
        // a sticky header is being learned.
        var offsets: [Int] = []
        var o = 1000
        while o > 0 { offsets.append(o); o -= step }
        offsets.append(0)

        let stitcher = ScrollStitcher(firstFrame: frame(offsets[0]))
        for k in 1..<offsets.count {
            let r = stitcher.append(frame(offsets[k]))
            guard case .aligned(let dy, _) = r else {
                throw StitchCheckFailure(description: "frame \(k) at \(offsets[k]): expected .aligned, got \(r)")
            }
            try checkEqual(dy, offsets[k] - offsets[k - 1], "frame \(k) dy")
        }
        try checkEqual(stitcher.stickyTop, headerRows, "stickyTop")
        try checkEqual(stitcher.stickyBottom, 0, "stickyBottom")

        let contentHeight = 1000 + contentRows
        try checkEqual(stitcher.coveredHeight, contentHeight, "coveredHeight")
        // Header exactly once at the very top, then doc rows 0..<contentHeight with no duplicates.
        try compareCanvas(stitcher, RawBitmap.stacked([header, doc.rows(0, contentHeight)]),
                          "sticky header scrolled up")
    }

    // MARK: finish() with no sticky bands

    private nonisolated static func testFinishWithoutSticky() throws {
        let doc = makeDocument(width: 400, height: 2000, seed: 0x0F1)
        let stitcher = ScrollStitcher(firstFrame: doc.rows(0, 500).cgImage())
        for o in stride(from: 120, through: 960, by: 120) {
            _ = stitcher.append(doc.rows(o, 500).cgImage())
        }
        try checkEqual(stitcher.stickyTop, 0, "stickyTop")
        try checkEqual(stitcher.stickyBottom, 0, "stickyBottom")
        let live = stitcher.finish()
        try checkEqual(live.height, stitcher.coveredHeight, "finish() height == coveredHeight")
        try compareCanvas(stitcher, doc.rows(0, 960 + 500), "no sticky")
    }

    // MARK: (e) identical frame

    private nonisolated static func testIdenticalFrame() throws {
        let doc = makeDocument(width: 400, height: 1200, seed: 0xD1D1)
        let f0 = doc.rows(0, 500).cgImage()
        let stitcher = ScrollStitcher(firstFrame: f0)
        try checkEqual(stitcher.append(doc.rows(0, 500).cgImage()), StitchResult.identical, "repeat frame")
        try checkEqual(stitcher.coveredHeight, 500, "coveredHeight unchanged")
        try checkEqual(stitcher.frameCount, 1, "frameCount unchanged")
        // Scrolling still works after an identical frame.
        guard case .aligned(let dy, let newRows) = stitcher.append(doc.rows(120, 500).cgImage()) else {
            throw StitchCheckFailure(description: "expected .aligned after an identical frame")
        }
        try checkEqual(dy, 120, "dy")
        try checkEqual(newRows, 120, "newRows")
    }

    // MARK: (f) unrelated frame

    private nonisolated static func testUnalignedFrame() throws {
        let doc = makeDocument(width: 400, height: 1200, seed: 0xE1E1)
        let other = makeDocument(width: 400, height: 1200, seed: 0x7777)
        let stitcher = ScrollStitcher(firstFrame: doc.rows(0, 500).cgImage())
        try checkEqual(stitcher.append(other.rows(600, 500).cgImage()), StitchResult.unaligned, "foreign frame")
        try checkEqual(stitcher.coveredHeight, 500, "coveredHeight unchanged")
        // The previous frame is kept, so a real continuation still registers.
        guard case .aligned(let dy, _) = stitcher.append(doc.rows(120, 500).cgImage()) else {
            throw StitchCheckFailure(description: "expected .aligned after a dropped frame")
        }
        try checkEqual(dy, 120, "dy after drop")
    }

    // MARK: size mismatch

    private nonisolated static func testSizeMismatch() throws {
        let doc = makeDocument(width: 400, height: 1200, seed: 0xF00D)
        let stitcher = ScrollStitcher(firstFrame: doc.rows(0, 500).cgImage())
        let narrow = makeDocument(width: 380, height: 500, seed: 0xF00D)
        try checkEqual(stitcher.append(narrow.cgImage()), StitchResult.unaligned, "narrow frame")
        try checkEqual(stitcher.append(doc.rows(0, 480).cgImage()), StitchResult.unaligned, "short frame")
    }

    // MARK: (g) blank region

    private nonisolated static func testBlankRegion() throws {
        let width = 400, view = 500, step = 120, frames = 12
        let stitcher = ScrollStitcher(firstFrame: makeBlank(width: width, height: view, level: 250).cgImage())
        for k in 1...frames {
            // Frames are flat except for one small block that blinks, so consecutive frames are not
            // byte-identical yet carry no usable vertical signal.
            let f = makeBlank(width: width, height: view, level: 250, blink: k % 2 == 1)
            let r = stitcher.append(f.cgImage())
            switch r {
            case .identical, .unaligned:
                break
            case .aligned(let dy, _):
                try check(abs(dy) <= step, "blank region produced an implausible dy \(dy)")
            case .limitReached:
                throw StitchCheckFailure(description: "unexpected .limitReached on a blank region")
            }
            try check(stitcher.coveredHeight <= view + step * frames,
                      "blank canvas overgrew: \(stitcher.coveredHeight)")
        }
        try check(stitcher.coveredHeight >= view, "canvas shrank")
        _ = stitcher.image  // must not crash
    }

    // MARK: maxHeight

    private nonisolated static func testMaxHeight() throws {
        let doc = makeDocument(width: 400, height: 2000, seed: 0x1234)
        let stitcher = ScrollStitcher(firstFrame: doc.rows(0, 500).cgImage(), maxHeight: 700)
        guard case .aligned = stitcher.append(doc.rows(120, 500).cgImage()) else {
            throw StitchCheckFailure(description: "first scroll should fit under maxHeight")
        }
        try checkEqual(stitcher.coveredHeight, 620, "coveredHeight after one step")
        try checkEqual(stitcher.append(doc.rows(240, 500).cgImage()), StitchResult.limitReached, "second step")
        try checkEqual(stitcher.coveredHeight, 620, "coveredHeight unchanged after limit")
    }

    // MARK: irregular hand scrolling

    private nonisolated static func testIrregularSteps() throws {
        let doc = makeDocument(width: 400, height: 3000, seed: 0x51DE)
        let view = 500
        let maxOffset = doc.height - view

        var offsets = [0]
        var rng: UInt64 = 0x2024
        var cur = 0
        for _ in 0..<60 {
            rng = mix(rng)
            // Mostly downward, sometimes back up, steps of 1...90 px.
            let magnitude = Int(rng % 90) + 1
            let step = (rng >> 32) % 4 == 0 ? -magnitude : magnitude
            cur = min(maxOffset, max(0, cur + step))
            if cur != offsets.last! { offsets.append(cur) }
        }

        let stitcher = ScrollStitcher(firstFrame: doc.rows(offsets[0], view).cgImage())
        var lo = offsets[0], hi = offsets[0] + view
        for k in 1..<offsets.count {
            let r = stitcher.append(doc.rows(offsets[k], view).cgImage())
            guard case .aligned(let dy, let newRows) = r else {
                throw StitchCheckFailure(description: "frame \(k) at \(offsets[k]): expected .aligned, got \(r)")
            }
            try checkEqual(dy, offsets[k] - offsets[k - 1], "frame \(k) dy")
            let expectedNew = max(0, lo - offsets[k]) + max(0, offsets[k] + view - hi)
            try checkEqual(newRows, expectedNew, "frame \(k) newRows")
            lo = min(lo, offsets[k]); hi = max(hi, offsets[k] + view)
        }
        try checkEqual(stitcher.coveredHeight, hi - lo, "coveredHeight")
        try compareCanvas(stitcher, doc.rows(lo, hi - lo), "irregular steps")
    }

    private nonisolated static func testOverLargeJump() throws {
        let doc = makeDocument(width: 400, height: 2000, seed: 0x7A9)
        let view = 500
        let stitcher = ScrollStitcher(firstFrame: doc.rows(0, view).cgImage())
        // Beyond band - minOverlap: there is no usable overlap, so the frame must be dropped
        // rather than placed and leaving uncovered rows in the middle of the canvas.
        try checkEqual(stitcher.append(doc.rows(480, view).cgImage()), StitchResult.unaligned, "big jump")
        try checkEqual(stitcher.coveredHeight, view, "coveredHeight unchanged")
        guard case .aligned(let dy, let newRows) = stitcher.append(doc.rows(200, view).cgImage()) else {
            throw StitchCheckFailure(description: "expected .aligned after a dropped jump")
        }
        try checkEqual(dy, 200, "dy")
        try checkEqual(newRows, 200, "newRows")
        try checkEqual(stitcher.coveredHeight, 700, "coveredHeight")
    }

    // MARK: performance

    private nonisolated static func testPerformance() throws {
        let view = 500, step = 120, frames = 25
        let doc = makeDocument(width: 400, height: view + step * frames + 10, seed: 0x9999)
        var images: [CGImage] = []
        for k in 0..<frames { images.append(doc.rows(k * step, view).cgImage()) }

        let t0 = DispatchTime.now().uptimeNanoseconds
        let stitcher = ScrollStitcher(firstFrame: images[0])
        for k in 1..<frames {
            _ = stitcher.append(images[k])
            _ = stitcher.image  // live preview cost is part of the budget
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000.0
        print(String(format: "    [perf] %d frames of 400x500 stitched in %.1f ms (%.2f ms/frame)",
                     frames, elapsed, elapsed / Double(frames)))
        try checkEqual(stitcher.coveredHeight, view + step * (frames - 1), "coveredHeight")
        try check(elapsed < 1000, "25 frames took \(elapsed) ms, expected well under 1000 ms")
    }
}
