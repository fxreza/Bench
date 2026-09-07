import Foundation
import AppKit
import BenchTestKit
@testable import Klip

// Phase 3E part 2: the table-driven `Views/History/GlobalKeyMonitor.swift`.
//
// GlobalKeyMonitor itself needs a real NSWindow / first responder to drive
// end-to-end (that is exercised instead by the offscreen render harness —
// see docs/plan/briefs/3E2-shortcuts-wiring.md's Verify section), but
// everything the monitor's dispatch depends on is unit-testable directly:
// `ShortcutManager.action(for:)` resolving a synthetic NSEvent to the right
// `ShortcutAction`, and that resolution changing after a rebind. This
// complements Tests/ShortcutTests.swift (which covers the manager's model
// half in isolation) by exercising *every* default binding — not just a
// couple of spot checks — plus the modifier-exactness cases the old
// hardcoded keycode switch used to special-case by hand (e.g. ⌘C vs ⌥⌘C).
enum KeyMonitorTests {
    static let tests: [(String, () throws -> Void)] = [
        ("resolution_everyDefaultBindingMapsToItsOwnAction", testEveryDefaultResolves),
        ("resolution_rebindingCmdPToCmdShiftPChangesWhichEventMatches", testRebindChangesResolution),
        ("resolution_modifierExactness_cmdCVsOptionCmdC", testModifierExactnessCopyVsCopyPlain),
        ("resolution_modifierExactness_pinVsTogglePreviewShareKeycode35", testModifierExactnessPinVsTogglePreview),
        ("resolution_unboundEventResolvesToNil", testUnboundEventIsNil),
        ("resolution_fixedKeysResolveWithExpectedModifiers", testFixedKeysResolve),
        // 5A-01 — the monitor is app-wide; it must only act on the panel.
        ("scope_eventOutsideThePanelIsReturnedUntouchedForEveryAction", testForeignEventPassesThroughForEveryAction),
        ("scope_shouldHandleIsFalseWithoutAKeyPanel", testShouldHandleGate),
        ("scope_panelEventsStillDispatch", testPanelEventsStillDispatch),
        // Quick Look — Space doubles as a typed character, so it has gates.
        ("quickLook_barePredicatesMatchOnlyTheirOwnKeys", testQuickLookKeyPredicates),
        ("quickLook_spaceOpensThePreviewWhenSearchIsEmpty", testSpaceOpensQuickLook),
        ("quickLook_spaceStaysACharacterWhileTextIsBeingTyped", testSpaceIsTypedWhileSearching),
        ("quickLook_cmdYAlwaysOpensThePreview", testCmdYAlwaysOpensQuickLook),
    ]

    // MARK: - Fixtures

