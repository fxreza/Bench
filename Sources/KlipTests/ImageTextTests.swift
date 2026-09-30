import AppKit
import Foundation
import SwiftUI
import BenchTestKit
@testable import Klip

// Copying the text inside an image (replaces the manual "Extract text").
//
// Klip now reads the text in every image on its own and stores it in
// `ClipboardItem.ocrText`: nil = not read yet, "" = read and none found,
// non-empty = the text. These tests cover what the UI does with those three
// states: `ImageTextState` (the one place that classifies them), the view
// model's `copyImageText(for:)` behind the preview icon, the text block's
// copy button and the row menu's "Copy Text", and the folded text block under
// the image (`FoldedImageText`), including that its "is there a toggle"
// decision really happens in one layout pass.

enum ImageTextTests {
    static let tests: [(String, () throws -> Void)] = [
        ("state_classifiesEveryOcrTextValue", testStateClassification),
        ("state_legacyNoTextMarkerIsNoText_evenWithWhitespace", testLegacySentinel),
        ("state_onlyImagesHaveImageText", testOnlyImages),
        ("state_copyHelp_saysWhyEachOffStateIsOff", testCopyHelp),
        ("copyImageText_copiesTrimmedTextAndConfirms", testCopyImageText),
        ("copyImageText_isASilentNoOpWithoutText", testCopyWithoutText),
        ("copyImageText_usesTheStoresCurrentText_notAStaleRowValue", testCopyUsesCurrentText),
        ("foldedText_shortTextIsShownWhole_withNoToggle", testShortTextIsWhole),
        ("foldedText_longTextFoldsToFourLinesPlusToggle", testLongTextFolds),
        ("foldedText_fiveLinesIsTheFirstToFold", testFiveLinesFolds),
        ("foldedText_expandedShowsEverythingAndALessToggle", testExpanded),
        ("foldedText_decisionHoldsAtEveryPreviewTextSize", testDecisionAcrossFontScales),
        ("foldedText_appKitMeasurementMatchesSwiftUIText", testMeasurementMatchesSwiftUI),
        ("section_hostsWithSeparatorCopyButtonAndFoldedText", testSectionHosts),
    ]

    // MARK: - Helpers

    private static func image(ocrText: String?) -> ClipboardItem {
        ClipboardItem(type: .image, imageFilename: "x.png", imageUTI: "public.png", ocrText: ocrText)
    }

