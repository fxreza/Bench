// Panel chrome adapted from Clipfield (MIT, Copyright 2026 Alex Jolley) —
// UI/Overlay/OverlayPanel.swift.

import Cocoa
import QuickLookUI

/// Borderless, resizable floating panel that closes when it loses key focus.
///
/// Borderless windows cannot become key by default, so `canBecomeKey` is
/// overridden — the search field needs to accept text.
class HistoryPanel: NSPanel {
    var onClickOutside: (() -> Void)?

    /// Activating an accessory app is asynchronous and can produce a transient
    /// resign-key right after the panel is ordered in. The controller pushes
    /// this a moment into the future on every show so that blip does not close
    /// the window we just opened. Clicking away afterwards still closes it.
    var suppressResignUntil: Date = .distantPast

    /// True while the system Quick Look panel is up (Space / ⌘Y).
    ///
    /// Quick Look takes key focus, and this panel closes on `resignKey` — so
    /// without the flag, Space would open the preview and dismiss the history
    /// window underneath it in the same breath. `HistoryWindowController`
    /// clears it on every show as a backstop, in case a preview ever goes away
    /// without handing control back.
    var isQuickLookPresenting = false

    /// True while a modal this panel put on screen — today the QR card's
    /// "Save PNG…" panel — holds key focus. Same problem and same fix as
    /// `isQuickLookPresenting`: without it, opening the save panel dismisses
    /// the window (and with it the card that opened it).
    var isModalPresenting = false

    /// Consumed once by the `didBecomeKey` observer in
    /// `HistoryWindowController.setupPanel`.
    ///
    /// Closing Quick Look hands key focus back to this panel, which fires
    /// `didBecomeKey` → `bufferWindowDidOpen` → `handleWindowDidOpen()` — the
    /// "Klip always opens on All" reset. Without this, previewing a clip
    /// inside a folder and pressing Esc would drop the user back on All with
    /// their kind chip and tag filter cleared, as if the window had been
    /// summoned afresh.
    var suppressNextBecomeKey = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func resignKey() {
        super.resignKey()
        guard !isQuickLookPresenting, !isModalPresenting else { return }
        guard Date() >= suppressResignUntil else { return }
        // Keep Open (`SettingsManager.keepWindowOpen`): the whole point of the
        // mode is that the window survives handing focus to the app being
        // pasted into, so losing key must stop meaning "close". The window is
        // still dismissed by Esc, by the global hotkey and by the menu bar.
        guard !SettingsManager.shared.keepWindowOpen else { return }
        onClickOutside?()
    }

    // MARK: - Quick Look
    //
    // `QLPreviewPanel` finds its controller by walking the key window's
    // responder chain, which ends here. These three are `NSObject`'s
    // `QLPreviewPanelController` category, hence `override`.

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = QuickLookController.shared
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        QuickLookController.shared.didEndControl()
    }
}
