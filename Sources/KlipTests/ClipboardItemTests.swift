import Foundation
import BenchTestKit
@testable import Klip

// Ported from BufferTests/ClipboardItemTests.swift (the Xcode XCTest target,
// left untouched) plus new coverage for the JSON forward-compat contract
// described in docs/analysis/buffer.md section 2.

enum ClipboardItemTests {
    static let tests: [(String, () throws -> Void)] = [
        ("equatable_onOcrText_isPinned_isBookmarked_tags", testEquatable),
        ("jsonRoundTrip_textItem_preservesAllFields", testJSONRoundTripText),
        ("jsonRoundTrip_imageItem_preservesAllFields", testJSONRoundTripImage),
        ("decode_missingOptionalFields_usesDefaults", testDecodeMissingOptionalFields),
        ("previewText_capsAt200Chars", testPreviewTextCap),
        ("isEditable_falseAbove5000Chars", testIsEditableLimit),
        ("isProtected_coversEveryProtectionFlag", testIsProtected),
        ("previewText_usesFileAttachmentName", testPreviewTextFileAttachment),
        ("jsonRoundTrip_preservesNewV2Fields", testJSONRoundTripNewFields),
        ("decode_v25File_defaultsNewFields", testDecodeLegacyDefaultsNewFields),
        ("decode_ignoresRemovedTruncationKeys", testDecodeIgnoresRemovedKeys),
        ("contentKind_labelAndSymbolForEveryCase", testContentKindMetadata),
        ("fileAttachment_isReference", testFileAttachmentIsReference),
    ]

    // MARK: - Ported from BufferTests

    static func testEquatable() throws {
        let id = UUID()
        let timestamp = Date()

        let item1 = ClipboardItem(
            id: id, type: .image, timestamp: timestamp,
            isPinned: false, isBookmarked: false, tags: [], ocrText: nil
        )

        // Item with updated OCR text
        let itemWithOCR = ClipboardItem(
            id: id, type: .image, timestamp: timestamp,
            isPinned: false, isBookmarked: false, tags: [], ocrText: "extracted text"
        )

        // Item with updated pin state
        let itemPinned = ClipboardItem(
            id: id, type: .image, timestamp: timestamp,
            isPinned: true, isBookmarked: false, tags: [], ocrText: nil
        )

        // Item with updated bookmark state
        let itemBookmarked = ClipboardItem(
            id: id, type: .image, timestamp: timestamp,
            isPinned: false, isBookmarked: true, tags: [], ocrText: nil
        )

        // Item with updated tags
        let itemWithTags = ClipboardItem(
            id: id, type: .image, timestamp: timestamp,
            isPinned: false, isBookmarked: false, tags: ["tag1"], ocrText: nil
        )

        try expect(item1 != itemWithOCR, "items with different ocrText should not be equal")
        try expect(item1 != itemPinned, "items with different isPinned should not be equal")
        try expect(item1 != itemBookmarked, "items with different isBookmarked should not be equal")
        try expect(item1 != itemWithTags, "items with different tags should not be equal")
        try expectEqual(item1, item1, "identical items should be equal")
    }

    // MARK: - JSON round-trip

    static func testJSONRoundTripText() throws {
        let original = ClipboardItem(
            id: UUID(),
            type: .text,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            sourceApp: "TextEdit",
            textContent: "hello world",
            textFilename: "texts/abc.txt",
            imageFilename: nil,
            isPinned: true,
            isBookmarked: true,
            tags: ["work", "urgent"],
            ocrText: "hello ocr"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ClipboardItem.self, from: data)

        try expectEqual(decoded, original, "decoded .text item should equal the original")
        try expectEqual(decoded.sourceApp, original.sourceApp, "sourceApp should round-trip")
        try expectEqual(decoded.textContent, original.textContent, "textContent should round-trip")
        try expectEqual(decoded.textFilename, original.textFilename, "textFilename should round-trip")
        try expectEqual(decoded.imageFilename, original.imageFilename, "imageFilename should round-trip")
        try expectEqual(decoded.timestamp, original.timestamp, "timestamp should round-trip")
    }

    static func testJSONRoundTripImage() throws {
        let original = ClipboardItem(
            id: UUID(),
            type: .image,
            timestamp: Date(timeIntervalSince1970: 1_700_000_500),
            sourceApp: "Preview",
            textContent: nil,
            textFilename: nil,
            imageFilename: "images/def.png",
            isPinned: false,
            isBookmarked: true,
            tags: ["screenshot"],
            ocrText: nil
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ClipboardItem.self, from: data)

        try expectEqual(decoded, original, "decoded .image item should equal the original")
        try expectEqual(decoded.imageFilename, original.imageFilename, "imageFilename should round-trip")
        try expectEqual(decoded.tags, original.tags, "tags should round-trip")
        try expectNil(decoded.textContent, "textContent should stay nil for an image item")
    }

