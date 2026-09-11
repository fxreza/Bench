import Cocoa
import SwiftUI
import UniformTypeIdentifiers

/// Manages the floating history window.
///
/// Public API is unchanged (`showWindow`, `close`, `refocus`, `pasteItem`,
/// `pasteMultiple`, `previousApp`, `viewModel`) — `KlipFeature` calls it.
/// There is deliberately no `toggle()`: `KlipFeature.toggleHistoryWindow()`
/// owns that.
class HistoryWindowController: NSWindowController, NSWindowDelegate {
    private let store: ClipboardStore
    /// Owns the window's state so it survives SwiftUI view identity resets.
    let viewModel: HistoryViewModel
    var previousApp: NSRunningApplication?

    /// Default window size when the user has never resized it (Clipfield's
    /// "standard" overlay size).
    private static let defaultSize = NSSize(width: 880, height: 540)
    private static let minSize = NSSize(width: 560, height: 380)
    private static let maxSize = NSSize(width: 1600, height: 1100)

    /// Shared flag: true if the content view should reset search on the next open
    var shouldResetOnOpen: Bool {
        get { viewModel.shouldResetOnOpen }
        set { viewModel.shouldResetOnOpen = newValue }
    }

    /// Last selected item UUID — restored when reopening within the threshold
    var savedSelectedID: UUID? {
        get { viewModel.savedSelectedID }
        set { viewModel.savedSelectedID = newValue }
    }

    /// Whether this open should start with an empty search field.
    ///
    /// This used to be a 90-second timer on the last close: reopen quickly
    /// and the query came back, reopen later and it did not. Nothing on
    /// screen said which of the two you were getting, so a query typed to
    /// find one clip could still be filtering the list minutes later, with
    /// the rest of the history apparently missing. It is a setting now
    /// (`Settings ▸ General ▸ Search`), off by default: the field is empty
    /// every single time unless the user asks for it to be kept.
    private var shouldResetSearch: Bool {
        !SettingsManager.shared.keepSearchBetweenOpens
    }

    /// Persisted content size, clamped so a stale value cannot make the window
    /// unusable.
    private var panelSize: NSSize {
        let settings = SettingsManager.shared
        guard let w = settings.windowWidth, let h = settings.windowHeight, w > 0, h > 0 else {
            return Self.defaultSize
        }
        return NSSize(
            width: min(max(w, Self.minSize.width), Self.maxSize.width),
            height: min(max(h, Self.minSize.height), Self.maxSize.height)
        )
    }

    init(store: ClipboardStore) {
        self.store = store
        self.viewModel = HistoryViewModel(store: store)

        let panel = HistoryPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init(window: panel)

        panel.onClickOutside = { [weak self] in
            self?.close()
        }

        setupPanel(panel)
        setupContent()
    }

    override func close() {
        viewModel.isPresented = false
        // A preview left on screen after the history window went away would
        // have nothing to hand focus back to.
        QuickLookController.shared.close()
        super.close()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupPanel(_ panel: HistoryPanel) {
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        // The SwiftUI content draws its own rounded material card, so the window
        // itself is clear and its shadow tracks that shape.
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // Not movable by its background: a background drag would fight the
        // row drag-and-drop and the pane resizers. Moving is done by
        // `WindowDragModifier` on the SwiftUI content instead, which only
        // fires for presses nothing else claimed.
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .utilityWindow

        panel.contentMinSize = Self.minSize
        panel.contentMaxSize = Self.maxSize
        panel.delegate = self

        // Notify content view when window becomes key so it can reset state
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: panel,
            queue: .main
        ) { [weak panel] _ in
            // Coming back from a Quick Look preview is not the window being
            // opened — see `HistoryPanel.suppressNextBecomeKey`.
            if panel?.suppressNextBecomeKey == true {
                panel?.suppressNextBecomeKey = false
                return
            }
            NotificationCenter.default.post(name: .bufferWindowDidOpen, object: nil)
        }
    }

