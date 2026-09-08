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
                "snap.openApp1", "snap.openApp2", "snap.openApp3",
            ]
            try expectEqual(ids, expected)
            try expectEqual(SnapFeature.actionTable.count, 23)
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
            // Launchers live on Caps Lock+⌥ (⌃⌥), away from the ⌃⌘ window family.
            try expectEqual(binding("snap.terminalScript"), KeyBinding(17, [.control, .option]))
            try expectEqual(binding("snap.downloadsScript"), KeyBinding(14, [.control, .option]))
            // The spare app launchers ship unbound.
            for slot in 1...SnapSettings.launcherSlots {
                try expectEqual(binding("snap.openApp\(slot)"), nil)
            }
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

// MARK: - Modifier move / resize

/// Pure arithmetic only: no Accessibility, no event monitors, no timer.
/// Frames are AX coordinates (top-left origin, y down) and pointers are Cocoa
/// (bottom-left origin, y up) - exactly the mix `ModifierDragController`
/// hands to the math.
enum ModifierDragTests {
    /// `XCTUnwrap` for a runner with no XCTest: a nil frame fails the test
    /// instead of trapping.
    static func require(
        _ rect: CGRect?, _ message: String = "expected a frame",
        file: StaticString = #file, line: UInt = #line
    ) throws -> CGRect {
        guard let rect else { throw TestFailure(message: message, file: file, line: line) }
        return rect
    }

    /// A 400 x 300 window whose top edge is 200 pt below the top of the screen.
    static let frame = CGRect(x: 100, y: 200, width: 400, height: 300)
    static let start = CGPoint(x: 500, y: 500)

