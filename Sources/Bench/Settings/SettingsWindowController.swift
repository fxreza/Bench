import AppKit
import BenchCore
import SwiftUI

/// One row of the Settings sidebar.
enum SettingsPane: Hashable {
    case general
    case shortcuts
    case permissions
    case about
    /// A module's own pane, by feature id.
    case feature(String)

    init(_ destination: BenchSettingsDestination) {
        switch destination {
        case .general: self = .general
        case .shortcuts: self = .shortcuts
        case .permissions: self = .permissions
        case .about: self = .about
        case .feature(let id): self = .feature(id)
        }
    }
}

/// Drives which pane `SettingsView`'s sidebar has selected.
///
/// A singleton rather than state owned by the window controller, because
/// `show(destination:)` needs to switch panes on an already-open window from
/// outside SwiftUI - that is what `BenchSettings.open(_:)` does from a module.
@MainActor
final class SettingsSelection: ObservableObject {
    static let shared = SettingsSelection()
    @Published var pane: SettingsPane = .general
    private init() {}
}

/// Owns the single Settings window: a plain `NSWindow` wrapping a SwiftUI root
/// via `NSHostingController`. Bench is `LSUIElement`/`.accessory`, so there is
/// no menu-bar-driven `Scene` lifecycle to hook a SwiftUI `Settings` scene
/// into. Ported from Transi's `SettingsWindowController`.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var current: SettingsWindowController?

    static let contentSize = NSSize(width: 760, height: 560)

    /// Shows the window, creating it on first use. A second call re-fronts the
    /// existing window; passing a destination also switches panes.
    static func show(destination: BenchSettingsDestination? = nil) {
        if let destination {
            SettingsSelection.shared.pane = SettingsPane(destination)
        }
        let controller = current ?? SettingsWindowController()
        current = controller
        controller.showWindow(nil)
    }

    private init() {
        let hostingController = NSHostingController(
            rootView: SettingsView(selection: SettingsSelection.shared))
        hostingController.view.frame = NSRect(origin: .zero, size: Self.contentSize)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Bench Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(Self.contentSize)
        window.minSize = NSSize(width: 680, height: 460)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// `makeKeyAndOrderFront` alone can leave an `.accessory` app's window
    /// behind whatever app is frontmost; `NSApp.activate` is what actually
    /// brings keyboard focus here, which the Shortcuts pane's recorder fields
    /// depend on just as much as the user does.
    ///
    /// Permission polling is driven by the window, not by view `onAppear`,
    /// which also fires for offscreen renders.
    override func showWindow(_ sender: Any?) {
        // One `startPolling` per `windowWillClose`: re-fronting an open window
        // must not add a second poller that nothing ever balances.
        if window?.isVisible != true { PermissionsState.shared.startPolling() }
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        PermissionsState.shared.stopPolling()
        Self.current = nil
    }
}