    // MARK: - Forward-compat contract (buffer.md section 2)

    static func testDecodeMissingOptionalFields() throws {
        let id = UUID()
        // Simulates a history.json entry written before isPinned/isBookmarked/
        // tags/ocrText existed. Decoding must succeed and fall back to defaults
        // rather than throwing or discarding the whole history file.
        let json = """
        {
            "id": "\(id.uuidString)",
            "type": "text",
            "timestamp": 1700000000,
            "textContent": "legacy item with no optional fields"
        }
        """
        let decoded = try JSONDecoder().decode(ClipboardItem.self, from: Data(json.utf8))

        try expectEqual(decoded.id, id, "id should decode correctly")
        try expectEqual(decoded.textContent, "legacy item with no optional fields", "textContent should decode correctly")
        try expectEqual(decoded.isPinned, false, "missing isPinned should default to false")
        try expectEqual(decoded.isBookmarked, false, "missing isBookmarked should default to false")
        try expectEqual(decoded.tags, [], "missing tags should default to an empty array")
        try expectNil(decoded.ocrText, "missing ocrText should default to nil")
    }

    // MARK: - Computed properties

    static func testPreviewTextCap() throws {
        let longText = String(repeating: "a", count: 250)
        let item = ClipboardItem.text(longText)

        try expectEqual(item.previewText.count, 201, "previewText should cap at 200 chars plus an ellipsis")
        try expect(item.previewText.hasSuffix("\u{2026}"), "previewText over 200 chars should end with an ellipsis")
        try expectEqual(String(item.previewText.dropLast()), String(longText.prefix(200)), "previewText body should be the first 200 chars")

        let shortText = String(repeating: "b", count: 50)
        let shortItem = ClipboardItem.text(shortText)
        try expectEqual(shortItem.previewText, shortText, "previewText should not truncate text under the cap")
    }

    static func testIsEditableLimit() throws {
        let overLimit = ClipboardItem.text(String(repeating: "x", count: 5001))
        try expect(!overLimit.isEditable, "text item over 5000 chars should not be editable")

        let atLimit = ClipboardItem.text(String(repeating: "x", count: 5000))
        try expect(atLimit.isEditable, "text item at exactly 5000 chars should be editable")

        let shortItem = ClipboardItem.text("short")
        try expect(shortItem.isEditable, "short text item should be editable")
    }

    // MARK: - Phase 1B additions

    static func testIsProtected() throws {
        let plain = ClipboardItem.text("plain")
        try expect(!plain.isProtected, "a loose item is not protected")

        var pinned = plain; pinned.isPinned = true
        var bookmarked = plain; bookmarked.isBookmarked = true
        var tagged = plain; tagged.tags = ["t"]
        var locked = plain; locked.isLocked = true
        var foldered = plain; foldered.folderID = UUID()

        try expect(pinned.isProtected, "pinned items are protected from eviction")
        try expect(bookmarked.isProtected, "bookmarked items are protected from eviction")
        try expect(tagged.isProtected, "tagged items are protected from eviction")
        try expect(locked.isProtected, "locked items are protected from eviction")
        try expect(foldered.isProtected, "foldered items are protected from eviction")

        // Only isLocked blocks deletion; the other flags do not.
        try expect(!pinned.isLocked, "pinning must not imply a lock")
        try expect(!foldered.isLocked, "the model does not lock on its own — the store does that when filing")
    }

    static func testPreviewTextFileAttachment() throws {
        let single = ClipboardItem(
            type: .text,
            textContent: "ignored",
            fileAttachment: FileAttachment(originalName: "Report.pdf", byteSize: 10)
        )
        try expectEqual(single.previewText, "Report.pdf", "a file item previews as its original name")
        try expect(single.isFile, "an item with an attachment is a file item")

        let multiple = ClipboardItem(
            type: .text,
            fileAttachment: FileAttachment(
                originalName: "Report.pdf",
                additionalNames: ["Notes.txt", "Data.csv"],
                byteSize: 30
            )
        )
        try expectEqual(multiple.previewText, "Report.pdf +2", "extra files are summarised with a +N suffix")

        try expect(!ClipboardItem.text("hi").isFile, "a plain text item is not a file item")
    }

