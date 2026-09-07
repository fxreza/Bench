import AppKit
import BenchTestKit
@testable import Piko

// Top-level code in main.swift is nonisolated; every suite runs inside the
// MainActor block below, so tests may touch @MainActor types freely.
exit(MainActor.assumeIsolated {
    let suites: [TestSuite] = [
        ("NotchGeometryTests", NotchGeometryTests.tests),
        ("MediaRemoteStreamParserTests", MediaRemoteStreamParserTests.tests),
        ("ModelsTests", ModelsTests.tests),
        ("SettingsTests", SettingsTests.tests),
        ("BundledResourceTests", BundledResourceTests.tests),
        ("FeatureTests", FeatureTests.tests),
    ]
    return runSuites(suites)
})
