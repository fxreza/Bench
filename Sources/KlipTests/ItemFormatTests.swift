import Foundation
import BenchTestKit
@testable import Klip

// The preview pane's **Kind** row (`ItemFormat`).
//
// The point of the table is that the row says what people call the thing, so
// the tests are mostly assertions about specific, recognisable names: the
// formats where the system's own `localizedDescription` would have said
// something nobody uses ("Office Open XML spreadsheet" for a .xlsx) are the
// ones worth pinning down. The fallback path is covered too, because that is
// what carries every format the table does not list.

enum ItemFormatTests {
    static let tests: [(String, () throws -> Void)] = [
        ("format_imageUsesTheStoredUTI", testImageFromUTI),
        ("format_imageFallsBackToTheStoredFilename", testImageFromFilename),
        ("format_namesOfficeFilesTheWayPeopleDo", testOfficeNames),
        ("format_namesTheCommonDocumentAndArchiveTypes", testCommonNames),
        ("format_isCaseInsensitiveOnTheExtension", testCaseInsensitive),
        ("format_fallsBackToTheSystemDescription", testSystemFallback),
        ("format_fallsBackToTheBareExtension", testExtensionFallback),
        ("format_isNilWithNothingToGoOn", testNoAnswer),
        ("format_multiFileCopy_agreesOrSaysMultiple", testMultiFile),
        ("format_copiedFolder_readsAsFolder", testFolder),
        ("format_textClipsAreNamedToo", testTextKinds),
        ("format_plainVersusRichText", testPlainVersusRich),
    ]

    // MARK: - Images

    static func testImageFromUTI() throws {
        var item = ClipboardItem.image(filename: "shot.dat", uti: "public.heic")
        try expectEqual(ItemFormat.label(forImage: item), "HEIC image",
                        "the UTI captured with the bytes wins over the filename")

        item = ClipboardItem.image(filename: "shot.jpg", uti: "public.jpeg")
        try expectEqual(ItemFormat.label(forImage: item), "JPEG image")
    }

    static func testImageFromFilename() throws {
        // Captured before `imageUTI` existed: the extension is all there is.
        let item = ClipboardItem.image(filename: "screenshot.png")
        try expectEqual(ItemFormat.label(forImage: item), "PNG image")
    }

    // MARK: - Files

    private static func file(_ name: String, uti: String? = nil, plus extras: [String] = []) -> FileAttachment {
        FileAttachment(originalName: name, additionalNames: extras, uti: uti, byteSize: 1)
    }

    static func testOfficeNames() throws {
        // Every one of these would otherwise read as "Office Open XML …".
        try expectEqual(ItemFormat.label(forFile: file("Budget.xlsx")), "Excel spreadsheet")
        try expectEqual(ItemFormat.label(forFile: file("Letter.docx")), "Word document")
        try expectEqual(ItemFormat.label(forFile: file("Pitch.pptx")), "PowerPoint presentation")
    }

    static func testCommonNames() throws {
        try expectEqual(ItemFormat.label(forFile: file("Report.pdf")), "PDF document")
        try expectEqual(ItemFormat.label(forFile: file("notes.txt")), "Plain text")
        try expectEqual(ItemFormat.label(forFile: file("rows.csv")), "CSV spreadsheet")
        try expectEqual(ItemFormat.label(forFile: file("Backup.zip")), "ZIP archive")
        try expectEqual(ItemFormat.label(forFile: file("clip.mp4")), "MP4 video")
        try expectEqual(ItemFormat.label(forFile: file("Plan.numbers")), "Numbers spreadsheet",
                        "named here rather than by the system, which answers nothing without iWork installed")
    }

    static func testCaseInsensitive() throws {
        try expectEqual(ItemFormat.label(forFile: file("SCAN.PDF")), "PDF document")
        try expectEqual(ItemFormat.label(forFile: file("Photo.JPEG")), "JPEG image")
    }

    static func testSystemFallback() throws {
        // Not in the table; the system knows this one and its description is
        // both correct and the name people use.
        try expectEqual(ItemFormat.label(forFile: file("Layers.psd")), "Adobe Photoshop document")
    }

    static func testExtensionFallback() throws {
        // Nothing recognises it, so the extension itself is the honest answer.
        try expectEqual(ItemFormat.label(forFile: file("data.qqzz")), "QQZZ file")
    }

    static func testNoAnswer() throws {
        try expectNil(ItemFormat.label(forFile: file("README")),
                      "no extension and no UTI leaves nothing to say, so the row is hidden")
    }

    static func testMultiFile() throws {
        try expectEqual(
            ItemFormat.label(forFile: file("a.png", uti: "public.png", plus: ["b.png", "c.png"])),
            "PNG image",
            "a batch that agrees is described by what it is"
        )
        try expectEqual(
            ItemFormat.label(forFile: file("a.png", uti: "public.png", plus: ["notes.txt"])),
            "Multiple types",
            "and a mixed batch is not described by whichever file came first"
        )
    }

    static func testFolder() throws {
        try expectEqual(ItemFormat.label(forFile: file("Projects", uti: "public.folder")), "Folder")
    }

    // MARK: - Text

    /// Every clip gets a Kind, so the row sits in the same place on all of
    /// them instead of appearing and disappearing as the selection moves.
    static func testTextKinds() throws {
        for (kind, expected) in [
            (ContentKind.link, "Link"),
            (.email, "Email address"),
            (.phone, "Phone number"),
            (.color, "Color"),
            (.code, "Code"),
        ] {
            var item = ClipboardItem(type: .text, textContent: "x")
            item.kind = kind
            try expectEqual(ItemFormat.label(forText: item), expected, "\(kind) reads as \(expected)")
        }
    }

    /// The one thing the row says about a text clip that is not already on
    /// screen: whether pasting it will carry its formatting.
    static func testPlainVersusRich() throws {
        var plain = ClipboardItem(type: .text, textContent: "hello")
        plain.kind = .text
        try expectEqual(ItemFormat.label(forText: plain), "Plain text")

        var rich = ClipboardItem(type: .text, textContent: "hello")
        rich.kind = .text
        rich.rtfFilename = "abc.rtf"
        try expectEqual(ItemFormat.label(forText: rich), "Rich text",
                        "an archived RTF flavor is what makes it rich, whatever the detector said")

        var detectedRich = ClipboardItem(type: .text, textContent: "hello")
        detectedRich.kind = .richText
        try expectEqual(ItemFormat.label(forText: detectedRich), "Rich text")
    }
}
