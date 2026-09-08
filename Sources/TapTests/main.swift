import AppKit
import BenchTestKit
@testable import Tap

// Top-level code in main.swift is nonisolated; the suites run inside the
// MainActor block below so they may touch @MainActor types freely.
//
// Everything here is pure: the tap decision logic, the settings round-trip
// and the feature's own description. Nothing in this runner loads
// MultitouchSupport, installs an event tap, or posts a mouse event.
exit(MainActor.assumeIsolated {
    let suites: [TestSuite] = [
        ("TapDetectorTests", TapDetectorTests.tests),
        ("ContactFilterTests", ContactFilterTests.tests),
        ("SettingsTests", SettingsTests.tests),
        ("FeatureTests", FeatureTests.tests),
    ]
    return runSuites(suites)
})
