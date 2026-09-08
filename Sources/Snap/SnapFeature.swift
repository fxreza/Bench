import AppKit
import Combine
import SwiftUI
import BenchCore

/// Window management: the BetterTouchTool triggers this Mac used to carry,
/// reimplemented as a Bench module.
///
/// Four groups of behaviour:
///
/// - **Layouts.** Sixteen placements (halves, quarters, thirds, two-thirds,
///   maximize, center) plus "Restore Previous Size", all on ⌃⌘ combinations.
///   Geometry is `SnapLayout`, Accessibility plumbing is `WindowController`.
/// - **Previous window.** ⌥⇥ flips between the last two focused windows
///   (`FocusHistory`), pressing again flips back.
/// - **Two scripts.** ⌃⌥T opens a new Terminal window and ⌃⌥E opens
///   Downloads in Finder (`ScriptRunner`). Typed as Caps Lock+⌥ on this
///   Mac: ⌃⌥ is a family no app or system shortcut uses with a letter, so
///   launchers live there, away from the ⌃⌘ window family.
/// - **App launchers.** Three unbound slots that open whatever app was
///   picked in the Snap pane, for the next thing worth a shortcut.
/// - **Moving & resizing modifier keys.** Holding ⇧⌥ and moving the mouse
///   moves the window under the pointer; ⇧⌃ resizes it from its top-left
///   corner. No click needed, and no window is raised unless the user turns
///   that on (`ModifierDragController`).
///
/// ### Not ported from BetterTouchTool
///
/// - *Unpin Focused Window To NOT Float On Top* - undoing "float on top"
///   needs BTT's private window-level manipulation, which has no
///   Accessibility equivalent.
/// - The three *Menubar Item: │* separators - cosmetic dividers in BTT's own
///   menu bar, with nothing to reproduce in Bench.
/// - *Doubleclick Window Titlebar* (maximize / restore cycle) - left out on
///   request.
///
/// ### Caps Lock
///
/// Caps Lock is remapped to Right Control on this Mac, so "Caps+⌘←" is
/// physically ⌃⌘←. BTT could tell right Control from left; Carbon hot keys
/// cannot, so Bench registers plain ⌃⌘ and either Control key works.
public final class SnapFeature: BenchFeature {
    public let id = "snap"
    public let title = "Snap"
    public let symbolName = "macwindow.on.rectangle"
    public let summary = "Window layouts, restore, previous window and two scripts"
    /// Accessibility moves the windows; Automation is the per-app Apple
    /// Events grant the two scripts need.
    public let requiredPermissions: [BenchPermission] = [.accessibility, .automation]

    // MARK: - Actions

    /// What a bound shortcut or a menu item does.
    enum Action: Equatable, Sendable {
        case layout(SnapLayout)
        case restore
        case previousWindow
        case terminalScript
        case downloadsScript
        /// One of `SnapSettings.launcherSlots` app launchers, 1-based.
        case openApp(Int)
    }

    private nonisolated static let control: KeyModifiers = [.control, .command]
    /// Caps Lock+⌥ on this Mac: the launcher family.
    private nonisolated static let launcher: KeyModifiers = [.control, .option]

