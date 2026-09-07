import Foundation
import BenchTestKit
@testable import Klip

// Phase 3C: ContentDetector.detect(text:) rule coverage, plus a few
// detect(for:fullText:) mapping cases (image/file/large-text-preview).
//
// Note on "mailto:john@doe.com": the brief's rule text is explicit that
// "mailto: is NOT link", matching Clipfield's SmartTagger (which tags a
// mailto scheme as .email, never .link). A mailto URI is therefore expected
// to classify as .email here, not .link.

enum ContentDetectorTests {
    static let tests: [(String, () throws -> Void)] = [
        ("table_textCases", testTextCases),
        ("table_linkCases", testLinkCases),
        ("table_emailCases", testEmailCases),
        ("table_phoneCases", testPhoneCases),
        ("table_colorCases", testColorCases),
        ("table_codeCases", testCodeCases),
        ("detectForItem_imageItem_isImage", testDetectForItemImage),
        ("detectForItem_fileItem_isFile", testDetectForItemFile),
        ("detectForItem_textItem_usesFullTextWhenGiven", testDetectForItemUsesFullText),
        ("detectForItem_textItem_fallsBackToStoredPreview", testDetectForItemFallsBackToPreview),
        ("detect_emptyOrWhitespaceOnly_isText", testEmptyIsText),
    ]

    // MARK: - Table-driven cases

    private static let textCases: [(String, String)] = [
        ("plain sentence", "Just a normal sentence about nothing in particular."),
        ("phone-shaped but embedded in prose", "Call me at 555-0100 tomorrow"),
        ("hashtag, not a color", "#hashtag"),
        ("markdown paragraph", "This is a paragraph.\nIt continues on the next line.\nAnd wraps up here."),
        ("url with trailing sentence punctuation", "Check out https://example.com. It's great."),
        ("bare url plus trailing period, no other prose", "https://example.com."),
        ("prose containing code-ish words but no structure", "I have a class tomorrow.\nSee you there!"),
        ("indented list, no code symbols", "Steps:\n  1. Do this\n  2. Do that"),
        ("too-long hex-looking string", "#" + String(repeating: "a", count: 70)),
        ("email look-alike missing TLD", "john@doe"),
        ("multi-line prose with a return mention", "I will return the item tomorrow.\nLet me know when you get it."),
        ("single line SELECT/FROM prose (single line never counts)", "Please SELECT the best option FROM the list."),
    ]

    private static let linkCases: [(String, String)] = [
        ("bare https URL", "https://x.y/z?q=1"),
        ("bare http URL", "http://example.com"),
        ("bare ftp URL", "ftp://ftp.example.com/file.zip"),
        ("www with path, no scheme", "www.example.com/path?x=1"),
        ("localhost with port", "http://localhost:3000"),
    ]

    private static let emailCases: [(String, String)] = [
        ("simple email", "john@doe.com"),
        ("email with subdomain and plus tag", "jane.doe+news@mail.example.co.uk"),
        ("mailto uri wrapping an email", "mailto:john@doe.com"),
    ]

    private static let phoneCases: [(String, String)] = [
        ("dashed local number", "555-0100"),
        ("parens area code", "(555) 123-4567"),
        ("plus country code", "+1 555-123-4567"),
        ("dotted number", "555.123.4567"),
    ]

    private static let colorCases: [(String, String)] = [
        ("3-digit hex", "#FFF"),
        ("4-digit hex with alpha", "#FFFA"),
        ("6-digit hex", "#336699"),
        ("8-digit hex with alpha", "#336699FF"),
        ("uppercase hex", "#ABCDEF"),
        ("rgb()", "rgb(1,2,3)"),
        ("rgba()", "rgba(10, 20, 30, 0.5)"),
        ("hsl() case-insensitive", "HSL(120, 100%, 50%)"),
    ]

    private static let codeCases: [(String, String)] = [
        ("swift function", "func greet(name: String) -> String {\n    return \"Hello, \\(name)!\"\n}"),
        ("json object blob", "{\n  \"name\": \"value\",\n  \"num\": 5,\n  \"nested\": {\"a\": 1}\n}"),
        ("json array blob", "[\n  1,\n  2,\n  3\n]"),
        ("css-like block", ".button {\n  color: red;\n  padding: 4px;\n}"),
        ("multi-line sql select/from", "SELECT id, name\nFROM users\nWHERE active = 1;"),
        ("python def with parens", "def hello():\n    return \"hi\""),
        ("shell command, single short line", "$ npm install"),
        ("git command, single short line", "git status"),
        ("curl command, single short line", "curl -s https://example.com"),
    ]

    static func testTextCases() throws {
        for (label, input) in textCases {
            try expectEqual(ContentDetector.detect(text: input), .text, "expected .text for [\(label)]")
        }
    }

    static func testLinkCases() throws {
        for (label, input) in linkCases {
            try expectEqual(ContentDetector.detect(text: input), .link, "expected .link for [\(label)]")
        }
    }

    static func testEmailCases() throws {
        for (label, input) in emailCases {
            try expectEqual(ContentDetector.detect(text: input), .email, "expected .email for [\(label)]")
        }
    }

    static func testPhoneCases() throws {
        for (label, input) in phoneCases {
            try expectEqual(ContentDetector.detect(text: input), .phone, "expected .phone for [\(label)]")
        }
    }

    static func testColorCases() throws {
        for (label, input) in colorCases {
            try expectEqual(ContentDetector.detect(text: input), .color, "expected .color for [\(label)]")
        }
    }

    static func testCodeCases() throws {
        for (label, input) in codeCases {
            try expectEqual(ContentDetector.detect(text: input), .code, "expected .code for [\(label)]")
        }
    }

    static func testEmptyIsText() throws {
        try expectEqual(ContentDetector.detect(text: ""), .text)
        try expectEqual(ContentDetector.detect(text: "   \n  \t "), .text)
    }

    // MARK: - detect(for:fullText:)

    static func testDetectForItemImage() throws {
        let item = ClipboardItem.image(filename: "abc.png")
        try expectEqual(ContentDetector.detect(for: item, fullText: nil), .image)
    }

    static func testDetectForItemFile() throws {
        let attachment = FileAttachment(originalName: "Report.pdf", storedRelativePath: "files/x/Report.pdf")
        let item = ClipboardItem(type: .text, textContent: "Report.pdf", fileAttachment: attachment)
        try expectEqual(ContentDetector.detect(for: item, fullText: nil), .file)
    }

    static func testDetectForItemUsesFullText() throws {
        // The stored preview alone would not look like code, but the full
        // captured text does — detect(for:fullText:) should use fullText
        // when it's supplied (as ClipboardWatcher does at capture time).
        let preview = "func greet() {"
        let full = "func greet() {\n    return \"hi\"\n}"
        let item = ClipboardItem.largeText(preview: preview, filename: "big.txt")
        try expectEqual(ContentDetector.detect(for: item, fullText: full), .code)
    }

    static func testDetectForItemFallsBackToPreview() throws {
        // No fullText supplied (as in the backfill path) — falls back to the
        // item's own stored textContent, which for large text is the
        // 500-char inline preview. Good enough for classification.
        let item = ClipboardItem.largeText(preview: "https://example.com/really-long-preview", filename: "big.txt")
        try expectEqual(ContentDetector.detect(for: item, fullText: nil), .link)
    }
}
