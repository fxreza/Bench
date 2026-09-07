import AppKit
// BenchCore is Snap's own dependency; the test runner reaches it
// transitively for KeyBinding, which the action table is stated in.
import BenchCore
import BenchTestKit
@testable import Snap

// MARK: - Helpers

/// Rectangle comparison with a tolerance: thirds of a 1000 pt screen are
/// 333.333…, and an exact `==` on those would be a test about binary
/// floating point rather than about layout.
func expectRect(
    _ actual: CGRect, _ expected: CGRect, _ message: String = "",
    accuracy: CGFloat = 0.0005, file: StaticString = #file, line: UInt = #line
) throws {
    let close =
        abs(actual.origin.x - expected.origin.x) <= accuracy
        && abs(actual.origin.y - expected.origin.y) <= accuracy
        && abs(actual.size.width - expected.size.width) <= accuracy
        && abs(actual.size.height - expected.size.height) <= accuracy
    if !close {
        let detail = "\(actual) != \(expected)"
        throw TestFailure(
            message: message.isEmpty ? detail : "\(message) (\(detail))", file: file, line: line)
    }
}

/// The screen every layout test measures against: 1000 x 800 at (100, 50),
/// Cocoa coordinates.
let visible = CGRect(x: 100, y: 50, width: 1000, height: 800)

// MARK: - Layout, no gap

enum LayoutTests {
    static let tests: [TestCase] = [
        ("halves fill the visible frame", {
            try expectRect(SnapLayout.leftHalf.frame(in: visible), CGRect(x: 100, y: 50, width: 500, height: 800))
            try expectRect(SnapLayout.rightHalf.frame(in: visible), CGRect(x: 600, y: 50, width: 500, height: 800))
            try expectRect(SnapLayout.topHalf.frame(in: visible), CGRect(x: 100, y: 450, width: 1000, height: 400))
            try expectRect(SnapLayout.bottomHalf.frame(in: visible), CGRect(x: 100, y: 50, width: 1000, height: 400))
        }),
        ("quarters", {
            try expectRect(SnapLayout.topLeft.frame(in: visible), CGRect(x: 100, y: 450, width: 500, height: 400))
            try expectRect(SnapLayout.topRight.frame(in: visible), CGRect(x: 600, y: 450, width: 500, height: 400))
            try expectRect(SnapLayout.bottomLeft.frame(in: visible), CGRect(x: 100, y: 50, width: 500, height: 400))
            try expectRect(SnapLayout.bottomRight.frame(in: visible), CGRect(x: 600, y: 50, width: 500, height: 400))
        }),
        ("thirds", {
            let third = 1000.0 / 3.0
            try expectRect(SnapLayout.leftThird.frame(in: visible), CGRect(x: 100, y: 50, width: third, height: 800))
            try expectRect(
                SnapLayout.middleThird.frame(in: visible),
                CGRect(x: 100 + third, y: 50, width: third, height: 800))
            try expectRect(
                SnapLayout.rightThird.frame(in: visible),
                CGRect(x: 1100 - third, y: 50, width: third, height: 800))
        }),
        ("two thirds", {
            let two = 2000.0 / 3.0
            try expectRect(
                SnapLayout.leftTwoThirds.frame(in: visible),
                CGRect(x: 100, y: 50, width: two, height: 800))
            try expectRect(
                SnapLayout.centerTwoThirds.frame(in: visible),
                CGRect(x: 600 - two / 2, y: 50, width: two, height: 800))
            try expectRect(
                SnapLayout.rightTwoThirds.frame(in: visible),
                CGRect(x: 1100 - two, y: 50, width: two, height: 800))
        }),
        ("center two thirds is centered", {
            let rect = SnapLayout.centerTwoThirds.frame(in: visible)
            try expectEqual(rect.midX, visible.midX, "centered horizontally")
            try expectEqual(rect.height, visible.height, "full height")
        }),
        ("maximize is the whole visible frame", {
            try expectRect(SnapLayout.maximize.frame(in: visible), visible)
        }),
        ("center keeps the size", {
            let rect = SnapLayout.center.frame(in: visible, gap: 0, currentSize: CGSize(width: 400, height: 300))
            try expectRect(rect, CGRect(x: 400, y: 300, width: 400, height: 300))
        }),
        ("center clamps a window larger than the screen", {
            let rect = SnapLayout.center.frame(in: visible, gap: 0, currentSize: CGSize(width: 2000, height: 2000))
            try expectRect(rect, visible)
        }),
        ("center with no reported size fills the screen", {
            try expectRect(SnapLayout.center.frame(in: visible), visible)
        }),
        ("every layout stays inside the visible frame", {
            for layout in SnapLayout.allCases {
                let rect = layout.frame(in: visible, gap: 0, currentSize: CGSize(width: 300, height: 200))
                try expect(visible.contains(rect.insetBy(dx: 0.001, dy: 0.001)), "\(layout) escaped: \(rect)")
            }
        }),
        ("action ids match the shortcut table", {
            try expectEqual(SnapLayout.leftHalf.actionID, "snap.leftHalf")
            try expectEqual(SnapLayout.centerTwoThirds.actionID, "snap.centerTwoThirds")
        }),
    ]
}

