import AppKit
import BenchTestKit
@testable import Klip

// Klip's test suites, registered by hand the way Klip's Tests/TestRunner.swift
// did — keep it obvious, no reflection or discovery. Top-level code in
// main.swift is nonisolated; every suite runs inside the MainActor block
// below, so tests may touch @MainActor types freely.
exit(MainActor.assumeIsolated {
    let suites: [TestSuite] = [
        ("ClipboardItemTests", ClipboardItemTests.tests),
        ("ClipboardStoreTests", ClipboardStoreTests.tests),
        ("DedupeTests", DedupeTests.tests),
        ("FolderOrderTests", FolderOrderTests.tests),
        ("TrashTests", TrashTests.tests),
        ("TrashUXTests", TrashUXTests.tests),
        ("DeleteConfirmTests", DeleteConfirmTests.tests),
        ("FolderTests", FolderTests.tests),
        ("FolderUXTests", FolderUXTests.tests),
        ("FilterStateTests", FilterStateTests.tests),
        ("ImageAnalysisTests", ImageAnalysisTests.tests),
        ("SemanticImageSearchTests", SemanticImageSearchTests.tests),
        ("TagsChipTests", TagsChipTests.tests),
        ("ClipTitleTests", ClipTitleTests.tests),
        ("WindowReopenTests", WindowReopenTests.tests),
        ("ActionBarLegendTests", ActionBarLegendTests.tests),
        ("SettingsManagerTests", SettingsManagerTests.tests),
        ("ShortcutTests", ShortcutTests.tests),
        ("KeyMonitorTests", KeyMonitorTests.tests),
        ("ContentDetectorTests", ContentDetectorTests.tests),
        ("ClipboardWatcherTests", ClipboardWatcherTests.tests),
        ("SourceAppCreditTests", SourceAppCreditTests.tests),
        ("SelectionTests", SelectionTests.tests),
        ("ImageFormatTests", ImageFormatTests.tests),
        ("LockTests", LockTests.tests),
        ("FileClipTests", FileClipTests.tests),
        ("RichCaptureTests", RichCaptureTests.tests),
        ("SyncMergeTests", SyncMergeTests.tests),
        ("SyncKindFilterTests", SyncKindFilterTests.tests),
        ("CloudDriveSyncTests", CloudDriveSyncTests.tests),
        ("StoreHardeningTests", StoreHardeningTests.tests),
        ("SyncLockTests", SyncLockTests.tests),
        ("ImageDimensionsTests", ImageDimensionsTests.tests),
        ("ItemFormatTests", ItemFormatTests.tests),
        ("ImageTextTests", ImageTextTests.tests),
        ("QRCodeTests", QRCodeTests.tests),
        ("ViewRegressionTests", ViewRegressionTests.tests),
        ("KlipFeatureTests", KlipFeatureTests.tests),
    ]
    return runSuites(suites)
})
