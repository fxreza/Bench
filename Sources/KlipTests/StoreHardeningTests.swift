import Foundation
import BenchTestKit
@testable import Klip

// Task 5C, pass A — regressions for the store/persistence/capture findings in
// `docs/plan/review-5A.md`:
//
//   5A-02  eviction bookkeeping is batched, and a store that is over its cap at
//          launch is trimmed once instead of inside the next `add()`
//   5A-03  sync-ignore bookkeeping is a no-op when sync was never enabled
//   5A-05  one undecodable record no longer costs the whole history
//   5A-08  file capture fingerprints before copying; orphaned assets are swept
//   5A-09  same-basename files in one copy are uniquified, not dropped
//   5A-13  the save debounce has a maximum delay
//   5A-18  a merge never deletes an asset a surviving item still points at
//   5A-28  `textChunk` falls back to the inline preview when the file is gone
//   5A-06  `applyRemoteMerge` never drops a locked local clip
//
// Every test runs against a throwaway data directory, reusing
// `ClipboardStoreTests.withStore`.

enum StoreHardeningTests {
    static let tests: [(String, () throws -> Void)] = [
        ("load_oneBadRecordAmongThree_keepsTheGoodOnes", testPartialDecodeKeepsGoodRecords),
        ("load_oneBadFolderRecord_keepsTheGoodOnes", testPartialFolderDecode),
        ("load_overCapHistory_isTrimmedOnceAtLaunch", testLaunchTrim),
        ("add_toAnOverCapStore_staysUnderTwentyMilliseconds", testAddOverCapIsFast),
        ("evictions_withSyncNeverEnabled_writeNoSyncIgnoreFile", testSyncIgnoreSkippedWhenSyncOff),
        ("evictions_withSyncEnabled_stillRecordAndPersist", testSyncIgnoreRecordedWhenSyncOn),
        ("saveDebounce_burstFasterThanTheWindow_stillReachesDisk", testDebounceMaxDelay),
        ("fileCapture_planFingerprintsWithoutCopyingAnything", testPlanDoesNotCopy),
        ("fileCapture_repeatCapture_leavesNoOrphanDirectory", testRepeatCaptureLeavesNoOrphan),
        ("fileCapture_sameBasenameTwice_keepsBothFiles", testSameBasenameFilesBothKept),
        ("launch_sweepsOrphanedAssets", testOrphanSweep),
        ("launch_afterAPartialDecode_doesNotSweep", testNoSweepAfterPartialDecode),
        ("textChunk_missingBackingFile_fallsBackToThePreview", testTextChunkFallback),
        ("applyRemoteMerge_neverDropsALockedClip", testMergeKeepsLockedClip),
        ("applyRemoteMerge_keepsAssetsASurvivorStillPointsAt", testMergeKeepsSharedAsset),
    ]

    // MARK: - Helpers

    static func item(_ text: String, at seconds: TimeInterval) -> ClipboardItem {
        ClipboardItem(type: .text, timestamp: Date(timeIntervalSince1970: seconds), textContent: text)
    }

    /// Encodes `items` into the v2 wrapper, optionally splicing in raw JSON
    /// objects (used to plant an undecodable record).
    static func writeHistory(_ items: [ClipboardItem], extra: [(index: Int, object: [String: Any])] = [], to dir: URL) throws {
        let data = try JSONEncoder().encode(items)
        var objects = (try JSONSerialization.jsonObject(with: data) as? [Any]) ?? []
        for entry in extra.sorted(by: { $0.index > $1.index }) {
            objects.insert(entry.object, at: min(entry.index, objects.count))
        }
        let wrapper: [String: Any] = ["version": 2, "items": objects]
        let encoded = try JSONSerialization.data(withJSONObject: wrapper)
        try encoded.write(to: dir.appendingPathComponent("history.json"))
    }

    /// Runs with sync settings forced off (and restored), so the sync-ignore
    /// gate is exercised deterministically whatever ran before.
    static func withSyncSetting<R>(enabled: Bool, everPushed: Bool = false, _ body: () throws -> R) rethrows -> R {
        let settings = SettingsManager.shared
        let previousEnabled = settings.syncEnabled
        let previousPush = settings.syncLastPush
        let previousPull = settings.syncLastPull
        settings.syncEnabled = enabled
        settings.syncLastPush = everPushed ? Date() : nil
        settings.syncLastPull = nil
        defer {
            settings.syncEnabled = previousEnabled
            settings.syncLastPush = previousPush
            settings.syncLastPull = previousPull
        }
        return try body()
    }