// MARK: - Layout with a gap

enum GapTests {
    /// gap 10 on the 1000 x 800 frame: content is 980 x 780 at (110, 60),
    /// halves are (980-10)/2 = 485 wide and (780-10)/2 = 385 tall, thirds are
    /// (980-20)/3 = 320 wide, two thirds are 650.
    static let tests: [TestCase] = [
        ("halves with a 10 pt gap", {
            try expectRect(
                SnapLayout.leftHalf.frame(in: visible, gap: 10),
                CGRect(x: 110, y: 60, width: 485, height: 780))
            try expectRect(
                SnapLayout.rightHalf.frame(in: visible, gap: 10),
                CGRect(x: 605, y: 60, width: 485, height: 780))
            try expectRect(
                SnapLayout.topHalf.frame(in: visible, gap: 10),
                CGRect(x: 110, y: 455, width: 980, height: 385))
            try expectRect(
                SnapLayout.bottomHalf.frame(in: visible, gap: 10),
                CGRect(x: 110, y: 60, width: 980, height: 385))
        }),
        ("quarters with a 10 pt gap", {
            try expectRect(
                SnapLayout.topLeft.frame(in: visible, gap: 10),
                CGRect(x: 110, y: 455, width: 485, height: 385))
            try expectRect(
                SnapLayout.topRight.frame(in: visible, gap: 10),
                CGRect(x: 605, y: 455, width: 485, height: 385))
            try expectRect(
                SnapLayout.bottomLeft.frame(in: visible, gap: 10),
                CGRect(x: 110, y: 60, width: 485, height: 385))
            try expectRect(
                SnapLayout.bottomRight.frame(in: visible, gap: 10),
                CGRect(x: 605, y: 60, width: 485, height: 385))
        }),
        ("thirds with a 10 pt gap", {
            try expectRect(
                SnapLayout.leftThird.frame(in: visible, gap: 10),
                CGRect(x: 110, y: 60, width: 320, height: 780))
            try expectRect(
                SnapLayout.middleThird.frame(in: visible, gap: 10),
                CGRect(x: 440, y: 60, width: 320, height: 780))
            try expectRect(
                SnapLayout.rightThird.frame(in: visible, gap: 10),
                CGRect(x: 770, y: 60, width: 320, height: 780))
        }),
        ("two thirds with a 10 pt gap", {
            try expectRect(
                SnapLayout.leftTwoThirds.frame(in: visible, gap: 10),
                CGRect(x: 110, y: 60, width: 650, height: 780))
            try expectRect(
                SnapLayout.centerTwoThirds.frame(in: visible, gap: 10),
                CGRect(x: 275, y: 60, width: 650, height: 780))
            try expectRect(
                SnapLayout.rightTwoThirds.frame(in: visible, gap: 10),
                CGRect(x: 440, y: 60, width: 650, height: 780))
        }),
        ("maximize and center respect the gap", {
            try expectRect(
                SnapLayout.maximize.frame(in: visible, gap: 10),
                CGRect(x: 110, y: 60, width: 980, height: 780))
            try expectRect(
                SnapLayout.center.frame(in: visible, gap: 10, currentSize: CGSize(width: 400, height: 300)),
                CGRect(x: 400, y: 300, width: 400, height: 300))
            try expectRect(
                SnapLayout.center.frame(in: visible, gap: 10, currentSize: CGSize(width: 5000, height: 5000)),
                CGRect(x: 110, y: 60, width: 980, height: 780))
        }),
        ("neighbours are exactly one gap apart", {
            let left = SnapLayout.leftHalf.frame(in: visible, gap: 10)
            let right = SnapLayout.rightHalf.frame(in: visible, gap: 10)
            try expectEqual(right.minX - left.maxX, 10, "gap between the halves")
            let first = SnapLayout.leftThird.frame(in: visible, gap: 10)
            let second = SnapLayout.middleThird.frame(in: visible, gap: 10)
            let thirdCol = SnapLayout.rightThird.frame(in: visible, gap: 10)
            try expectEqual(second.minX - first.maxX, 10, "gap between thirds")
            try expectEqual(thirdCol.minX - second.maxX, 10, "gap between thirds")
        }),
        ("a negative gap is treated as zero", {
            try expectRect(SnapLayout.maximize.frame(in: visible, gap: -20), visible)
        }),
        ("an absurd gap falls back to the visible frame", {
            try expectRect(SnapLayout.leftHalf.frame(in: visible, gap: 900), visible)
        }),
        ("rounding is only applied on the way out", {
            let third = SnapLayout.leftThird.frame(in: visible)
            try expectEqual(third.snapRounded.width, 333)
            try expectEqual(third.width == 333, false, "frame() itself does not round")
        }),
    ]
}

