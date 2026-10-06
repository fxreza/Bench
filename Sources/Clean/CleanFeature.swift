import AppKit
import SwiftUI
import BenchCore

/// Keyboard cleaning mode, after KeyboardCleanTool.
///
/// Start Cleaning Mode (pinned at the top of the status menu) blocks every
/// key, the trackpad and the mouse, darkens every screen and keeps the
/// display awake. Pressing and holding any trackpad or mouse button for a few
/// seconds unlocks; there is deliberately no key to unlock, since wiping the
/// keyboard would press it. Quitting Bench always unlocks.
///
/// Nothing runs between locks: `start()` holds nothing, and the event tap,
/// windows and power assertion exist only while locked.
///
/// Accessibility is required for the event tap. Without it the lock does not
/// start and an alert points to the Permissions pane.
public final class CleanFeature: BenchFeature {
    public let id = "clean"
    public let title = "Clean"
    public let symbolName = "sparkles"
    public let summary = "Lock keyboard, trackpad and mouse for cleaning"
    public let requiredPermissions: [BenchPermission] = [.accessibility]
    public let hotkeyActions: [HotkeyAction] = []

    private let settings = CleanSettings.shared
    private let input = InputLock()
    private let overlay = LockOverlay()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var menuTarget: MenuTarget?

    public init() {
        CleanCommands.start = { [weak self] in self?.lock() }
        input.onHoldBegan = { [weak self] duration in self?.overlay.beginHold(duration: duration) }
        input.onHoldCancelled = { [weak self] in self?.overlay.cancelHold() }
        input.onUnlockRequested = { [weak self] in self?.unlock() }
    }

    // MARK: - Lifecycle

    public func start() {}

    public func stop() {
        unlock()
    }

    // MARK: - Lock

    func lock() {
        guard !input.isActive else { return }
        guard input.start(holdSeconds: settings.holdSeconds) else {
            showAccessibilityAlert()
            return
        }
        // Frontmost, so hiding the pointer takes effect and no other app's
        // window can come up over the cover.
        NSApp.activate()
        overlay.show(darkness: settings.darkness, showIndicator: settings.showIndicator)
        CleanStatus.shared.isLocked = true

        // Locking the screen or sleeping ends cleaning mode, so the Mac never
        // comes back with its input still blocked.
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.unlock() }
        })
        distributedObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.unlock() }
        })
    }

    func unlock() {
        guard input.isActive else { return }
        input.stop()
        overlay.hide()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        distributedObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        workspaceObservers.removeAll()
        distributedObservers.removeAll()
        CleanStatus.shared.isLocked = false
    }

    private func showAccessibilityAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clean Needs Accessibility"
        alert.informativeText = "Bench can only block the keyboard, trackpad and mouse once it is allowed "
            + "under Privacy & Security > Accessibility."
        alert.addButton(withTitle: "Open Permissions")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            BenchSettings.open(.permissions)
        }
    }

    // MARK: - Menu and Settings

    /// No module section; the one action is pinned at the top of the menu.
    public func menuItems() -> [NSMenuItem] { [] }

    public func pinnedMenuItems() -> [NSMenuItem] {
        let target = MenuTarget { [weak self] in self?.lock() }
        menuTarget = target
        let item = NSMenuItem(title: "Start Cleaning Mode", action: #selector(MenuTarget.fire), keyEquivalent: "")
        item.target = target
        item.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        return [item]
    }

    public func makeSettingsView() -> AnyView {
        AnyView(CleanSettingsView())
    }
}

/// How the Settings pane starts a lock without holding the feature.
@MainActor
enum CleanCommands {
    static var start: (() -> Void)?
}

/// `NSMenuItem` needs an Objective-C target; the menu is rebuilt on every
/// open, so one is kept for the latest menu.
private final class MenuTarget: NSObject {
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    @objc func fire() { action() }
}
