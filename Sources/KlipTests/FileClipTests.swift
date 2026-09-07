import Foundation
import BenchTestKit
@testable import Klip

// File clip capture/store/paste coverage (Phase 3F). Uses the same
// `withTempDir`/`ClipboardStoreTests.withStore` harness as the rest of the
// store tests — every test runs against a throwaway storage root.

enum FileClipTests {
    static let tests: [(String, () throws -> Void)] = [
        ("makeFileItem_underCap_copiesIntoStorage", testCaptureUnderCapCopies),
        ("makeFileItem_overCap_keepsReferenceOnly", testCaptureOverCapReferences),
        ("makeFileItem_zeroCap_meansUnlimited", testCaptureZeroCapIsUnlimited),
        ("makeFileItem_multipleFiles_firstNamePlusAdditionalNames", testCaptureMultipleFiles),
        ("fingerprint_sameInputs_isStable", testFingerprintStable),
        ("fingerprint_differentContent_differs", testFingerprintDiffers),
        ("fileURLs_storedAttachment_resolvesUnderFilesDir", testFileURLsStored),
        ("fileURLs_referenceAttachment_resolvesOriginalPath", testFileURLsReference),
        ("fileURLs_skipsMissingNames", testFileURLsSkipsMissing),
        ("fileIsMissing_trueWhenNothingResolves", testFileIsMissing),
        ("fileIsMissing_falseForFoundFile", testFileIsMissingFalseWhenPresent),
        ("purgeFromTrash_removesCopiedFilesDirectory", testDeleteRemovesCopiedFiles),
        ("uniqueURL_noCollision_returnsSameName", testUniqueURLNoCollision),
        ("uniqueURL_collision_appendsCounter", testUniqueURLCollision),
        ("uniqueURL_collision_noExtension", testUniqueURLCollisionNoExtension),
        // 5A-23 — a failed save must not destroy the file already there.
        ("copyReplacingItem_replacesAnExistingFile", testCopyReplacingItemReplaces),
        ("copyReplacingItem_keepsTheOriginalWhenTheCopyFails", testCopyReplacingItemFailureKeepsOriginal),
        ("copyReplacingItem_writesWhenNothingIsThere", testCopyReplacingItemFresh),
    ]

    // MARK: - Helpers

    /// Writes a small file at `dir/name` with `contents` and returns its URL.
    @discardableResult
    private static func makeFile(_ name: String, in dir: URL, contents: String = "hello") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// Runs `body` with a fresh `ClipboardStore` (storage rooted in a temp
    /// dir) and a second, unrelated temp dir standing in for "the user's
    /// Desktop" — where captured source files live before being copied in.
    private static func withStoreAndSourceDir(
        capMB: Int,
        _ body: (ClipboardStore, URL, URL) throws -> Void
    ) throws {
        try withTempDir { sourceDir in
            try ClipboardStoreTests.withStore { store, storageDir in
                let previousCap = SettingsManager.shared.fileCopyCapMB
                SettingsManager.shared.fileCopyCapMB = capMB
                defer { SettingsManager.shared.fileCopyCapMB = previousCap }
                try body(store, storageDir, sourceDir)
            }
        }
    }

    // MARK: - Capture policy