// MARK: - Coordinate conversion

enum GeometryTests {
    /// A 1200 pt tall primary screen: AX y = 1200 - Cocoa maxY.
    static let primaryHeight: CGFloat = 1200

    static let tests: [TestCase] = [
        ("cocoa rect flips to AX", {
            // A window 100 tall whose top edge is 200 below the top of the
            // screen: Cocoa maxY 1000, so AX minY 200.
            let cocoa = CGRect(x: 50, y: 900, width: 400, height: 100)
            let ax = SnapGeometry.flipRect(cocoa, primaryHeight: primaryHeight)
            try expectRect(ax, CGRect(x: 50, y: 200, width: 400, height: 100))
        }),
        ("the flip is its own inverse", {
            let cocoa = CGRect(x: -300, y: 120, width: 640, height: 480)
            let there = SnapGeometry.flipRect(cocoa, primaryHeight: primaryHeight)
            let back = SnapGeometry.flipRect(there, primaryHeight: primaryHeight)
            try expectRect(back, cocoa)
        }),
        ("a screen above the primary keeps a positive Cocoa y", {
            // Second display sitting on top of the primary: Cocoa y 1200,
            // AX y -400 (above the primary's origin).
            let cocoa = CGRect(x: 0, y: 1200, width: 1600, height: 400)
            let ax = SnapGeometry.flipRect(cocoa, primaryHeight: primaryHeight)
            try expectRect(ax, CGRect(x: 0, y: -400, width: 1600, height: 400))
        }),
        ("points flip both ways", {
            let cocoa = CGPoint(x: 10, y: 1150)
            let ax = SnapGeometry.flipPoint(cocoa, primaryHeight: primaryHeight)
            try expectEqual(ax.y, 50)
            try expectEqual(SnapGeometry.flipPoint(ax, primaryHeight: primaryHeight).y, cocoa.y)
        }),
        ("rounding a frame keeps whole points", {
            let rect = CGRect(x: 10.4, y: 20.6, width: 333.33, height: 199.5)
            try expectRect(rect.snapRounded, CGRect(x: 10, y: 21, width: 333, height: 200))
        }),
    ]
}

// MARK: - Restore memory

enum RestoreMemoryTests {
    static func identity(_ id: CGWindowID) -> WindowIdentity {
        WindowIdentity(pid: 501, windowID: id, title: "")
    }

