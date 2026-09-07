import AppKit
import BenchCore
import Klip
import Lingo
import Shot
import Snap
import Piko
import notify

/// A feature that can open an image file handed to the app by Finder or
/// `open`. Only Shot implements it.
///
/// Declared here rather than in `BenchCore` so the app can hand
/// `application(_:open:)` to a module without `BenchFeature` growing a method
/// three of the four modules would leave empty. The conformance is added on
/// this side, below, since `ShotFeature` already has the method.
@MainActor
protocol ImageOpening: AnyObject {
    func openImage(at url: URL)
}

extension ShotFeature: ImageOpening {}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var settingsKeyMonitor: Any?
    private var openSettingsObserver: NSObjectProtocol?
    /// URLs that arrived before the app finished launching.
    private var pendingOpenURLs: [URL] = []

    private let settings = AppSettings.shared

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        FeatureRegistry.shared.register([ShotFeature(), KlipFeature(), LingoFeature(), SnapFeature(), PikoFeature()])
        AppearanceSettings.shared.apply()
        installEditMenu()
        installSettingsKeyMonitor()
        observeOpenSettings()

        statusBar = StatusBarController()
        FeatureRegistry.shared.startEnabled()

        warnAboutStandaloneAppsIfNeeded()
        runFirstLaunchIfNeeded()

        if settings.autoCheckUpdates {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                UpdateService.shared.checkOnLaunchIfNeeded()
            }
        }
        UpdateService.shared.checkIfJustUpdated()

        DebugHooks.install()

        if !pendingOpenURLs.isEmpty {
            let urls = pendingOpenURLs
            pendingOpenURLs = []
            open(imageURLs: urls)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        FeatureRegistry.shared.stopAll()
    }

    /// Relaunching Bench (from Finder, Spotlight or `open`) while it is
    /// already running reveals Settings. That is also the documented way back
    /// after the menu bar icon has been hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.show()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // Before `applicationDidFinishLaunching` there is no feature to hand
        // them to; opening a file in Finder launches the app this way.
        guard statusBar != nil else {
            pendingOpenURLs.append(contentsOf: urls)
            return
        }
        open(imageURLs: urls)
    }

    private func open(imageURLs urls: [URL]) {
        guard let feature = FeatureRegistry.shared.feature(id: "shot") else { return }
        guard let opener = feature as? ImageOpening else {
            NSLog("[Bench] Ignoring \(urls.count) file(s): Shot cannot open images yet.")
            return
        }
        urls.forEach { opener.openImage(at: $0) }
    }

    // MARK: - Menus and key monitors

    /// An `LSUIElement` app shows no menu bar, but ⌘C/⌘V/⌘X/⌘A/⌘Z are
    /// dispatched through the main menu's Edit key equivalents - without one,
    /// keyboard editing is dead in every text field of every module's
    /// Settings pane and only the right-click menu works. This menu is never
    /// shown; it exists so the standard editing shortcuts resolve. Ported
    /// from Transi's `AppDelegate.installEditMenu`.
    private func installEditMenu() {
        let mainMenu = NSMenu()
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: #selector(UndoManager.undo), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: #selector(UndoManager.redo), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    /// ⌘, opens Settings from any Bench window. A *local* monitor on purpose:
    /// it only sees events while a Bench window is key, so it can never steal
    /// ⌘, from another app's own settings the way a global hotkey would. The
    /// status menu's "Settings…" item is the always-available path.
    private func installSettingsKeyMonitor() {
        settingsKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               event.charactersIgnoringModifiers == "," {
                MainActor.assumeIsolated { SettingsWindowController.show() }
                return nil
            }
            return event
        }
    }

    /// `BenchSettings.open(_:)` is the only way a module opens Settings; the
    /// app owns the window and decides which pane to show.
    private func observeOpenSettings() {
        openSettingsObserver = NotificationCenter.default.addObserver(
            forName: .benchOpenSettings, object: nil, queue: .main
        ) { note in
            let destination = note.userInfo?["destination"] as? BenchSettingsDestination
            MainActor.assumeIsolated {
                SettingsWindowController.show(destination: destination ?? .general)
            }
        }
    }

    // MARK: - First launch

    /// Registers launch-at-login and points the user at Permissions, once.
    ///
    /// Launch at login is deferred a second, as Klip does: `SMAppService`
    /// registers the bundle that is running, and calling it while the app is
    /// still coming up races the LaunchServices registration of a freshly
    /// installed copy. On every later launch Bench says nothing about
    /// permissions - a module that needs one asks when it is used.
    private func runFirstLaunchIfNeeded() {
        guard !settings.hasCompletedOnboarding else { return }
        settings.hasCompletedOnboarding = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if let error = LaunchAtLogin.setEnabled(true) {
                NSLog("[Bench] First-launch launch-at-login registration failed: \(error)")
            }
        }

        let permissions = PermissionsState.shared
        permissions.refresh()
        let needed = Set(FeatureRegistry.shared.enabledFeatures.flatMap(\.requiredPermissions))
        let missing = needed.contains { !permissions.granted($0) }
        // A fresh install of a build whose modules are still stubs declares no
        // permissions at all; show the pane anyway when either grant that
        // every module eventually wants is missing.
        if missing || !permissions.accessibilityTrusted || !permissions.screenRecordingGranted {
            SettingsWindowController.show(destination: .permissions)
        }
    }

    // MARK: - Standalone apps

    /// Bench replaces Klip.app, Snapper.app and Transi.app, and registers the
    /// same global shortcuts they do. Two apps cannot own one combination:
    /// whichever registered first keeps it and the other silently loses it,
    /// which looks like a broken hotkey rather than a conflict. So say so
    /// once, offer to quit them, and let the user suppress the question.
    private func warnAboutStandaloneAppsIfNeeded() {
        guard !settings.suppressStandaloneQuitPrompt else { return }
        let running = Self.runningStandaloneApps()
        guard !running.isEmpty else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Klip, Snapper, Transi and Piko are still running."
        alert.informativeText = """
            Bench replaces them and uses the same shortcuts, media keys and \
            notch, so they will fight over them. Alcove and Glint clash with \
            Piko the same way.

            Still running: \(running.map(\.name).joined(separator: ", ")).

            Quitting them here only lasts until you log in again - turn off \
            Launch at Login in each of those apps yourself, Bench cannot do \
            that for them.
            """
        alert.addButton(withTitle: "Quit Them")
        alert.addButton(withTitle: "Not Now")
        let suppression = NSButton(checkboxWithTitle: "Don't ask again", target: nil, action: nil)
        alert.accessoryView = suppression
        alert.window.initialFirstResponder = suppression

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if suppression.state == .on {
            settings.suppressStandaloneQuitPrompt = true
        }
        guard response == .alertFirstButtonReturn else { return }
        for app in running {
            for instance in NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID) {
                instance.terminate()
            }
        }
    }

    /// The standalone apps Bench replaces, and whether each is running now.
    static let standaloneApps: [(name: String, bundleID: String)] = [
        ("Klip", "com.fxreza.klip"),
        ("Snapper", "com.fxreza.snapper"),
        ("Transi", "com.fxreza.transi"),
        ("Piko", "com.fxreza.piko"),
    ]

    static func runningStandaloneApps() -> [(name: String, bundleID: String)] {
        standaloneApps.filter {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty
        }
    }
}

// MARK: - Debug hooks

/// `notifyutil -p com.fxreza.bench.debug.<name>` hooks used by
/// `scripts/run_app.sh` and by automated UI checks. Only active when
/// `BENCH_DEBUG=1`. These are Darwin notifications (notify(3)), which is what
/// `notifyutil -p` posts. Ported from Snapper's `DebugHooks`.
@MainActor
enum DebugHooks {
    private static var tokens: [Int32] = []

    static func install() {
        guard ProcessInfo.processInfo.environment["BENCH_DEBUG"] == "1" else { return }
        let hooks: [(String, @MainActor () -> Void)] = [
            ("settings", { SettingsWindowController.show() }),
            ("quit", { NSApp.terminate(nil) }),
        ]
        for (name, action) in hooks {
            var token: Int32 = 0
            let status = notify_register_dispatch(
                "com.fxreza.bench.debug.\(name)", &token, DispatchQueue.main
            ) { _ in
                MainActor.assumeIsolated { action() }
            }
            if status == NOTIFY_STATUS_OK { tokens.append(token) }
        }
    }
}
