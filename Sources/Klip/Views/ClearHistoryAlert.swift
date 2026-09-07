// Lifted from Klip's Views/StatusBarController.swift (MIT, Copyright 2026
// Sam Reza): the Clear History confirmation and its result alert, the two
// pieces of that controller Bench still needs once the status item itself is
// the app's.

import AppKit

/// The "Clear History" flow behind the status menu item: a confirmation
/// alert with the keep-protected checkbox, the clear itself, and an
/// informational follow-up saying what happened.
@MainActor
enum ClearHistoryAlert {
    /// Runs the whole flow modally. Returns without doing anything when the
    /// user cancels.
    static func run(store: ClipboardStore) {
        let alert = NSAlert()
        alert.messageText = "Clear Clipboard History?"
        alert.informativeText = "Clear history? Pinned, favorited, tagged, locked and folder clips are kept."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")

        let checkbox = CheckboxRelay(alert: alert)
        alert.accessoryView = checkbox.button

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let keepProtected = checkbox.button.state == .on
        let result = store.clear(keepProtected: keepProtected)
        // 5A-10: nothing that just went away should keep a cached badge.
        ImageThumbnailCache.evictAll()
        showClearResult(result, keepProtected: keepProtected)
    }

    /// Reports the outcome of Clear History. The history window may not be
    /// open (no `HistoryViewModel` to hand a toast to from here), so this
    /// always uses a follow-up `NSAlert` - informational, auto-dismissible
    /// with Return/Esc.
    private static func showClearResult(_ result: ClipboardStore.DeleteResult, keepProtected: Bool) {
        let alert = NSAlert()
        alert.messageText = "History Cleared"
        alert.informativeText = clearResultMessage(
            deleted: result.deleted,
            kept: result.skippedLocked,
            keepProtected: keepProtected
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Wording of the Clear History result (review-2B low #1), as a pure
    /// function so `ViewRegressionTests` can pin it.
    ///
    /// The kept count is deliberately *not* described as "locked": with the
    /// checkbox on, `clear(keepProtected: true)` keeps everything protected —
    /// pinned, favorited, tagged, foldered **and** locked — so calling all of
    /// them locked (the wording the other delete surfaces use, where only
    /// locks can block a delete) would be wrong. With the checkbox off, locks
    /// really are the only thing left standing, and the message says so.
    static func clearResultMessage(deleted: Int, kept: Int, keepProtected: Bool) -> String {
        let clipsWord = deleted == 1 ? "clip" : "clips"
        guard kept > 0 else { return "Cleared \(deleted) \(clipsWord)." }
        let keptWord: String
        if keepProtected {
            keptWord = kept == 1 ? "protected clip" : "protected clips"
        } else {
            keptWord = kept == 1 ? "locked clip" : "locked clips"
        }
        return "Cleared \(deleted) \(clipsWord); \(kept) \(keptWord) kept."
    }

    /// The checkbox needs an `@objc` target to update the alert's wording
    /// as it is toggled; the alert is modal, so this only has to live for
    /// the duration of `run`.
    private final class CheckboxRelay: NSObject {
        let button: NSButton
        private weak var alert: NSAlert?

        init(alert: NSAlert) {
            self.alert = alert
            self.button = NSButton(checkboxWithTitle: "Keep pinned, favorited, tagged, locked and folder clips", target: nil, action: nil)
            super.init()
            button.target = self
            button.action = #selector(toggled(_:))
            button.state = .on
            button.sizeToFit()
            button.frame = NSRect(x: 0, y: 0, width: max(button.frame.width, 350), height: 24)
        }

        @objc private func toggled(_ sender: NSButton) {
            guard let alert else { return }
            if sender.state == .on {
                alert.informativeText = "Clear history? Pinned, favorited, tagged, locked and folder clips are kept."
            } else {
                alert.informativeText = "This will permanently delete every clip except locked ones - a lock always outranks Clear History."
            }
        }
    }
}