    static let tests: [TestCase] = [
        ("remembers the first frame only", {
            let memory = RestoreMemory()
            let window = identity(1)
            let original = CGRect(x: 0, y: 0, width: 400, height: 300)
            memory.rememberIfNeeded(window, frame: original)
            memory.rememberIfNeeded(window, frame: CGRect(x: 9, y: 9, width: 9, height: 9))
            try expectEqual(memory.frame(for: window), original)
            try expectEqual(memory.count, 1)
        }),
        ("restore hands the frame back and forgets it", {
            let memory = RestoreMemory()
            let window = identity(2)
            let original = CGRect(x: 5, y: 6, width: 700, height: 500)
            memory.rememberIfNeeded(window, frame: original)
            try expect(memory.has(window), "remembered")
            try expectEqual(memory.restore(window), original)
            try expect(!memory.has(window), "forgotten after restore")
            try expectNil(memory.restore(window))
            try expectEqual(memory.count, 0)
        }),
        ("an unknown window restores to nothing", {
            let memory = RestoreMemory()
            try expectNil(memory.restore(identity(99)))
        }),
        ("the oldest entry is evicted at capacity", {
            let memory = RestoreMemory(capacity: 3)
            for index in 1...4 {
                memory.rememberIfNeeded(
                    identity(CGWindowID(index)),
                    frame: CGRect(x: CGFloat(index), y: 0, width: 100, height: 100))
            }
            try expectEqual(memory.count, 3)
            try expectNil(memory.frame(for: identity(1)))
            try expectNotNil(memory.frame(for: identity(4)))
        }),
        ("the default cap is 64", {
            let memory = RestoreMemory()
            try expectEqual(memory.capacity, 64)
            for index in 1...100 {
                memory.rememberIfNeeded(identity(CGWindowID(index)), frame: .zero)
            }
            try expectEqual(memory.count, 64)
            try expectNil(memory.frame(for: identity(36)))
            try expectNotNil(memory.frame(for: identity(37)))
        }),
        ("quitting an app drops its windows", {
            let memory = RestoreMemory()
            memory.rememberIfNeeded(WindowIdentity(pid: 1, windowID: 10), frame: .zero)
            memory.rememberIfNeeded(WindowIdentity(pid: 2, windowID: 11), frame: .zero)
            memory.forgetAll(pid: 1)
            try expectEqual(memory.count, 1)
            try expectNotNil(memory.frame(for: WindowIdentity(pid: 2, windowID: 11)))
        }),
        ("a window id makes the title irrelevant", {
            let before = WindowIdentity(pid: 7, windowID: 42, title: "Untitled")
            let after = WindowIdentity(pid: 7, windowID: 42, title: "Renamed")
            try expectEqual(before, after)
        }),
        ("without a window id the title identifies the window", {
            let a = WindowIdentity(pid: 7, windowID: 0, title: "One")
            let b = WindowIdentity(pid: 7, windowID: 0, title: "Two")
            try expect(a != b, "different titles are different windows")
        }),
    ]
}

// MARK: - Title bar hit rule

enum TitleBarHitTests {
    /// An AX window frame: top-left origin, so y = 100 is its top edge.
    static let window = CGRect(x: 200, y: 100, width: 900, height: 600)

    static let tests: [TestCase] = [
        ("the window's own chrome in the band is a hit", {
            try expect(
                TitleBarClickWatcher.isTitleBarHit(role: "AXWindow", pointY: 110, windowFrame: window),
                "window role near the top edge")
        }),
        ("toolbars and the title text are hits", {
            try expect(TitleBarClickWatcher.isTitleBarHit(role: "AXToolbar", pointY: 115, windowFrame: window), "toolbar")
            try expect(TitleBarClickWatcher.isTitleBarHit(role: "AXStaticText", pointY: 112, windowFrame: window), "title")
        }),
        ("unnamed chrome in the band is a hit", {
            try expect(TitleBarClickWatcher.isTitleBarHit(role: nil, pointY: 101, windowFrame: window), "no role")
            try expect(TitleBarClickWatcher.isTitleBarHit(role: "AXGroup", pointY: 101, windowFrame: window), "group")
        }),
        ("controls in the band are not hits", {
            for role in ["AXButton", "AXTextField", "AXPopUpButton", "AXTabGroup", "AXSearchField", "AXMenuItem"] {
                try expect(
                    !TitleBarClickWatcher.isTitleBarHit(role: role, pointY: 110, windowFrame: window),
                    "\(role) must not maximize")
            }
        }),
        ("below the band is never a hit", {
            try expect(
                !TitleBarClickWatcher.isTitleBarHit(role: "AXWindow", pointY: 400, windowFrame: window),
                "middle of the window")
            try expect(
                !TitleBarClickWatcher.isTitleBarHit(role: "AXStaticText", pointY: 131, windowFrame: window),
                "one point past the band")
        }),
        ("the band is exactly 30 points from the top edge", {
            try expectEqual(TitleBarClickWatcher.titleBarBand, 30)
            try expect(
                TitleBarClickWatcher.isTitleBarHit(role: "AXWindow", pointY: 129.9, windowFrame: window),
                "inside the band")
            try expect(
                !TitleBarClickWatcher.isTitleBarHit(role: "AXWindow", pointY: 130, windowFrame: window),
                "the band is half-open")
        }),
        ("above the window is not a hit", {
            try expect(
                !TitleBarClickWatcher.isTitleBarHit(role: "AXWindow", pointY: 99, windowFrame: window),
                "over the menu bar")
        }),
        ("an empty window frame is not a hit", {
            try expect(
                !TitleBarClickWatcher.isTitleBarHit(role: "AXWindow", pointY: 0, windowFrame: .zero),
                "no frame, no title bar")
        }),
    ]
}

// MARK: - Feature wiring

