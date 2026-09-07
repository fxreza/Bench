import Foundation
import AppKit
import SwiftUI
import BenchTestKit
@testable import Klip

// Regressions from `docs/plan/review-5A.md` that live under `Views/`:
// 5A-07 / 5A-10 (thumbnail rendering + cache), 5A-14 (the pinned-first
// invariant the list's new separator logic relies on), 5A-22 (a stale
// selection index), 5A-30 (selection-wide menu labels) and review-2B's
// Clear History wording.
enum ViewRegressionTests {
    static let tests: [(String, () throws -> Void)] = [
        ("thumbnail_rendersOffTheMainThreadWithoutLockFocus", testThumbnailRendersOffMain),
        ("thumbnail_isCachedPerItemAndSizeAndEvictedOnDelete", testThumbnailCache),
        ("filteredItems_pinnedRunIsAContiguousPrefix", testPinnedPrefixInvariant),
        ("staleSelectionIndex_isClampedAndExtendSelectionIsSafe", testStaleSelectionIndex),
        ("rowMenuLabels_nameTheSelectionWideEntries", testRowMenuLabels),
        ("clearHistoryMessage_saysProtectedOrLocked", testClearHistoryMessage),
        // 3.0.1 — the QLPreviewView crash.
        ("filePreview_paneRendersAFileClipWithoutAborting", testFilePreviewPaneRenders),
        ("filePreview_thumbnailIsCachedAndKindLabelled", testFileThumbnailAndKindLabel),
        ("ocrCopyButton_writesPlainTextAndConfirms", testOCRCopy),
    ]

    // MARK: - Helpers

