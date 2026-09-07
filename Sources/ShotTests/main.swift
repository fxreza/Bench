// Shot's test runner. Ported from Snapper's Tests/Suites.swift and
// Tests/TestRunner.swift (MIT, Copyright 2026 Sam Reza); the runner itself is
// `BenchTestKit.runSuites` now, so only the registry is left. Each suite is a
// `static let suite` on its own enum - list it below to register it.

import AppKit
import BenchCore
import BenchTestKit
@testable import Shot

// Top-level code in main.swift is nonisolated; every suite runs inside the
// MainActor block below, so tests may touch @MainActor types freely.
exit(MainActor.assumeIsolated {
    // Bench registers every feature's actions with `ShortcutStore` at launch;
    // the suites that resolve an effective binding need the same state.
    ShortcutStore.shared.registerActions(ShotFeature().hotkeyActions)

    let suites: [TestSuite] = [
        ("SmokeTests", [
            ("the feature keeps its id", { try expectEqual(ShotFeature().id, "shot") }),
        ]),
        AnnotationDocumentTests.suite,
        RendererTests.suite,
        HitTestingTests.suite,
        ScreenshotDefaultsTests.suite,
        CaptureFormatTests.suite,
        TextRecognizerTests.suite,
        ScrollStitcherTests.suite,
        SelectionLayoutTests.suite,
    ]
    return runSuites(suites)
})
