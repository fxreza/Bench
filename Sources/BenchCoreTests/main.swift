import AppKit
import BenchTestKit
@testable import BenchCore

let suites: [TestSuite] = [
    ("KeyBindingTests", KeyBindingTests.tests),
    ("ShortcutStoreTests", ShortcutStoreTests.tests),
    ("SystemHotkeysTests", SystemHotkeysTests.tests),
    ("RecorderOutcomeTests", RecorderOutcomeTests.tests),
    ("CloudDriveTests", CloudDriveTests.tests),
    ("SettingsSyncTests", SettingsSyncTests.tests),
]

exit(MainActor.assumeIsolated { runSuites(suites) })
