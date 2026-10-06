import Foundation
import BenchTestKit
import BenchCore
@testable import Clean

// MARK: - UnlockHold

enum UnlockHoldTests {
    static let tests: [TestCase] = [
        ("a button held for the whole duration completes", {
            var hold = UnlockHold(duration: 3)
            try expect(hold.press(button: 0, at: 10), "first press starts the hold")
            try expect(!hold.isComplete(at: 12.9), "not yet at 2.9 s")
            try expect(hold.isComplete(at: 13), "complete at 3 s")
            try expectEqual(hold.progress(at: 11.5), 0.5)
        }),

        ("releasing early ends the hold", {
            var hold = UnlockHold(duration: 3)
            _ = hold.press(button: 0, at: 0)
            try expect(hold.release(button: 0), "release ends the hold")
            try expect(!hold.isHolding, "no hold after release")
            try expect(!hold.isComplete(at: 5), "a finished hold never completes")
            try expectEqual(hold.progress(at: 5), 0)
        }),

        ("a second button does not restart the count", {
            var hold = UnlockHold(duration: 3)
            _ = hold.press(button: 0, at: 0)
            try expect(!hold.press(button: 1, at: 2), "second button starts nothing")
            try expect(hold.isComplete(at: 3), "counted from the first press")
        }),

        ("the hold lasts until the last button comes up", {
            var hold = UnlockHold(duration: 3)
            _ = hold.press(button: 0, at: 0)
            _ = hold.press(button: 1, at: 1)
            try expect(!hold.release(button: 0), "one button still down")
            try expect(hold.isHolding, "still holding")
            try expect(hold.release(button: 1), "last button ends it")
        }),

        ("an up without a down is ignored", {
            var hold = UnlockHold(duration: 3)
            try expect(!hold.release(button: 0), "nothing to end")
            try expect(!hold.isHolding, "no hold")
        }),

        ("a new hold starts from zero", {
            var hold = UnlockHold(duration: 3)
            _ = hold.press(button: 0, at: 0)
            _ = hold.release(button: 0)
            try expect(hold.press(button: 0, at: 10), "new hold")
            try expect(!hold.isComplete(at: 12), "counted from the new press")
            try expect(hold.isComplete(at: 13), "complete 3 s after the new press")
        }),
    ]
}

// MARK: - Settings

enum SettingsTests {
    /// A throwaway defaults suite, so the tests never touch Bench's own.
    static func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "com.fxreza.bench.tests.clean.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    static let tests: [TestCase] = [
        ("defaults: 90 % dark, 3 s hold, indicator shown", {
            try withDefaults { defaults in
                let settings = CleanSettings(defaults: defaults)
                try expectEqual(settings.darkness, 0.9)
                try expectEqual(settings.holdSeconds, 3)
                try expect(settings.showIndicator, "indicator shown by default")
            }
        }),

        ("values round-trip through defaults", {
            try withDefaults { defaults in
                let settings = CleanSettings(defaults: defaults)
                settings.darkness = 0.5
                settings.holdSeconds = 7
                settings.showIndicator = false
                let reread = CleanSettings(defaults: defaults)
                try expectEqual(reread.darkness, 0.5)
                try expectEqual(reread.holdSeconds, 7)
                try expect(!reread.showIndicator, "indicator hidden after round-trip")
            }
        }),

        ("out-of-range stored values are clamped", {
            try withDefaults { defaults in
                defaults.set(1.7, forKey: CleanSettings.Key.darkness)
                defaults.set(60, forKey: CleanSettings.Key.holdSeconds)
                let settings = CleanSettings(defaults: defaults)
                try expectEqual(settings.darkness, 1)
                try expectEqual(settings.holdSeconds, 10)
            }
        }),

        ("clean settings take part in settings sync", {
            try expect(SettingsSync.isSynced(CleanSettings.Key.darkness), "darkness syncs")
        }),
    ]
}
