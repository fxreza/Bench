import AppKit
import ApplicationServices
import SelectedTextKit

/// Bounded selected-text capture.
///
/// Replaces `SelectedTextManager.getSelectedText(strategies:)`, whose built-in
/// chain has two problems for an interactive hotkey:
///
///  1. Its `.auto` strategy falls back to *menu-action copy*, which depth-first
///     walks the frontmost app's entire menu bar over the Accessibility API —
///     hundreds to thousands of cross-process calls, on the main thread, forcing
///     macOS to lazily build every submenu. We skip that strategy entirely and
///     go straight to the ⌘C fallback, which is what it degrades to anyway.
///  2. No strategy has a deadline, so one unresponsive app could stall the whole
///     capture for the AX messaging timeout (6s by default) and then keep going.
///     Here each strategy gets its own budget and the total is bounded.
enum TextCapture {

    /// Per-attempt deadlines. AX is near-instant when it works, so its budget is
    /// tight; the copy-based fallbacks need room for the pasteboard to settle.
    private enum Budget {
        static let accessibility: Duration = .milliseconds(400)
        static let appleScript: Duration = .milliseconds(1200)
        static let shortcut: Duration = .milliseconds(1500)
    }

    /// Lowers the process-wide Accessibility messaging timeout from the 6-second
    /// system default. A single `AXUIElementCopyAttributeValue` into a busy app
    /// (Electron, Chrome with a heavy tab, anything mid-beachball) would
    /// otherwise block for the full 6s before failing. Setting this on the
    /// system-wide element makes it the default for every AX element this
    /// process creates. Call once at launch.
    static func configureAccessibilityTimeout() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.4)
    }

    /// Reads the current selection, trying the cheap strategy first and falling
    /// back only as needed. Returns `nil` when nothing is selected.
    static func selectedText() async -> String? {
        // 1. Accessibility — works in most native apps, costs a few milliseconds.
        if let text = await attempt(within: Budget.accessibility, strategy: .accessibility) {
            return text
        }

        // 2. AppleScript — only meaningful in browsers, where AX often reports
        //    nothing for web content. Throws immediately elsewhere, so trying it
        //    unconditionally is cheap.
        if let text = await attempt(within: Budget.appleScript, strategy: .appleScript) {
            return text
        }

        // 3. Simulated ⌘C — the universal fallback. Backs up and restores the
        //    pasteboard itself (handled inside SelectedTextKit).
        return await attempt(within: Budget.shortcut, strategy: .shortcut)
    }

    /// Runs one strategy with a deadline. Any failure — thrown error, empty
    /// result, or blown budget — is reported as `nil` so the caller moves on.
    private static func attempt(within budget: Duration, strategy: TextStrategy) async -> String? {
        let text = await withDeadline(budget) {
            try? await SelectedTextManager.shared.getSelectedText(strategy: strategy)
        }
        guard let text = text ?? nil,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    /// Returns `body`'s result, or `nil` if it doesn't finish in time.
    ///
    /// Note the abandoned work isn't truly interrupted — the underlying AX and
    /// AppleScript calls are synchronous and can't be cancelled mid-flight. The
    /// point is that *we* stop waiting on them, so a wedged app costs us the
    /// budget rather than its own timeout.
    private static func withDeadline<T: Sendable>(
        _ budget: Duration,
        _ body: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await body() }
            group.addTask {
                try? await Task.sleep(for: budget)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
