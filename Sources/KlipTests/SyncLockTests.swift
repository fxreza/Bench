import Foundation
import BenchTestKit
@testable import Klip

// Task 5C, pass A — sync-side regressions:
//
//   5A-06 / 4B #3  a remote tombstone can never delete a locked clip
//   5A-17          two Macs copying the same file converge on one record
//   4B #10         push/pull are inert (and create nothing) when sync is off or
//                  iCloud Drive is unavailable
//   4B #7          a snapshot written by a newer Klip is ignored, not
//                  half-decoded
//
// The pure rules run straight through `SyncMerge`; the end-to-end cases reuse
// `CloudDriveSyncTests`' two-store + fake-cloud-root harness.

enum SyncLockTests {
    static let tests: [(String, () throws -> Void)] = [
        ("tombstone_afterALock_neverDeletes", testLockThenRemoteDelete),
        ("lock_afterATombstone_keepsTheClip", testRemoteDeleteThenLock),
        ("unlock_afterAnOldTombstone_keepsTheClip", testUnlockAfterOldTombstone),
        ("delete_afterAnUnlock_deletes", testDeleteAfterUnlock),
        ("lockedClipDeletedOnTheOtherMac_survivesEndToEnd", testLockSurvivesRemoteDelete),
        ("sameFileOnTwoMacs_foldsIntoOneRecord", testFileDedupeAcrossDevices),
        ("push_withMissingCloudRoot_createsNothing", testPushWithMissingCloudRoot),
        ("pull_withMissingCloudRoot_createsNothing", testPullWithMissingCloudRoot),
        ("push_withSyncDisabled_createsNothing", testPushWithSyncDisabled),
        ("remoteSnapshot_fromANewerKlip_isIgnored", testNewerSchemaIgnored),
    ]

    // MARK: - Helpers

    static let base = Date(timeIntervalSince1970: 1_700_000_000)
    static func at(_ offset: TimeInterval) -> Date { base.addingTimeInterval(offset) }

    static func clip(id: UUID = UUID(), text: String, updatedAt: Date, isLocked: Bool = false) -> ClipboardItem {
        var item = ClipboardItem(type: .text, timestamp: base, textContent: text, updatedAt: updatedAt)
        item.isLocked = isLocked
        return item
    }

    /// One remote device that only publishes a tombstone (it deleted the clip,
    /// so its own history no longer carries it).
    static func deletingRemote(_ id: UUID, at date: Date) -> SyncDeviceSnapshot {
        SyncDeviceSnapshot(
            deviceID: "device-B",
            deviceName: "Mac B",
            lastPush: date,
            items: [],
            deleted: [SyncTombstone(id: id, deletedAt: date)]
        )
    }

    // MARK: - 5A-06 / 4B #3, the four orderings

    /// A locks at T+10, B deletes at T+20 (it never saw the lock). The lock wins.
    static func testLockThenRemoteDelete() throws {
        let local = clip(text: "protected", updatedAt: at(10), isLocked: true)
        let result = SyncMerge.merge(SyncMerge.Input(
            localItems: [local],
            remotes: [deletingRemote(local.id, at: at(20))],
            now: at(30)
        ))
        try expectEqual(result.items.count, 1, "a tombstone must not delete a locked clip")
        try expect(result.items.first?.isLocked == true, "and it stays locked")
        try expect(result.removedItems.isEmpty, "nothing is removed, so no assets are deleted either")
        try expectEqual(result.deleted.count, 1, "the tombstone is kept (inert) and still travels")
    }

    /// B deletes at T+10, A locks at T+20. The later lock wins on recency too —
    /// this is the ordering that already worked, kept as a regression.
    static func testRemoteDeleteThenLock() throws {
        let local = clip(text: "protected", updatedAt: at(20), isLocked: true)
        let result = SyncMerge.merge(SyncMerge.Input(
            localItems: [local],
            remotes: [deletingRemote(local.id, at: at(10))],
            now: at(30)
        ))
        try expectEqual(result.items.count, 1, "an older tombstone loses to a later lock")
    }

    /// A tombstone from before the unlock stays inert afterwards: unlocking
    /// bumps `updatedAt` past it.
    static func testUnlockAfterOldTombstone() throws {
        let local = clip(text: "was locked", updatedAt: at(30), isLocked: false)
        let result = SyncMerge.merge(SyncMerge.Input(
            localItems: [local],
            remotes: [deletingRemote(local.id, at: at(20))],
            now: at(40)
        ))
        try expectEqual(result.items.count, 1, "an unlock outranks the tombstone that predates it")
    }

    /// Unlock at T+30, then a delete on the other Mac at T+40: that one deletes.
    static func testDeleteAfterUnlock() throws {
        let local = clip(text: "was locked", updatedAt: at(30), isLocked: false)
        let result = SyncMerge.merge(SyncMerge.Input(
            localItems: [local],
            remotes: [deletingRemote(local.id, at: at(40))],
            now: at(50)
        ))
        try expect(result.items.isEmpty, "a delete made after the unlock still deletes")
        try expectEqual(result.removedItems.count, 1, "and the local record is reported as removed")
    }

