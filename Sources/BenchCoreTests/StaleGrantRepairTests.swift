import Foundation
import BenchTestKit
@testable import BenchCore

enum StaleGrantRepairTests {
    static func makeDefaults() -> UserDefaults {
        let name = "bench.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    static let tests: [TestCase] = [
        ("granted permissions are recorded under this build", {
            let r = StaleGrantRepair.evaluate(
                granted: [.accessibility: true, .screenRecording: true],
                record: nil, build: "0.5.1 (19)", justUpdated: false)
            try expectEqual(r.stale, [])
            try expectEqual(r.record, ["accessibility": "0.5.1 (19)", "screenRecording": "0.5.1 (19)"])
        }),
        ("only the permission refused after an update is stale", {
            let r = StaleGrantRepair.evaluate(
                granted: [.accessibility: false, .screenRecording: true],
                record: ["accessibility": "0.5.0 (18)", "screenRecording": "0.5.0 (18)"],
                build: "0.5.1 (19)", justUpdated: true)
            try expectEqual(r.stale, [.accessibility])
            try expectEqual(r.record, ["screenRecording": "0.5.1 (19)"])
        }),
        ("a permission turned off under this build is left alone, now and after the next update", {
            let off = StaleGrantRepair.evaluate(
                granted: [.accessibility: false, .screenRecording: true],
                record: ["accessibility": "0.5.1 (19)", "screenRecording": "0.5.1 (19)"],
                build: "0.5.1 (19)", justUpdated: false)
            try expectEqual(off.stale, [])
            try expectNil(off.record["accessibility"])
            let next = StaleGrantRepair.evaluate(
                granted: [.accessibility: false, .screenRecording: true],
                record: off.record, build: "0.5.2 (20)", justUpdated: true)
            try expectEqual(next.stale, [])
        }),
        ("a permission never granted is not stale", {
            let r = StaleGrantRepair.evaluate(
                granted: [.accessibility: true, .screenRecording: false],
                record: ["accessibility": "0.5.0 (18)"], build: "0.5.1 (19)", justUpdated: true)
            try expectEqual(r.stale, [])
        }),
        ("a stale permission is reset once, not on every launch", {
            let first = StaleGrantRepair.evaluate(
                granted: [.accessibility: false, .screenRecording: true],
                record: ["accessibility": "0.5.0 (18)", "screenRecording": "0.5.0 (18)"],
                build: "0.5.1 (19)", justUpdated: true)
            try expectEqual(first.stale, [.accessibility])
            let second = StaleGrantRepair.evaluate(
                granted: [.accessibility: false, .screenRecording: true],
                record: first.record, build: "0.5.1 (19)", justUpdated: false)
            try expectEqual(second.stale, [])
        }),
        ("the first update onto this check treats refused permissions as stale", {
            let r = StaleGrantRepair.evaluate(
                granted: [.accessibility: false, .screenRecording: true],
                record: nil, build: "0.5.1 (19)", justUpdated: true)
            try expectEqual(r.stale, [.accessibility])
            let fresh = StaleGrantRepair.evaluate(
                granted: [.accessibility: false, .screenRecording: false],
                record: nil, build: "0.5.1 (19)", justUpdated: false)
            try expectEqual(fresh.stale, [], "a fresh install is not an update")
        }),
        ("automation is reset only when it last worked under another build", {
            let defaults = makeDefaults()
            try expect(!StaleGrantRepair.resetAutomationIfStale(defaults: defaults), "never worked")
            StaleGrantRepair.noteAutomationWorked(defaults: defaults)
            try expect(!StaleGrantRepair.resetAutomationIfStale(defaults: defaults), "refused under this build")
        }),
        ("tccutil service names", {
            try expectEqual(StaleGrantRepair.tccService(.accessibility), "Accessibility")
            try expectEqual(StaleGrantRepair.tccService(.screenRecording), "ScreenCapture")
            try expectEqual(StaleGrantRepair.tccService(.automation), "AppleEvents")
        }),
        ("permission bookkeeping stays on this Mac", {
            try expect(!SettingsSync.isSynced(StaleGrantRepair.grantedBuildKey), "granted builds")
            try expect(!SettingsSync.isSynced(StaleGrantRepair.automationBuildKey), "automation build")
        }),
    ]
}