    static func testCaptureUnderCapCopies() throws {
        try withStoreAndSourceDir(capMB: 1) { store, storageDir, sourceDir in
            let fileURL = try makeFile("small.txt", in: sourceDir, contents: "tiny")

            guard let (item, _) = store.makeFileItem(from: [fileURL], sourceApp: "Finder") else {
                throw TestFailure(message: "makeFileItem should succeed for a small file", file: #file, line: #line)
            }

            try expectEqual(item.type, .file, "captured item should be .file")
            try expectEqual(item.kind, .file, "captured item's kind should be .file")
            let attachment = try require(item.fileAttachment, "captured item should carry a fileAttachment")
            try expect(!attachment.isReference, "a file under the cap should be copied in, not referenced")
            let relative = try require(attachment.storedRelativePath, "a copied attachment should have a storedRelativePath")
            try expectEqual(relative, "files/\(item.id.uuidString)", "storedRelativePath should be files/<item-id>")

            let copiedURL = storageDir.appendingPathComponent(relative).appendingPathComponent("small.txt")
            try expect(FileManager.default.fileExists(atPath: copiedURL.path), "the file should be copied into files/<uuid>/")
            try expectEqual(try String(contentsOf: copiedURL, encoding: .utf8), "tiny", "the copied file's contents should match the source")
        }
    }

    static func testCaptureOverCapReferences() throws {
        try withStoreAndSourceDir(capMB: 1) { store, storageDir, sourceDir in
            // 1 MB cap; write ~2 MB so it's over.
            let bigContents = String(repeating: "x", count: 2 * 1024 * 1024)
            let fileURL = try makeFile("big.bin", in: sourceDir, contents: bigContents)

            guard let (item, _) = store.makeFileItem(from: [fileURL], sourceApp: "Finder") else {
                throw TestFailure(message: "makeFileItem should still succeed above the cap (as a reference)", file: #file, line: #line)
            }

            let attachment = try require(item.fileAttachment, "captured item should carry a fileAttachment")
            try expect(attachment.isReference, "a file over the cap should be kept as a reference, not copied")
            try expectEqual(attachment.referencePath, fileURL.path, "referencePath should be the original file's path")
            try expectNotNil(attachment.bookmark, "a reference attachment should carry a bookmark")

            let filesDir = storageDir.appendingPathComponent("files")
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: filesDir.path)) ?? []
            try expectEqual(contents.count, 0, "nothing should be copied into files/ when the cap is exceeded")
        }
    }

    static func testCaptureZeroCapIsUnlimited() throws {
        try withStoreAndSourceDir(capMB: 0) { store, storageDir, sourceDir in
            let bigContents = String(repeating: "y", count: 2 * 1024 * 1024)
            let fileURL = try makeFile("big.bin", in: sourceDir, contents: bigContents)

            guard let (item, _) = store.makeFileItem(from: [fileURL], sourceApp: nil) else {
                throw TestFailure(message: "makeFileItem should succeed", file: #file, line: #line)
            }
            let attachment = try require(item.fileAttachment, "should have an attachment")
            try expect(!attachment.isReference, "a cap of 0 (unlimited) should always copy, however large")
        }
    }

    static func testCaptureMultipleFiles() throws {
        try withStoreAndSourceDir(capMB: 0) { store, storageDir, sourceDir in
            let first = try makeFile("Report.pdf", in: sourceDir, contents: "pdf-bytes")
            let second = try makeFile("Notes.txt", in: sourceDir, contents: "notes")
            let third = try makeFile("Data.csv", in: sourceDir, contents: "a,b,c")

            guard let (item, _) = store.makeFileItem(from: [first, second, third], sourceApp: "Finder") else {
                throw TestFailure(message: "makeFileItem should succeed for multiple files", file: #file, line: #line)
            }
            let attachment = try require(item.fileAttachment, "should have an attachment")
            try expectEqual(attachment.originalName, "Report.pdf", "the first file's name is the original name")
            try expectEqual(attachment.additionalNames, ["Notes.txt", "Data.csv"], "the rest go in additionalNames")
            try expectEqual(attachment.byteSize, 9 + 5 + 5, "byteSize should be the sum of every file")

            let urls = store.fileURLs(for: item)
            try expectEqual(urls.count, 3, "all three copied files should resolve")
        }
    }

    // MARK: - Fingerprint / dedupe

    static func testFingerprintStable() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let entries: [(path: String, size: Int64, modificationDate: Date)] = [
            ("/a/one.txt", 100, date),
            ("/a/two.txt", 200, date),
        ]
        let first = ClipboardStore.fingerprint(for: entries)
        let second = ClipboardStore.fingerprint(for: entries.reversed())
        try expectEqual(first, second, "fingerprint should not depend on input order")
    }

    static func testFingerprintDiffers() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = ClipboardStore.fingerprint(for: [("/a/one.txt", 100, date)])
        let b = ClipboardStore.fingerprint(for: [("/a/one.txt", 101, date)])
        let c = ClipboardStore.fingerprint(for: [("/a/two.txt", 100, date)])
        try expect(a != b, "a different size should change the fingerprint")
        try expect(a != c, "a different path should change the fingerprint")
    }

