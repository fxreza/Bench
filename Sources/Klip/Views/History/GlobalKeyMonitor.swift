import SwiftUI
import AppKit

/// Installs a local NSEvent key-down monitor for the history window and routes
/// keys to `HistoryViewModel`.
///
/// Phase 3E made this table-driven: instead of a hardcoded keycode switch,
/// every keydown is resolved to a `ShortcutAction` via
/// `ShortcutManager.shared.action(for:)`, and the dispatch below switches on
/// that action. The per-action "what happens while editing / what happens to
/// the event afterwards" behaviour is preserved exactly from the old keycode
/// switch (see the case-by-case comments) — rebinding a key changes *which*
/// event triggers an action, never what the action does once triggered.
///
/// **Scope (review 5A-01).** `addLocalMonitorForEvents` is *app-wide*, not
/// window-scoped, and the history panel is built once at launch and only
/// ordered out on close — so without a gate this handler saw (and swallowed)
/// key events belonging to every other window the app can put on screen:
/// `NSSavePanel`/`NSOpenPanel` from "Save to Disk", the Clear History and
/// update `NSAlert`s, Settings, Permissions and Onboarding. Return in a save
/// panel resolved to `.paste`, was swallowed (so the panel never saved) and
/// pasted the clip into whatever app was frontmost. `shouldHandle` now gates
/// the *whole* handler on the event actually belonging to the history panel
/// **and** that panel being key; every other event is returned untouched.
///
/// `onBackspace` stays a closure because it needs the search field's
/// `@FocusState`, which can only live in a `View`.
struct GlobalKeyMonitor: NSViewRepresentable {
    let viewModel: HistoryViewModel
    let onBackspace: () -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // 5A-27: the monitor is installed unconditionally. It used to be
        // installed inside a `guard view.window != nil` with no retry, so a
        // hosting view that was not yet in a window left every in-window
        // shortcut dead for the rest of the session. The window is now
        // resolved per event by `shouldHandle` instead, so there is nothing
        // to wait for at install time.
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            Self.handle(
                event,
                panel: view.window,
                viewModel: context.coordinator.viewModel,
                onBackspace: context.coordinator.onBackspace
            )
        }
        context.coordinator.monitor = monitor
        return view
    }

    // MARK: - Scope gate (5A-01)

    /// The whole monitor body: gate first, dispatch only if the event belongs
    /// to the history panel. This is exactly what the installed monitor runs,
    /// exposed so `Tests/KeyMonitorTests.swift` can drive it with synthetic
    /// events.
    static func handle(
        _ event: NSEvent,
        panel: NSWindow?,
        viewModel: HistoryViewModel,
        onBackspace: (() -> Bool)?
    ) -> NSEvent? {
        guard shouldHandle(event, panel: panel) else { return event }
        return dispatch(
            event,
            viewModel: viewModel,
            firstResponder: panel?.firstResponder,
            onBackspace: onBackspace
        )
    }

    /// Whether this monitor owns `event`.
    ///
    /// True only when the event was routed to the history panel itself and
    /// that panel is the key window. A synthetic event (or any event bound
    /// for a save panel, an alert, Settings, Permissions or Onboarding) has a
    /// different `window` — or none — and is never touched.
    static func shouldHandle(_ event: NSEvent, panel: NSWindow?) -> Bool {
        guard let panel, panel.isKeyWindow else { return false }
        return event.window === panel
    }

    // MARK: - Dispatch

    /// Resolves `event` to a `ShortcutAction` and runs it. Returns `nil` to
    /// swallow the event, or the event itself to let it continue.
    ///
    /// Split out of the monitor closure so the gate above and the per-action
    /// behaviour below are both reachable from tests without a live window.
    static func dispatch(
        _ event: NSEvent,
        viewModel: HistoryViewModel,
        firstResponder: NSResponder?,
        onBackspace: (() -> Bool)?
    ) -> NSEvent? {
        let isEditing = viewModel.isEditing

        // While an inline prompt owns the keyboard, list shortcuts stand
        // down: only Esc is intercepted (to unwind one prompt layer),
        // everything else goes to the prompt's own text field. Escape
        // is fixed (not rebindable), so the raw keycode is safe here.
        if viewModel.isPromptShowing {
            if event.keyCode == 53 {
                viewModel.keyEscape()
                return nil
            }
            return event
        }

        guard let action = ShortcutManager.shared.action(for: event) else {
            // ⌘Y — Finder's *other* Quick Look key, and the unambiguous one.
            // It is deliberately not a row in the rebindable table: it exists
            // so Quick Look is always reachable even when the search field has
            // text and a bare Space has to stay a character (see `.quickLook`
            // below). Checked only *after* the table, so a user who binds
            // something of their own to ⌘Y still wins.
            if isQuickLookFallback(event) {
                if isEditing { return event }
                viewModel.keyQuickLook()
                return nil
            }
            // Unbound/unknown event: fall through untouched, exactly
            // as the old switch's `default: return event`.
            return event
        }

        switch action {
        // MARK: Fixed navigation keys (↑ ↓ ⇧↑ ⇧↓) — while editing,
        // let them move the text cursor instead of the selection.
        case .moveUp:
            if isEditing { return event }
            viewModel.scrollTrigger = true
            viewModel.keyUp()
            return nil
        case .moveDown:
            if isEditing { return event }
            viewModel.scrollTrigger = true
            viewModel.keyDown()
            return nil
        case .extendUp:
            if isEditing { return event }
            viewModel.keyExtendUp()
            return nil
        case .extendDown:
            if isEditing { return event }
            viewModel.keyExtendDown()
            return nil

        // MARK: Fixed ↩ / ⌥↩ — while editing, let Return insert a
        // newline (or do nothing) instead of pasting.
        case .paste:
            if isEditing { return event }
            viewModel.keyEnter()
            return nil
        case .pastePlain:
            if isEditing { return event }
            viewModel.keyPastePlain()
            return nil

        // MARK: Fixed Esc — always runs; keyEscape() itself unwinds
        // edit mode → tag input → prompt → window, one layer at a time.
        case .escape:
            viewModel.keyEscape()
            return nil

        // MARK: ⌘⌫ delete vs bare ⌫ clear-filter. These used to share
        // one keycode case; the two actions now carry the modifier
        // distinction themselves, but the isEditing behaviour differs
        // per action exactly as before: ⌘⌫ is swallowed as a no-op
        // while editing, but a bare ⌫ still reaches the text editor.
        case .delete:
            if isEditing { return nil } // ⌘Delete is no-op while editing
            viewModel.keyDelete()
            return nil
        case .clearFilter:
            // Backspace only ever meant "clear the tag filter", so with tags
            // hidden it is a plain Backspace again.
            guard Features.tagsEnabled else { return event }
            if isEditing { return event }
            if onBackspace?() == true { return nil }
            return event

        // MARK: ⌘C / ⌥⌘C — defer to an NSTextView first responder so
        // selected text inside e.g. the edit field copies natively.
        case .copy:
            if isEditing { return event }
            if firstResponder is NSTextView { return event }
            viewModel.keyCopy()
            return nil
        case .copyPlain:
            if isEditing { return event }
            if firstResponder is NSTextView { return event }
            viewModel.keyCopyPlain()
            return nil

        // MARK: Single-key item toggles — swallowed (not passed to
        // the text editor) while editing, same as the old ⌘P/⌘B/⌘T cases.
        case .pin:
            if isEditing { return nil }
            viewModel.keyPin()
            return nil
        case .star:
            if isEditing { return nil }
            viewModel.keyBookmark()
            return nil
        case .lock:
            if isEditing { return nil }
            viewModel.keyLock()
            return nil
        case .addTag:
            // Tags are hidden (`Features.tagsEnabled`), so ⌘T is not Klip's
            // to take: the event goes back to whatever else might want it
            // rather than opening an editor nothing else in the window
            // acknowledges.
            guard Features.tagsEnabled else { return event }
            if isEditing { return nil }
            viewModel.keyAddTag()
            return nil

        // MARK: ⌘E — unconditional, exactly as before: toggles edit
        // mode on regardless of whether it is already active.
        case .edit:
            viewModel.keyEdit()
            return nil

        // MARK: ⌘S save-to-disk — passes through untouched while
        // editing, same as the old case.
        case .saveToDisk:
            if isEditing { return event }
            viewModel.keySaveImage()
            return nil

        // MARK: Fixed Tab — while editing, let it move focus instead
        // of tag-completing.
        case .tabComplete:
            if isEditing { return event }
            viewModel.keyTabComplete()
            return nil

        // MARK: New in 3E — organize/window actions with no prior
        // keycode case. Organize actions mirror the swallow-while-
        // editing pattern of pin/favorite/addTag; window toggles run
        // unconditionally like edit, since they affect layout, not
        // the text being edited.
        // MARK: F2 rename — swallowed while editing (the title is already
        // in the editor there, so opening the card on top would be two
        // fields for one name).
        case .renameClip:
            if isEditing { return nil }
            viewModel.keyRenameClip()
            return nil

        // MARK: ⌘K QR code — swallowed while editing, like the other
        // per-clip actions: the card would cover the text being edited.
        case .showQR:
            if isEditing { return nil }
            viewModel.keyShowQR()
            return nil

        case .newFolder:
            if isEditing { return nil }
            viewModel.keyNewFolder()
            return nil
        case .renameFolder:
            if isEditing { return nil }
            viewModel.keyRenameFolder()
            return nil
        case .moveToFolder:
            if isEditing { return nil }
            viewModel.keyMoveToFolder()
            return nil
        case .toggleSidebar:
            viewModel.toggleSidebar()
            return nil
        case .togglePreview:
            viewModel.togglePreviewPane()
            return nil
        case .toggleKeepOpen:
            viewModel.toggleKeepOpen()
            return nil

        // MARK: Space Quick Look. Space is also a literal character, and the
        // search field holds focus for the whole time the panel is open, so a
        // *bare* Space stands down whenever something text-shaped can use it:
        // while editing, while the tag input is open, and whenever there is
        // search text for it to be a space in. Any other binding the user
        // chooses — and the ⌘Y fallback above — is unambiguous and always runs.
        case .quickLook:
            if isEditing || viewModel.showTagInput { return event }
            if isBareSpace(event) && !viewModel.searchText.isEmpty { return event }
            viewModel.keyQuickLook()
            return nil
        }
    }

    /// A Space with no modifiers — the one binding that doubles as a typed
    /// character.
    static func isBareSpace(_ event: NSEvent) -> Bool {
        event.keyCode == 49
            && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
    }

    /// ⌘Y, the fixed second way into Quick Look.
    static func isQuickLookFallback(_ event: NSEvent) -> Bool {
        event.keyCode == 16
            && ClipKeyModifiers(eventFlags: event.modifierFlags.intersection(.deviceIndependentFlagsMask)) == [.command]
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.viewModel = viewModel
        context.coordinator.onBackspace = onBackspace
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    class Coordinator {
        var monitor: Any?
        var viewModel: HistoryViewModel
        var onBackspace: (() -> Bool)?

        init(viewModel: HistoryViewModel) {
            self.viewModel = viewModel
        }

        deinit {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}
