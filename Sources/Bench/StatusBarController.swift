import AppKit
import BenchCore

/// Bench's one menu bar item.
///
/// Either mouse button rebuilds and shows the menu, so it always reflects the
/// modules that are switched on right now and whatever they want to offer at
/// this moment. Modelled on Snapper's and Klip's `StatusBarController`.
@MainActor
final class StatusBarController {
    private var statusItem: NSStatusItem?
    private let settings = AppSettings.shared

    init() {
        if !settings.hideMenuBarIcon {
            // Deferred by one run-loop turn on purpose. A status item created
            // inside `applicationDidFinishLaunching` - before AppKit has
            // finished setting up the menu bar - is registered but never laid
            // out: it reports a bogus frame (x = screen width, y = -1) and
            // draws nothing. Creating it once the launch turn has finished
            // puts it in the bar normally.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.statusItem == nil else { return }
                self.createStatusItem()
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(visibilityChanged),
            name: .benchStatusBarVisibilityChanged,
            object: nil)
        // No observer for shortcut or feature changes: the menu is rebuilt on
        // every click, so it always shows the current state without being told.
    }

    // MARK: - Item

    private func createStatusItem() {
        // squareLength + a dedicated autosaveName, rather than variableLength
        // in the generic "Item-0" slot: the icon asks for the least width it
        // can and remembers its own position, which keeps it from being the
        // first thing macOS drops when the menu bar runs out of room.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "BenchStatusItem"
        item.isVisible = true
        statusItem = item

        guard let button = item.button else { return }
        // `isTemplate` is set on the CONFIGURED image, not the original:
        // `withSymbolConfiguration` returns a new NSImage that does not
        // inherit the flag. Setting it before the call would leave the menu
        // bar with a non-template, solid-black glyph.
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let image = NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: "Bench")
        let configured = image?.withSymbolConfiguration(config) ?? image
        configured?.isTemplate = true
        button.image = configured

        button.target = self
        button.action = #selector(handleClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func removeStatusItem() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    @objc private func visibilityChanged() {
        if settings.hideMenuBarIcon {
            removeStatusItem()
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Menu Bar Icon Hidden"
            alert.informativeText =
                "Bench keeps running and its shortcuts keep working. "
                + "To get Settings back, launch Bench again from Finder or Spotlight."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } else if statusItem == nil {
            createStatusItem()
        }
    }

    // MARK: - Menu

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        showMenu()
    }

    private func showMenu() {
        let menu = NSMenu()

        // One section per enabled module, in registration order. A module
        // that offers nothing right now (or is not ported yet) contributes no
        // header either, rather than an empty heading over a separator.
        for feature in FeatureRegistry.shared.enabledFeatures {
            let items = feature.menuItems()
            guard !items.isEmpty else { continue }
            menu.addItem(header(feature.title))
            items.forEach { menu.addItem($0) }
            menu.addItem(.separator())
        }

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let permissionsItem = NSMenuItem(title: "Permissions…", action: #selector(openPermissions), keyEquivalent: "")
        permissionsItem.target = self
        menu.addItem(permissionsItem)

        let updatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updatesItem.target = self
        menu.addItem(updatesItem)

        menu.addItem(.separator())

        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(.separator())

        let versionItem = NSMenuItem(title: "\(BenchInfo.appName) \(BenchInfo.shortVersion)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        let quitItem = NSMenuItem(title: "Quit Bench", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil // reset so the button action fires again next click
    }

    /// A module's section heading: disabled, small, uppercased and dimmed, so
    /// the sections read as groups rather than as items you can pick.
    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .kern: 0.6,
            ])
        return item
    }

    // MARK: - Actions

    @objc private func openSettings() { SettingsWindowController.show() }
    @objc private func openPermissions() { SettingsWindowController.show(destination: .permissions) }
    @objc private func checkForUpdates() { UpdateService.shared.checkForUpdates(silent: false) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleLaunchAtLogin() {
        if let error = LaunchAtLogin.setEnabled(!LaunchAtLogin.isEnabled) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't Change Launch at Login"
            alert.informativeText = error
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