    static func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 3.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(20_000)
        }
        return condition()
    }

    // MARK: - 5A-05 per-record decode

    static func testPartialDecodeKeepsGoodRecords() throws {
        let good = [item("one", at: 3), item("two", at: 2), item("three", at: 1)]
        try ClipboardStoreTests.withStore(seed: { dir in
            try writeHistory(good, extra: [(1, ["id": "not-a-uuid", "type": "text", "timestamp": 0])], to: dir)
        }) { store, dir in
            try expectEqual(store.items.count, 3, "the three decodable records must survive one bad one")
            try expectEqual(
                Set(store.items.compactMap { $0.textContent }),
                Set(["one", "two", "three"]),
                "every good record is kept"
            )

            let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            let quarantined = contents.filter { $0.hasPrefix("history.corrupt-") }
            try expectEqual(quarantined.count, 1, "a copy of the raw file is kept once for inspection")
            try expect(
                FileManager.default.fileExists(atPath: dir.appendingPathComponent("history.json").path),
                "the original stays in place — the good records are re-saved over it"
            )

            store.flushPendingSave()
            let onDisk = try ClipboardStoreTests.readHistoryFile(dir)
            try expectEqual(onDisk.items.count, 3, "the rewritten file holds only the salvaged records")
        }
    }

    static func testPartialFolderDecode() throws {
        try ClipboardStoreTests.withStore(seed: { dir in
            let folders = [Folder(name: "Work", sortIndex: 0), Folder(name: "Home", sortIndex: 1)]
            let data = try JSONEncoder().encode(folders)
            var objects = (try JSONSerialization.jsonObject(with: data) as? [Any]) ?? []
            objects.insert(["id": "nope", "name": 42], at: 1)
            let wrapper: [String: Any] = ["version": 1, "folders": objects]
            try JSONSerialization.data(withJSONObject: wrapper)
                .write(to: dir.appendingPathComponent("folders.json"))
        }) { store, _ in
            try expectEqual(store.folders.map { $0.name }, ["Work", "Home"], "the good folders load")
        }
    }

    // MARK: - 5A-02 eviction cost

    static func testLaunchTrim() throws {
        let overCap = (0..<1200).map { item("clip \($0)", at: TimeInterval(2_000_000 - $0)) }
        try withSyncSetting(enabled: false) {
            try ClipboardStoreTests.withStore(limit: .k1, seed: { dir in
                try writeHistory(overCap, to: dir)
            }) { store, _ in
                try expectEqual(store.items.count, 1000, "a store over its cap at launch is trimmed once, at launch")
                try expectEqual(store.items.first?.textContent, "clip 0", "the newest clips are the ones kept")
            }
        }
    }

    static func testAddOverCapIsFast() throws {
        let overCap = (0..<10_000).map { item("clip \($0)", at: TimeInterval(2_000_000 - $0)) }
        try withSyncSetting(enabled: true) {
            try ClipboardStoreTests.withStore(limit: .k1, seed: { dir in
                try writeHistory(overCap, to: dir)
            }) { store, _ in
                // Launch already trimmed to the cap; a copy now evicts exactly
                // one clip and must not rewrite `sync-ignore.json` inline.
                let start = Date()
                store.add(item("just copied", at: 3_000_000))
                let elapsed = Date().timeIntervalSince(start) * 1000
                print("[measure] 5A-02 add() on a 10,000-item store over cap: \(String(format: "%.2f", elapsed)) ms")
                try expect(elapsed < 20, "an add at the cap must stay under 20 ms on main (was \(elapsed) ms)")
                try expectEqual(store.items.count, 1000, "the cap still holds")
                try expectEqual(store.items.first?.textContent, "just copied", "the new clip is kept")
            }
        }
    }

    // MARK: - 5A-03 sync-ignore gate

    static func testSyncIgnoreSkippedWhenSyncOff() throws {
        try withSyncSetting(enabled: false) {
            try ClipboardStoreTests.withStore(limit: .k1) { store, dir in
                for index in 0..<1_010 {
                    store.add(item("clip \(index)", at: TimeInterval(1_000_000 + index)))
                }
                store.flushPendingSave()
                try expect(store.syncIgnoredIDs.isEmpty, "no sync-ignore bookkeeping when sync was never enabled")
                try expect(
                    !FileManager.default.fileExists(atPath: dir.appendingPathComponent("sync-ignore.json").path),
                    "and no sync-ignore.json is written"
                )
            }
        }
    }

    static func testSyncIgnoreRecordedWhenSyncOn() throws {
        try withSyncSetting(enabled: true) {
            try ClipboardStoreTests.withStore(limit: .k1) { store, dir in
                for index in 0..<1_005 {
                    store.add(item("clip \(index)", at: TimeInterval(1_000_000 + index)))
                }
                store.flushPendingSave()
                try expectEqual(store.syncIgnoredIDs.count, 5, "the five evicted clips are remembered")
                try expect(
                    FileManager.default.fileExists(atPath: dir.appendingPathComponent("sync-ignore.json").path),
                    "the debounced write lands once the queue is flushed"
                )
            }
        }
    }

    // MARK: - 5A-13 debounce starvation

    static func testDebounceMaxDelay() throws {
        try withSyncSetting(enabled: false) {
            try ClipboardStoreTests.withStore { store, dir in
                // A mutation every 10 ms is faster than the 300 ms trailing
                // debounce; without a maximum delay nothing ever reached disk.
                let start = Date()
                var index = 0
                while Date().timeIntervalSince(start) < 3.0 {
                    store.add(item("burst \(index)", at: TimeInterval(1_000_000 + index)))
                    index += 1
                    usleep(10_000)
                }

                let url = dir.appendingPathComponent("history.json")
                try expect(FileManager.default.fileExists(atPath: url.path), "the burst must not starve the write")
                let onDisk = try ClipboardStoreTests.readHistoryFile(dir)
                print("[measure] 5A-13 clips on disk mid-burst: \(onDisk.items.count) of \(index) added")
                try expect(
                    onDisk.items.count >= 50,
                    "the write should land ~2 s in, not after the burst (\(onDisk.items.count) items on disk)"
                )
            }
        }
    }

    // MARK: - 5A-08 / 5A-09 file capture

    static func makeFile(_ url: URL, contents: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    static func testPlanDoesNotCopy() throws {
        try ClipboardStoreTests.withStore { store, dir in
            let source = dir.appendingPathComponent("src/note.txt")
            try makeFile(source, contents: "hello")

            let first = try require(store.planFileCapture(from: [source]), "planning should succeed")
            let second = try require(store.planFileCapture(from: [source]), "planning should succeed twice")
            try expectEqual(first.fingerprint, second.fingerprint, "the same files fingerprint the same")

            let filesDir = dir.appendingPathComponent("files")
            let contents = try FileManager.default.contentsOfDirectory(atPath: filesDir.path)
            try expect(contents.isEmpty, "planning must not copy anything into files/")
        }
    }

    static func testRepeatCaptureLeavesNoOrphan() throws {
        try ClipboardStoreTests.withStore { store, dir in
            let source = dir.appendingPathComponent("src/note.txt")
            try makeFile(source, contents: "hello")

            let plan = try require(store.planFileCapture(from: [source]), "planning should succeed")
            _ = try require(store.makeFileItem(from: plan, sourceApp: nil), "the first capture stores the file")

            // The repeat capture is dropped on the fingerprint, before any copy.
            let repeatPlan = try require(store.planFileCapture(from: [source]), "planning should succeed")
            try expectEqual(repeatPlan.fingerprint, plan.fingerprint, "a repeat ⌘C fingerprints identically")

            let filesDir = dir.appendingPathComponent("files")
            let contents = try FileManager.default.contentsOfDirectory(atPath: filesDir.path)
            try expectEqual(contents.count, 1, "a deduped repeat capture leaves no second copy behind")
        }
    }

    static func testSameBasenameFilesBothKept() throws {
        try ClipboardStoreTests.withStore { store, dir in
            let first = dir.appendingPathComponent("a/report.pdf")
            let second = dir.appendingPathComponent("b/report.pdf")
            try makeFile(first, contents: "first")
            try makeFile(second, contents: "second")

            let capture = try require(store.makeFileItem(from: [first, second], sourceApp: "Finder"), "capture should succeed")
            let attachment = try require(capture.item.fileAttachment, "the clip carries an attachment")
            try expectNotNil(attachment.storedRelativePath, "both files must be copied in, not degraded to a reference")
            try expectEqual(attachment.originalName, "report.pdf", "the first keeps its name")
            try expectEqual(attachment.additionalNames, ["report (2).pdf"], "the second is uniquified")

            let urls = store.fileURLs(for: capture.item)
            try expectEqual(urls.count, 2, "both files resolve from the clip")
            let bodies = Set(urls.compactMap { try? String(contentsOf: $0, encoding: .utf8) })
            try expectEqual(bodies, Set(["first", "second"]), "and both still hold their own bytes")
        }
    }

    // MARK: - 5A-08 orphan sweep

    static func testOrphanSweep() throws {
        try ClipboardStoreTests.withStore(seed: { dir in
            let images = dir.appendingPathComponent("images", isDirectory: true)
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            let orphan = images.appendingPathComponent("orphan.png")
            try Data("not really a png".utf8).write(to: orphan)
            // Older than the sweep's one-minute safety window.
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-3600)],
                ofItemAtPath: orphan.path
            )
        }) { _, dir in
            let orphan = dir.appendingPathComponent("images/orphan.png")
            let swept = waitUntil { !FileManager.default.fileExists(atPath: orphan.path) }
            try expect(swept, "an asset no item references is swept at launch")
        }
    }

    static func testNoSweepAfterPartialDecode() throws {
        let good = [item("one", at: 3)]
        try ClipboardStoreTests.withStore(seed: { dir in
            try writeHistory(good, extra: [(1, ["id": "not-a-uuid", "type": "text", "timestamp": 0])], to: dir)
            let images = dir.appendingPathComponent("images", isDirectory: true)
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            let orphan = images.appendingPathComponent("maybe-orphan.png")
            try Data("bytes".utf8).write(to: orphan)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-3600)],
                ofItemAtPath: orphan.path
            )
        }) { _, dir in
            let candidate = dir.appendingPathComponent("images/maybe-orphan.png")
            usleep(300_000)
            try expect(
                FileManager.default.fileExists(atPath: candidate.path),
                "after a partial decode the store does not know all its assets, so it must not sweep"
            )
        }
    }

    // MARK: - 5A-28 chunked preview fallback

    static func testTextChunkFallback() throws {
        try ClipboardStoreTests.withStore { store, _ in
            let clip = ClipboardItem.largeText(preview: "the inline preview", filename: "gone.txt", sourceApp: nil)
            let chunk = try require(store.textChunk(for: clip, charCount: 2000), "a missing backing file must not blank the pane")
            try expectEqual(chunk.text, "the inline preview", "the preview stands in for the missing file")
        }
    }

    // MARK: - 5A-06 / 5A-18 merge application

    static func testMergeKeepsLockedClip() throws {
        try ClipboardStoreTests.withStore { store, dir in
            let filename = try require(store.saveImage(Data("png".utf8)), "the image should be saved")
            var locked = ClipboardItem.image(filename: filename)
            locked.isLocked = true
            store.add(locked)

            // A merge that decided to drop the locked clip (a remote tombstone
            // that got past `SyncMerge`, a hand-built result, a future rule).
            store.applyRemoteMerge(SyncMerge.Result(
                items: [],
                folders: [],
                deleted: [SyncTombstone(id: locked.id, deletedAt: Date())],
                deletedFolders: [],
                arrivedItemIDs: [],
                removedItems: [locked],
                changed: true
            ))

            try expectEqual(store.items.count, 1, "a locked clip is never removed by a merge")
            try expectEqual(store.items.first?.id, locked.id, "and it is the same clip")
            try expect(
                FileManager.default.fileExists(atPath: dir.appendingPathComponent("images/\(filename)").path),
                "its bytes stay too"
            )
        }
    }

    static func testMergeKeepsSharedAsset() throws {
        try ClipboardStoreTests.withStore { store, dir in
            let filename = try require(store.saveImage(Data("png".utf8)), "the image should be saved")
            let survivor = ClipboardItem.image(filename: filename)
            let duplicate = ClipboardItem.image(filename: filename)

            store.applyRemoteMerge(SyncMerge.Result(
                items: [survivor],
                folders: [],
                deleted: [],
                deletedFolders: [],
                arrivedItemIDs: [],
                removedItems: [duplicate],
                changed: true
            ))

            try expectEqual(store.items.count, 1, "the fold leaves one record")
            try expect(
                FileManager.default.fileExists(atPath: dir.appendingPathComponent("images/\(filename)").path),
                "the survivor's own file must not be deleted with the duplicate"
            )
        }
    }

    static func require<T>(_ value: T?, _ message: String, file: StaticString = #file, line: UInt = #line) throws -> T {
        guard let value = value else {
            throw TestFailure(message: message, file: file, line: line)
        }
        return value
    }
}