    private static func event(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    private static func freshManager() -> ShortcutManager {
        let suiteName = "KeyMonitorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return ShortcutManager(defaults: defaults)
    }

    private static func eventFlags(for modifiers: ClipKeyModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { flags.insert(.command) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.control) { flags.insert(.control) }
        return flags
    }

    // MARK: - Every default binding resolves to its own action

    /// GlobalKeyMonitor's dispatch is only as correct as this resolution: a
    /// synthetic NSEvent built from each action's own `defaultBinding` must
    /// resolve back to that exact action, for every action, not just the
    /// handful ShortcutTests spot-checks.
    static func testEveryDefaultResolves() throws {
        let manager = freshManager()
        for action in ShortcutAction.allCases {
            let binding = action.defaultBinding
            let syntheticEvent = event(keyCode: binding.keyCode, modifiers: eventFlags(for: binding.modifiers))
            try expectEqual(manager.action(for: syntheticEvent), action, "\(action) defaultBinding should resolve to itself")
        }
    }

    // MARK: - Rebinding changes resolution

    static func testRebindChangesResolution() throws {
        let manager = freshManager()
        let plainCmdP = event(keyCode: 35, modifiers: [.command])
        try expectEqual(manager.action(for: plainCmdP), .pin, "Cmd+P should resolve to pin before rebinding")

        let newBinding = ClipKeyBinding(keyCode: 35, modifiers: [.command, .shift])
        try expectEqual(manager.set(newBinding, for: .pin), .ok)

        // The old Cmd+P event no longer matches anything: nothing else
        // defaults to keycode 35 with a bare Cmd modifier.
        try expectNil(manager.action(for: plainCmdP), "plain Cmd+P should no longer resolve once pin is rebound away from it")

        // The new Cmd+Shift+P event now resolves to pin.
        let cmdShiftP = event(keyCode: 35, modifiers: [.command, .shift])
        try expectEqual(manager.action(for: cmdShiftP), .pin, "Cmd+Shift+P should resolve to pin after rebinding")
    }

    // MARK: - Modifier exactness

    /// `.copy` (⌘C) and `.copyPlain` (⌥⌘C) share a keycode; only the exact
    /// modifier set distinguishes them, exactly like GlobalKeyMonitor's old
    /// hardcoded `case 8` used to lump both under `contains(.command)`
    /// before 3E gave copyPlain its own action.
    static func testModifierExactnessCopyVsCopyPlain() throws {
        let manager = freshManager()
        let cmdC = event(keyCode: 8, modifiers: [.command])
        let cmdOptC = event(keyCode: 8, modifiers: [.command, .option])

        try expectEqual(manager.action(for: cmdC), .copy)
        try expectEqual(manager.action(for: cmdOptC), .copyPlain)
    }

    /// `.pin` (⌘P) and `.togglePreview` (⌥⌘P) also share a keycode (35).
    static func testModifierExactnessPinVsTogglePreview() throws {
        let manager = freshManager()
        let cmdP = event(keyCode: 35, modifiers: [.command])
        let cmdOptP = event(keyCode: 35, modifiers: [.command, .option])

        try expectEqual(manager.action(for: cmdP), .pin)
        try expectEqual(manager.action(for: cmdOptP), .togglePreview)
    }

    // MARK: - Unbound events fall through

    static func testUnboundEventIsNil() throws {
        let manager = freshManager()
        // Plain "C" with no modifiers is not any action's default binding —
        // GlobalKeyMonitor must let it fall through untouched (`return
        // event`) so typing in the search field is unaffected.
        let plainC = event(keyCode: 8, modifiers: [])
        try expectNil(manager.action(for: plainC))

        // An exotic combination on a keycode nothing binds to.
        let unmatched = event(keyCode: 200, modifiers: [.command, .shift, .option, .control])
        try expectNil(manager.action(for: unmatched))
    }

    // MARK: - Fixed keys (arrows, Return, Tab, Esc) resolve as documented

    static func testFixedKeysResolve() throws {
        let manager = freshManager()
        try expectEqual(manager.action(for: event(keyCode: 126, modifiers: [])), .moveUp)
        try expectEqual(manager.action(for: event(keyCode: 125, modifiers: [])), .moveDown)
        try expectEqual(manager.action(for: event(keyCode: 126, modifiers: [.shift])), .extendUp)
        try expectEqual(manager.action(for: event(keyCode: 125, modifiers: [.shift])), .extendDown)
        try expectEqual(manager.action(for: event(keyCode: 53, modifiers: [])), .escape)
        try expectEqual(manager.action(for: event(keyCode: 48, modifiers: [])), .tabComplete)
        try expectEqual(manager.action(for: event(keyCode: 36, modifiers: [])), .paste)
        try expectEqual(manager.action(for: event(keyCode: 36, modifiers: [.option])), .pastePlain)
        // Bare Backspace (clearFilter) vs Cmd+Backspace (delete) — same
        // keycode, distinguished only by the Cmd modifier.
        try expectEqual(manager.action(for: event(keyCode: 51, modifiers: [])), .clearFilter)
        try expectEqual(manager.action(for: event(keyCode: 51, modifiers: [.command])), .delete)
    }

    // MARK: - 5A-01: the local monitor is app-wide and must gate on the panel
    //
    // `NSEvent.addLocalMonitorForEvents` fires for *every* window the process
    // puts on screen. Before this gate, Return inside an `NSSavePanel` (⌘S →
    // "Save to Disk"), inside the "Clear Clipboard History?" alert or inside
    // the update alerts resolved to `.paste`, was swallowed (so the panel
    // never saved) and pasted the clip into whatever app was frontmost —
    // and ⌘C/⌘S/⌘E/⌘L/⌘P/⌘B/⌘1-9 fired while Settings, Permissions or
    // Onboarding had focus.
    //
    // A synthetic `NSEvent` has `window == nil`, which is exactly the shape
    // of "this event is not the history panel's": the assertions below drive
    // the real monitor body (`GlobalKeyMonitor.handle`) with one event per
    // action and require every one of them to come back untouched, with no
    // view-model side effect at all.

    /// State that must not move when a foreign event passes through.
    private struct ViewModelSnapshot: Equatable {
        var itemCount: Int
        var selectedID: UUID?
        var selectedIndex: Int
        var selectedIDs: Set<UUID>
        var isEditing: Bool
        var showTagInput: Bool
        var scrollTrigger: Bool
        var isPromptShowing: Bool
        var scopeIsAll: Bool
        var sidebarCollapsed: Bool
        var showPreviewPane: Bool
        var hasToast: Bool

        init(_ vm: HistoryViewModel) {
            itemCount = vm.store.items.count
            selectedID = vm.selectedID
            selectedIndex = vm.selectedIndex
            selectedIDs = vm.selectedIDs
            isEditing = vm.isEditing
            showTagInput = vm.showTagInput
            scrollTrigger = vm.scrollTrigger
            isPromptShowing = vm.isPromptShowing
            scopeIsAll = vm.scope == .all
            sidebarCollapsed = SettingsManager.shared.sidebarCollapsed
            showPreviewPane = SettingsManager.shared.showPreviewPane
            hasToast = vm.toast != nil
        }
    }

    static func testForeignEventPassesThroughForEveryAction() throws {
        try FolderUXTests.withViewModel { vm, store in
            FolderUXTests.seed(vm, store, ["alpha", "beta", "gamma"])
            vm.applyFilters(resetSelection: .defaultItem)

            // Any of these firing means the monitor acted on an event that
            // belonged to another window.
            var pasted = false, pastedMultiple = false, copied = false, dismissed = false
            vm.onPaste = { _, _ in pasted = true }
            vm.onPasteMultiple = { _, _ in pastedMultiple = true }
            vm.onCopyToClipboard = { _, _ in copied = true }
            vm.onDismiss = { dismissed = true }

            var backspaceCalls = 0
            let onBackspace: () -> Bool = { backspaceCalls += 1; return true }

            let before = ViewModelSnapshot(vm)

            for action in ShortcutAction.allCases {
                let binding = action.defaultBinding
                let synthetic = event(keyCode: binding.keyCode, modifiers: eventFlags(for: binding.modifiers))

                // `panel: nil` is the "the hosting view has no window" case;
                // a synthetic event's own `window` is nil too, so this also
                // covers "the event belongs to some other window".
                let result = GlobalKeyMonitor.handle(synthetic, panel: nil, viewModel: vm, onBackspace: onBackspace)

                try expect(result === synthetic,
                           "\(action): a foreign event must be returned untouched, not swallowed")
                try expectEqual(ViewModelSnapshot(vm), before,
                                "\(action): a foreign event must not touch view-model state")
            }

            try expect(!pasted && !pastedMultiple && !copied && !dismissed,
                       "no controller callback may fire for events outside the panel")
            try expectEqual(backspaceCalls, 0, "the search field's backspace hook must not fire either")

            // Same again with a prompt up (the early-return branch) and while
            // editing (the branch that swallows ⌘⌫ / ⌘P / ⌘B / ⌘T).
            vm.requestNewFolder()
            let esc = event(keyCode: 53, modifiers: [])
            try expect(GlobalKeyMonitor.handle(esc, panel: nil, viewModel: vm, onBackspace: onBackspace) === esc,
                       "Esc outside the panel must not unwind a prompt")
            try expect(vm.showNewFolderPrompt, "the prompt must still be showing")
            vm.cancelNewFolder()

            vm.isEditing = true
            let cmdDelete = event(keyCode: 51, modifiers: [.command])
            try expect(GlobalKeyMonitor.handle(cmdDelete, panel: nil, viewModel: vm, onBackspace: onBackspace) === cmdDelete,
                       "⌘⌫ outside the panel must not be swallowed while editing")
            vm.isEditing = false
        }
    }

    /// The gate itself: no window, or a window that is not key, is never ours.
    static func testShouldHandleGate() throws {
        let returnKey = event(keyCode: 36, modifiers: [])
        try expect(!GlobalKeyMonitor.shouldHandle(returnKey, panel: nil),
                   "with no hosting window the monitor must stand down")
    }

    /// The counter-test: when the event *does* belong to the key panel the
    /// dispatch still runs, so the gate above is what blocks foreign events —
    /// not a broken dispatch. Only the two fixed, non-rebindable keys are
    /// used here so `ShortcutManager.shared`'s stored bindings cannot matter.
    static func testPanelEventsStillDispatch() throws {
        try FolderUXTests.withViewModel { vm, store in
            let items = FolderUXTests.seed(vm, store, ["alpha", "beta"])
            vm.applyFilters(resetSelection: .defaultItem)
            vm.selectSingle(items[0].id)

            var pastedID: UUID?
            vm.onPaste = { item, _ in pastedID = item.id }
            vm.onPasteMultiple = { items, _ in pastedID = items.first?.id }
            var dismissed = false
            vm.onDismiss = { dismissed = true }

            let returnKey = event(keyCode: 36, modifiers: [])
            try expectNil(GlobalKeyMonitor.dispatch(returnKey, viewModel: vm, firstResponder: nil, onBackspace: nil),
                          "Return inside the panel is consumed")
            try expectEqual(pastedID, items[0].id, "Return inside the panel pastes the focused clip")

            let esc = event(keyCode: 53, modifiers: [])
            try expectNil(GlobalKeyMonitor.dispatch(esc, viewModel: vm, firstResponder: nil, onBackspace: nil),
                          "Esc inside the panel is consumed")
            try expect(dismissed, "Esc inside the panel closes the window")
        }
    }

    // MARK: - Quick Look (Space / ⌘Y)
    //
    // Space is the one binding that is also a literal character, and the
    // search field holds focus for as long as the panel is open. So the
    // dispatch has to hand a bare Space back to the field whenever it could
    // be part of what the user is typing, and ⌘Y exists as the way in that
    // never has to.

    static func testQuickLookKeyPredicates() throws {
        try expect(GlobalKeyMonitor.isBareSpace(event(keyCode: 49, modifiers: [])),
                   "a modifier-free Space is the ambiguous case")
        try expect(!GlobalKeyMonitor.isBareSpace(event(keyCode: 49, modifiers: [.command])),
                   "⌘Space is not a typed character")
        try expect(!GlobalKeyMonitor.isBareSpace(event(keyCode: 36, modifiers: [])),
                   "Return is not Space")

        try expect(GlobalKeyMonitor.isQuickLookFallback(event(keyCode: 16, modifiers: [.command])),
                   "⌘Y is the fixed fallback")
        try expect(!GlobalKeyMonitor.isQuickLookFallback(event(keyCode: 16, modifiers: [])),
                   "a bare Y is just a letter for the search field")
        try expect(!GlobalKeyMonitor.isQuickLookFallback(event(keyCode: 16, modifiers: [.command, .shift])),
                   "⇧⌘Y is not ⌘Y")
    }

    static func testSpaceOpensQuickLook() throws {
        try FolderUXTests.withViewModel { vm, store in
            let items = FolderUXTests.seed(vm, store, ["alpha", "beta"])
            vm.applyFilters(resetSelection: .defaultItem)
            vm.selectSingle(items[0].id)

            var previewedID: UUID?
            vm.onQuickLook = { previewedID = $0.id }

            let space = event(keyCode: 49, modifiers: [])
            try expectNil(GlobalKeyMonitor.dispatch(space, viewModel: vm, firstResponder: nil, onBackspace: nil),
                          "Space with an empty search field is consumed")
            try expectEqual(previewedID, items[0].id, "Space previews the focused clip")
        }
    }

    static func testSpaceIsTypedWhileSearching() throws {
        try FolderUXTests.withViewModel { vm, store in
            let items = FolderUXTests.seed(vm, store, ["alpha", "beta"])
            vm.applyFilters(resetSelection: .defaultItem)
            vm.selectSingle(items[0].id)

            var previewed = false
            vm.onQuickLook = { _ in previewed = true }

            let space = event(keyCode: 49, modifiers: [])

            // Mid-search: the space belongs to the query being typed.
            vm.searchText = "alp"
            try expect(GlobalKeyMonitor.dispatch(space, viewModel: vm, firstResponder: nil, onBackspace: nil) === space,
                       "with search text, Space must reach the search field")
            vm.searchText = ""

            // The tag input owns the keyboard the same way.
            vm.showTagInput = true
            try expect(GlobalKeyMonitor.dispatch(space, viewModel: vm, firstResponder: nil, onBackspace: nil) === space,
                       "with the tag input open, Space must reach it")
            vm.showTagInput = false

            // So does the inline editor.
            vm.isEditing = true
            try expect(GlobalKeyMonitor.dispatch(space, viewModel: vm, firstResponder: nil, onBackspace: nil) === space,
                       "while editing, Space must reach the editor")
            vm.isEditing = false

            try expect(!previewed, "none of those may have opened a preview")
        }
    }

    static func testCmdYAlwaysOpensQuickLook() throws {
        try FolderUXTests.withViewModel { vm, store in
            let items = FolderUXTests.seed(vm, store, ["alpha", "beta"])
            vm.applyFilters(resetSelection: .defaultItem)
            vm.selectSingle(items[0].id)

            var previewedID: UUID?
            vm.onQuickLook = { previewedID = $0.id }

            // The case Space cannot serve: a query is already being typed.
            vm.searchText = "alp"
            let cmdY = event(keyCode: 16, modifiers: [.command])
            try expectNil(GlobalKeyMonitor.dispatch(cmdY, viewModel: vm, firstResponder: nil, onBackspace: nil),
                          "⌘Y is consumed even with search text")
            try expectEqual(previewedID, items[0].id, "⌘Y previews the focused clip")
        }
    }
}
