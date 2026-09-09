import Foundation
import BenchTestKit
@testable import Tap

// MARK: - Helpers

/// Three fingers sitting still in the middle of the pad, in normalized units.
let restingFingers: [MTPoint] = [
    MTPoint(x: 0.40, y: 0.50),
    MTPoint(x: 0.50, y: 0.52),
    MTPoint(x: 0.60, y: 0.50),
]

/// The same three fingers shifted by `dx`, `dy` each.
func fingers(movedBy dx: Float, _ dy: Float = 0) -> [MTPoint] {
    restingFingers.map { MTPoint(x: $0.x + dx, y: $0.y + dy) }
}

let twoFingers: [MTPoint] = Array(restingFingers.prefix(2))

// MARK: - TapDetector

enum TapDetectorTests {
    static let tests: [TestCase] = [
        ("three fingers down and straight back up is a tap", {
            var detector = TapDetector()
            try expectEqual(detector.update(fingers: restingFingers, timestamp: 10.00), .none)
            try expectEqual(detector.update(fingers: restingFingers, timestamp: 10.05), .none)
            try expectEqual(detector.update(fingers: [], timestamp: 10.10), .middleClick)
        }),

        ("fingers lifting one at a time still taps", {
            var detector = TapDetector()
            _ = detector.update(fingers: restingFingers, timestamp: 1.00)
            try expectEqual(detector.update(fingers: twoFingers, timestamp: 1.04), .none)
            try expectEqual(detector.update(fingers: [restingFingers[0]], timestamp: 1.06), .none)
            try expectEqual(detector.update(fingers: [], timestamp: 1.08), .middleClick)
        }),

        ("a slow touch is not a tap", {
            var detector = TapDetector()
            _ = detector.update(fingers: restingFingers, timestamp: 0)
            _ = detector.update(fingers: restingFingers, timestamp: 0.3)
            try expectEqual(detector.update(fingers: [], timestamp: 0.4), .none)
        }),

        ("right at the duration limit still taps", {
            var detector = TapDetector()
            let limit = TapDetector.Config().maxDuration
            _ = detector.update(fingers: restingFingers, timestamp: 5)
            try expectEqual(detector.update(fingers: [], timestamp: 5 + limit), .middleClick)
        }),

        ("fingers that slide are a scroll, not a tap", {
            var detector = TapDetector()
            _ = detector.update(fingers: restingFingers, timestamp: 0)
            // 0.05 per finger, 0.15 summed: well over the 0.03 budget.
            _ = detector.update(fingers: fingers(movedBy: 0.05), timestamp: 0.05)
            try expectEqual(detector.update(fingers: [], timestamp: 0.10), .none)
        }),

        ("a flick out and back is not a tap either", {
            var detector = TapDetector()
            _ = detector.update(fingers: restingFingers, timestamp: 0)
            _ = detector.update(fingers: fingers(movedBy: 0, 0.04), timestamp: 0.04)
            _ = detector.update(fingers: restingFingers, timestamp: 0.08)
            try expectEqual(detector.update(fingers: [], timestamp: 0.12), .none)
        }),

        ("a jitter under the movement budget still taps", {
            var detector = TapDetector()
            _ = detector.update(fingers: restingFingers, timestamp: 0)
            // 0.003 per finger, 0.009 summed.
            _ = detector.update(fingers: fingers(movedBy: 0.003), timestamp: 0.05)
            try expectEqual(detector.update(fingers: [], timestamp: 0.10), .middleClick)
        }),

        ("a click during the touch cancels the tap", {
            var detector = TapDetector()
            _ = detector.update(fingers: restingFingers, timestamp: 0)
            detector.noteClick()
            _ = detector.update(fingers: restingFingers, timestamp: 0.05)
            try expectEqual(detector.update(fingers: [], timestamp: 0.10), .none)
        }),

        ("the next touch after a click is unaffected", {
            var detector = TapDetector()
            _ = detector.update(fingers: restingFingers, timestamp: 0)
            detector.noteClick()
            _ = detector.update(fingers: [], timestamp: 0.10)
            _ = detector.update(fingers: restingFingers, timestamp: 1.00)
            try expectEqual(detector.update(fingers: [], timestamp: 1.05), .middleClick)
        }),

        ("two fingers do nothing", {
            var detector = TapDetector()
            try expectEqual(detector.update(fingers: twoFingers, timestamp: 0), .none)
            try expectEqual(detector.update(fingers: twoFingers, timestamp: 0.05), .none)
            try expectEqual(detector.update(fingers: [], timestamp: 0.10), .none)
        }),

        ("a fourth finger cancels the gesture", {
            var detector = TapDetector()
            _ = detector.update(fingers: restingFingers, timestamp: 0)
            _ = detector.update(
                fingers: restingFingers + [MTPoint(x: 0.7, y: 0.5)], timestamp: 0.03)
            _ = detector.update(fingers: restingFingers, timestamp: 0.06)
            // Tracking restarted at 0.06, so this lift is measured from there.
            try expectEqual(detector.update(fingers: [], timestamp: 0.10), .middleClick)
        }),

        ("reset drops a touch in progress", {
            var detector = TapDetector()
            _ = detector.update(fingers: restingFingers, timestamp: 0)
            detector.reset()
            try expectEqual(detector.update(fingers: [], timestamp: 0.05), .none)
        }),

        ("the config is the documented one", {
            let config = TapDetector.Config()
            try expectEqual(config.fingers, 3)
            try expectEqual(config.maxDuration, 0.25)
            try expectEqual(config.maxMovement, 0.03)
        }),
    ]
}

