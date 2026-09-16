import Foundation
import BenchTestKit
@testable import BenchCore

// `CloudDrive`: the shared iCloud Drive folder and the one-time move of a
// folder that used to sit at the top of the container.
enum CloudDriveTests {
    static let tests: [TestCase] = [
        ("folders live under Bench/", {
            let container = URL(fileURLWithPath: "/tmp/cloud", isDirectory: true)
            try expectEqual(CloudDrive.benchRoot(in: container).path, "/tmp/cloud/Bench")
            try expectEqual(CloudDrive.folder(named: "Klip", in: container).path, "/tmp/cloud/Bench/Klip")
        }),
        ("legacy folder is moved into Bench/ once", {
            try withTempDir { cloud in
                let fm = FileManager.default
                let legacyFile = cloud.appendingPathComponent("Klip/devices/x/history.json")
                try fm.createDirectory(at: legacyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("{}".utf8).write(to: legacyFile)

                try expect(CloudDrive.migrateLegacyFolder(named: "Klip", in: cloud), "first call moves")
                try expect(fm.fileExists(atPath: cloud.appendingPathComponent("Bench/Klip/devices/x/history.json").path), "file travelled")
                try expect(!fm.fileExists(atPath: cloud.appendingPathComponent("Klip").path), "old folder is gone")
                try expect(!CloudDrive.migrateLegacyFolder(named: "Klip", in: cloud), "nothing left to move")
            }
        }),
        ("legacy folder is left alone when the new one exists", {
            try withTempDir { cloud in
                let fm = FileManager.default
                try fm.createDirectory(at: cloud.appendingPathComponent("Klip/devices"), withIntermediateDirectories: true)
                try fm.createDirectory(at: cloud.appendingPathComponent("Bench/Klip/devices"), withIntermediateDirectories: true)
                try expect(!CloudDrive.migrateLegacyFolder(named: "Klip", in: cloud), "no move over an existing folder")
                try expect(fm.fileExists(atPath: cloud.appendingPathComponent("Klip/devices").path), "old folder untouched")
            }
        }),
    ]
}

// `SettingsSync` end to end: two simulated Macs with their own preferences
// domains and state directories, sharing one temp stand-in for iCloud
// Drive. Everything is driven through the synchronous entry points so no
// timer, watcher or run loop is involved.
enum SettingsSyncTests {
    /// One simulated Mac.
    @MainActor
    final class Instance {
        let name: String
        let defaults: UserDefaults
        let suite: String
        let sync: SettingsSync
        let extras: FakeContributor

        init(name: String, root: URL, cloud: URL) {
            self.name = name
            suite = "bench.tests.sync.\(name).\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            extras = FakeContributor()
            sync = SettingsSync(
                defaults: defaults,
                domainName: suite,
                cloudRoot: cloud,
                stateDirectory: root.appendingPathComponent("state-\(name)", isDirectory: true),
                deviceID: "device-\(name)",
                deviceName: "Mac \(name)")
            sync.register(extras)
        }

        /// A second process on the same Mac: same preferences, same state
        /// directory, same identity.
        init(relaunching other: Instance, root: URL, cloud: URL) {
            name = other.name
            suite = other.suite
            defaults = other.defaults
            extras = other.extras
            sync = SettingsSync(
                defaults: defaults,
                domainName: suite,
                cloudRoot: cloud,
                stateDirectory: root.appendingPathComponent("state-\(name)", isDirectory: true),
                deviceID: "device-\(name)",
                deviceName: "Mac \(name)")
            sync.register(extras)
        }

        func set(_ value: Any?, _ key: String) {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        func value(_ key: String) -> Any? { defaults.object(forKey: key) }

        func cleanUp() { defaults.removePersistentDomain(forName: suite) }
    }

