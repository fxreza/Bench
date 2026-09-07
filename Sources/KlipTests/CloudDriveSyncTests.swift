import Foundation
import BenchTestKit
@testable import Klip

// Phase 4A: `CloudDriveSync` end to end — two real `ClipboardStore`s in two
// temp data directories, sharing one temp stand-in for iCloud Drive.
//
// Each store is rooted explicitly (`ClipboardStore(directory:)`), so both
// instances can live side by side; `Instance.run` flushes the store's
// debounced write after each step so the on-disk state is settled before the
// other Mac reads it. Pushes and pulls are driven through the synchronous
// entry points (`pushSynchronously`/`pullSynchronously`) so nothing depends on
// a timer, a watcher or a run loop.

enum CloudDriveSyncTests {
    static let tests: [(String, () throws -> Void)] = [
        ("addOnA_pushPullsThroughToB", testBasicPropagation),
        ("deviceFiles_haveTheDocumentedShape", testFileLayout),
        ("lockAndTagOnB_reachA", testFlagsAndTagsPropagate),
        ("deleteOnA_removesItOnB_andStaysDeleted", testDeletePropagates),
        ("evictionOnA_keepsItOnB_andNeverComesBack", testEvictionDoesNotPropagate),
        ("imageAsset_isCopiedThroughTheCloud", testImageAssetTravels),
        ("largeAttachment_isSkippedAndMarkedLocalOnly", testLargeAttachmentSkipped),
        ("corruptRemoteFile_isIgnoredWithAWarning", testCorruptRemoteFileIgnored),
        ("foldersAndFolderDeletes_travel", testFoldersTravel),
        ("syncDisabled_neverTouchesTheCloud", testDisabledSyncIsInert),
        ("removeThisDeviceFromCloud_deletesOnlyItsOwnDirectory", testRemoveOwnDevice),
        ("applyRemoteMerge_trimsToTheHistoryLimit", testMergeRespectsHistoryLimit),
        ("statusLine_readsTheWayItIsSpecified", testStatusLine),
    ]

    // MARK: - Harness

    /// One simulated Mac: its own data directory, store and sync service.
    final class Instance {
        let name: String
        let dataDir: URL
        let store: ClipboardStore
        let sync: CloudDriveSync

        init(name: String, dataDir: URL, cloudRoot: URL, maxAttachmentBytes: Int64? = nil) {
            self.name = name
            self.dataDir = dataDir
            self.store = ClipboardStore(directory: dataDir)
            self.sync = CloudDriveSync(
                store: store,
                cloudRoot: cloudRoot,
                deviceID: "device-\(name)",
                deviceName: "Mac \(name)",
                maxAttachmentBytes: maxAttachmentBytes
            )
        }

        /// Runs `body` against this instance and flushes its debounced save
        /// afterwards, so the other Mac never reads a half-written folder.
        @discardableResult
        func run<R>(_ body: (ClipboardStore, CloudDriveSync) throws -> R) rethrows -> R {
            defer { store.flushPendingSave() }
            return try body(store, sync)
        }

        func push() { run { _, sync in sync.pushSynchronously() } }
        func pull() { run { _, sync in sync.pullSynchronously() } }

        var items: [ClipboardItem] { run { store, _ in store.items } }
    }

    /// Two instances plus the shared fake iCloud Drive container.
    static func withTwoMacs(
        maxAttachmentBytes: Int64? = nil,
        _ body: (Instance, Instance, URL) throws -> Void
    ) throws {
        try withTempDir { root in
            let cloud = root.appendingPathComponent("cloud", isDirectory: true)
            let dirA = root.appendingPathComponent("data-a", isDirectory: true)
            let dirB = root.appendingPathComponent("data-b", isDirectory: true)
            for dir in [cloud, dirA, dirB] {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }

            let settings = SettingsManager.shared
            let previousEnabled = settings.syncEnabled
            let previousPush = settings.syncLastPush
            let previousPull = settings.syncLastPull
            defer {
                settings.syncEnabled = previousEnabled
                settings.syncLastPush = previousPush
                settings.syncLastPull = previousPull
            }
            settings.syncEnabled = true

            let a = Instance(name: "A", dataDir: dirA, cloudRoot: cloud, maxAttachmentBytes: maxAttachmentBytes)
            let b = Instance(name: "B", dataDir: dirB, cloudRoot: cloud, maxAttachmentBytes: maxAttachmentBytes)
            try body(a, b, cloud)
        }
    }

