import Foundation
import AppKit
import BenchTestKit
@testable import Klip

// Rich-text capture / write-back coverage (Phase 3D): the `PasteboardFlavors`
// bundle (round trip, the 16 MB cap, the concealed-type check), the
// `ClipboardStore` RTF/flavors file helpers (write, read, and delete —
// including the drop-on-edit path via `clearRichFlavors`), and the
// `HistoryViewModel` paste-mode selection logic driven by
// `SettingsManager.alwaysPastePlain`.
//
// Pasteboard tests use a private, uniquely-named `NSPasteboard` rather than
// `.general`, so running this suite never touches the developer's real
// clipboard.

enum RichCaptureTests {
    static let tests: [(String, () throws -> Void)] = [
        ("flavors_roundTrip_preservesEveryTypeAndItem", testFlavorsRoundTrip),
        ("flavors_capture_emptyPasteboard_isNil", testFlavorsCaptureEmpty),
        ("flavors_capture_overCap_isNil", testFlavorsCaptureOverCap),
        ("flavors_restore_corruptData_returnsFalse", testFlavorsRestoreCorrupt),
        ("flavors_isConcealed_trueForEachMarkerType", testIsConcealedTrueForMarkers),
        ("flavors_isConcealed_falseForOrdinaryText", testIsConcealedFalseOrdinary),
        ("store_saveRTF_writesUnderTextsDirectory", testSaveRTFWritesFile),
        ("store_saveFlavors_writesUnderFlavorsDirectory", testSaveFlavorsWritesFile),
        ("store_rtfData_flavorsData_roundTripThroughDisk", testStoreRTFFlavorsRoundTrip),
        ("store_purgeItem_removesRTFAndFlavorsFiles", testDeleteRemovesRTFAndFlavorsFiles),
        ("store_clearRichFlavors_dropsFieldsFilesAndDemotesKind", testClearRichFlavorsDemotesKind),
        ("store_clearRichFlavors_noOpWhenNoRichBacking", testClearRichFlavorsNoOp),
        ("pasteMode_default_isRichUnlessAlwaysPlainIsOn", testDefaultPasteModeFollowsSetting),
        ("pasteMode_alternate_isAlwaysOppositeOfDefault", testAlternatePasteModeIsOpposite),
        ("keyPastePlain_multiSelection_pastesWholeSelectionInAlternateMode", testKeyPastePlainMultiSelection),
        ("keyCopyPlain_singleItem_copiesInAlternateMode", testKeyCopyPlainSingleItem),
    ]

    // MARK: - Pasteboard harness

    /// A private, uniquely-named pasteboard so these tests never disturb the
    /// developer's real clipboard.
    private static func withPrivatePasteboard<R>(_ body: (NSPasteboard) throws -> R) rethrows -> R {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.klip.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        return try body(pasteboard)
    }

    // MARK: - PasteboardFlavors: round trip / cap

    static func testFlavorsRoundTrip() throws {
        try withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("hello world", forType: .string)
            pasteboard.setData(Data("custom-payload".utf8), forType: .init("com.klip.tests.custom"))

            guard let captured = PasteboardFlavors.capture(pasteboard) else {
                throw TestFailure(message: "capture should succeed for a populated pasteboard", file: #file, line: #line)
            }

            pasteboard.clearContents()
            try expect(PasteboardFlavors.restore(captured, to: pasteboard), "restore should report success")

            try expectEqual(pasteboard.string(forType: .string), "hello world", "plain string flavor should round-trip")
            let customData = pasteboard.data(forType: .init("com.klip.tests.custom"))
            try expectEqual(customData, Data("custom-payload".utf8), "custom flavor should round-trip byte-for-byte")
        }
    }

