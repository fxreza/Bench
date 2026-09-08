import AppKit
import BenchTestKit
@testable import Snap

// Top-level code in main.swift is nonisolated; every suite runs inside the
// MainActor block below, so tests may touch @MainActor types freely.
//
// Everything here is pure: geometry, the restore-memory bookkeeping, the
// title bar hit rule and the action table. Nothing in this runner talks to
// Accessibility, installs an event tap, moves a window or runs a script.
exit(MainActor.assumeIsolated {
    let suites: [TestSuite] = [
        ("LayoutTests", LayoutTests.tests),
        ("GapTests", GapTests.tests),
        ("GeometryTests", GeometryTests.tests),
        ("RestoreMemoryTests", RestoreMemoryTests.tests),
        ("FeatureTests", FeatureTests.tests),
        ("ModifierDragTests", ModifierDragTests.tests),
    ]
    return runSuites(suites)
})
