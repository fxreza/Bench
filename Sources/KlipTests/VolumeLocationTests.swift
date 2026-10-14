import Foundation
import BenchTestKit
@testable import Klip

// Reference clips on network shares and unplugged volumes (2026-10-07: a
// clip from a sleeping Mac's share froze Bench for two minutes while its
// row was drawn). Classification must come from the mount table alone.

enum VolumeLocationTests {
    static let tests: [(String, () throws -> Void)] = [
        ("startupDisk_isLocal", testStartupDiskIsLocal),
        ("unmountedVolume_isUnmounted", testUnmountedVolume),
        ("mountedShare_isNetwork", testMountedShare),
        ("usbDrive_isLocal", testUSBDrive),
        ("bootVolumeLink_followsTheLink", testBootVolumeLink),
        ("emptyMountTable_fallsBackToLocal", testEmptyMountTable),
        ("realMountTable_hasTheStartupDisk", testRealMountTable),
        ("fileURLs_unmountedReference_isEmptyAndMissing", testUnmountedReferenceIsMissing),
        ("localFileURLs_networkReference_isNotTouched", testNetworkReferenceNotTouched),
        ("probe_slowWork_givesUpAndQuarantines", testProbeDeadline),
    ]

    private static let mounts: [VolumeLocation.Mount] = [
        .init(point: "/", isLocal: true),
        .init(point: "/System/Volumes/Data", isLocal: true),
        .init(point: "/Volumes/Mona", isLocal: false),
        .init(point: "/Volumes/USB", isLocal: true),
    ]

    private static func location(_ path: String, links: [String: String] = [:]) -> VolumeLocation {
        VolumeLocation.of(path: path, mounts: mounts, readLink: { links[$0] })
    }

    static func testStartupDiskIsLocal() throws {
        try expectEqual(location("/Users/sam/Downloads/a.pdf"), .local)
    }

    static func testUnmountedVolume() throws {
        try expectEqual(location("/Volumes/monakazemi/Public/AK injury"), .unmounted)
        try expectEqual(location("/Volumes/Mona-1/x"), .unmounted, "a name that only starts like a mounted share is not on it")
    }

    static func testMountedShare() throws {
        try expectEqual(location("/Volumes/Mona/Drawings/a.jpg"), .network(mountPoint: "/Volumes/Mona"))
        try expectEqual(location("/Volumes/Mona"), .network(mountPoint: "/Volumes/Mona"))
    }

    static func testUSBDrive() throws {
        try expectEqual(location("/Volumes/USB/DCIM/1.jpg"), .local)
    }

    static func testBootVolumeLink() throws {
        let links = ["/Volumes/Macintosh HD": "/", "/Volumes/Share Link": "/Volumes/Mona"]
        try expectEqual(location("/Volumes/Macintosh HD/Users/sam/a.txt", links: links), .local)
        try expectEqual(location("/Volumes/Share Link/a.txt", links: links), .network(mountPoint: "/Volumes/Mona"))
    }

    static func testEmptyMountTable() throws {
        try expectEqual(VolumeLocation.of(path: "/Volumes/X/a", mounts: [], readLink: { _ in nil }), .local)
    }

    static func testRealMountTable() throws {
        let real = VolumeLocation.currentMounts()
        try expect(real.contains { $0.point == "/" && $0.isLocal }, "the startup disk should be in the mount table as local: \(real)")
        try expectEqual(VolumeLocation.of(path: NSHomeDirectory()), .local)
    }

    private static func referenceItem(path: String) -> ClipboardItem {
        ClipboardItem.file(attachment: FileAttachment(originalName: (path as NSString).lastPathComponent, referencePath: path))
    }

    static func testUnmountedReferenceIsMissing() throws {
        try ClipboardStoreTests.withStore { store, _ in
            let item = referenceItem(path: "/Volumes/klip-test-never-mounted-\(UUID().uuidString)/a.txt")
            try expectEqual(store.fileLocation(for: item), .unmounted)
            try expectEqual(store.fileURLs(for: item), [])
            try expect(store.fileIsMissing(item), "a clip on a volume that is not mounted is missing")
        }
    }

    static func testNetworkReferenceNotTouched() throws {
        guard let share = VolumeLocation.currentMounts().first(where: { !$0.isLocal && $0.point.hasPrefix("/Volumes/") }) else {
            print("    (no network share mounted; skipped)")
            return
        }
        try ClipboardStoreTests.withStore { store, _ in
            let item = referenceItem(path: share.point + "/klip-test-\(UUID().uuidString).txt")
            try expect(store.fileLocation(for: item).isNetwork, "\(share.point) should classify as a network share")
            try expectEqual(store.localFileURLs(for: item), [])
        }
    }

    static func testProbeDeadline() throws {
        let mount = "/Volumes/klip-test-\(UUID().uuidString)"
        let start = Date()
        let slow = NetworkShareProbe.run(mountPoint: mount) { () -> Int in
            Thread.sleep(forTimeInterval: NetworkShareProbe.timeout + 1)
            return 1
        }
        try expectNil(slow, "work past the deadline gives no result")
        try expect(Date().timeIntervalSince(start) < NetworkShareProbe.timeout + 0.5, "the caller waits no longer than the deadline")

        var ran = false
        let again = NetworkShareProbe.run(mountPoint: mount) { () -> Int in ran = true; return 2 }
        try expectNil(again, "a share that missed the deadline is skipped for a while")
        try expect(!ran, "the skipped work never starts")

        try expectEqual(NetworkShareProbe.run(mountPoint: mount + "-other") { 3 }, 3, "another share is unaffected")
    }
}