    /// Every action, in the order the Shortcuts pane and the Window submenu
    /// show them. The ids are frozen: `ShortcutStore` persists rebinds under
    /// them.
    nonisolated static let actionTable: [(id: String, title: String, action: Action, binding: KeyBinding?, note: String?)] = [
        ("snap.leftHalf", "Left Half", .layout(.leftHalf), KeyBinding(123, control), nil),
        ("snap.rightHalf", "Right Half", .layout(.rightHalf), KeyBinding(124, control), nil),
        ("snap.topHalf", "Top Half", .layout(.topHalf), KeyBinding(126, control), nil),
        ("snap.bottomHalf", "Bottom Half", .layout(.bottomHalf), KeyBinding(125, control), nil),
        ("snap.maximize", "Maximize", .layout(.maximize), KeyBinding(36, control),
         "Fills the screen's visible area. Not macOS full screen."),
        ("snap.restore", "Restore Previous Size", .restore, KeyBinding(51, control),
         "Back to the frame the window had before Snap first moved it."),
        ("snap.center", "Center", .layout(.center), KeyBinding(8, control), nil),
        ("snap.topLeft", "Top Left Quarter", .layout(.topLeft), KeyBinding(33, control), nil),
        ("snap.topRight", "Top Right Quarter", .layout(.topRight), KeyBinding(30, control), nil),
        ("snap.bottomLeft", "Bottom Left Quarter", .layout(.bottomLeft), KeyBinding(41, control), nil),
        ("snap.bottomRight", "Bottom Right Quarter", .layout(.bottomRight), KeyBinding(39, control), nil),
        ("snap.leftThird", "Left Third", .layout(.leftThird), KeyBinding(34, control), nil),
        ("snap.middleThird", "Middle Third", .layout(.middleThird), KeyBinding(31, control), nil),
        ("snap.rightThird", "Right Third", .layout(.rightThird), KeyBinding(35, control), nil),
        ("snap.leftTwoThirds", "Left Two Thirds", .layout(.leftTwoThirds), KeyBinding(38, control), nil),
        ("snap.centerTwoThirds", "Center Two Thirds", .layout(.centerTwoThirds), KeyBinding(40, control), nil),
        ("snap.rightTwoThirds", "Right Two Thirds", .layout(.rightTwoThirds), KeyBinding(37, control), nil),
        ("snap.previousWindow", "Activate Previous Window", .previousWindow, KeyBinding(48, [.option]),
         "Flips between the last two focused windows; press again to flip back."),
        ("snap.terminalScript", "New Terminal Window", .terminalScript, KeyBinding(17, launcher),
         "Runs the Terminal script from this pane. Caps Lock+⌥T on this Mac."),
        ("snap.downloadsScript", "Open Downloads in Finder", .downloadsScript, KeyBinding(14, launcher),
         "Runs the Finder script from this pane. Caps Lock+⌥E on this Mac."),
        ("snap.openApp1", "Open App 1", .openApp(1), nil, "Pick the app in the Snap pane. Ships unbound."),
        ("snap.openApp2", "Open App 2", .openApp(2), nil, "Pick the app in the Snap pane. Ships unbound."),
        ("snap.openApp3", "Open App 3", .openApp(3), nil, "Pick the app in the Snap pane. Ships unbound."),
    ]

    public private(set) lazy var hotkeyActions: [HotkeyAction] = Self.actionTable.map {
        HotkeyAction(id: $0.id, featureID: "snap", title: $0.title, defaultBinding: $0.binding, note: $0.note)
    }

    // MARK: - State

    private let settings = SnapSettings.shared
    private let controller = WindowController()
    private let focusHistory = FocusHistory()
    private let menuTarget = SnapMenuTarget()
    private lazy var modifierDrag = ModifierDragController(settings: settings, controller: controller)

    private var cancellables: Set<AnyCancellable> = []
    private var isRunning = false
    /// The Accessibility prompt and the jump to Settings happen once per
    /// launch, not on every refused hotkey press.
    private var permissionPromptShown = false

    public init() {}

    // MARK: - Lifecycle

    public func start() {
        guard !isRunning else { return }
        isRunning = true

        for action in hotkeyActions {
            let id = action.id
            HotkeyCenter.shared.bind(action) { [weak self] in
                self?.perform(actionID: id, fromMenu: false)
            }
        }

        focusHistory.start()
        modifierDrag.start()
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        HotkeyCenter.shared.unbindAll(featureID: id)
        cancellables.removeAll()
        focusHistory.stop()
        modifierDrag.stop()
        controller.memory.removeAll()
    }

    // MARK: - Performing

    private func perform(actionID: String, fromMenu: Bool) {
        guard let entry = Self.actionTable.first(where: { $0.id == actionID }) else { return }
        perform(entry.action, fromMenu: fromMenu)
    }

    private func perform(_ action: Action, fromMenu: Bool) {
        switch action {
        case .layout(let layout):
            guard requireAccessibility() else { return }
            if !controller.apply(layout, gap: settings.effectiveGap) { NSSound.beep() }
        case .restore:
            guard requireAccessibility() else { return }
            if !controller.restore() { NSSound.beep() }
        case .previousWindow:
            guard requireAccessibility() else { return }
            if !focusHistory.activatePrevious() { NSSound.beep() }
        case .terminalScript:
            runScript(settings.terminalScript, name: "New Terminal Window", fromMenu: fromMenu)
        case .downloadsScript:
            runScript(settings.downloadsScript, name: "Open Downloads in Finder", fromMenu: fromMenu)
        case .openApp(let slot):
            openApp(slot: slot, fromMenu: fromMenu)
        }
    }