    static func testFlavorsCaptureEmpty() throws {
        try withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            try expectNil(PasteboardFlavors.capture(pasteboard), "an empty pasteboard has nothing to capture")
        }
    }

    static func testFlavorsCaptureOverCap() throws {
        try withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            // One byte over the cap so the total is unambiguously too large.
            let oversized = Data(repeating: 0x41, count: PasteboardFlavors.maxRawBytes + 1)
            pasteboard.setData(oversized, forType: .init("com.klip.tests.oversized"))

            try expectNil(PasteboardFlavors.capture(pasteboard), "capture should refuse a bundle over the 16 MB cap")
        }
    }

    static func testFlavorsRestoreCorrupt() throws {
        try withPrivatePasteboard { pasteboard in
            let garbage = Data("not a plist".utf8)
            try expect(!PasteboardFlavors.restore(garbage, to: pasteboard), "restore should fail gracefully on undecodable data")
        }
    }

    // MARK: - Concealed types

    static func testIsConcealedTrueForMarkers() throws {
        for marker in PasteboardFlavors.concealedTypes {
            try withPrivatePasteboard { pasteboard in
                pasteboard.clearContents()
                pasteboard.setString("secret", forType: .string)
                pasteboard.setData(Data(), forType: marker)
                try expect(PasteboardFlavors.isConcealed(pasteboard), "\(marker.rawValue) should mark the pasteboard concealed")
            }
        }
    }

    static func testIsConcealedFalseOrdinary() throws {
        try withPrivatePasteboard { pasteboard in
            pasteboard.clearContents()
            pasteboard.setString("just some text", forType: .string)
            try expect(!PasteboardFlavors.isConcealed(pasteboard), "ordinary text should not be treated as concealed")
        }
    }

    // MARK: - ClipboardStore file helpers

    static func testSaveRTFWritesFile() throws {
        try ClipboardStoreTests.withStore { store, dir in
            let itemID = UUID()
            let rtf = Data("{\\rtf1 hello}".utf8)
            guard let filename = store.saveRTF(rtf, itemID: itemID) else {
                throw TestFailure(message: "saveRTF should succeed", file: #file, line: #line)
            }
            try expectEqual(filename, "\(itemID.uuidString).rtf", "filename should follow the <id>.rtf convention")

            let url = dir.appendingPathComponent("texts").appendingPathComponent(filename)
            try expect(FileManager.default.fileExists(atPath: url.path), "the RTF file should exist under texts/")
            try expectEqual(try Data(contentsOf: url), rtf)
        }
    }

    static func testSaveFlavorsWritesFile() throws {
        try ClipboardStoreTests.withStore { store, dir in
            let itemID = UUID()
            let flavors = Data("bplist00-fake".utf8)
            guard let filename = store.saveFlavors(flavors, itemID: itemID) else {
                throw TestFailure(message: "saveFlavors should succeed", file: #file, line: #line)
            }
            try expectEqual(filename, "\(itemID.uuidString).plist", "filename should follow the <id>.plist convention")

            let url = dir.appendingPathComponent("flavors").appendingPathComponent(filename)
            try expect(FileManager.default.fileExists(atPath: url.path), "the flavors file should exist under flavors/")
            try expectEqual(try Data(contentsOf: url), flavors)
        }
    }

    static func testStoreRTFFlavorsRoundTrip() throws {
        try ClipboardStoreTests.withStore { store, _ in
            var item = ClipboardItem.text("rich clip", sourceApp: "Notes")
            let rtf = Data("{\\rtf1 rich}".utf8)
            let flavors = Data("flavors-bundle".utf8)
            item.rtfFilename = store.saveRTF(rtf, itemID: item.id)
            item.flavorsFilename = store.saveFlavors(flavors, itemID: item.id)
            item.kind = .richText

            try expectEqual(store.rtfData(for: item), rtf, "rtfData(for:) should read back what saveRTF wrote")
            try expectEqual(store.flavorsData(for: item), flavors, "flavorsData(for:) should read back what saveFlavors wrote")
        }
    }

    static func testDeleteRemovesRTFAndFlavorsFiles() throws {
        try ClipboardStoreTests.withStore { store, dir in
            var item = ClipboardItem.text("rich clip", sourceApp: "Notes")
            item.rtfFilename = store.saveRTF(Data("{\\rtf1}".utf8), itemID: item.id)
            item.flavorsFilename = store.saveFlavors(Data("flavors".utf8), itemID: item.id)
            item.kind = .richText

            store.add(item)
            try expect(store.delete(item), "the item should delete")

            let rtfURL = dir.appendingPathComponent("texts").appendingPathComponent(item.rtfFilename!)
            let flavorsURL = dir.appendingPathComponent("flavors").appendingPathComponent(item.flavorsFilename!)
            // 5D: kept while the clip is recoverable, removed by the purge.
            try expect(FileManager.default.fileExists(atPath: rtfURL.path), "the RTF file survives in the trash")
            try expectEqual(store.purgeFromTrash(ids: [item.id]), 1)
            try expect(!FileManager.default.fileExists(atPath: rtfURL.path), "the RTF file should be removed with the item")
            try expect(!FileManager.default.fileExists(atPath: flavorsURL.path), "the flavors file should be removed with the item")
        }
    }

    static func testClearRichFlavorsDemotesKind() throws {
        try ClipboardStoreTests.withStore { store, dir in
            var item = ClipboardItem.text("rich clip", sourceApp: "Notes")
            item.rtfFilename = store.saveRTF(Data("{\\rtf1}".utf8), itemID: item.id)
            item.flavorsFilename = store.saveFlavors(Data("flavors".utf8), itemID: item.id)
            item.kind = .richText
            store.add(item)

            store.clearRichFlavors(for: item)

            let updated = try require(store.items.first(where: { $0.id == item.id }), "item should still exist")
            try expectNil(updated.rtfFilename, "rtfFilename should be cleared")
            try expectNil(updated.flavorsFilename, "flavorsFilename should be cleared")
            try expectEqual(updated.kind, .text, "kind should be demoted from richText to text")

            let rtfURL = dir.appendingPathComponent("texts").appendingPathComponent(item.rtfFilename!)
            let flavorsURL = dir.appendingPathComponent("flavors").appendingPathComponent(item.flavorsFilename!)
            try expect(!FileManager.default.fileExists(atPath: rtfURL.path), "the RTF file should be deleted")
            try expect(!FileManager.default.fileExists(atPath: flavorsURL.path), "the flavors file should be deleted")
        }
    }

    static func testClearRichFlavorsNoOp() throws {
        try ClipboardStoreTests.withStore { store, _ in
            let item = ClipboardItem.text("plain clip", sourceApp: "Notes")
            store.add(item)

            // Should not throw or touch anything for a plain item.
            store.clearRichFlavors(for: item)

            let updated = try require(store.items.first(where: { $0.id == item.id }), "item should still exist")
            try expectNil(updated.rtfFilename)
            try expectNil(updated.flavorsFilename)
        }
    }

    // MARK: - PasteMode selection (HistoryViewModel + SettingsManager.alwaysPastePlain)

    private static func withAlwaysPastePlain<R>(_ value: Bool, _ body: () throws -> R) rethrows -> R {
        let previous = SettingsManager.shared.alwaysPastePlain
        SettingsManager.shared.alwaysPastePlain = value
        defer { SettingsManager.shared.alwaysPastePlain = previous }
        return try body()
    }

    static func testDefaultPasteModeFollowsSetting() throws {
        let a = ClipboardItem(type: .text, textContent: "a")
        try LockTests.withViewModel(seed: [a]) { viewModel, _ in
            try withAlwaysPastePlain(false) {
                try expectEqual(viewModel.defaultPasteMode, .rich, "default should be rich when the setting is off")
            }
            try withAlwaysPastePlain(true) {
                try expectEqual(viewModel.defaultPasteMode, .plain, "default should be plain when the setting is on")
            }
        }
    }

    static func testAlternatePasteModeIsOpposite() throws {
        let a = ClipboardItem(type: .text, textContent: "a")
        try LockTests.withViewModel(seed: [a]) { viewModel, _ in
            try withAlwaysPastePlain(false) {
                try expectEqual(viewModel.alternatePasteMode, .plain, "alternate should be plain when default is rich")
            }
            try withAlwaysPastePlain(true) {
                try expectEqual(viewModel.alternatePasteMode, .rich, "alternate should be rich when default is plain (swap)")
            }
        }
    }

    static func testKeyPastePlainMultiSelection() throws {
        let a = ClipboardItem(type: .text, textContent: "a")
        let b = ClipboardItem(type: .text, textContent: "b")

        try LockTests.withViewModel(seed: [a, b]) { viewModel, _ in
            try withAlwaysPastePlain(false) {
                viewModel.selectedIDs = [a.id, b.id]

                var capturedItems: [ClipboardItem]?
                var capturedMode: PasteMode?
                viewModel.onPasteMultiple = { items, mode in
                    capturedItems = items
                    capturedMode = mode
                }

                viewModel.keyPastePlain()

                try expectEqual(capturedItems?.count, 2, "multi-selection should paste as a batch")
                try expectEqual(capturedMode, .plain, "⌥↩ should use the alternate (plain) mode when default is rich")
            }
        }
    }

    static func testKeyCopyPlainSingleItem() throws {
        let a = ClipboardItem(type: .text, textContent: "a")

        try LockTests.withViewModel(seed: [a]) { viewModel, _ in
            try withAlwaysPastePlain(true) {
                viewModel.selectSingle(a.id)

                var capturedItem: ClipboardItem?
                var capturedMode: PasteMode?
                viewModel.onCopyToClipboard = { item, mode in
                    capturedItem = item
                    capturedMode = mode
                }

                viewModel.keyCopyPlain()

                try expectEqual(capturedItem?.id, a.id)
                try expectEqual(capturedMode, .rich, "⌥⌘C should use the alternate (rich) mode when default is plain")
            }
        }
    }

    // MARK: - Small local helper

    private static func require<T>(_ value: T?, _ message: String, file: StaticString = #file, line: UInt = #line) throws -> T {
        guard let value else { throw TestFailure(message: message, file: file, line: line) }
        return value
    }
}