enum FeatureTests {
    static let tests: [TestCase] = [
        ("identity", {
            let feature = SnapFeature()
            try expectEqual(feature.id, "snap")
            try expectEqual(feature.title, "Snap")
            try expectEqual(feature.requiredPermissions, [.accessibility, .automation])
        }),
        ("every BetterTouchTool trigger has an action", {
            let ids = Set(SnapFeature.actionTable.map(\.id))
            let expected: Set<String> = [
                "snap.leftHalf", "snap.rightHalf", "snap.topHalf", "snap.bottomHalf",
                "snap.maximize", "snap.restore", "snap.center",
                "snap.topLeft", "snap.topRight", "snap.bottomLeft", "snap.bottomRight",
                "snap.leftThird", "snap.middleThird", "snap.rightThird",
                "snap.leftTwoThirds", "snap.centerTwoThirds", "snap.rightTwoThirds",
                "snap.previousWindow", "snap.terminalScript", "snap.downloadsScript",
            ]
            try expectEqual(ids, expected)
            try expectEqual(SnapFeature.actionTable.count, 20)
        }),
        ("every layout is reachable from a shortcut", {
            let layouts = SnapFeature.actionTable.compactMap { entry -> SnapLayout? in
                if case .layout(let layout) = entry.action { return layout }
                return nil
            }
            try expectEqual(Set(layouts), Set(SnapLayout.allCases))
        }),
        ("default bindings match the exported triggers", {
            func binding(_ id: String) -> KeyBinding? {
                SnapFeature.actionTable.first { $0.id == id }?.binding
            }
            try expectEqual(binding("snap.leftHalf"), KeyBinding(123, [.control, .command]))
            try expectEqual(binding("snap.maximize"), KeyBinding(36, [.control, .command]))
            try expectEqual(binding("snap.restore"), KeyBinding(51, [.control, .command]))
            try expectEqual(binding("snap.center"), KeyBinding(8, [.control, .command]))
            try expectEqual(binding("snap.bottomRight"), KeyBinding(39, [.control, .command]))
            try expectEqual(binding("snap.centerTwoThirds"), KeyBinding(40, [.control, .command]))
            try expectEqual(binding("snap.previousWindow"), KeyBinding(48, [.option]))
            try expectEqual(binding("snap.terminalScript"), KeyBinding(17, [.control, .command]))
            try expectEqual(binding("snap.downloadsScript"), KeyBinding(14, [.command]))
        }),
        ("no two actions ship with the same shortcut", {
            var seen: Set<KeyBinding> = []
            for entry in SnapFeature.actionTable {
                guard let binding = entry.binding else { continue }
                try expect(seen.insert(binding).inserted, "duplicate default \(binding.display)")
            }
        }),
        ("hotkey actions mirror the table", {
            let feature = SnapFeature()
            try expectEqual(feature.hotkeyActions.count, SnapFeature.actionTable.count)
            try expect(feature.hotkeyActions.allSatisfy { $0.featureID == "snap" }, "feature id on every action")
            try expect(
                feature.hotkeyActions.allSatisfy { $0.id.hasPrefix("snap.") },
                "every action id is namespaced")
        }),
        ("script defaults are the exported ones", {
            try expect(
                SnapSettings.Defaults.terminalScript.contains("do script \"\""),
                "Terminal script opens a new window in a running Terminal")
            try expect(
                SnapSettings.Defaults.downloadsScript.contains("folder \"Downloads\" of home"),
                "Finder script targets Downloads")
        }),
        ("the gap is clamped", {
            let settings = SnapSettings(defaults: UserDefaults(suiteName: "snap.tests.\(UUID().uuidString)")!)
            settings.gap = -5
            try expectEqual(settings.effectiveGap, 0)
            settings.gap = 10_000
            try expectEqual(settings.effectiveGap, 200)
            settings.gap = 12
            try expectEqual(settings.effectiveGap, 12)
        }),
        ("settings defaults", {
            let suite = "snap.tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let settings = SnapSettings(defaults: defaults)
            try expectEqual(settings.gap, 0)
            try expect(settings.titleBarDoubleClick, "title bar gesture is on by default")
            try expect(settings.titleBarDoubleClickRestores, "the second double-click restores by default")
            try expectEqual(settings.terminalScript, SnapSettings.Defaults.terminalScript)
        }),
        ("a reset puts the shipped script back", {
            let suite = "snap.tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let settings = SnapSettings(defaults: defaults)
            settings.terminalScript = "beep"
            settings.downloadsScript = "beep"
            settings.resetTerminalScript()
            settings.resetDownloadsScript()
            try expectEqual(settings.terminalScript, SnapSettings.Defaults.terminalScript)
            try expectEqual(settings.downloadsScript, SnapSettings.Defaults.downloadsScript)
        }),
    ]
}
