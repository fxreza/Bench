import CoreGraphics
import Foundation
import Vision

/// Outcome of feeding one frame to `ScrollStitcher`.
nonisolated enum StitchResult: Sendable, Equatable {
    /// Frame is byte-identical to the previous one; nothing to do.
    case identical
    /// Frame registered against the previous one.
    /// - dy: vertical scroll offset in px between previous and this frame
    ///       (positive = content moved up = user scrolled down).
    /// - newRows: rows actually added to the canvas (0 when re-covering known rows).
    case aligned(dy: Int, newRows: Int)
    /// Could not register the frame; it is dropped and the previous frame is kept.
    case unaligned
    /// Writing this frame would push the canvas past `maxHeight`; nothing was written.
    case limitReached
}

/// Pure, testable stitcher for manual scrolling capture.
///
/// The user scrolls a fixed region by hand (down, up, or back and forth) while frames of that
/// region are captured a few times per second. Every frame is registered against the previous one
/// with row signatures, mapped onto an absolute canvas row range, and only the rows that fall
/// *outside* the already covered range are written. Re-scrolling therefore never duplicates rows,
/// and scrolling above the first frame simply grows the canvas upward.
///
/// Pixel format is always RGBA8 premultiplied, sRGB, 4 bytes per pixel; the backing canvas is a
/// single growable byte buffer (doubling, with head-room prepended when it has to grow upward).
///
/// Thread safety: all public members take an internal lock, so the type is safe to hand between
/// the capture queue and the UI, hence `@unchecked Sendable`.
nonisolated final class ScrollStitcher: @unchecked Sendable {

    // MARK: - Tuning constants

    /// Rows sampled for the fast "is this the same frame" check.
    private static let identicalSampleRows = 16
    /// Number of non-identical frames used to learn sticky header/footer sizes.
    private static let stickyLearnFrames = 4
    /// Sticky bands may never eat more than this fraction of the frame (percent).
    private static let stickyMaxPercent = 35
    /// Minimum fraction of overlapping rows that must hash-match for a candidate offset (percent).
    private static let matchPercent = 90
    /// Mean absolute per-byte difference tolerated by the sampled pixel verification.
    private static let sadTolerance = 16
    /// Mean abs difference per byte tolerated for anti-aliasing jitter.
    private static let jitterTolerance = 14

    // MARK: - Immutable geometry

    /// Frame width in px. Frames of any other size are rejected.
    let width: Int
    /// Frame height in px. Frames of any other size are rejected.
    let height: Int
    /// Hard cap on the stitched canvas height in px.
    let maxHeight: Int

    private let bytesPerRow: Int
    private let colorSpace: CGColorSpace
    private let bitmapInfo: UInt32

    // MARK: - State (guarded by `lock`)

    private let lock = NSLock()

    /// The very first frame, kept whole so the sticky header band can always be sourced from it
    /// even when `stickyTop` grows after later frames have already been written.
    private let firstFrameBuf: UnsafeMutablePointer<UInt8>
    /// Previous accepted frame, RGBA8. Doubles as "the last appended frame" for the sticky footer.
    private var prevFrame: UnsafeMutablePointer<UInt8>
    /// Scratch buffer the incoming frame is decoded into.
    private var curFrame: UnsafeMutablePointer<UInt8>
    /// Per-row 64-bit signatures of `prevFrame` / `curFrame`, indexed by frame row.
    private var prevHashes: [UInt64]
    private var curHashes: [UInt64]

    /// Growable canvas buffer.
    private var canvas: UnsafeMutablePointer<UInt8>
    /// Rows the canvas buffer can hold.
    private var capacity: Int
    /// Absolute canvas row stored at buffer row 0.
    private var originRow: Int

    /// Absolute canvas row of row 0 of the previous frame.
    private var frameTopRow: Int
    private var coveredMin: Int
    private var coveredMax: Int

    private var _frameCount: Int
    private var _stickyTop: Int
    private var _stickyBottom: Int
    private var stickyBudget: Int

    // MARK: - Init

    /// - Parameters:
    ///   - firstFrame: the first captured frame; its full height (sticky rows included) seeds the canvas.
    ///   - maxHeight: canvas height at which `append` starts returning `.limitReached`.
    init(firstFrame: CGImage, maxHeight: Int = 60_000) {
        self.width = max(1, firstFrame.width)
        self.height = max(1, firstFrame.height)
        self.maxHeight = max(self.height, maxHeight)
        self.bytesPerRow = self.width * 4
        self.colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        self.bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        let frameBytes = self.bytesPerRow * self.height
        firstFrameBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: frameBytes)
        firstFrameBuf.initialize(repeating: 0, count: frameBytes)
        prevFrame = UnsafeMutablePointer<UInt8>.allocate(capacity: frameBytes)
        prevFrame.initialize(repeating: 0, count: frameBytes)
        curFrame = UnsafeMutablePointer<UInt8>.allocate(capacity: frameBytes)
        curFrame.initialize(repeating: 0, count: frameBytes)

        capacity = self.height * 2
        let canvasBytes = self.bytesPerRow * capacity
        canvas = UnsafeMutablePointer<UInt8>.allocate(capacity: canvasBytes)
        canvas.initialize(repeating: 0, count: canvasBytes)

        originRow = 0
        frameTopRow = 0
        coveredMin = 0
        coveredMax = self.height
        _frameCount = 1
        _stickyTop = 0
        _stickyBottom = 0
        stickyBudget = Self.stickyLearnFrames
        prevHashes = []
        curHashes = []

        ScrollStitcher.decode(firstFrame, into: prevFrame, width: self.width, height: self.height,
                              bytesPerRow: bytesPerRow, colorSpace: colorSpace, bitmapInfo: bitmapInfo)
        prevHashes = ScrollStitcher.rowHashes(prevFrame, height: self.height, bytesPerRow: bytesPerRow)
        curHashes = prevHashes
        memcpy(firstFrameBuf, prevFrame, frameBytes)
        // The first frame writes its FULL height: sticky bands are not known yet, so every row is
        // provisionally treated as content. Once a sticky band IS detected, `learnSticky` retracts
        // the covered range over it again so later frames overwrite the chrome with real content,
        // and `finish()` re-attaches the band exactly once at the very top/bottom.
        memcpy(canvas, prevFrame, frameBytes)
    }

    deinit {
        firstFrameBuf.deallocate()
        prevFrame.deallocate()
        curFrame.deallocate()
        canvas.deallocate()
    }

    // MARK: - Public state

    /// Number of frames that contributed to the canvas (the first frame plus every `.aligned` one).
    var frameCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _frameCount
    }

    /// Canvas height in px (only rows ever covered).
    var coveredHeight: Int {
        lock.lock(); defer { lock.unlock() }
        return coveredMax - coveredMin
    }

    /// Rows at the top of the region detected as sticky (identical across frames while scrolling).
    var stickyTop: Int {
        lock.lock(); defer { lock.unlock() }
        return _stickyTop
    }

    /// Rows at the bottom of the region detected as sticky.
    var stickyBottom: Int {
        lock.lock(); defer { lock.unlock() }
        return _stickyBottom
    }

    /// Current stitched image: the sticky header from the first frame, the covered rows, and the
    /// sticky footer from the most recently accepted frame.
    ///
    /// Cheap enough to call after every frame for a live preview: it copies the covered slice of the
    /// backing buffer once and wraps it, it never re-renders or reallocates the canvas. Including
    /// the sticky bands costs two extra memcpys of at most 35% of a frame each, so the preview is
    /// WYSIWYG with `finish()`.
    ///
    /// Note `image.height == stickyTop + coveredHeight + stickyBottom`.
    var image: CGImage {
        lock.lock(); defer { lock.unlock() }
        return composedImage()
    }

    /// The finished capture: `[stickyTop rows of the FIRST frame] + covered rows +
    /// [stickyBottom rows of the LAST appended frame]`.
    ///
    /// This is the image the editor should receive when the user presses Done. It does not mutate
    /// the stitcher, so it is safe to call more than once, and it is identical to `image` — the
    /// separate name exists so the capture session has an explicit terminal call.
    func finish() -> CGImage {
        lock.lock(); defer { lock.unlock() }
        return composedImage()
    }

    private func composedImage() -> CGImage {
        let coveredRows = max(0, coveredMax - coveredMin)
        let rows = max(1, _stickyTop + coveredRows + _stickyBottom)
        var data = Data(count: rows * bytesPerRow)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            var cursor = 0
            if _stickyTop > 0 {
                // Header: always from the first frame, so it is the header the user started with.
                memcpy(base, firstFrameBuf, _stickyTop * bytesPerRow)
                cursor += _stickyTop * bytesPerRow
            }
            if coveredRows > 0 {
                memcpy(base + cursor,
                       canvas + (coveredMin - originRow) * bytesPerRow,
                       coveredRows * bytesPerRow)
                cursor += coveredRows * bytesPerRow
            }
            if _stickyBottom > 0 {
                // Footer: from the most recently accepted frame, so it is the footer the user
                // finished on, placed once at the very bottom.
                memcpy(base + cursor,
                       prevFrame + (height - _stickyBottom) * bytesPerRow,
                       _stickyBottom * bytesPerRow)
            }
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let img = CGImage(width: width,
                                height: rows,
                                bitsPerComponent: 8,
                                bitsPerPixel: 32,
                                bytesPerRow: bytesPerRow,
                                space: colorSpace,
                                bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                                provider: provider,
                                decode: nil,
                                shouldInterpolate: false,
                                intent: .defaultIntent)
        else {
            // Cannot fail for a valid RGBA8 buffer; fall back to a 1x1 image rather than trapping.
            let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: colorSpace, bitmapInfo: bitmapInfo)!
            return ctx.makeImage()!
        }
        return img
    }

    // MARK: - Append

    func append(_ frame: CGImage) -> StitchResult {
        lock.lock(); defer { lock.unlock() }

        // 1. Geometry must match the first frame.
        guard frame.width == width, frame.height == height else { return .unaligned }

        ScrollStitcher.decode(frame, into: curFrame, width: width, height: height,
                              bytesPerRow: bytesPerRow, colorSpace: colorSpace, bitmapInfo: bitmapInfo)

        // 2. Fast identical check on evenly spaced sampled rows.
        if sampledRowsEqual() { return .identical }

        // 3. Sticky header/footer learning (before registration: sticky rows would otherwise
        //    poison the row-signature match).
        if stickyBudget > 0 {
            learnSticky()
            stickyBudget -= 1
        }

        let top = _stickyTop
        let bandHeight = height - _stickyTop - _stickyBottom
        guard bandHeight > 0 else { return .unaligned }

        // 4. Offset estimation over row signatures, then sampled-pixel verification.
        curHashes = ScrollStitcher.rowHashes(curFrame, height: height, bytesPerRow: bytesPerRow)
        let dy: Int
        if let exact = estimateOffset(top: top, bandHeight: bandHeight), verifyOffset(dy: exact, top: top, bandHeight: bandHeight) {
            dy = exact
        } else if let v = visionOffset(top: top, bandHeight: bandHeight) {
            dy = v
        } else {
            return .unaligned
        }

        // 5. Absolute placement: only rows outside the covered range are written.
        let newFrameTop = frameTopRow + dy
        let bandTopAbs = newFrameTop + top
        let bandBottomAbs = newFrameTop + height - _stickyBottom

        let newMin = min(coveredMin, bandTopAbs)
        let newMax = max(coveredMax, bandBottomAbs)

        // 7. maxHeight guard, applied to the composed output height (`finish()`), not just the
        //    covered span, since that is the image the caller ends up with.
        if (newMax - newMin) + _stickyTop + _stickyBottom > maxHeight { return .limitReached }

        ensureCapacity(min: newMin, max: newMax)

        var newRows = 0
        // Rows above the covered range (canvas grows upward).
        if bandTopAbs < coveredMin {
            let hi = min(bandBottomAbs, coveredMin)
            newRows += copyRows(fromFrameTop: newFrameTop, absLo: bandTopAbs, absHi: hi)
        }
        // Rows below the covered range.
        if bandBottomAbs > coveredMax {
            let lo = max(bandTopAbs, coveredMax)
            newRows += copyRows(fromFrameTop: newFrameTop, absLo: lo, absHi: bandBottomAbs)
        }

        coveredMin = newMin
        coveredMax = newMax
        frameTopRow = newFrameTop
        _frameCount += 1

        swap(&prevFrame, &curFrame)
        prevHashes = curHashes

        return .aligned(dy: dy, newRows: newRows)
    }

    // MARK: - Steps

    private func sampledRowsEqual() -> Bool {
        let n = min(Self.identicalSampleRows, height)
        var i = 0
        while i < n {
            let y = (height - 1) * i / max(1, n - 1)
            if memcmp(prevFrame + y * bytesPerRow, curFrame + y * bytesPerRow, bytesPerRow) != 0 {
                return false
            }
            i += 1
        }
        // Sampled rows all match: confirm on the whole frame before declaring the frame a no-op.
        return memcmp(prevFrame, curFrame, bytesPerRow * height) == 0
    }

    /// Rows byte-identical between the previous and current frame at the same y, while the middle
    /// differs, are sticky candidates. Grows from the top and from the bottom, keeping the max seen,
    /// each capped at `stickyMaxPercent` of the frame height.
    private func learnSticky() {
        var candTop = 0
        while candTop < height,
              memcmp(prevFrame + candTop * bytesPerRow, curFrame + candTop * bytesPerRow, bytesPerRow) == 0 {
            candTop += 1
        }
        if candTop >= height { return }  // whole frame equal: no information

        var candBottom = 0
        while candBottom < height - candTop {
            let y = height - 1 - candBottom
            if memcmp(prevFrame + y * bytesPerRow, curFrame + y * bytesPerRow, bytesPerRow) != 0 { break }
            candBottom += 1
        }
        // The middle has to actually differ, otherwise the frame barely moved and tells us nothing.
        if (candTop + candBottom) * 100 > height * 70 { return }

        let cap = height * Self.stickyMaxPercent / 100
        let newTop = max(_stickyTop, min(candTop, cap))
        let newBottom = max(_stickyBottom, min(candBottom, cap))

        // Retract the covered range over rows the first frame wrote before the band was known, so
        // later frames rewrite them with real content instead of leaving a strip of chrome buried
        // in the middle of the canvas. Only safe while the covered edge still sits exactly on the
        // first frame's boundary: once the canvas has grown past it, those rows carry real content.
        if newTop > _stickyTop && coveredMin == _stickyTop {
            coveredMin = newTop
        }
        if newBottom > _stickyBottom && coveredMax == height - _stickyBottom {
            coveredMax = height - newBottom
        }
        _stickyTop = newTop
        _stickyBottom = newBottom
    }

    /// Searches dy in `-(band-minOverlap)...(band-minOverlap)` for the shift whose overlapping rows
    /// hash-match best. Candidates need >= `matchPercent` matching rows; the winner maximises
    /// `matches - 3 * mismatches`, which prefers the largest fully-matching overlap (so a uniform
    /// band resolves to the smallest |dy|) while still beating a partially-blank dy = 0.
    /// Ties go to the smaller |dy|.
    private func estimateOffset(top: Int, bandHeight: Int) -> Int? {
        let minOverlap = max(24, bandHeight / 8)
        guard bandHeight > minOverlap else { return nil }
        let maxShift = bandHeight - minOverlap

        var bestScore = Int.min
        var bestDY: Int?

        prevHashes.withUnsafeBufferPointer { pb in
            curHashes.withUnsafeBufferPointer { cb in
                var k = 0
                while k <= maxShift {
                    var s = 0
                    while s < 2 {
                        let dy = s == 0 ? k : -k
                        if s == 1 && k == 0 { s += 1; continue }
                        s += 1

                        let lo = max(0, -dy)
                        let hi = min(bandHeight, bandHeight - dy)
                        let overlap = hi - lo
                        if overlap < minOverlap { continue }

                        var matches = 0
                        var i = lo
                        while i < hi {
                            if cb[top + i] == pb[top + i + dy] { matches += 1 }
                            i += 1
                        }
                        if matches * 100 < overlap * Self.matchPercent { continue }
                        let score = matches - 3 * (overlap - matches)
                        if score > bestScore {
                            bestScore = score
                            bestDY = dy
                        }
                    }
                    k += 1
                }
            }
        }
        return bestDY
    }

    /// Sampled SAD over roughly every 8th row of the overlap, guarding against repeated-content
    /// false positives that survive the hash stage.
    /// Registration for content that is re-rendered with sub-pixel jitter while
    /// scrolling (browsers): Vision's translational alignment plus a tolerant
    /// pixel check. Vision's sign convention is resolved by trying both.
    private func visionOffset(top: Int, bandHeight: Int) -> Int? {
        guard let prev = bandImage(prevFrame, top: top, height: bandHeight),
              let cur = bandImage(curFrame, top: top, height: bandHeight) else { return nil }
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: prev, options: [:])
        let handler = VNImageRequestHandler(cgImage: cur, options: [:])
        guard (try? handler.perform([request])) != nil,
              let obs = request.results?.first else { return nil }
        let ty = Int(obs.alignmentTransform.ty.rounded())
        let minOverlap = max(24, bandHeight / 8)
        guard abs(ty) <= bandHeight - minOverlap else { return nil }
        if ty == 0 { return verifyOffset(dy: 0, top: top, bandHeight: bandHeight, tolerance: Self.jitterTolerance) ? 0 : nil }
        for cand in [ty, -ty] where verifyOffset(dy: cand, top: top, bandHeight: bandHeight, tolerance: Self.jitterTolerance) { return cand }
        return nil
    }

    private func bandImage(_ buffer: UnsafeMutablePointer<UInt8>, top: Int, height: Int) -> CGImage? {
        CGContext(data: buffer + top * bytesPerRow, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo)?.makeImage()
    }

    private func verifyOffset(dy: Int, top: Int, bandHeight: Int, tolerance: Int = ScrollStitcher.sadTolerance) -> Bool {
        let lo = max(0, -dy)
        let hi = min(bandHeight, bandHeight - dy)
        guard hi > lo else { return false }

        var total: UInt64 = 0
        var bytes = 0
        var i = lo
        while i < hi {
            let c = curFrame + (top + i) * bytesPerRow
            let p = prevFrame + (top + i + dy) * bytesPerRow
            var b = 0
            while b < bytesPerRow {
                let d = Int(c[b]) &- Int(p[b])
                total &+= UInt64(d < 0 ? -d : d)
                b += 1
            }
            bytes += bytesPerRow
            i += 8
        }
        guard bytes > 0 else { return false }
        return total <= UInt64(bytes) * UInt64(tolerance)
    }

    /// Copies absolute rows `absLo..<absHi` out of the current frame into the canvas. Both ranges
    /// are contiguous and share `bytesPerRow`, so this is a single memcpy.
    private func copyRows(fromFrameTop frameTop: Int, absLo: Int, absHi: Int) -> Int {
        guard absHi > absLo else { return 0 }
        let srcRow = absLo - frameTop
        let dstRow = absLo - originRow
        memcpy(canvas + dstRow * bytesPerRow,
               curFrame + srcRow * bytesPerRow,
               (absHi - absLo) * bytesPerRow)
        return absHi - absLo
    }

    /// Grows the backing buffer so absolute rows `min..<max` fit. Doubles (never reallocates per
    /// frame) and prepends head-room when the canvas has to grow upward.
    private func ensureCapacity(min newMin: Int, max newMax: Int) {
        let curLo = originRow
        let curHi = originRow + capacity
        if newMin >= curLo && newMax <= curHi { return }

        let deficitTop = Swift.max(0, curLo - newMin)
        let deficitBottom = Swift.max(0, newMax - curHi)
        let padTop = deficitTop > 0 ? Swift.max(deficitTop, capacity / 2) : 0
        let padBottom = deficitBottom > 0 ? Swift.max(deficitBottom, capacity / 2) : 0

        let newOrigin = curLo - padTop
        let newCapacity = capacity + padTop + padBottom
        let newBytes = newCapacity * bytesPerRow

        let fresh = UnsafeMutablePointer<UInt8>.allocate(capacity: newBytes)
        fresh.initialize(repeating: 0, count: newBytes)
        // Only the covered slice carries meaning; copy just that.
        let liveRows = coveredMax - coveredMin
        if liveRows > 0 {
            memcpy(fresh + (coveredMin - newOrigin) * bytesPerRow,
                   canvas + (coveredMin - curLo) * bytesPerRow,
                   liveRows * bytesPerRow)
        }
        canvas.deallocate()
        canvas = fresh
        capacity = newCapacity
        originRow = newOrigin
    }

    // MARK: - Pixels

    private static func decode(_ image: CGImage,
                               into buffer: UnsafeMutablePointer<UInt8>,
                               width: Int,
                               height: Int,
                               bytesPerRow: Int,
                               colorSpace: CGColorSpace,
                               bitmapInfo: UInt32) {
        memset(buffer, 0, bytesPerRow * height)
        guard let ctx = CGContext(data: buffer,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow,
                                  space: colorSpace,
                                  bitmapInfo: bitmapInfo)
        else { return }
        ctx.setBlendMode(.copy)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// FNV-1a over 32-bit words; `bytesPerRow` is always a multiple of 4 so the buffer can be read
    /// as words without alignment games, and no per-pixel Swift boxing happens in the loop.
    private static func rowHashes(_ buffer: UnsafeMutablePointer<UInt8>,
                                  height: Int,
                                  bytesPerRow: Int) -> [UInt64] {
        let wordsPerRow = bytesPerRow / 4
        var out = [UInt64](repeating: 0, count: height)
        let words = UnsafeRawPointer(buffer).bindMemory(to: UInt32.self, capacity: wordsPerRow * height)
        out.withUnsafeMutableBufferPointer { ob in
            var y = 0
            while y < height {
                var h: UInt64 = 0xcbf2_9ce4_8422_2325
                let base = y * wordsPerRow
                var i = 0
                while i < wordsPerRow {
                    h = (h ^ UInt64(words[base + i])) &* 0x0000_0100_0000_01b3
                    i += 1
                }
                ob[y] = h
                y += 1
            }
        }
        return out
    }
}
