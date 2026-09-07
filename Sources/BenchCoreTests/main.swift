import AppKit
import BenchTestKit
@testable import BenchCore

let suites: [TestSuite] = [
    ("KeyBindingTests", KeyBindingTests.tests),
    ("ShortcutStoreTests", ShortcutStoreTests.tests),
    ("SystemHotkeysTests", SystemHotkeysTests.tests),
    ("RecorderOutcomeTests", RecorderOutcomeTests.tests),
]

exit(MainActor.assumeIsolated { runSuites(suites) })