    static func klipRoot(_ cloud: URL) -> URL {
        cloud.appendingPathComponent("Klip", isDirectory: true)
    }

    static func deviceDir(_ cloud: URL, _ device: String) -> URL {
        klipRoot(cloud).appendingPathComponent("devices/\(device)", isDirectory: true)
    }

    static func text(_ value: String) -> ClipboardItem {
        ClipboardItem(type: .text, textContent: value)
    }

    // MARK: - Propagation

    static func testBasicPropagation() throws {
        try withTwoMacs { a, b, _ in
            a.run { store, _ in store.add(text("from A")) }
            a.push()

            try expect(b.items.isEmpty, "B should know nothing before it pulls")
            b.pull()

            try expectEqual(b.items.count, 1, "the clip should arrive on B")
            try expectEqual(b.items.first?.textContent, "from A")

            // And back the other way, without duplicating what B just adopted.
            b.run { store, _ in store.add(text("from B")) }
            b.push()
            a.pull()
            try expectEqual(a.items.count, 2, "A gets B's clip and keeps its own")
            try expectEqual(Set(a.items.compactMap { $0.textContent }), Set(["from A", "from B"]))

            // A second pull changes nothing — the merge is idempotent.
            let before = a.items
            a.pull()
            try expectEqual(a.items, before, "a repeat pull must be a no-op")
        }
    }