    /// The 4B probe scenario 3, end to end: two stores, one fake cloud root.
    static func testLockSurvivesRemoteDelete() throws {
        try CloudDriveSyncTests.withTwoMacs { a, b, _ in
            a.run { store, _ in store.add(ClipboardItem(type: .text, textContent: "shared clip")) }
            a.push()
            b.pull()
            try expectEqual(b.items.count, 1, "the clip reaches B")

            // A locks it; B (which has not pulled the lock) deletes it later.
            a.run { store, _ in
                if let item = store.items.first { store.toggleLock(item) }
            }
            let target = try require(b.items.first, "B has the clip")
            b.run { store, _ in store.delete(target) }

            a.push()
            b.push()
            a.pull()
            b.pull()

            try expectEqual(a.items.count, 1, "the locked clip survives on A")
            try expect(a.items.first?.isLocked == true, "and it is still locked")
            try expectEqual(b.items.count, 1, "and A's republish gives it back to B")
        }
    }

    // MARK: - 5A-17 file dedupe

    static func testFileDedupeAcrossDevices() throws {
        let attachment = FileAttachment(
            originalName: "notes.pdf",
            additionalNames: [],
            storedRelativePath: "files/\(UUID().uuidString)",
            referencePath: nil,
            bookmark: nil,
            uti: "com.adobe.pdf",
            byteSize: 4096
        )
        var remoteAttachment = attachment
        remoteAttachment.storedRelativePath = "files/\(UUID().uuidString)"

        let local = ClipboardItem(type: .file, timestamp: at(0), kind: .file, fileAttachment: attachment)
        let remote = ClipboardItem(type: .file, timestamp: at(5), kind: .file, fileAttachment: remoteAttachment)

        let result = SyncMerge.merge(SyncMerge.Input(
            localItems: [local],
            remotes: [SyncDeviceSnapshot(deviceID: "device-B", deviceName: "Mac B", items: [remote])],
            now: at(10)
        ))
        try expectEqual(result.items.count, 1, "the same file copied on two Macs is one clip, not two")
        try expectEqual(result.items.first?.id, local.id, "the older record survives, as the fold rule says")
    }

    // MARK: - 4B #10 availability gate

    /// A `CloudDriveSync` whose container does not exist, with sync switched on.
    static func withMissingRoot(_ body: (CloudDriveSync, URL) throws -> Void) throws {
        try withTempDir { root in
            let dataDir = root.appendingPathComponent("data", isDirectory: true)
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            let missing = root.appendingPathComponent("no-such-cloud", isDirectory: true)

            let settings = SettingsManager.shared
            let previous = settings.syncEnabled
            settings.syncEnabled = true
            defer { settings.syncEnabled = previous }

            let store = ClipboardStore(directory: dataDir)
            let sync = CloudDriveSync(store: store, cloudRoot: missing, deviceID: "device-X", deviceName: "Mac X")
            defer { store.flushPendingSave() }
            try body(sync, missing)
        }
    }

    static func testPushWithMissingCloudRoot() throws {
        try withMissingRoot { sync, missing in
            try expect(!sync.isAvailable, "the container is not there")
            try expect(!sync.pushSynchronously(), "the quit-time push must report failure, not proceed")
            try expect(
                !FileManager.default.fileExists(atPath: missing.path),
                "and it must never create the iCloud Drive container itself"
            )
            try expect(!sync.isAvailable, "still unavailable afterwards")
        }
    }

    static func testPullWithMissingCloudRoot() throws {
        try withMissingRoot { sync, missing in
            try expect(!sync.pullSynchronously(), "a pull with no container does nothing")
            try expect(
                !FileManager.default.fileExists(atPath: missing.path),
                "and creates nothing"
            )
        }
    }

    static func testPushWithSyncDisabled() throws {
        try withTempDir { root in
            let dataDir = root.appendingPathComponent("data", isDirectory: true)
            let cloud = root.appendingPathComponent("cloud", isDirectory: true)
            for dir in [dataDir, cloud] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }

            let settings = SettingsManager.shared
            let previous = settings.syncEnabled
            settings.syncEnabled = false
            defer { settings.syncEnabled = previous }

            let store = ClipboardStore(directory: dataDir)
            let sync = CloudDriveSync(store: store, cloudRoot: cloud, deviceID: "device-X", deviceName: "Mac X")
            defer { store.flushPendingSave() }

            store.add(ClipboardItem(type: .text, textContent: "local only"))
            try expect(!sync.pushSynchronously(), "a disabled sync pushes nothing")
            try expect(
                !FileManager.default.fileExists(atPath: cloud.appendingPathComponent("Klip").path),
                "and does not create Klip/ inside the container"
            )
        }
    }

    // MARK: - 4B #7 schema version

    static func testNewerSchemaIgnored() throws {
        try CloudDriveSyncTests.withTwoMacs { a, b, cloud in
            b.run { store, _ in store.add(ClipboardItem(type: .text, textContent: "from B")) }
            b.push()

            // Rewrite B's snapshot as if a newer Klip had written it.
            let historyURL = CloudDriveSyncTests.deviceDir(cloud, "device-B").appendingPathComponent("history.json")
            let data = try Data(contentsOf: historyURL)
            var object = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            object["version"] = 999
            try JSONSerialization.data(withJSONObject: object).write(to: historyURL)

            a.pull()
            try expect(a.items.isEmpty, "a snapshot from a newer Klip is ignored, not half-decoded")
            let error = try require(a.sync.lastError, "and the mismatch is reported once")
            try expect(error.contains("newer version"), "the message should explain why: \(error)")
        }
    }

    static func require<T>(_ value: T?, _ message: String, file: StaticString = #file, line: UInt = #line) throws -> T {
        guard let value = value else {
            throw TestFailure(message: message, file: file, line: line)
        }
        return value
    }
}