    private static func withBoard<R>(_ body: (NSPasteboard) throws -> R) rethrows -> R {
        let board = NSPasteboard(name: NSPasteboard.Name("KlipTests-imagetext-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        return try body(board)
    }

    /// `n` short lines, exactly `n` lines whatever the width.
    private static func lines(_ n: Int) -> String {
        (1...n).map { "line \($0)" }.joined(separator: "\n")
    }

    /// The height `view` lays out to at `width`, in a real `NSHostingView`.
    private static func hostedHeight<V: View>(_ view: V, width: CGFloat = 260) -> CGFloat {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view.frame(width: width, alignment: .topLeading))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// Runs `body` with the preview text size set to `scale`, restoring it
    /// after. The live singleton, like `SettingsManagerTests` does.
    private static func withPreviewScale<R>(_ scale: Double, _ body: () throws -> R) rethrows -> R {
        let settings = SettingsManager.shared
        let original = settings.previewFontScale
        defer { settings.previewFontScale = original }
        settings.previewFontScale = scale
        return try body()
    }

    private static let textSize13 = KlipFontRole.preview.baseSize

    // MARK: - ImageTextState

    static func testStateClassification() throws {
        try expectEqual(ImageTextState(image(ocrText: nil)), .reading, "nil means not read yet")
        try expectEqual(ImageTextState(image(ocrText: "")), .noText, "empty means read, nothing found")
        try expectEqual(ImageTextState(image(ocrText: "  \n\t ")), .noText, "blank is no text too")
        try expectEqual(ImageTextState(image(ocrText: "Invoice 4471")), .text("Invoice 4471"))
        try expectEqual(ImageTextState(image(ocrText: "  Invoice 4471 \n")), .text("Invoice 4471"),
                        "the text is trimmed, which is also what gets copied")

        try expect(!ImageTextState(image(ocrText: nil)).canCopy, "nothing to copy while it is being read")
        try expect(!ImageTextState(image(ocrText: "")).canCopy, "nothing to copy when there is no text")
        try expect(ImageTextState(image(ocrText: "hi")).canCopy, "text can be copied")
        try expectEqual(ImageTextState(image(ocrText: "hi")).text, "hi")
        try expectNil(ImageTextState(image(ocrText: nil)).text)
    }

    /// Old builds stored this string when the manual extraction found nothing.
    /// The model migrates it, but a clip that arrives from a Mac that has not
    /// updated still carries it, and it must not be offered as text to copy.
    static func testLegacySentinel() throws {
        let sentinel = ImageTextState.legacyNoTextSentinel
        try expectEqual(sentinel, "No text found in this image.", "the exact string old builds wrote")
        try expectEqual(ImageTextState(image(ocrText: sentinel)), .noText)
        try expectEqual(ImageTextState(image(ocrText: "  \(sentinel)\n")), .noText,
                        "surrounding whitespace does not hide the marker")
        try expect(!ImageTextState(image(ocrText: sentinel)).canCopy, "the marker is not copyable text")

        // Real text that merely mentions the phrase is text.
        try expectEqual(ImageTextState(image(ocrText: "\(sentinel) Really.")), .text("\(sentinel) Really."))
    }

    static func testOnlyImages() throws {
        let text = ClipboardItem(type: .text, textContent: "hello", ocrText: "stray ocr")
        try expectEqual(ImageTextState(text), .notAnImage, "a text clip has no image text, even with a stray ocrText")
        try expect(!ImageTextState(text).canCopy, "a text clip has nothing to copy out of an image")

        let file = ClipboardItem(type: .file, ocrText: "stray ocr")
        try expectEqual(ImageTextState(file), .notAnImage)
    }

    static func testCopyHelp() throws {
        let notImage = ImageTextState(ClipboardItem(type: .text, textContent: "x")).copyHelp
        let reading = ImageTextState(image(ocrText: nil)).copyHelp
        let none = ImageTextState(image(ocrText: "")).copyHelp
        let ready = ImageTextState(image(ocrText: "words")).copyHelp

        try expectEqual(notImage, "Only images have text to copy")
        try expectEqual(reading, "Reading the image…")
        try expectEqual(none, "No text found in this image")
        try expectEqual(ready, "Copy text in image")
        try expectEqual(Set([notImage, reading, none, ready]).count, 4, "each state has its own tooltip")
    }

    // MARK: - copyImageText

    static func testCopyImageText() throws {
        try FolderUXTests.withViewModel { vm, store in
            try withBoard { board in
                let item = image(ocrText: "  Receipt total 42.00 \n")
                store.items = [item]

                vm.copyImageText(for: item, to: board)
                try expectEqual(board.string(forType: .string), "Receipt total 42.00",
                                "the image's text lands on the pasteboard, trimmed")
                try expectEqual(vm.toast?.text, "Text copied", "and the copy confirms itself")
            }
        }
    }

    static func testCopyWithoutText() throws {
        try FolderUXTests.withViewModel { vm, store in
            try withBoard { board in
                let candidates: [(String, ClipboardItem)] = [
                    ("not read yet", image(ocrText: nil)),
                    ("no text found", image(ocrText: "")),
                    ("blank", image(ocrText: "   ")),
                    ("legacy marker", image(ocrText: ImageTextState.legacyNoTextSentinel)),
                    ("not an image", ClipboardItem(type: .text, textContent: "hello", ocrText: "stray")),
                ]
                for (label, item) in candidates {
                    store.items = [item]
                    vm.toast = nil
                    board.clearContents()

                    vm.copyImageText(for: item, to: board)
                    try expectNil(board.string(forType: .string), "\(label): nothing is written")
                    try expectNil(vm.toast, "\(label): and no toast claims a copy")
                }
            }
        }
    }

    /// The row menu and the pane hold the clip as it was when the view was
    /// built. The background read can land after that; the copy should still
    /// use the text that is there now.
    static func testCopyUsesCurrentText() throws {
        try FolderUXTests.withViewModel { vm, store in
            try withBoard { board in
                let stale = image(ocrText: nil)
                store.items = [stale]
                store.items[0].ocrText = "Arrived after the menu opened"

                vm.copyImageText(for: stale, to: board)
                try expectEqual(board.string(forType: .string), "Arrived after the menu opened")

                // And the reverse: a stale row that still carries text does
                // not override a clip that has since been read as empty.
                let staleWithText = image(ocrText: "old")
                store.items = [staleWithText]
                store.items[0].ocrText = ""
                board.clearContents()
                vm.toast = nil
                vm.copyImageText(for: staleWithText, to: board)
                try expectNil(board.string(forType: .string), "the store's empty text wins over a stale value")
                try expectNil(vm.toast)
            }
        }
    }

    // MARK: - FoldedImageText

    static func testShortTextIsWhole() throws {
        try withPreviewScale(1.0) {
            for n in 1...FoldedImageText.collapsedLineCount {
                let height = hostedHeight(FoldedImageText(text: lines(n)))
                let whole = FoldedImageText.textHeight(lines: n, fontSize: textSize13)
                try expectEqual(height, whole, "\(n) line(s) is drawn whole, at exactly its own height: no toggle row")
            }
        }
    }

    static func testLongTextFolds() throws {
        try withPreviewScale(1.0) {
            let folded = FoldedImageText.collapsedBlockHeight(textSize: textSize13)
            let fourLines = FoldedImageText.textHeight(lines: 4, fontSize: textSize13)
            try expect(folded > fourLines, "the folded block is the four lines plus the toggle row")

            let height = hostedHeight(FoldedImageText(text: lines(30)))
            try expectEqual(height, folded, "30 lines fold to four lines plus the toggle, not 30 lines")

            // Wrapping counts too: one long paragraph with no newlines at all.
            let paragraph = Array(repeating: "word", count: 300).joined(separator: " ")
            try expectEqual(hostedHeight(FoldedImageText(text: paragraph)), folded,
                            "a long paragraph folds the same way")
        }
    }

    /// The boundary: four lines is whole, five is the first to fold. This is
    /// the claim behind offering `ViewThatFits` exactly the folded height.
    static func testFiveLinesFolds() throws {
        try withPreviewScale(1.0) {
            let folded = FoldedImageText.collapsedBlockHeight(textSize: textSize13)
            try expectEqual(hostedHeight(FoldedImageText(text: lines(5))), folded,
                            "five lines is one more than fits, so it folds")
            try expect(
                hostedHeight(FoldedImageText(text: lines(4))) < folded,
                "four lines is still shown whole and is shorter than the folded block")
        }
    }

    static func testExpanded() throws {
        try withPreviewScale(1.0) {
            let folded = FoldedImageText.collapsedBlockHeight(textSize: textSize13)
            let toggleRow = FoldedImageText.textHeight(
                lines: 1, fontSize: FoldedImageText.toggleSize(forTextSize: textSize13))
            let expected = FoldedImageText.textHeight(lines: 30, fontSize: textSize13)
                + FoldedImageText.lineSpacing + toggleRow

            let height = hostedHeight(FoldedImageText(text: lines(30), startsExpanded: true))
            try expectEqual(height, expected, "expanded: all 30 lines plus the Show less row")
            try expect(height > folded, "expanded is taller than folded")
        }
    }

    /// The fold must not depend on the default text size: at every "Preview
    /// text size" the AppKit-measured budget has to keep four lines whole and
    /// five folded, or the toggle would appear on short text / vanish on long.
    static func testDecisionAcrossFontScales() throws {
        for scale in [0.8, 0.9, 1.0, 1.15, 1.3, 1.5, 2.0] {
            try withPreviewScale(scale) {
                let size = KlipFontRole.preview.baseSize * scale
                let folded = FoldedImageText.collapsedBlockHeight(textSize: size)

                try expectEqual(
                    hostedHeight(FoldedImageText(text: lines(4))),
                    FoldedImageText.textHeight(lines: 4, fontSize: size),
                    "scale \(scale): four lines is shown whole")
                try expectEqual(
                    hostedHeight(FoldedImageText(text: lines(5))), folded,
                    "scale \(scale): five lines folds")
                try expectEqual(
                    hostedHeight(FoldedImageText(text: lines(40))), folded,
                    "scale \(scale): forty lines folds to the same block")
            }
        }
    }

    /// The premise of the above: AppKit's measurement is what SwiftUI's `Text`
    /// lays out. If a macOS release ever makes them disagree this fails here,
    /// instead of the toggle silently appearing on four-line text.
    static func testMeasurementMatchesSwiftUI() throws {
        for size in [8.0, 10.4, 13.0, 15.0, 19.5, 26.0] {
            for n in [1, 2, 4, 5] {
                let swiftUI = hostedHeight(
                    Text(lines(n)).font(.system(size: size)).lineSpacing(FoldedImageText.lineSpacing))
                try expectEqual(swiftUI, FoldedImageText.textHeight(lines: n, fontSize: size),
                                "\(n) lines at \(size) pt")
            }
        }
    }

    // MARK: - ImageTextSection

    static func testSectionHosts() throws {
        try withPreviewScale(1.0) {
            var copied = 0
            let height = hostedHeight(ImageTextSection(text: lines(30)) { copied += 1 })
            let folded = FoldedImageText.collapsedBlockHeight(textSize: textSize13)
            try expect(height >= folded, "the section is at least as tall as its folded text")
            try expect(height < FoldedImageText.textHeight(lines: 30, fontSize: textSize13),
                       "and nowhere near the height of the whole text")
            try expectEqual(copied, 0, "laying the view out copies nothing")
        }
    }
}
