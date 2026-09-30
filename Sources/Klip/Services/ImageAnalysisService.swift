import Foundation
import ImageIO
// Vision's request types predate Sendable; every one of them is created,
// performed and read on the single thread that calls `analyze(imageAt:)`.
@preconcurrency import Vision

/// What one image clip was found to contain: the text in it (`""` when
/// none) and what it shows (`[]` when nothing cleared the floor). Stored on
/// the clip as `ocrText` / `imageLabels`.
nonisolated struct ImageAnalysis: Equatable, Sendable {
    var text: String
    var labels: [String]

    /// "Read, found nothing": what an image whose file is gone or will not
    /// decode is stamped with, so the backfill does not try it every launch.
    static let empty = ImageAnalysis(text: "", labels: [])
}

/// Reads an image clip for search: the text in it (`VNRecognizeTextRequest`)
/// and what it shows (`VNClassifyImageRequest`), both from **one**
/// `VNImageRequestHandler.perform`, so the pixels are decoded and uploaded
/// once for the two requests.
///
/// On-device only, nothing leaves the Mac. Everything here is `nonisolated`
/// (the module builds with `-default-isolation MainActor`) and synchronous:
/// `ImageAnalysisQueue` calls `analyze(imageAt:)` on its own utility-QoS
/// queue, one image at a time.
///
/// Measured on this Mac (macOS 27, Apple silicon), decode + both requests:
/// ~165 ms for a 2880x1800 screenshot with 40 lines of text
/// (`ImageAnalysisTests.service_realVision_screenshotTiming`), ~300 ms for
/// one packed with ~120 lines, 50-100 ms for a photo with no text. The very
/// first text request made by a newly built binary costs ~23 s of wall time
/// while Vision prepares the accurate text model (mostly waiting on a
/// system service; ~3.6 s CPU in-process); every later launch of the same
/// binary starts in ~0.2 s. In the app that is once per installed build, in
/// the background, and only delays the first result.
nonisolated enum ImageAnalysisService {
    enum Outcome: Equatable, Sendable {
        /// Both requests ran. `ImageAnalysis.text` may be empty.
        case analyzed(ImageAnalysis)
        /// The file is missing or is not an image ImageIO can decode.
        /// Permanent for these bytes, so the caller records `.empty`.
        case unreadable
        /// Vision itself failed. Possibly transient (resources, a system
        /// service restarting), so the caller must not persist anything
        /// and should try again on a later launch.
        case failed
    }

    // MARK: - Tuning

    /// Longest the shorter side of the image handed to Vision may be.
    ///
    /// Not the long side, which is what the usual "max 2000 px" thumbnail
    /// rule caps: that would squash a 1600x12000 scrolling capture to
    /// 267x2000, where 13 pt text is 4 px tall and Vision reads **0** of its
    /// 280 lines. Capping the short side keeps such captures close to full
    /// resolution (1500x11250: ~290 text lines recognized instead of 0).
    ///
    /// It also fixes the opposite case. Vision's accurate recognizer reads
    /// *worse* the larger a screenshot is once its text is small relative to
    /// the frame: a synthetic 5120x2880 (5K Retina) page with 13 pt text gave
    /// 8 of 201 lines at full size, 6 at 4216 px wide, 23 at 3771, but 159 at
    /// 2667x1500. 2880x1800 and 3456x2234 pages read completely at every
    /// size tried, from 1200 px short side up to full resolution, so 1500
    /// costs them nothing. (A 6016x3384 XDR page read poorly at every size
    /// tried; that is Vision's limit, not this one's.)
    static let maxShortSide = 1_500

    /// Ceiling on the long side, so an absurdly long scrolling capture
    /// cannot allocate an unbounded bitmap (1500 x 12000 x 4 bytes is 72 MB,
    /// released as soon as the request returns).
    static let maxLongSide = 12_000

    /// Classifier labels below this confidence are dropped.
    ///
    /// Chosen on 45 sample photos (the macOS account pictures plus desktop
    /// pictures) against Apple's precision/recall helpers:
    /// - `hasMinimumPrecision(0.1, forRecall: 0.8)`, the high-recall filter
    ///   Apple suggests for search, let low-confidence junk through ("insect"
    ///   on a bee-less sunflower at 0.098, "toucan"/"vulture" on a parrot at
    ///   0.05-0.10) and at the same time **dropped** correct generic labels
    ///   far above that ("sky"/"outdoor" at 0.33 on the Sonoma picture, 0.14
    ///   on the zebra): for an easy class the recall-0.8 operating point sits
    ///   at a high threshold.
    /// - Adding `hasMinimumRecall(0.01, forPrecision: 0.9)` as a rescue for
    ///   sub-floor labels never fired on the sample.
    /// - A flat 0.1 kept every label a person would search for on those
    ///   pictures ("flower", "sunflower", "bird", "penguin", "sky", "guitar",
    ///   "document", "screenshot") and little else. Two to eight labels per
    ///   image is typical.
    ///
    /// The classifier's taxonomy is hierarchical, so a confident leaf brings
    /// its parents along ("sunflower" with "flower" and "plant"), which is
    /// exactly what search wants.
    static let labelConfidenceFloor: Float = 0.1

    /// At most this many labels are kept, most confident first.
    static let maxLabels = 15

    // MARK: - Analysis

    /// Decodes the image at `url` (downsampled, see `maxShortSide`) and runs
    /// text recognition and classification on it. Blocking; call it from a
    /// background queue.
    static func analyze(imageAt url: URL) -> Outcome {
        autoreleasepool {
            guard let image = downsampledImage(at: url) else { return .unreadable }

            let classify = VNClassifyImageRequest()
            let recognize = VNRecognizeTextRequest()
            // `.accurate` is what the manual "Extract text" used, and the
            // speed of `.fast` is not worth its misses in a background pass.
            recognize.recognitionLevel = .accurate
            // Language correction turns near-misses into dictionary words,
            // which is what a search query will be. ~100 ms of the budget.
            recognize.usesLanguageCorrection = true
            // Screenshots of French, German, Chinese... pages become
            // searchable too; ~20% slower than English-only on the sample.
            recognize.automaticallyDetectsLanguage = true

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([recognize, classify])
            } catch {
                print("[Klip] Image analysis failed for \(url.lastPathComponent): \(error.localizedDescription)")
                return .failed
            }

            let lines = (recognize.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let candidates = (classify.results ?? []).map { (identifier: $0.identifier, confidence: $0.confidence) }
            return .analyzed(ImageAnalysis(
                text: joinedText(lines),
                labels: selectLabels(candidates)
            ))
        }
    }

    /// The image at `url`, decoded straight to the size Vision gets.
    ///
    /// `CGImageSourceCreateThumbnailAtIndex` decodes *at* the target size
    /// (JPEG and HEIC scale during decode), so a 48 MP photo never exists in
    /// memory at full resolution the way `NSImage(contentsOf:)` + `cgImage`
    /// would make it. The EXIF orientation is applied, so a photo taken in
    /// portrait is read upright. An animated GIF contributes its first
    /// frame.
    static func downsampledImage(at url: URL) -> CGImage? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions as CFDictionary)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: targetMaxPixelSize(width: width, height: height),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
    }

    /// The `kCGImageSourceThumbnailMaxPixelSize` (a long-side length) that
    /// brings a `width` x `height` image within `maxShortSide` and
    /// `maxLongSide`, never upscaling. Pure, so the sizing rule is testable.
    static func targetMaxPixelSize(width: Int, height: Int) -> Int {
        let short = Double(min(width, height))
        let long = Double(max(width, height))
        guard short > 0 else { return max(width, height) }
        let scale = min(1, Double(maxShortSide) / short, Double(maxLongSide) / long)
        return max(1, Int((long * scale).rounded()))
    }

    // MARK: - Shaping the results

    /// One recognized line per `\n`, blank lines dropped, surrounding
    /// whitespace trimmed. `""` when the image has no text, which is the
    /// stored "read, nothing there" state.
    static func joinedText(_ lines: [String]) -> String {
        lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// The labels worth keeping from a classifier result: at or above
    /// `labelConfidenceFloor`, most confident first (identifier breaks ties,
    /// so the order is deterministic), normalized, de-duplicated after
    /// normalization, and capped at `maxLabels`.
    static func selectLabels(_ candidates: [(identifier: String, confidence: Float)]) -> [String] {
        let kept = candidates
            .filter { $0.confidence >= labelConfidenceFloor }
            .sorted { lhs, rhs in
                lhs.confidence != rhs.confidence ? lhs.confidence > rhs.confidence : lhs.identifier < rhs.identifier
            }
        var seen = Set<String>()
        var labels: [String] = []
        for candidate in kept {
            let label = normalizedLabel(candidate.identifier)
            guard !label.isEmpty, seen.insert(label).inserted else { continue }
            labels.append(label)
            if labels.count == maxLabels { break }
        }
        return labels
    }

    /// Vision identifier -> search label: underscores become spaces,
    /// lowercased, and the taxonomy's catch-all `_other` qualifier is
    /// dropped (`"celestial_body_other"` -> `"celestial body"`,
    /// `"computer_keyboard"` -> `"computer keyboard"`). Other qualifiers are
    /// kept as they are (`"balloon_hotair"` -> `"balloon hotair"`): search is
    /// a substring match, so "balloon" still finds it.
    static func normalizedLabel(_ identifier: String) -> String {
        var words = identifier
            .lowercased()
            .split(whereSeparator: { $0 == "_" || $0.isWhitespace })
            .map(String.init)
        if words.count > 1, words.last == "other" { words.removeLast() }
        return words.joined(separator: " ")
    }
}