    /// A tiny solid-colour PNG.
    private static func pngData(width: Int = 64, height: Int = 64) throws -> Data {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw TestFailure(message: "could not make a bitmap", file: #file, line: #line) }
        rep.size = NSSize(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw TestFailure(message: "could not encode PNG", file: #file, line: #line)
        }
        return data
    }

    /// Runs the main run loop until `condition` holds or `timeout` elapses.
    @discardableResult
    private static func pump(timeout: TimeInterval = 5, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    // MARK: - 5A-07: no `lockFocus` off the main thread

    /// `NSImage.lockFocus` is main-thread-only; the renderer now draws into
    /// an `NSBitmapImageRep` through an explicit context, which is safe from
    /// any thread. This drives it from a background queue, which is exactly
    /// how `ClipRow` uses it.
    static func testThumbnailRendersOffMain() throws {
        let source = NSImage(data: try pngData())
        try expectNotNil(source, "precondition: the fixture image decodes")

        var rendered: NSImage?
        var finished = false
        DispatchQueue.global(qos: .userInitiated).async {
            rendered = ImageThumbnailCache.render(source!, size: NSSize(width: 76, height: 76))
            finished = true
        }
        try expect(pump { finished }, "the background render should complete")

        let thumb = try require(rendered, "an off-main render must produce an image")
        try expectEqual(thumb.size, NSSize(width: 76, height: 76), "the thumbnail is the requested size")
        try expect(!thumb.representations.isEmpty, "the thumbnail carries a real bitmap representation")
    }

    // MARK: - 5A-10: thumbnails are cached, and dropped on delete

    static func testThumbnailCache() throws {
        try ClipboardStoreTests.withStore { store, _ in
            let filename = try require(store.saveImage(try pngData()), "the fixture image should save")
            var item = ClipboardItem.image(filename: filename)
            item.kind = .image
            store.add(item)

            func thumbnail(size: CGFloat = 38) throws -> NSImage {
                var result: NSImage??
                Task { result = await ImageThumbnailCache.thumbnail(for: item, store: store, size: size) }
                try expect(pump { result != nil }, "the thumbnail request should finish")
                return try require(result ?? nil, "the thumbnail should render")
            }

            let first = try thumbnail()
            let second = try thumbnail()
            try expect(first === second, "a second request for the same item and size is a cache hit")

            let bigger = try thumbnail(size: 240)
            try expect(bigger !== first, "a different size is a different cache entry")

            ImageThumbnailCache.evict(itemIDs: [item.id])
            let afterEvict = try thumbnail()
            try expect(afterEvict !== first, "eviction drops the cached copy")
        }
    }


    // MARK: - 3.0.1: the file preview must not abort during layout

    /// The 3.0.0 crash: `PreviewPane.fileBody` embedded a `QLPreviewView`
    /// through an `NSViewRepresentable`, and `updateNSView` set its
    /// `previewItem` — i.e. called `-[QLPreviewView setPreviewItem:]` from
    /// inside `NSHostingView.layout()`. QuickLook raises an assertion there
    /// and calls `abort()`, so the app died the moment a file clip was
    /// selected (three user crash reports).
    ///
    /// This drives exactly that path: a real `.file` clip, selected, hosted
    /// and laid out for real. Against 3.0.0's `PreviewPane` this test
    /// aborts the whole runner; against 3.0.1 it renders a static thumbnail
    /// and returns. `scripts/gate.sh` additionally fails the build if
    /// `QLPreviewView` ever reappears as a symbol in the binary.
    static func testFilePreviewPaneRenders() throws {
        _ = NSApplication.shared

        try ClipboardStoreTests.withStore { store, _ in
            try withTempDir { sourceDir in
                let url = sourceDir.appendingPathComponent("note.txt")
                try Data("hello from a file clip".utf8).write(to: url)

                guard let (item, _) = store.makeFileItem(from: [url], sourceApp: "Finder") else {
                    throw TestFailure(message: "makeFileItem should capture a small file", file: #file, line: #line)
                }
                store.add(item)

                let viewModel = HistoryViewModel(store: store)
                viewModel.applyFilters(resetSelection: .defaultItem)
                viewModel.selectSingle(item.id)
                try expectEqual(viewModel.selectedItem?.id, item.id, "precondition: the file clip is selected")
                try expectEqual(viewModel.selectedItem?.type, .file, "precondition: it is a .file clip")

                let host = NSHostingView(rootView: FilePreviewHarness(store: store, viewModel: viewModel))
                host.frame = NSRect(x: 0, y: 0, width: 320, height: 620)
                let window = NSWindow(
                    contentRect: host.frame,
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: true
                )
                window.contentView = host
                defer { window.contentView = nil }

                // First layout — this is where 3.0.0 aborted.
                host.layoutSubtreeIfNeeded()

                // Let the async thumbnail land, then lay out again so the
                // pane re-renders with an image in it.
                pump(timeout: 2) { false }
                host.layoutSubtreeIfNeeded()

                try expect(host.frame.width > 0, "the hosted preview pane still has a frame after layout")
                try expectEqual(viewModel.selectedItem?.id, item.id, "the selection survived the render")
            }
        }
    }

    /// The replacement rendering path: a real QuickLook *thumbnail* (not a UI
    /// class), cached per item and size, plus the kind label the fallback
    /// card shows next to the name.
    static func testFileThumbnailAndKindLabel() throws {
        try withTempDir { dir in
            let url = dir.appendingPathComponent("swatch.png")
            try pngData(width: 128, height: 96).write(to: url)
            let itemID = UUID()
            let size = CGSize(width: 240, height: 320)

            func thumbnail(_ size: CGSize) throws -> NSImage {
                var result: NSImage??
                Task { result = await FilePreview.thumbnail(for: url, itemID: itemID, size: size) }
                try expect(pump { result != nil }, "the thumbnail request should finish")
                return try require(result ?? nil, "QuickLook should render a thumbnail for a PNG")
            }

            let first = try thumbnail(size)
            let second = try thumbnail(size)
            try expect(first === second, "a second request for the same item and size is a cache hit")

            let wider = try thumbnail(CGSize(width: 400, height: 320))
            try expect(wider !== first, "a different pane width is a different cache entry")

            try expectEqual(FilePreview.kindLabel(for: url, name: "swatch.png"), "PNG image")
            try expectEqual(FilePreview.kindLabel(for: nil, name: "gone.pdf"), "PDF file",
                            "a missing file still names its kind from the extension")
            try expectNil(FilePreview.kindLabel(for: nil, name: "noextension"))
        }
    }


    // MARK: - 3.0.1 user item 11: the OCR copy button

    /// The copy icon beside OCR-extracted text wrote to the pasteboard with
    /// no feedback at all, so a missed click on the bare 12 pt glyph was
    /// indistinguishable from a failed copy. It now goes through
    /// `PasteController.copyPlainText` (ignore-next-change first, then the
    /// write) and toasts on success.
    ///
    /// Runs against a private pasteboard, never `.general` — a test must not
    /// touch the user's real clipboard.
    static func testOCRCopy() throws {
        try FolderUXTests.withViewModel { vm, _ in
            let board = NSPasteboard(name: NSPasteboard.Name("KlipTests-ocr-\(UUID().uuidString)"))
            defer { board.releaseGlobally() }

            vm.copyOCRText("  Receipt total 42.00  ", to: board)
            try expectEqual(board.string(forType: .string), "Receipt total 42.00",
                            "the OCR text lands on the pasteboard, trimmed")
            try expectEqual(vm.toast?.text, "OCR text copied", "a successful copy confirms itself")

            // Nothing to copy: no write, and no toast claiming otherwise.
            vm.toast = nil
            board.clearContents()
            vm.copyOCRText("   \n  ", to: board)
            try expectNil(board.string(forType: .string), "an empty OCR string writes nothing")
            try expectNil(vm.toast, "and does not claim to have copied")
        }
    }

    // MARK: - 5A-14: the invariant the list's separator logic relies on

    /// `ClipList` no longer materialises `Array(items.enumerated())`; it
    /// counts the pinned prefix instead. That is only equivalent because
    /// `FilterState.apply` partitions pinned items to the front as a
    /// contiguous run — pinned here, so the list cannot silently start
    /// drawing separators in the wrong place.
    static func testPinnedPrefixInvariant() throws {
        var items: [ClipboardItem] = []
        for i in 0..<40 {
            items.append(ClipboardItem(type: .text, textContent: "item \(i)", isPinned: i % 7 == 0))
        }
        let filtered = FilterState.apply(items, FilterState())
        let pinnedCount = filtered.prefix(while: { $0.isPinned }).count

        try expectEqual(pinnedCount, items.filter { $0.isPinned }.count,
                        "every pinned item is in the leading run")
        try expect(filtered.dropFirst(pinnedCount).allSatisfy { !$0.isPinned },
                   "nothing pinned appears after the run")

        // The first unpinned row — where the separator is drawn.
        try expectEqual(filtered[safe: pinnedCount]?.isPinned, false)
    }

    // MARK: - 5A-22: a stale index must not crash ⇧↑ / ⇧↓

    static func testStaleSelectionIndex() throws {
        try FolderUXTests.withViewModel { vm, store in
            FolderUXTests.seed(vm, store, ["a", "b", "c", "d", "e"])
            vm.applyFilters(resetSelection: .defaultItem)

            // The latent state the finding describes: an index left pointing
            // past the end of a now-shorter list, with no selected id to
            // re-anchor it.
            vm.selectedID = nil
            vm.selectedIDs = []
            vm.selectedIndex = 4
            store.items = Array(store.items.prefix(2))
            vm.applyFilters(resetSelection: .preserve)

            try expect(vm.selectedIndex < vm.filteredItems.count,
                       "applyFilters must clamp an out-of-range index")

            // Both of these used to index `filteredItems` directly.
            vm.keyExtendUp()
            vm.keyExtendDown()

            // And with an empty list.
            store.items = []
            vm.applyFilters(resetSelection: .preserve)
            vm.keyExtendUp()
            vm.keyExtendDown()
            try expectEqual(vm.selectedIndex, 0, "an empty list clamps to 0")
        }
    }

    // MARK: - 5A-30 / review-2B wording

    static func testRowMenuLabels() throws {
        try expectEqual(RowMenuLabels.lock(selectionCount: 1, allLocked: false), "Lock")
        try expectEqual(RowMenuLabels.lock(selectionCount: 1, allLocked: true), "Unlock")
        try expectEqual(RowMenuLabels.lock(selectionCount: 10, allLocked: false), "Lock 10 Clips",
                        "a selection-wide lock says how many clips it will lock")
        try expectEqual(RowMenuLabels.lock(selectionCount: 10, allLocked: true), "Unlock 10 Clips")
        try expectEqual(RowMenuLabels.delete(selectionCount: 1), "Delete")
        try expectEqual(RowMenuLabels.delete(selectionCount: 3), "Delete 3 Clips")
        try expectEqual(RowMenuLabels.moveToFolder(selectionCount: 1), "Move to Folder")
        try expectEqual(RowMenuLabels.moveToFolder(selectionCount: 2), "Move 2 Clips to Folder")
        try expectEqual(RowMenuLabels.saveToDisk(selectionCount: 1), "Save to Disk…")
        try expectEqual(RowMenuLabels.saveToDisk(selectionCount: 4), "Save 4 Clips to Disk…")
    }

    static func testClearHistoryMessage() throws {
        try expectEqual(
            ClearHistoryAlert.clearResultMessage(deleted: 12, kept: 0, keepProtected: true),
            "Cleared 12 clips."
        )
        try expectEqual(
            ClearHistoryAlert.clearResultMessage(deleted: 1, kept: 0, keepProtected: true),
            "Cleared 1 clip."
        )
        // Checkbox on: everything protected survives, not just locks.
        try expectEqual(
            ClearHistoryAlert.clearResultMessage(deleted: 12, kept: 3, keepProtected: true),
            "Cleared 12 clips; 3 protected clips kept."
        )
        try expectEqual(
            ClearHistoryAlert.clearResultMessage(deleted: 12, kept: 1, keepProtected: true),
            "Cleared 12 clips; 1 protected clip kept."
        )
        // Checkbox off: only locks can survive, so the wording says so.
        try expectEqual(
            ClearHistoryAlert.clearResultMessage(deleted: 12, kept: 2, keepProtected: false),
            "Cleared 12 clips; 2 locked clips kept."
        )
    }

    // MARK: - Local helper

    private static func require<T>(_ value: T?, _ message: String, file: StaticString = #file, line: UInt = #line) throws -> T {
        guard let value else { throw TestFailure(message: message, file: file, line: line) }
        return value
    }
}

/// Owns the `@FocusState` bindings `PreviewPane` requires — they can only
/// live inside a `View`, so the test cannot construct the pane directly.
private struct FilePreviewHarness: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var viewModel: HistoryViewModel
    @FocusState private var isTextEditorFocused: Bool
    @FocusState private var isEditTitleFocused: Bool
    @FocusState private var isTagInputFocused: Bool

    var body: some View {
        PreviewPane(
            store: store,
            viewModel: viewModel,
            isTextEditorFocused: $isTextEditorFocused,
            isEditTitleFocused: $isEditTitleFocused,
            isTagInputFocused: $isTagInputFocused
        )
    }
}
