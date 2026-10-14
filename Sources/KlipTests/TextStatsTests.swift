import AppKit
import BenchTestKit
@testable import Klip

// Word and character counts on the preview footer's Size row (0.5.0).

enum TextStatsTests {
    static let tests: [(String, () throws -> Void)] = [
        ("empty_isZero", testEmpty),
        ("punctuationAndSpaces_areNotWords", testPunctuation),
        ("characters_countSpacesAndLineBreaks", testCharacters),
        ("emojiAndAccents_countOnce", testGraphemes),
        ("persian_countsWords", testPersian),
        ("viewModel_imageHasNoStats_inlineTextDoes", testViewModelStats),
        ("sizeSummary_joinsOnlyWhatFits", testSizeSummary),
    ]

    static func testEmpty() throws {
        try expectEqual(TextStats.count(""), TextStats(words: 0, characters: 0))
    }

    static func testPunctuation() throws {
        try expectEqual(TextStats.count("Hello, world!  -- it's 2026.").words, 4)
    }

    static func testCharacters() throws {
        try expectEqual(TextStats.count("a b\nc").characters, 5)
    }

    static func testGraphemes() throws {
        let stats = TextStats.count("café 👍🏽")
        try expectEqual(stats.characters, 6)
        try expectEqual(stats.words, 1)
    }

    static func testPersian() throws {
        try expectEqual(TextStats.count("سلام دنیا").words, 2)
    }

    static func testViewModelStats() throws {
        try ClipboardStoreTests.withStore { store, _ in
            let viewModel = HistoryViewModel(store: store)
            let text = ClipboardItem(type: .text, textContent: "one two three")
            try expectEqual(viewModel.textStats(for: text), TextStats(words: 3, characters: 13))
            let image = ClipboardItem(type: .image, imageFilename: "\(UUID().uuidString).png")
            try expectEqual(viewModel.textStats(for: image), nil)
        }
    }

    static func testSizeSummary() throws {
        try expectEqual(
            PreviewPane.sizeSummary(byteCount: "1 KB", dimensions: nil, textStats: TextStats(words: 214, characters: 1187)),
            "1 KB · 214 words · 1,187 characters"
        )
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1920, pixelsHigh: 1080, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let image = NSImage(size: NSSize(width: 1920, height: 1080))
        image.addRepresentation(rep)
        try expectEqual(
            PreviewPane.sizeSummary(byteCount: "2 MB", dimensions: PixelDimensions(image: image), textStats: nil),
            "2 MB · 1920 × 1080 px"
        )
        try expectEqual(PreviewPane.sizeSummary(byteCount: nil, dimensions: nil, textStats: TextStats(words: 1, characters: 1)), "1 word · 1 character")
        try expectEqual(PreviewPane.sizeSummary(byteCount: nil, dimensions: nil, textStats: nil), "—")
    }
}