    static let tests: [TestCase] = [
        ("below the threshold nothing moves", {
            // ~1.4 pt of travel against a 2 pt threshold.
            let pointer = CGPoint(x: start.x + 1, y: start.y + 1)
            try expectNil(ModifierDragMath.frame(
                for: .move, startFrame: frame, startPointer: start, pointer: pointer, threshold: 2))
            try expectNil(ModifierDragMath.frame(
                for: .resize, startFrame: frame, startPointer: start, pointer: pointer, threshold: 2))
        }),
        ("the threshold is a distance, not a per-axis limit", {
            try expect(
                ModifierDragMath.passedThreshold(from: start, to: CGPoint(x: 502, y: 500), threshold: 2),
                "2 pt right is exactly the threshold")
            try expect(
                !ModifierDragMath.passedThreshold(from: start, to: CGPoint(x: 501, y: 500), threshold: 2),
                "1 pt right is not")
            try expect(
                ModifierDragMath.passedThreshold(from: start, to: start, threshold: 0),
                "a zero threshold is always passed")
        }),
        ("moving right and down carries the window along", {
            // Cocoa +30 x, -20 y (down the screen) is AX +30 x, +20 y.
            let pointer = CGPoint(x: start.x + 30, y: start.y - 20)
            let moved = try require(ModifierDragMath.frame(
                for: .move, startFrame: frame, startPointer: start, pointer: pointer, threshold: 2))
            try expectRect(moved, CGRect(x: 130, y: 220, width: 400, height: 300))
        }),
        ("moving left and up carries it back", {
            let pointer = CGPoint(x: start.x - 45, y: start.y + 15)
            let moved = try require(ModifierDragMath.frame(
                for: .move, startFrame: frame, startPointer: start, pointer: pointer, threshold: 2))
            try expectRect(moved, CGRect(x: 55, y: 185, width: 400, height: 300))
        }),
        ("resizing keeps the top-left corner and follows the pointer", {
            // Right grows the width, down grows the height.
            let pointer = CGPoint(x: start.x + 60, y: start.y - 40)
            let resized = try require(ModifierDragMath.frame(
                for: .resize, startFrame: frame, startPointer: start, pointer: pointer, threshold: 2))
            try expectRect(resized, CGRect(x: 100, y: 200, width: 460, height: 340))
        }),
        ("resizing the other way shrinks the window", {
            let pointer = CGPoint(x: start.x - 100, y: start.y + 50)
            let resized = try require(ModifierDragMath.frame(
                for: .resize, startFrame: frame, startPointer: start, pointer: pointer, threshold: 2))
            try expectRect(resized, CGRect(x: 100, y: 200, width: 300, height: 250))
        }),
        ("a resize is never driven below the minimum size", {
            let pointer = CGPoint(x: start.x - 5000, y: start.y + 5000)
            let resized = try require(ModifierDragMath.frame(
                for: .resize, startFrame: frame, startPointer: start, pointer: pointer, threshold: 2))
            try expectRect(resized, CGRect(x: 100, y: 200, width: 50, height: 50))
            try expectEqual(ModifierDragMath.minimumSize, CGSize(width: 50, height: 50))
        }),
        ("a move is never clamped, only a resize", {
            let pointer = CGPoint(x: start.x - 5000, y: start.y + 5000)
            let moved = try require(ModifierDragMath.frame(
                for: .move, startFrame: frame, startPointer: start, pointer: pointer, threshold: 2))
            try expectRect(moved, CGRect(x: -4900, y: -4800, width: 400, height: 300))
        }),
        ("a Cocoa pointer delta flips into AX space", {
            let delta = ModifierDragMath.axDelta(from: start, to: CGPoint(x: 510, y: 480))
            try expectEqual(delta.width, 10)
            try expectEqual(delta.height, 20, "down the screen is a positive AX delta")
        }),
        ("a modifier combination matches exactly", {
            let move: NSEvent.ModifierFlags = [.shift, .option]
            try expect(ModifierDragMath.matches([.shift, .option], move), "the combination itself")
            try expect(!ModifierDragMath.matches([.shift, .option, .command], move), "one extra modifier does not")
            try expect(!ModifierDragMath.matches([.shift], move), "one missing modifier does not")
            try expect(!ModifierDragMath.matches([.shift, .control], move), "the resize combination does not")
            try expect(!ModifierDragMath.matches([], move), "no modifiers at all does not")
        }),
        ("an empty combination is never triggered", {
            try expect(!ModifierDragMath.matches([], []), "nothing held")
            try expect(!ModifierDragMath.matches([.shift, .option], []), "something held")
        }),
        ("Caps Lock and the numeric pad do not break a match", {
            // Caps Lock is Right Control on this Mac, so a stray `.capsLock`
            // can only come from another keyboard - and either way it must
            // not cancel a gesture the user is deliberately holding.
            let resize: NSEvent.ModifierFlags = [.shift, .control]
            try expect(ModifierDragMath.matches([.shift, .control, .capsLock], resize), "caps lock ignored")
            try expect(ModifierDragMath.matches([.shift, .control, .numericPad], resize), "numeric pad ignored")
        }),
        ("either Control key is Control", {
            // The device-dependent right-Control bit (0x2000) sits below the
            // device-independent mask, so ⌃ is ⌃ whichever key was pressed.
            let rightControl = NSEvent.ModifierFlags(
                rawValue: NSEvent.ModifierFlags.control.rawValue | 0x2000).union(.shift)
            try expect(ModifierDragMath.matches(rightControl, [.shift, .control]), "right control matches")
        }),
        ("the shipped defaults are BetterTouchTool's", {
            try expectEqual(SnapSettings.Defaults.moveModifiers, [.shift, .option])
            try expectEqual(SnapSettings.Defaults.resizeModifiers, [.shift, .control])
            try expectEqual(SnapSettings.Defaults.dragThreshold, 2)
            try expect(!SnapSettings.Defaults.bringToFront, "bring to front is off")
            try expect(SnapSettings.Defaults.modifierDragEnabled, "the gestures are on")
        }),
        ("gesture settings round-trip through defaults", {
            let suite = "snap.tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            let settings = SnapSettings(defaults: defaults)
            settings.moveModifiers = [.control, .command]
            settings.dragThreshold = 7
            settings.bringToFront = true
            settings.modifierDragEnabled = false
            let reread = SnapSettings(defaults: defaults)
            try expectEqual(reread.moveModifiers, [.control, .command])
            try expectEqual(reread.dragThreshold, 7)
            try expect(reread.bringToFront, "bring to front persisted")
            try expect(!reread.modifierDragEnabled, "the enable flag persisted")
        }),
        ("the threshold is clamped", {
            let settings = SnapSettings(defaults: UserDefaults(suiteName: "snap.tests.\(UUID().uuidString)")!)
            settings.dragThreshold = -3
            try expectEqual(settings.effectiveDragThreshold, 0)
            settings.dragThreshold = 10_000
            try expectEqual(settings.effectiveDragThreshold, 100)
            settings.dragThreshold = 4
            try expectEqual(settings.effectiveDragThreshold, 4)
        }),
    ]
}