    static func testJSONRoundTripNewFields() throws {
        let folderID = UUID()
        let attachment = FileAttachment(
            originalName: "Deck.key",
            additionalNames: ["Script.md"],
            storedRelativePath: nil,
            referencePath: "/Users/someone/Desktop/Deck.key",
            bookmark: Data([0xDE, 0xAD, 0xBE, 0xEF]),
            uti: "com.apple.keynote.key",
            byteSize: 1_048_576
        )
        let original = ClipboardItem(
            type: .text,
            timestamp: Date(timeIntervalSince1970: 1_700_000_900),
            sourceApp: "Finder",
            textContent: "Deck.key",
            isLocked: true,
            folderID: folderID,
            kind: .file,
            fileAttachment: attachment,
            rtfFilename: "deck.rtf",
            flavorsFilename: "deck.plist"
        )

        let decoded = try JSONDecoder().decode(ClipboardItem.self, from: JSONEncoder().encode(original))
        try expectEqual(decoded, original, "an item with every new field should round-trip")
        try expectEqual(decoded.isLocked, true, "isLocked should round-trip")
        try expectEqual(decoded.folderID, folderID, "folderID should round-trip")
        try expectEqual(decoded.kind, .file, "kind should round-trip")
        try expectEqual(decoded.fileAttachment, attachment, "fileAttachment should round-trip")
        try expect(decoded.fileAttachment?.isReference == true, "a reference attachment stays a reference")
        try expectEqual(decoded.rtfFilename, "deck.rtf", "rtfFilename should round-trip")
        try expectEqual(decoded.flavorsFilename, "deck.plist", "flavorsFilename should round-trip")
    }

    static func testDecodeLegacyDefaultsNewFields() throws {
        // A v2.5.0 history entry: none of the Phase 1B keys exist.
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "type": "text",
            "timestamp": 1700000000,
            "textContent": "old clip",
            "isPinned": true,
            "isBookmarked": false,
            "tags": ["work"]
        }
        """
        let decoded = try JSONDecoder().decode(ClipboardItem.self, from: Data(json.utf8))

        try expectEqual(decoded.isLocked, false, "missing isLocked should default to false")
        try expectNil(decoded.folderID, "missing folderID should default to nil")
        try expectNil(decoded.kind, "missing kind should stay nil (not yet detected)")
        try expectNil(decoded.fileAttachment, "missing fileAttachment should default to nil")
        try expectNil(decoded.rtfFilename, "missing rtfFilename should default to nil")
        try expectNil(decoded.flavorsFilename, "missing flavorsFilename should default to nil")
        try expect(decoded.isProtected, "a tagged, pinned legacy item is still protected")
        try expect(!decoded.isFile, "a legacy text item is not a file item")
    }

    static func testDecodeIgnoresRemovedKeys() throws {
        // isTruncated / originalSizeBytes were removed in Phase 1B. Old files
        // still carry them and must decode without complaint.
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "type": "text",
            "timestamp": 1700000000,
            "textContent": "preview only",
            "isTruncated": true,
            "originalSizeBytes": 99999999
        }
        """
        let decoded = try JSONDecoder().decode(ClipboardItem.self, from: Data(json.utf8))
        try expectEqual(decoded.textContent, "preview only", "the surviving fields should decode")
        try expect(decoded.isEditable, "a short text item stays editable")
    }

    static func testContentKindMetadata() throws {
        try expectEqual(ContentKind.allCases.count, 9, "there should be nine content kinds")
        for kind in ContentKind.allCases {
            try expect(!kind.label.isEmpty, "\(kind.rawValue) should have a label")
            try expect(!kind.systemImage.isEmpty, "\(kind.rawValue) should have an SF Symbol")
            let decoded = try JSONDecoder().decode(ContentKind.self, from: JSONEncoder().encode(kind))
            try expectEqual(decoded, kind, "\(kind.rawValue) should round-trip through JSON")
        }
        try expectEqual(ContentKind.code.systemImage, "chevron.left.forwardslash.chevron.right", "code symbol")
        try expectEqual(ContentKind.richText.rawValue, "richText", "raw values are the stable storage keys")
    }

    static func testFileAttachmentIsReference() throws {
        let copied = FileAttachment(originalName: "a.txt", storedRelativePath: "files/x/a.txt", byteSize: 4)
        try expect(!copied.isReference, "an attachment with a stored path is not a reference")

        let referenced = FileAttachment(originalName: "a.txt", referencePath: "/tmp/a.txt", byteSize: 4)
        try expect(referenced.isReference, "an attachment without a stored path is a reference")

        let decoded = try JSONDecoder().decode(FileAttachment.self, from: Data("""
        {"originalName": "a.txt"}
        """.utf8))
        try expectEqual(decoded.originalName, "a.txt", "originalName should decode")
        try expectEqual(decoded.additionalNames, [], "missing additionalNames should default to empty")
        try expectEqual(decoded.byteSize, 0, "missing byteSize should default to 0")
        try expect(decoded.isReference, "an attachment with no stored path is a reference")
    }
}