    /// Opens (or brings forward) the app picked for `slot`. An empty slot
    /// beeps on a hotkey and explains itself from the menu, like the scripts.
    private func openApp(slot: Int, fromMenu: Bool) {
        guard let url = settings.launcherURL(slot) else {
            NSSound.beep()
            guard fromMenu else { return }
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Open App \(slot) has no app yet"
            alert.informativeText = "Pick one in Settings > Snap > Open apps."
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { NSLog("[Snap] open app %@ failed: %@", url.path, error.localizedDescription) }
        }
    }

    /// True when Snap may talk to other apps' windows. When it may not, the
    /// user is prompted and taken to the Permissions pane once, and the
    /// action does nothing else.
    private func requireAccessibility() -> Bool {
        if PermissionsState.shared.accessibilityTrusted { return true }
        guard !permissionPromptShown else { return false }
        permissionPromptShown = true
        PermissionsState.shared.requestAccessibility()
        BenchSettings.open(.permissions)
        return false
    }

    /// Script failures raise an alert only when the user picked the item
    /// from the menu; a failure on a hotkey press would otherwise put a
    /// modal in front of whatever they were doing.
    private func runScript(_ source: String, name: String, fromMenu: Bool) {
        ScriptRunner.run(source) { message in
            guard let message else { return }
            NSLog("[Snap] script \"%@\" failed: %@", name, message)
            guard fromMenu else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\(name) failed"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    // MARK: - Menu

    /// One "Window" item with a submenu: a flat list of twenty items in the
    /// status menu would bury every other module.
    public func menuItems() -> [NSMenuItem] {
        let root = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Window")
        submenu.autoenablesItems = false
        // The previous menu's items are gone; their handlers go with them.
        menuTarget.reset()

        func add(_ ids: [String]) {
            for id in ids {
                guard let entry = Self.actionTable.first(where: { $0.id == id }) else { continue }
                let item = menuTarget.makeItem(
                    title: entry.title,
                    binding: ShortcutStore.shared.binding(for: id)
                ) { [weak self] in
                    self?.perform(entry.action, fromMenu: true)
                }
                submenu.addItem(item)
            }
        }

        add(["snap.leftHalf", "snap.rightHalf", "snap.topHalf", "snap.bottomHalf"])
        submenu.addItem(.separator())
        add(["snap.topLeft", "snap.topRight", "snap.bottomLeft", "snap.bottomRight"])
        submenu.addItem(.separator())
        add(["snap.leftThird", "snap.middleThird", "snap.rightThird",
             "snap.leftTwoThirds", "snap.centerTwoThirds", "snap.rightTwoThirds"])
        submenu.addItem(.separator())
        add(["snap.maximize", "snap.center", "snap.restore"])
        submenu.addItem(.separator())
        add(["snap.previousWindow"])
        submenu.addItem(.separator())
        add(["snap.terminalScript", "snap.downloadsScript"])

        // Launchers show under the app they open; an empty slot is not
        // listed, so the menu never offers an "Open App 2" that does nothing.
        let launchers = (1...SnapSettings.launcherSlots).compactMap { slot -> NSMenuItem? in
            guard let name = settings.launcherName(slot) else { return nil }
            return menuTarget.makeItem(
                title: "Open \(name)",
                binding: ShortcutStore.shared.binding(for: "snap.openApp\(slot)")
            ) { [weak self] in
                self?.perform(.openApp(slot), fromMenu: true)
            }
        }
        if !launchers.isEmpty {
            submenu.addItem(.separator())
            launchers.forEach { submenu.addItem($0) }
        }

        root.submenu = submenu
        return [root]
    }

    // MARK: - Settings

    public func makeSettingsView() -> AnyView {
        AnyView(SnapSettingsView())
    }
}

/// Target for the Window submenu: `NSMenuItem` needs an ObjC target/action
/// pair, and `SnapFeature` is a plain Swift class. Handlers are kept by tag,
/// and the whole table is rebuilt on every menu open, so a rebound shortcut
/// shows up immediately.
@MainActor
final class SnapMenuTarget: NSObject {
    private var handlers: [Int: () -> Void] = [:]
    private var nextTag = 1

    /// Drops the handlers of a menu that is being rebuilt.
    func reset() {
        handlers.removeAll()
        nextTag = 1
    }

    func makeItem(title: String, binding: KeyBinding?, handler: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(fire(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        if let binding, let equivalent = binding.menuKeyEquivalent {
            item.keyEquivalent = equivalent
            item.keyEquivalentModifierMask = binding.eventFlags
        }
        item.tag = nextTag
        handlers[nextTag] = handler
        nextTag += 1
        return item
    }

    @objc private func fire(_ sender: NSMenuItem) {
        handlers[sender.tag]?()
    }
}
