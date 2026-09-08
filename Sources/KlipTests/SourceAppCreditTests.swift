import AppKit
import BenchCore
import Foundation
import BenchTestKit
@testable import Klip

// Who a clip is credited to (the preview pane's "From" row).
//
// The frontmost app at the moment the pasteboard changes is the right answer
// for a normal copy, but not for a Bench screenshot: Shot's overlay and editor
// are Bench windows, so every capture used to read "Bench". Shot now writes the
// captured app's name onto the pasteboard under
// `SourceAppPasteboard.sourceAppNameType`, and that hint wins when present.
enum SourceAppCreditTests {
    static let tests: [(String, () throws -> Void)] = [
        ("sourceApp_hintWinsOverTheFrontmostApp", testHintWins),
        ("sourceApp_frontmostAppIsUsedWithoutAHint", testNoHint),
        ("sourceApp_blankHintIsIgnored", testBlankHint),
        ("sourceApp_hintRoundTripsThroughAPasteboard", testPasteboardRoundTrip),
    ]

    private static func testHintWins() throws {
        try expectEqual(ClipboardWatcher.sourceApp(hint: "IINA", frontmostName: "Bench"), "IINA")
        // Trimmed, so a stray newline in the payload cannot become the name.
        try expectEqual(ClipboardWatcher.sourceApp(hint: "  Google Chrome\n", frontmostName: "Bench"), "Google Chrome")
    }

    private static func testNoHint() throws {
        try expectEqual(ClipboardWatcher.sourceApp(hint: nil, frontmostName: "Safari"), "Safari")
        try expect(ClipboardWatcher.sourceApp(hint: nil, frontmostName: nil) == nil,
                   "no hint and no frontmost app credits nothing")
    }

    private static func testBlankHint() throws {
        try expectEqual(ClipboardWatcher.sourceApp(hint: "   ", frontmostName: "Safari"), "Safari")
        try expect(ClipboardWatcher.sourceApp(hint: "", frontmostName: nil) == nil,
                   "a blank hint with no frontmost app credits nothing")
    }

    /// End to end over a private pasteboard: what Shot writes is what Klip reads.
    private static func testPasteboardRoundTrip() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.fxreza.klip.tests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(Data("plain".utf8), forType: .string)
        let credit = SourceAppPasteboard.data(for: "IINA")
        try expectNotNil(credit, "SourceAppPasteboard refused a valid app name")
        item.setData(credit ?? Data(), forType: SourceAppPasteboard.sourceAppNameType)
        pasteboard.writeObjects([item])

        let hint = SourceAppPasteboard.name(from: pasteboard.data(forType: SourceAppPasteboard.sourceAppNameType))
        try expectEqual(ClipboardWatcher.sourceApp(hint: hint, frontmostName: "Bench"), "IINA")

        // An ordinary copy carries no hint, so the frontmost app still wins.
        let plain = NSPasteboard(name: NSPasteboard.Name("com.fxreza.klip.tests.\(UUID().uuidString)"))
        plain.clearContents()
        plain.setString("plain", forType: .string)
        let none = SourceAppPasteboard.name(from: plain.data(forType: SourceAppPasteboard.sourceAppNameType))
        try expectEqual(ClipboardWatcher.sourceApp(hint: none, frontmostName: "Safari"), "Safari")
    }
}