    /// Stands in for Lingo's API key file.
    @MainActor
    final class FakeContributor: SettingsSyncContributor {
        var values: [String: String] = [:]
        var applied: [(String, Any?)] = []
        let settingsSyncKeys = ["lingo.secret.test_key"]
        func settingsSyncValue(forKey key: String) -> Any? { values[key] }
        func applySettingsSyncValue(_ value: Any?, forKey key: String) {
            applied.append((key, value))
            if let value = value as? String { values[key] = value } else { values[key] = nil }
        }
    }

    @MainActor
    static func withPair(_ body: (Instance, Instance, URL) throws -> Void) throws {
        try withTempDir { root in
            let cloud = root.appendingPathComponent("cloud", isDirectory: true)
            try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
            let a = Instance(name: "A", root: root, cloud: cloud)
            let b = Instance(name: "B", root: root, cloud: cloud)
            defer {
                a.cleanUp()
                b.cleanUp()
            }
            try body(a, b, cloud)
        }
    }

    /// Timestamps decide the merge, so two edits in one test must not share
    /// a `Date()`.
    static func tick() { Thread.sleep(forTimeInterval: 0.005) }

    static let tests: [TestCase] = [
        ("isSynced: module prefixes in, per-Mac keys out", {
            try expect(SettingsSync.isSynced("snap.gap"), "module key")
            try expect(SettingsSync.isSynced("bench.shortcuts.overrides"), "shortcuts")
            try expect(SettingsSync.isSynced("bench.feature.klip.enabled"), "module switch")
            try expect(SettingsSync.isSynced("lingo.translationHistory"), "history")
            try expect(SettingsSync.isSynced("klip.sync.kinds"), "a Klip sync preference")
            try expect(!SettingsSync.isSynced("klip.sync.deviceID"), "Klip's identity")
            try expect(!SettingsSync.isSynced("klip.sync.enabled"), "Klip's own switch")
            try expect(!SettingsSync.isSynced("bench.settingsSync.enabled"), "this switch")
            try expect(!SettingsSync.isSynced("bench.hasCompletedOnboarding"), "onboarding")
            try expect(!SettingsSync.isSynced("shot.importedFromSnapper"), "import flag")
            try expect(!SettingsSync.isSynced("NSWindow Frame Settings"), "not ours")
        }),

        ("value set on A reaches B", { try MainActor.assumeIsolated {
            try withPair { a, b, _ in
                a.set(42.0, "snap.gap")
                a.set(true, "tap.fnClick")
                try expect(a.sync.pushSynchronously(), "push")
                let applied = b.sync.pullSynchronously()
                try expectEqual(Set(applied), ["snap.gap", "tap.fnClick"])
                try expectEqual(b.value("snap.gap") as? Double, 42.0)
                try expectEqual(b.value("tap.fnClick") as? Bool, true)
            }
        } }),

        ("file layout is the documented one", { try MainActor.assumeIsolated {
            try withPair { a, _, cloud in
                a.set("x", "piko.app")
                try expect(a.sync.pushSynchronously(), "push")
                let file = cloud.appendingPathComponent("Bench/Settings/devices/device-A/settings.plist")
                let data = try Data(contentsOf: file)
                let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
                try expectEqual(plist?["version"] as? Int, 1)
                try expectEqual((plist?["device"] as? [String: Any])?["id"] as? String, "device-A")
                try expectEqual((plist?["device"] as? [String: Any])?["name"] as? String, "Mac A")
                let entry = (plist?["entries"] as? [String: Any])?["piko.app"] as? [String: Any]
                try expectEqual(entry?["v"] as? String, "x")
                try expectEqual(entry?["o"] as? String, "device-A")
                try expectNotNil((entry?["m"] as? NSNumber)?.int64Value, "modified stamp, milliseconds since 1970")
            }
        } }),

        ("newest edit wins in both directions", { try MainActor.assumeIsolated {
            try withPair { a, b, _ in
                a.set(1, "snap.resizeStep")
                try expect(a.sync.pushSynchronously(), "push A")
                b.sync.pullSynchronously()
                try expectEqual(b.value("snap.resizeStep") as? Int, 1)

                tick()
                b.set(2, "snap.resizeStep")
                try expect(b.sync.pushSynchronously(), "push B")
                a.sync.pullSynchronously()
                try expectEqual(a.value("snap.resizeStep") as? Int, 2, "B's later edit reached A")

                tick()
                a.set(3, "snap.resizeStep")
                try expect(a.sync.pushSynchronously(), "push A again")
                b.sync.pullSynchronously()
                try expectEqual(b.value("snap.resizeStep") as? Int, 3, "A's later edit reached B")

                // A's stale file must not undo B's newer value.
                tick()
                b.set(4, "snap.resizeStep")
                b.sync.noteLocalChanges()
                b.sync.pullSynchronously()
                try expectEqual(b.value("snap.resizeStep") as? Int, 4, "older remote does not overwrite")
            }
        } }),

        ("removal travels as a tombstone", { try MainActor.assumeIsolated {
            try withPair { a, b, _ in
                a.set("dark", "bench.appearance.colorScheme")
                try expect(a.sync.pushSynchronously(), "push")
                b.sync.pullSynchronously()
                try expectEqual(b.value("bench.appearance.colorScheme") as? String, "dark")

                tick()
                a.set(nil, "bench.appearance.colorScheme")
                try expect(a.sync.pushSynchronously(), "push removal")
                let applied = b.sync.pullSynchronously()
                try expectEqual(applied, ["bench.appearance.colorScheme"])
                try expectNil(b.value("bench.appearance.colorScheme"), "removed on B too")

                // And the tombstone does not resurrect on the next cycle.
                try expect(b.sync.pushSynchronously(), "push B")
                try expectEqual(a.sync.pullSynchronously(), [])
                try expectNil(a.value("bench.appearance.colorScheme"))
            }
        } }),

        ("per-Mac keys never leave", { try MainActor.assumeIsolated {
            try withPair { a, b, _ in
                a.set(true, "bench.hasCompletedOnboarding")
                a.set("id-A", "klip.sync.deviceID")
                a.set(true, "klip.sync.enabled")
                a.set("Mac A", "bench.settingsSync.deviceName")
                a.set(1, "Unrelated")
                a.set(5, "snap.gap")
                try expect(a.sync.pushSynchronously(), "push")
                try expectEqual(b.sync.pullSynchronously(), ["snap.gap"])
                try expectNil(b.value("bench.hasCompletedOnboarding"))
                try expectNil(b.value("klip.sync.deviceID"))
                try expectNil(b.value("klip.sync.enabled"))
                try expectNil(b.value("Unrelated"))
            }
        } }),

        ("a Mac joining adopts the existing values and contributes its own", { try MainActor.assumeIsolated {
            try withPair { a, b, _ in
                a.set("a", "lingo.targetLanguage")
                try expect(a.sync.pushSynchronously(), "push A")

                // B was configured on its own before sync was switched on.
                b.set("b", "lingo.targetLanguage")
                b.set("only-b", "lingo.secondaryLanguage")
                b.sync.pullSynchronously()
                try expectEqual(b.value("lingo.targetLanguage") as? String, "a", "B takes the synced value")
                try expect(b.sync.pushSynchronously(), "push B")

                a.sync.pullSynchronously()
                try expectEqual(a.value("lingo.targetLanguage") as? String, "a", "A keeps its value")
                try expectEqual(a.value("lingo.secondaryLanguage") as? String, "only-b", "A gets B's extra key")
            }
        } }),

        ("contributor values travel and are removable", { try MainActor.assumeIsolated {
            try withPair { a, b, _ in
                a.extras.values["lingo.secret.test_key"] = "s3cret"
                try expect(a.sync.pushSynchronously(), "push")
                try expectEqual(b.sync.pullSynchronously(), ["lingo.secret.test_key"])
                try expectEqual(b.extras.values["lingo.secret.test_key"], "s3cret")
                try expectNil(b.value("lingo.secret.test_key"), "never lands in defaults")

                tick()
                a.extras.values["lingo.secret.test_key"] = nil
                try expect(a.sync.pushSynchronously(), "push removal")
                try expectEqual(b.sync.pullSynchronously(), ["lingo.secret.test_key"])
                try expectNil(b.extras.values["lingo.secret.test_key"], "removed on B")
            }
        } }),

        ("stores are told which keys changed", { try MainActor.assumeIsolated {
            try withPair { a, b, _ in
                var seen: [String] = []
                let observer = SettingsSync.observeApplied(prefix: "snap.") { keys in seen = keys }
                defer { NotificationCenter.default.removeObserver(observer) }

                a.set(1, "snap.gap")
                a.set(2, "tap.fnClick")
                try expect(a.sync.pushSynchronously(), "push")
                b.sync.pullSynchronously()
                try expectEqual(seen, ["snap.gap"], "only the observed prefix")
            }
        } }),

        ("state survives a relaunch, and unchanged values are not re-stamped", { try MainActor.assumeIsolated {
            try withTempDir { root in
                let cloud = root.appendingPathComponent("cloud", isDirectory: true)
                try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
                let a = Instance(name: "A", root: root, cloud: cloud)
                let b = Instance(name: "B", root: root, cloud: cloud)
                defer {
                    a.cleanUp()
                    b.cleanUp()
                }

                a.set(1, "shot.jpegQuality")
                try expect(a.sync.pushSynchronously(), "push A")
                b.sync.pullSynchronously()

                tick()
                b.set(2, "shot.jpegQuality")
                try expect(b.sync.pushSynchronously(), "push B")

                // A relaunches: its state file says 1 was stamped before B's
                // 2, so B's edit still wins even though A pushes first.
                let a2 = Instance(relaunching: a, root: root, cloud: cloud)
                try expect(a2.sync.pushSynchronously(), "push A after relaunch")
                try expectEqual(a2.sync.pullSynchronously(), ["shot.jpegQuality"])
                try expectEqual(a2.value("shot.jpegQuality") as? Int, 2)

                // Nothing changed on A, so B has nothing new to take.
                try expect(a2.sync.pushSynchronously(), "push A again")
                try expectEqual(b.sync.pullSynchronously(), [])
            }
        } }),

        ("without iCloud Drive nothing is written", { try MainActor.assumeIsolated {
            try withTempDir { root in
                let missing = root.appendingPathComponent("no-cloud", isDirectory: true)
                let a = Instance(name: "A", root: root, cloud: missing)
                defer { a.cleanUp() }
                a.set(1, "snap.gap")
                try expect(!a.sync.isAvailable, "unavailable")
                try expect(!a.sync.pushSynchronously(), "push refused")
                try expectEqual(a.sync.pullSynchronously(), [])
                try expect(!FileManager.default.fileExists(atPath: missing.path), "container never manufactured")
            }
        } }),

        ("status line reads the way it is specified", {
            let now = Date()
            try expectEqual(
                CloudSyncStatusLine.text(enabled: false, available: true, lastPush: nil, lastPull: nil, devices: [], now: now),
                "Sync is off.")
            try expectEqual(
                CloudSyncStatusLine.text(enabled: true, available: false, lastPush: nil, lastPull: nil, devices: [], now: now),
                "iCloud Drive is not available on this Mac.")
            try expectEqual(
                CloudSyncStatusLine.text(
                    enabled: true, available: true,
                    lastPush: now.addingTimeInterval(-120), lastPull: now.addingTimeInterval(-5),
                    devices: ["Studio"], now: now),
                "Last push 2 min ago · last pull just now · 1 device: Studio")
        }),
    ]
}