// MARK: - Settings

enum SettingsTests {
    /// A throwaway defaults suite, so the tests never touch Bench's own.
    static func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "com.fxreza.bench.tests.tap.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    static let tests: [TestCase] = [
        ("the default mode is click", {
            try withDefaults { defaults in
                try expectEqual(TapSettings(defaults: defaults).mode, .click)
            }
        }),

        ("every mode round-trips through defaults", {
            try withDefaults { defaults in
                for mode in TapSettings.MiddleClickMode.allCases {
                    TapSettings(defaults: defaults).mode = mode
                    try expectEqual(
                        defaults.string(forKey: TapSettings.Key.middleClickMode), mode.rawValue)
                    try expectEqual(TapSettings(defaults: defaults).mode, mode)
                }
            }
        }),

        ("fn+click is on by default", {
            try withDefaults { defaults in
                try expect(TapSettings(defaults: defaults).fnClickEnabled, "fn+click defaults on")
            }
        }),

        ("fn+click round-trips through defaults", {
            try withDefaults { defaults in
                for value in [false, true] {
                    TapSettings(defaults: defaults).fnClickEnabled = value
                    try expectEqual(defaults.bool(forKey: TapSettings.Key.fnClick), value)
                    try expectEqual(TapSettings(defaults: defaults).fnClickEnabled, value)
                }
            }
        }),

        ("the triggers are independent", {
            // Every combination has to be reachable, which is why fn+click is
            // its own switch and not a fifth `MiddleClickMode`.
            let fnOnly = MiddleClickTriggers(mode: .off, fnClick: true)
            try expect(!fnOnly.convertsClick, "fn only converts no three-finger click")
            try expect(!fnOnly.detectsTap, "fn only watches no tap")
            try expect(fnOnly.needsEventTap, "fn only still needs the event tap")

            let fingersOnly = MiddleClickTriggers(mode: .both, fnClick: false)
            try expect(fingersOnly.convertsClick, "fingers only converts clicks")
            try expect(fingersOnly.detectsTap, "fingers only watches taps")
            try expect(fingersOnly.needsEventTap, "fingers only needs the event tap")

            let all = MiddleClickTriggers(mode: .both, fnClick: true)
            try expect(all.convertsClick && all.detectsTap && all.needsEventTap, "all on")

            let none = MiddleClickTriggers(mode: .off, fnClick: false)
            try expect(none.isOff, "nothing on")
            try expect(!none.needsEventTap, "nothing on installs no event tap")
        }),

        ("an unknown stored value falls back to the default", {
            try withDefaults { defaults in
                defaults.set("sideways", forKey: TapSettings.Key.middleClickMode)
                try expectEqual(TapSettings(defaults: defaults).mode, .click)
            }
        }),

        ("the raw values are the frozen ones", {
            try expectEqual(
                TapSettings.MiddleClickMode.allCases.map(\.rawValue),
                ["off", "click", "tap", "both"])
        }),

        ("modes say what they switch on", {
            try expect(!TapSettings.MiddleClickMode.off.convertsClick, "off converts nothing")
            try expect(!TapSettings.MiddleClickMode.off.detectsTap, "off detects nothing")
            try expect(TapSettings.MiddleClickMode.click.convertsClick, "click converts clicks")
            try expect(!TapSettings.MiddleClickMode.click.detectsTap, "click ignores taps")
            try expect(!TapSettings.MiddleClickMode.tap.convertsClick, "tap ignores clicks")
            try expect(TapSettings.MiddleClickMode.tap.detectsTap, "tap detects taps")
            try expect(TapSettings.MiddleClickMode.both.convertsClick, "both converts clicks")
            try expect(TapSettings.MiddleClickMode.both.detectsTap, "both detects taps")
        }),
    ]
}

// MARK: - Feature

enum FeatureTests {
    static let tests: [TestCase] = [
        ("the feature describes itself the way the registry expects", {
            let feature = TapFeature()
            try expectEqual(feature.id, "tap")
            try expectEqual(feature.title, "Tap")
            try expectEqual(feature.symbolName, "hand.tap")
            try expect(feature.hotkeyActions.isEmpty, "Tap declares no shortcuts")
            try expectEqual(feature.requiredPermissions, [.accessibility])
            try expect(feature.menuItems().isEmpty, "Tap adds no status menu section")
        }),

        ("the multitouch frame struct has the C layout", {
            // If this fails the callback would read past the end of Apple's
            // buffer; MultitouchMonitor.start() checks it at runtime too.
            try expectEqual(MemoryLayout<MTTouch>.stride, MTTouch.expectedStride)
            try expectEqual(MemoryLayout<MTPoint>.size, 8)
            try expectEqual(MemoryLayout<MTVector>.size, 16)
        }),
    ]
}
