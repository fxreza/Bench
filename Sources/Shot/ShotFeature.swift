// Shot: Snapper (MIT, Copyright 2026 Sam Reza) as a Bench module. This file
// takes the place of Snapper's `AppDelegate.swift` and
// `Views/StatusBarController.swift`: the hotkey registrations become
// `HotkeyCenter` bindings, the status item's capture rows become
// `menuItems()`, and the Settings window becomes `makeSettingsView()`.

import AppKit
import SwiftUI
import BenchCore

/// Screenshots, scrolling capture and the annotation editor.
public final class ShotFeature: BenchFeature {
    /// The one place the module's id is spelled out; every preferences key
    /// and hotkey action id is built from it.
    nonisolated static let featureID = "shot"

    public let id = ShotFeature.featureID
    public let title = "Shot"
    public let symbolName = "camera.viewfinder"
    public let summary = "Screenshots, scrolling capture and annotation"
    public let requiredPermissions: [BenchPermission] = [.screenRecording, .accessibility]

    public var hotkeyActions: [HotkeyAction] {
        CaptureAction.allCases.map { action in
            HotkeyAction(
                id: action.hotkeyActionID,
                featureID: ShotFeature.featureID,
                title: action.title,
                defaultBinding: action.defaultBinding,
                note: action.shortcutNote)
        }
    }

    /// Menu items need an Objective-C target that outlives the menu; the
    /// feature keeps this one for its whole life.
    private let menuTarget = MenuTarget()
    private var observers: [NSObjectProtocol] = []

    public init() {}

    // MARK: - Lifecycle

    public func start() {
        // Before anything reads `SettingsManager.shared`: the singleton
        // caches its values at init, so an import after that point would not
        // be visible until the next launch.
        SettingsManager.importFromSnapperIfNeeded()

        for action in CaptureAction.allCases {
            let hotkey = HotkeyAction(
                id: action.hotkeyActionID,
                featureID: ShotFeature.featureID,
                title: action.title,
                defaultBinding: action.defaultBinding,
                note: action.shortcutNote)
            HotkeyCenter.shared.bind(hotkey) {
                CaptureCoordinator.shared.perform(CaptureShortcut(action, .main))
            }
        }
        bindVariantHotkeys()

        // A variant is "the main combination plus the variant modifiers", so
        // it has to be re-derived whenever either half moves.
        for name in [Notification.Name.benchShortcutsChanged, .shotVariantModifiersChanged] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.bindVariantHotkeys() }
            }
            observers.append(observer)
        }
    }

    public func stop() {
        HotkeyCenter.shared.unbindAll(featureID: id)
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        // Editor windows may hold unsaved annotations, so they stay; a live
        // overlay or scrolling session is state the user cannot get out of
        // without the hotkeys, so it goes.
        OverlayController.shared.cancel()
        CaptureCoordinator.shared.cancelScrollSession()
    }

    /// Registers the "same keys plus the variant modifiers" combination of
    /// every action that writes a file. Not rebindable and not persisted:
    /// `bindFixed` takes whatever `effectiveBinding` currently derives, and
    /// nil when there is nothing to derive (the main shortcut is cleared, or
    /// it already carries every variant modifier).
    private func bindVariantHotkeys() {
        let settings = SettingsManager.shared
        for action in CaptureAction.allCases where action.producesImage {
            let shortcut = CaptureShortcut(action, .alternate)
            HotkeyCenter.shared.bindFixed(
                id: action.variantHotkeyID,
                binding: settings.effectiveBinding(for: shortcut)
            ) {
                CaptureCoordinator.shared.perform(shortcut)
            }
        }
    }

    // MARK: - Routing

    /// Opens an image file in the editor. Bench routes
    /// `application(_:open:)` and Finder's "Open With" here.
    public func openImage(at url: URL) {
        CaptureCoordinator.shared.openImage(at: url)
    }

    // MARK: - Menu

    public func menuItems() -> [NSMenuItem] {
        let settings = SettingsManager.shared
        var items: [NSMenuItem] = []

        for action in CaptureAction.allCases {
            items.append(captureItem(CaptureShortcut(action, .main), settings: settings))
            // Held ⌥ swaps the row for its variant, the same way the ⌥
            // shortcut does. Actions that write no file have no variant.
            if action.producesImage {
                let variant = captureItem(CaptureShortcut(action, .alternate), settings: settings)
                variant.keyEquivalentModifierMask = .option
                variant.isAlternate = true
                items.append(variant)
            }
        }

        let openImageItem = NSMenuItem(title: "Open Image…", action: #selector(MenuTarget.openImageSelected), keyEquivalent: "")
        openImageItem.target = menuTarget
        items.append(openImageItem)

        return items
    }

    private func captureItem(_ shortcut: CaptureShortcut, settings: SettingsManager) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: #selector(MenuTarget.captureItemSelected(_:)), keyEquivalent: "")
        item.target = menuTarget
        item.representedObject = ShortcutBox(shortcut)
        item.image = Self.symbolImage(shortcut.action.symbolName)
        item.attributedTitle = Self.captureTitle(for: shortcut, settings: settings)
        item.keyEquivalentModifierMask = []
        return item
    }

    private static func symbolImage(_ name: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    /// The action's title with its format and hotkey appended as a dimmed,
    /// disabled-looking suffix, e.g. "Capture Area    PNG · ⌘⇧4".
    private static func captureTitle(for shortcut: CaptureShortcut, settings: SettingsManager) -> NSAttributedString {
        let title = NSMutableAttributedString(
            string: shortcut.action.title,
            attributes: [.font: NSFont.menuFont(ofSize: 0)]
        )
        var parts = shortcut.action.producesImage ? [settings.format(for: shortcut).title] : []
        if let binding = settings.effectiveBinding(for: shortcut) { parts.append(binding.display) }
        title.append(NSAttributedString(
            string: "    " + parts.joined(separator: " · "),
            attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor]
        ))
        return title
    }

    // MARK: - Settings

    public func makeSettingsView() -> AnyView {
        AnyView(ShotSettingsView())
    }
}

/// `NSMenuItem.representedObject` is `Any?`, but AppKit stores it in an
/// Objective-C property, so a Swift struct has to travel in a box.
private final class ShortcutBox: NSObject {
    let shortcut: CaptureShortcut
    init(_ shortcut: CaptureShortcut) { self.shortcut = shortcut }
}

/// The `@objc` target for the status menu's items, kept alive by the feature.
private final class MenuTarget: NSObject {
    @objc func captureItemSelected(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ShortcutBox else { return }
        CaptureCoordinator.shared.perform(box.shortcut)
    }

    @objc func openImageSelected() {
        CaptureCoordinator.shared.openImageFile()
    }
}

/// Shot's pane in the Settings window: the three tabs Snapper had that are
/// still the module's own. Startup, updates, About and Permissions belong to
/// Bench now.
private struct ShotSettingsView: View {
    private enum Tab: String {
        case general, shortcuts, appearance
    }

    @State private var tab: Tab = .general

    var body: some View {
        TabView(selection: $tab) {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            ShortcutsTab()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                .tag(Tab.shortcuts)
            AppearanceTab()
                .tabItem { Label("Editor", systemImage: "paintbrush") }
                .tag(Tab.appearance)
        }
    }
}
