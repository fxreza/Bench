import Foundation
import AppKit
import BenchTestKit
@testable import Klip

// Capture path (review 5A-04 / 5A-29).
//
// `ClipboardWatcher.capture(from:)` is the poll body, split out of
// `checkClipboard()` so it can be driven against a **private** pasteboard —
// the tests below never touch `NSPasteboard.general`, so running them cannot
// disturb the user's clipboard.
//
// What is pinned here:
//  - a text clip still lands in the store, classified, with its rich flavors;
//  - consecutive duplicates are still skipped (the dedupe contract survives
//    the move of the expensive half to a background queue);
//  - a very large clip no longer freezes the caller: capture of a 15 MB clip
//    returns in milliseconds instead of the measured 5.0 s.
enum ClipboardWatcherTests {
    static let tests: [(String, () throws -> Void)] = [
        ("capture_textClipIsStoredAndClassified", testTextCapture),
        ("capture_consecutiveDuplicateIsSkipped", testDuplicateSkipped),
        ("capture_largeTextIsFileBackedAndDoesNotBlockTheCaller", testLargeTextCapture),
        ("ownWrite_flagRaisedBeforeAWriteSkipsThatWriteOnly", testOwnWriteSkipped),
        ("ownWrite_staleFlagDoesNotSwallowTheNextClip", testStaleFlagIgnored),
        ("ownWrite_flagRaisedAfterTheWriteWasConsumedCannotEatALaterClip", testLateFlagCannotEatLaterClip),
    ]

    // MARK: - Harness

    /// A pasteboard of our own, so nothing here reads or writes the real one.
    private static func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("com.fxreza.klip.tests.\(UUID().uuidString)"))
    }

    /// Runs the main run loop until `condition` holds or `timeout` elapses.
    /// The watcher hands finished captures back with `DispatchQueue.main.async`,
    /// which never runs while a test blocks the main thread.
    @discardableResult
    private static func pump(timeout: TimeInterval = 5, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private static func withWatcher(
        _ body: (ClipboardWatcher, ClipboardStore, NSPasteboard) throws -> Void
    ) throws {
        try ClipboardStoreTests.withStore { store, _ in
            let watcher = ClipboardWatcher(store: store)
            let pasteboard = makePasteboard()
            // Prime `lastChangeCount` against *this* pasteboard so the first
            // real write below is unambiguously a change.
            pasteboard.clearContents()
            watcher.capture(from: pasteboard)
            try body(watcher, store, pasteboard)
        }
    }

    private static func write(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Text capture

    static func testTextCapture() throws {
        try withWatcher { watcher, store, pasteboard in
            write("https://example.com/thing", to: pasteboard)
            watcher.capture(from: pasteboard)

            try expect(pump { store.items.count == 1 }, "the clip should reach the store")
            try expectEqual(store.items[0].textContent, "https://example.com/thing")
            try expectEqual(store.items[0].kind, .link, "detection still runs on the captured text")
        }
    }

    static func testDuplicateSkipped() throws {
        try withWatcher { watcher, store, pasteboard in
            write("same content", to: pasteboard)
            watcher.capture(from: pasteboard)
            try expect(pump { store.items.count == 1 }, "the first copy should be captured")

            // A second copy of identical content: a new changeCount, same
            // content hash — must not produce a second clip.
            write("same content", to: pasteboard)
            watcher.capture(from: pasteboard)
            pump(timeout: 0.5) { store.items.count > 1 }
            try expectEqual(store.items.count, 1, "a consecutive duplicate must still be skipped")

            // Different content is captured again.
            write("something else", to: pasteboard)
            watcher.capture(from: pasteboard)
            try expect(pump { store.items.count == 2 }, "new content should be captured")
        }
    }

    // MARK: - 5A-04: a huge clip must not freeze the caller

    static func testLargeTextCapture() throws {
        try withWatcher { watcher, store, pasteboard in
            // ~15 MB of log-shaped text — the exact shape that measured
            // 5,001 ms of main-thread time inside `ContentDetector.detect`.
            let line = "2026-05-01 12:00:00.123 [info] request handled in 12ms path=/v1/items status=200\n"
            var text = ""
            text.reserveCapacity(15_000_000)
            while text.utf8.count < 15_000_000 { text += line }

            write(text, to: pasteboard)

            let started = Date()
            watcher.capture(from: pasteboard)
            let blocked = Date().timeIntervalSince(started)

            // Deliberately loose (the harness reports the real number, which
            // is ~an order of magnitude below this): the point is that the
            // multi-second freeze is gone, without making the suite flaky on
            // a loaded machine.
            try expect(blocked < 0.5,
                       "capture must not block the caller (blocked \(Int(blocked * 1000)) ms)")

            try expect(pump(timeout: 20) { store.items.count == 1 }, "the clip should still arrive")
            let item = store.items[0]
            try expect(item.textFilename != nil, "a 15 MB clip is file-backed")
            try expectEqual(item.textContent?.count, 500, "the inline preview is still 500 chars")
            try expectEqual(store.fullText(for: item)?.utf8.count, text.utf8.count,
                            "the full text round-trips through the backing file")
        }
    }

    // MARK: - Own writes (the lost-screenshot bug)

    /// What every Klip paste/copy path does: raise the flag, then write.
    private static func raiseOwnWriteFlag() {
        NotificationCenter.default.post(name: .bufferIgnoreNextChange, object: nil)
    }

    static func testOwnWriteSkipped() throws {
        try withWatcher { watcher, store, pasteboard in
            raiseOwnWriteFlag()
            write("pasted from history", to: pasteboard)
            watcher.capture(from: pasteboard)
            pump(timeout: 0.3) { !store.items.isEmpty }
            try expectEqual(store.items.count, 0, "Klip's own write must not become a clip")

            // The flag was spent on that write; the next change is a real clip.
            write("a real copy", to: pasteboard)
            watcher.capture(from: pasteboard)
            try expect(pump { store.items.count == 1 }, "the following real clip must be captured")
            try expectEqual(store.items[0].textContent, "a real copy")
        }
    }

    static func testStaleFlagIgnored() throws {
        try withWatcher { watcher, store, pasteboard in
            var clock = Date()
            watcher.now = { clock }

            // A flag raised, then no pasteboard change for longer than the
            // window: it cannot belong to a write that is still coming.
            raiseOwnWriteFlag()
            clock = clock.addingTimeInterval(watcher.ownWriteWindow + 1)

            write("screenshot", to: pasteboard)
            watcher.capture(from: pasteboard)
            try expect(pump { store.items.count == 1 }, "a stale flag must not swallow a real clip")
        }
    }

    /// The exact sequence that lost screenshots: flag, write, poll (flag
    /// spent), a second flag raised 100 ms later with no write behind it,
    /// then the user's next capture.
    static func testLateFlagCannotEatLaterClip() throws {
        try withWatcher { watcher, store, pasteboard in
            var clock = Date()
            watcher.now = { clock }

            raiseOwnWriteFlag()
            write("pasted from history", to: pasteboard)
            watcher.capture(from: pasteboard)          // poll lands: flag spent

            clock = clock.addingTimeInterval(0.1)
            raiseOwnWriteFlag()                        // the late post, nothing written

            clock = clock.addingTimeInterval(watcher.ownWriteWindow + 0.5)   // user takes a screenshot later
            write("screenshot", to: pasteboard)
            watcher.capture(from: pasteboard)
            try expect(pump { store.items.count == 1 }, "the screenshot must be captured")
            try expectEqual(store.items[0].textContent, "screenshot")
        }
    }
}