    static func testFileLayout() throws {
        try withTwoMacs { a, _, cloud in
            a.run { store, _ in store.add(text("layout")) }
            a.push()

            let dir = deviceDir(cloud, "device-A")
            for name in ["history.json", "folders.json", "tombstones.json"] {
                try expect(
                    FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path),
                    "\(name) should exist in this device's cloud directory"
                )
            }

            let data = try Data(contentsOf: dir.appendingPathComponent("history.json"))
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            try expectEqual(object?["version"] as? Int, 1, "history.json is a versioned wrapper")
            let device = object?["device"] as? [String: Any]
            try expectEqual(device?["id"] as? String, "device-A")
            try expectEqual(device?["name"] as? String, "Mac A")
            try expectNotNil(device?["lastPush"], "the device stamp carries its last push")
            try expectEqual((object?["items"] as? [Any])?.count, 1)

            let tombData = try Data(contentsOf: dir.appendingPathComponent("tombstones.json"))
            let tombs = try JSONSerialization.jsonObject(with: tombData) as? [String: Any]
            try expectNotNil(tombs?["deleted"], "tombstones.json has a deleted list")
            try expectNotNil(tombs?["deletedFolders"], "tombstones.json has a deletedFolders list")
        }
    }

    static func testFlagsAndTagsPropagate() throws {
        try withTwoMacs { a, b, _ in
            a.run { store, _ in store.add(text("shared")) }
            a.push()
            b.pull()

            b.run { store, _ in
                guard let item = store.items.first else { return }
                store.toggleLock(item)
                store.addTag("work", to: item)
            }
            b.push()
            a.pull()

            let item = try require(a.items.first, "A should still have the clip")
            try expect(item.isLocked, "a lock set on B reaches A")
            try expectEqual(item.tags, ["work"], "a tag set on B reaches A")
        }
    }

    static func testDeletePropagates() throws {
        try withTwoMacs { a, b, cloud in
            a.run { store, _ in store.add(text("doomed")) }
            a.push()
            b.pull()
            try expectEqual(b.items.count, 1, "B has the clip before the delete")

            a.run { store, _ in
                guard let item = store.items.first else { return }
                store.delete(item)
            }
            a.push()

            // The tombstone is published…
            let tombData = try Data(contentsOf: deviceDir(cloud, "device-A").appendingPathComponent("tombstones.json"))
            let tombs = try JSONSerialization.jsonObject(with: tombData) as? [String: Any]
            try expectEqual((tombs?["deleted"] as? [Any])?.count, 1, "an explicit delete writes a tombstone")

            b.pull()
            try expect(b.items.isEmpty, "the delete reaches B")

            // …and does not come back when B publishes its own view.
            b.push()
            a.pull()
            try expect(a.items.isEmpty, "the deleted clip must not resurrect on A")
            b.pull()
            try expect(b.items.isEmpty, "nor on B")
        }
    }

    static func testEvictionDoesNotPropagate() throws {
        try withTwoMacs { a, b, _ in
            let settings = SettingsManager.shared
            let previousLimit = settings.historyLimit
            settings.historyLimit = .k1
            defer { settings.historyLimit = previousLimit }

            let oldest = text("oldest clip")
            a.run { store, _ in
                store.add(oldest)
            }
            a.push()
            b.pull()
            try expectEqual(b.items.count, 1, "B has the clip before A evicts it")

            // Push A over the 1,000-item cap so the oldest clip is evicted.
            a.run { store, _ in
                for index in 0..<1000 {
                    store.add(text("filler \(index)"))
                }
            }
            try expect(
                a.run { store, _ in !store.items.contains { $0.id == oldest.id } },
                "the oldest clip should have been evicted by the cap"
            )
            try expect(
                a.run { store, _ in store.syncIgnoredIDs[oldest.id] != nil },
                "eviction records a sync-ignore entry"
            )
            a.push()

            // From here on B (and A) keep everything, so the only thing that can
            // remove the clip is the sync rules — not another cap trim.
            settings.historyLimit = .unlimited

            b.pull()
            try expect(
                b.items.contains { $0.id == oldest.id },
                "an eviction on A must not delete the clip on B"
            )

            b.push()
            a.pull()
            try expect(
                a.run { store, _ in !store.items.contains { $0.id == oldest.id } },
                "an evicted clip must never come back from another Mac"
            )
        }
    }

    // MARK: - Assets

    static func testImageAssetTravels() throws {
        try withTwoMacs { a, b, cloud in
            let pixels = Data(repeating: 0x42, count: 2048)
            var filename = ""
            a.run { store, _ in
                filename = store.saveImage(pixels) ?? ""
                store.add(ClipboardItem.image(filename: filename))
            }
            try expect(!filename.isEmpty, "the image should have been written locally")
            a.push()

            try expect(
                FileManager.default.fileExists(
                    atPath: klipRoot(cloud).appendingPathComponent("images/\(filename)").path
                ),
                "the image should be mirrored into the cloud images directory"
            )

            b.pull()
            let local = b.dataDir.appendingPathComponent("images/\(filename)")
            try expect(
                FileManager.default.fileExists(atPath: local.path),
                "B should have downloaded the image for the clip it just adopted"
            )
            try expectEqual(try Data(contentsOf: local), pixels, "and the bytes should match")
        }
    }

    static func testLargeAttachmentSkipped() throws {
        // 1 MB cap, 2 MB payload.
        try withTwoMacs(maxAttachmentBytes: 1024 * 1024) { a, b, cloud in
            var itemID = UUID()
            try a.run { store, _ in
                var attachment = FileAttachment(originalName: "huge.bin", uti: "public.data", byteSize: 2 * 1024 * 1024)
                var item = ClipboardItem.file(attachment: attachment)
                itemID = item.id
                let dir = a.dataDir.appendingPathComponent("files/\(itemID.uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try Data(repeating: 0x7, count: 2 * 1024 * 1024)
                    .write(to: dir.appendingPathComponent("huge.bin"))
                attachment.storedRelativePath = "files/\(itemID.uuidString)/huge.bin"
                item.fileAttachment = attachment
                store.add(item)
            }
            a.push()

            try expect(
                !FileManager.default.fileExists(
                    atPath: klipRoot(cloud).appendingPathComponent("files/\(itemID.uuidString)").path
                ),
                "a payload over the cap must not be copied to iCloud Drive"
            )
            try expect(
                a.run { store, _ in store.items.first?.fileAttachment?.syncSkippedLarge == true },
                "the clip is marked local-only"
            )

            b.pull()
            try expectEqual(b.items.count, 1, "the clip itself still syncs")
            try expect(
                b.items.first?.fileAttachment?.syncSkippedLarge == true,
                "and arrives flagged as local-only on the other Mac"
            )
        }
    }

    // MARK: - Robustness

    static func testCorruptRemoteFileIgnored() throws {
        try withTwoMacs { a, b, cloud in
            b.run { store, _ in store.add(text("from B")) }
            b.push()
            a.pull()
            try expectEqual(a.items.count, 1, "A adopted B's clip while the file was readable")

            // Now scribble over B's snapshot.
            let history = deviceDir(cloud, "device-B").appendingPathComponent("history.json")
            try Data("{ not json at all".utf8).write(to: history)

            let before = a.items
            a.pull()
            try expectEqual(a.items, before, "a corrupt remote file must change nothing")
            let error = try require(a.sync.lastError, "the corrupt file should be reported")
            try expect(
                error.contains("Ignoring unreadable"),
                "the warning should name the problem, got: \(error)"
            )

            // And sync keeps working once the other Mac republishes.
            b.push()
            a.pull()
            try expectEqual(a.items.count, 1, "sync recovers after the file is rewritten")
        }
    }

    static func testFoldersTravel() throws {
        try withTwoMacs { a, b, _ in
            var folderID = UUID()
            a.run { store, _ in
                let folder = store.createFolder(name: "Snippets")
                folderID = folder.id
                store.add(text("filed clip"))
                if let item = store.items.first {
                    store.moveItems(ids: [item.id], toFolder: folderID)
                }
            }
            a.push()
            b.pull()

            try expectEqual(b.run { store, _ in store.folders.map { $0.name } }, ["Snippets"], "the folder travels")
            try expectEqual(b.items.first?.folderID, folderID, "so does the membership")
            try expect(b.items.first?.isLocked == true, "filing locks the clip, and the lock travels")

            // A rename on B wins on A (newer `updatedAt`).
            b.run { store, _ in store.renameFolder(id: folderID, to: "Renamed") }
            b.push()
            a.pull()
            try expectEqual(a.run { store, _ in store.folders.map { $0.name } }, ["Renamed"], "the rename reaches A")

            // Deleting the folder on B orphans the clip on A without deleting it.
            b.run { store, _ in store.deleteFolder(id: folderID, mode: .moveItemsOut) }
            b.push()
            a.pull()
            try expect(a.run { store, _ in store.folders.isEmpty }, "the folder delete reaches A")
            let item = try require(a.items.first, "the clip itself survives its folder")
            try expectNil(item.folderID, "the membership is dropped")
            try expect(item.isLocked, "the lock survives")
        }
    }

    static func testDisabledSyncIsInert() throws {
        try withTwoMacs { a, _, cloud in
            let settings = SettingsManager.shared
            settings.syncEnabled = false
            a.run { _, sync in sync.startIfEnabled() }
            try expect(!a.sync.isActive, "sync must not run while the setting is off")

            a.run { store, _ in store.add(text("private")) }
            try expect(
                !FileManager.default.fileExists(atPath: klipRoot(cloud).path),
                "nothing at all should be written to iCloud Drive while sync is off"
            )

            // Turning it back on and pushing explicitly still works.
            settings.syncEnabled = true
            a.push()
            try expect(
                FileManager.default.fileExists(
                    atPath: deviceDir(cloud, "device-A").appendingPathComponent("history.json").path
                ),
                "a push after enabling writes this device's snapshot"
            )
        }
    }

    static func testRemoveOwnDevice() throws {
        try withTwoMacs { a, b, cloud in
            a.run { store, _ in store.add(text("from A")) }
            a.push()
            b.run { store, _ in store.add(text("from B")) }
            b.push()

            a.run { _, sync in sync.removeThisDeviceFromCloud() }
            // `removeThisDeviceFromCloud` hands the delete to its I/O queue.
            waitUntil { !FileManager.default.fileExists(atPath: deviceDir(cloud, "device-A").path) }

            try expect(
                !FileManager.default.fileExists(atPath: deviceDir(cloud, "device-A").path),
                "this device's directory is gone"
            )
            try expect(
                FileManager.default.fileExists(atPath: deviceDir(cloud, "device-B").path),
                "the other Mac's snapshot is untouched"
            )
        }
    }

    // MARK: - Status line

    static func testStatusLine() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try expectEqual(
            SyncStatusLine.text(enabled: false, available: true, lastPush: nil, lastPull: nil, devices: [], now: now),
            "Sync is off."
        )
        try expectEqual(
            SyncStatusLine.text(enabled: true, available: false, lastPush: nil, lastPull: nil, devices: [], now: now),
            "iCloud Drive is not available on this Mac."
        )
        try expectEqual(
            SyncStatusLine.text(
                enabled: true,
                available: true,
                lastPush: now.addingTimeInterval(-120),
                lastPull: now.addingTimeInterval(-60),
                devices: ["MacBook", "Studio"],
                now: now
            ),
            "Last push 2 min ago · last pull 1 min ago · 2 devices: MacBook, Studio"
        )
        try expectEqual(
            SyncStatusLine.text(enabled: true, available: true, lastPush: nil, lastPull: nil, devices: [], now: now),
            "Not pushed yet · not pulled yet · no other devices yet"
        )
    }

    /// A pull must not leave the store above the user's history limit, and the
    /// clips it trims must land in the sync-ignore list rather than coming
    /// straight back on the next pull.
    static func testMergeRespectsHistoryLimit() throws {
        try ClipboardStoreTests.withStore(limit: .k1) { store, _ in
            let base = Date(timeIntervalSince1970: 1_700_000_000)
            var merged: [ClipboardItem] = []
            for index in 0..<1005 {
                merged.append(ClipboardItem(
                    type: .text,
                    timestamp: base.addingTimeInterval(TimeInterval(-index)),
                    textContent: "pulled \(index)"
                ))
            }
            let oldest = merged.suffix(5).map { $0.id }

            store.applyRemoteMerge(SyncMerge.Result(
                items: merged,
                folders: [],
                deleted: [],
                deletedFolders: [],
                arrivedItemIDs: merged.map { $0.id },
                removedItems: [],
                changed: true
            ))

            try expectEqual(store.items.count, 1000, "the pulled history is trimmed to this Mac's limit")
            for id in oldest {
                try expect(store.syncIgnoredIDs[id] != nil, "a trimmed clip is remembered as evicted, not deleted")
            }
        }
    }

    // MARK: - Small helpers

    static func require<T>(_ value: T?, _ message: String, file: StaticString = #file, line: UInt = #line) throws -> T {
        guard let value = value else {
            throw TestFailure(message: message, file: file, line: line)
        }
        return value
    }

    /// Spins the main run loop until `condition` holds (or 2 s pass) — for the
    /// few entry points that hand their work to a background queue.
    static func waitUntil(timeout: TimeInterval = 2.0, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }
}
