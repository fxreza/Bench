import AppKit
import BenchTestKit
@testable import Clean

// Top-level code in main.swift is nonisolated; the suites run inside the
// MainActor block below so they may touch @MainActor types freely.
//
// Everything here is pure: the hold-to-unlock logic and the settings
// round-trip. Nothing in this runner installs an event tap or opens a window.
exit(MainActor.assumeIsolated {
    let suites: [TestSuite] = [
        ("UnlockHoldTests", UnlockHoldTests.tests),
        ("SettingsTests", SettingsTests.tests),
    ]
    return runSuites(suites)
})