    private func setupContent() {
        viewModel.onCopyToClipboard = { [weak self] item, mode in
            self?.copyToClipboard(item, mode: mode)
        }
        viewModel.onPaste = { [weak self] item, mode in
            self?.pasteItem(item, mode: mode)
        }
        viewModel.onPasteMultiple = { [weak self] items, mode in
            self?.pasteMultiple(items, mode: mode)
        }
        viewModel.onDismiss = { [weak self] in
            self?.close()
        }
        viewModel.onQuickLook = { [weak self] item in
            self?.quickLook(item)
        }
        viewModel.onSaveQRCode = { [weak self] data, suggestedName in
            self?.saveQRCode(data, suggestedName: suggestedName)
        }

        let contentView = HistoryContentView(store: store, viewModel: viewModel)
        let host = NSHostingView(rootView: contentView)
        // The window controls its own frame; without this the flexible SwiftUI
        // content drives the hosting view's fitting size and blows the window up.
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: panelSize)
        window?.contentView = host
    }

    /// Space / ⌘Y. Lives here rather than in the view model because Quick
    /// Look takes key focus from the panel, and the panel has to be told so it
    /// does not close itself out from under the preview.
    private func quickLook(_ item: ClipboardItem) {
        let panel = window as? HistoryPanel
        if !QuickLookController.shared.toggle(item: item, store: store, host: panel) {
            viewModel.showToast("Nothing to preview")
        }
    }

    /// The QR card's "Save PNG…". Here rather than in the view model for the
    /// same reason as `quickLook`: the save panel takes key focus, and the
    /// history panel closes on `resignKey` unless it is told to hold on.
    private func saveQRCode(_ data: Data, suggestedName: String) {
        let panel = window as? HistoryPanel
        panel?.isModalPresenting = true
        defer { panel?.isModalPresenting = false }

        let save = NSSavePanel()
        save.allowedContentTypes = [.png]
        save.nameFieldStringValue = suggestedName
        save.canCreateDirectories = true

        guard save.runModal() == .OK, let url = save.url else { return }
        do {
            try data.write(to: url)
        } catch {
            print("[Buffer] Failed to save QR code: \(error)")
            viewModel.showToast("Could not save the QR code")
        }
    }

    private func copyToClipboard(_ item: ClipboardItem, mode: PasteMode) {
        NotificationCenter.default.post(name: .bufferIgnoreNextChange, object: nil)
        PasteController.copyToClipboard(item, store: store, mode: mode)
    }

    /// Keep Open (`SettingsManager.keepWindowOpen`): the window survives a
    /// paste instead of closing behind it, so several clips can be pasted in
    /// a row without summoning Klip again each time.
    ///
    /// Note what it does *not* change: pasting still hands focus to the
    /// target app (`PasteController` activates `previousApp` and synthesises
    /// ⌘V there), so after a paste Klip is visible but no longer the key
    /// window — the next clip is chosen with the mouse, not with ↩. Making ↩
    /// keep working would mean yanking focus back to Klip after every paste,
    /// which bounces the caret out of the document mid-typing; that is a
    /// deliberate no.
    private func closeUnlessKeptOpen() {
        guard !SettingsManager.shared.keepWindowOpen else { return }
        close()
    }

    func pasteItem(_ item: ClipboardItem, mode: PasteMode = .rich) {
        let appToRestore = previousApp
        closeUnlessKeptOpen()
        NotificationCenter.default.post(name: .bufferIgnoreNextChange, object: nil)
        PasteController.paste(item, store: store, previousApp: appToRestore, mode: mode)
    }

    func pasteMultiple(_ items: [ClipboardItem], mode: PasteMode = .rich) {
        let appToRestore = previousApp
        closeUnlessKeptOpen()
        NotificationCenter.default.post(name: .bufferIgnoreNextChange, object: nil)
        PasteController.pasteMultiple(items, store: store, previousApp: appToRestore, mode: mode)
    }

    /// Bring an already-visible window back to the keyboard without treating
    /// it as a fresh open.
    ///
    /// Only reachable in Keep Open mode: everywhere else, a window that lost
    /// key has already closed itself. `suppressNextBecomeKey` keeps
    /// `handleWindowDidOpen` out of it, so refocusing does not snap the
    /// sidebar back to All or wipe the query the way summoning Klip does —
    /// this is picking the window back up, not opening it.
    func refocus() {
        guard let window, window.isVisible else { return }
        // The app in front right now is what a paste should go back to.
        previousApp = NSWorkspace.shared.frontmostApplication
        let panel = window as? HistoryPanel
        panel?.suppressNextBecomeKey = true
        panel?.suppressResignUntil = Date().addingTimeInterval(0.4)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    override func showWindow(_ sender: Any?) {
        previousApp = NSWorkspace.shared.frontmostApplication
        // Compute reset decision *before* super.showWindow fires didBecomeKeyNotification
        // → bufferWindowDidOpen, so the content view onReceive handler sees the right value.
        shouldResetOnOpen = shouldResetSearch

        let panel = window as? HistoryPanel
        panel?.suppressResignUntil = Date().addingTimeInterval(0.4)
        // Backstop: a preview that somehow went away without handing control
        // back would otherwise leave the panel unable to close on click-away,
        // or eat the reopen reset of a genuine later open.
        panel?.isQuickLookPresenting = false
        panel?.suppressNextBecomeKey = false
        position(window)

        // Start collapsed so the card can bounce in.
        viewModel.isPresented = false

        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(window?.contentView)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                self.viewModel.isPresented = true
            } else {
                withAnimation(Theme.promptSpring) {
                    self.viewModel.isPresented = true
                }
            }
        }
    }

    /// Centre the panel on the screen under the mouse, sitting 8 % above dead
    /// centre — reads better than perfectly centred (Clipfield's placement).
    ///
    /// With `SettingsManager.rememberWindowPosition` on and a position saved
    /// by `windowDidMove`, that position wins, nudged back onto the screen it
    /// is closest to so a display that has since gone away cannot strand the
    /// window off-screen.
    private func position(_ window: NSWindow?) {
        guard let window else { return }
        let size = panelSize
        window.setContentSize(size)

        if let frame = rememberedFrame(size: size) {
            window.setFrame(frame, display: true)
            return
        }

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            window.center()
            return
        }
        let x = visible.midX - size.width / 2
        let y = visible.midY - size.height / 2 + visible.height * 0.08
        window.setFrame(
            NSRect(x: x, y: y, width: size.width, height: size.height),
            display: true
        )
    }

    /// The saved origin with the given size, clamped into the visible frame of
    /// the screen holding it (or the nearest one). Nil when nothing is saved
    /// or the setting is off.
    private func rememberedFrame(size: NSSize) -> NSRect? {
        let settings = SettingsManager.shared
        guard settings.rememberWindowPosition,
              let x = settings.windowOriginX, let y = settings.windowOriginY,
              x.isFinite, y.isFinite else { return nil }
        var frame = NSRect(x: x, y: y, width: size.width, height: size.height)

        let screens = NSScreen.screens
        guard !screens.isEmpty else { return frame }
        let host = screens.first { $0.frame.intersects(frame) }
            ?? screens.min { a, b in
                a.frame.distanceSquared(to: frame.origin) < b.frame.distanceSquared(to: frame.origin)
            }
        guard let visible = host?.visibleFrame else { return frame }

        frame.origin.x = min(max(frame.minX, visible.minX), max(visible.maxX - frame.width, visible.minX))
        frame.origin.y = min(max(frame.minY, visible.minY), max(visible.maxY - frame.height, visible.minY))
        return frame
    }

    // MARK: - NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        guard let size = window?.contentView?.frame.size else { return }
        let settings = SettingsManager.shared
        settings.windowWidth = Double(size.width)
        settings.windowHeight = Double(size.height)
    }

    /// Records where the user dragged the window, only while Remember
    /// Position is on. Off, the origin stays nil and every open goes back to
    /// the default placement.
    func windowDidMove(_ notification: Notification) {
        let settings = SettingsManager.shared
        guard settings.rememberWindowPosition, let origin = window?.frame.origin else { return }
        settings.windowOriginX = Double(origin.x)
        settings.windowOriginY = Double(origin.y)
    }
}

private extension NSRect {
    /// Squared distance from `point` to the nearest point of this rect (zero
    /// when inside).
    func distanceSquared(to point: NSPoint) -> CGFloat {
        let dx = max(minX - point.x, 0, point.x - maxX)
        let dy = max(minY - point.y, 0, point.y - maxY)
        return dx * dx + dy * dy
    }
}