    // MARK: - fileURLs / fileIsMissing

    static func testFileURLsStored() throws {
        try withStoreAndSourceDir(capMB: 0) { store, storageDir, sourceDir in
            let fileURL = try makeFile("Doc.txt", in: sourceDir)
            guard let (item, _) = store.makeFileItem(from: [fileURL], sourceApp: nil) else {
                throw TestFailure(message: "capture should succeed", file: #file, line: #line)
            }
            let urls = store.fileURLs(for: item)
            try expectEqual(urls.count, 1, "one file should resolve")
            try expect(urls[0].path.hasPrefix(storageDir.path), "a copied attachment resolves under the storage directory")
        }
    }

    static func testFileURLsReference() throws {
        try ClipboardStoreTests.withStore { store, _ in
            try withTempDir { sourceDir in
                let fileURL = try makeFile("Ref.txt", in: sourceDir)
                let attachment = FileAttachment(originalName: "Ref.txt", referencePath: fileURL.path, byteSize: 5)
                let item = ClipboardItem.file(attachment: attachment)
                let urls = store.fileURLs(for: item)
                try expectEqual(urls, [fileURL], "a reference attachment should resolve to its referencePath")
            }
        }
    }

    static func testFileURLsSkipsMissing() throws {
        try ClipboardStoreTests.withStore { store, _ in
            let attachment = FileAttachment(originalName: "Gone.txt", referencePath: "/nonexistent/Gone.txt", byteSize: 5)
            let item = ClipboardItem.file(attachment: attachment)
            try expectEqual(store.fileURLs(for: item), [], "a reference to a missing path should resolve to nothing, not a dangling URL")
        }
    }

    static func testFileIsMissing() throws {
        try ClipboardStoreTests.withStore { store, _ in
            let attachment = FileAttachment(originalName: "Gone.txt", referencePath: "/nonexistent/Gone.txt", byteSize: 5)
            let item = ClipboardItem.file(attachment: attachment)
            try expect(store.fileIsMissing(item), "a file item whose payload can't be resolved should be reported missing")

            try expect(!store.fileIsMissing(ClipboardItem.text("plain")), "a non-file item is never 'missing'")
        }
    }

    static func testFileIsMissingFalseWhenPresent() throws {
        try withStoreAndSourceDir(capMB: 0) { store, _, sourceDir in
            let fileURL = try makeFile("Here.txt", in: sourceDir)
            guard let (item, _) = store.makeFileItem(from: [fileURL], sourceApp: nil) else {
                throw TestFailure(message: "capture should succeed", file: #file, line: #line)
            }
            try expect(!store.fileIsMissing(item), "a freshly copied-in file should not be reported missing")
        }
    }

    // MARK: - deleteAssociatedFiles

    static func testDeleteRemovesCopiedFiles() throws {
        try withStoreAndSourceDir(capMB: 0) { store, storageDir, sourceDir in
            let fileURL = try makeFile("ToDelete.txt", in: sourceDir)
            guard let (item, _) = store.makeFileItem(from: [fileURL], sourceApp: nil) else {
                throw TestFailure(message: "capture should succeed", file: #file, line: #line)
            }

            let copiedDir = storageDir.appendingPathComponent("files/\(item.id.uuidString)")
            try expect(FileManager.default.fileExists(atPath: copiedDir.path), "precondition: the copy landed on disk")

            store.add(item)
            try expect(store.delete(item), "deleting an unlocked file item should succeed")
            // 5D: the delete moves the clip to the trash, which keeps its
            // payload so a restore is complete; the purge is what removes it.
            try expect(FileManager.default.fileExists(atPath: copiedDir.path), "files/<uuid>/ survives in the trash")
            try expectEqual(store.purgeFromTrash(ids: [item.id]), 1)
            try expect(!FileManager.default.fileExists(atPath: copiedDir.path), "files/<uuid>/ should be removed on purge")
        }
    }

    // MARK: - uniqueURL (Save All naming)

    static func testUniqueURLNoCollision() throws {
        try withTempDir { dir in
            let url = PasteController.uniqueURL(for: "Report.pdf", in: dir)
            try expectEqual(url.lastPathComponent, "Report.pdf", "no existing file means the name is used as-is")
        }
    }

    static func testUniqueURLCollision() throws {
        try withTempDir { dir in
            try makeFile("Report.pdf", in: dir)
            let second = PasteController.uniqueURL(for: "Report.pdf", in: dir)
            try expectEqual(second.lastPathComponent, "Report 2.pdf", "a collision should append ' 2' before the extension")

            try makeFile("Report 2.pdf", in: dir)
            let third = PasteController.uniqueURL(for: "Report.pdf", in: dir)
            try expectEqual(third.lastPathComponent, "Report 3.pdf", "each further collision increments the counter")
        }
    }

    static func testUniqueURLCollisionNoExtension() throws {
        try withTempDir { dir in
            try makeFile("README", in: dir)
            let url = PasteController.uniqueURL(for: "README", in: dir)
            try expectEqual(url.lastPathComponent, "README 2", "a name with no extension still gets a counter suffix")
        }
    }

    // MARK: - copyReplacingItem (5A-23)

    static func testCopyReplacingItemReplaces() throws {
        try withTempDir { dir in
            let source = try makeFile("source.txt", in: dir, contents: "new bytes")
            let destination = try makeFile("saved.txt", in: dir, contents: "existing bytes")

            try PasteController.copyReplacingItem(at: source, to: destination)

            try expectEqual(try String(contentsOf: destination, encoding: .utf8), "new bytes",
                            "the destination should hold the new content")
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
                .filter { $0.hasPrefix(".klip-save-") }
            try expect(leftovers.isEmpty, "no staging file should be left behind")
        }
    }

    /// The finding: the old code removed the destination first, so a failing
    /// copy left the user with neither file.
    static func testCopyReplacingItemFailureKeepsOriginal() throws {
        try withTempDir { dir in
            let missingSource = dir.appendingPathComponent("gone.txt")
            let destination = try makeFile("saved.txt", in: dir, contents: "existing bytes")

            var threw = false
            do {
                try PasteController.copyReplacingItem(at: missingSource, to: destination)
            } catch {
                threw = true
            }

            try expect(threw, "a missing source must surface as an error")
            try expectEqual(try String(contentsOf: destination, encoding: .utf8), "existing bytes",
                            "the pre-existing file must survive a failed save")
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
                .filter { $0.hasPrefix(".klip-save-") }
            try expect(leftovers.isEmpty, "no staging file should be left behind")
        }
    }

    static func testCopyReplacingItemFresh() throws {
        try withTempDir { dir in
            let source = try makeFile("source.txt", in: dir, contents: "new bytes")
            let destination = dir.appendingPathComponent("saved.txt")

            try PasteController.copyReplacingItem(at: source, to: destination)
            try expectEqual(try String(contentsOf: destination, encoding: .utf8), "new bytes")
        }
    }

    // MARK: - Small local helper

    private static func require<T>(_ value: T?, _ message: String, file: StaticString = #file, line: UInt = #line) throws -> T {
        guard let value else { throw TestFailure(message: message, file: file, line: line) }
        return value
    }
}
