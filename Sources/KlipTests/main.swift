import AppKit
import BenchTestKit
@testable import Klip

// Top-level code in main.swift is nonisolated; every suite runs inside the
// MainActor block below, so tests may touch @MainActor types freely.
exit(MainActor.assumeIsolated {
    let suites: [TestSuite] = [
        ("SmokeTests", [("feature id", { try expectEqual(KlipFeature().id, "klip") })]),
    ]
    return runSuites(suites)
})
