import AppKit
import BenchCore

// Adapted from Transi's AppDelegate.swift (MIT, Copyright 2026 Sam Reza):
// the status-item setup, the hotkey registration, and the app-lifecycle
// bits (Edit menu shim, ⌘, monitor, Accessibility/Screen Recording
// onboarding prompts, updater) are all `Bench`'s job now, not a feature
// module's — see `LingoFeature`'s doc comment. What's left here is the
// four core flows, the double-press-to-compose rule, and the dynamic
// Engine/Translate To submenus.

/// Owns Lingo's popup, its hotkey bindings, and the menu items `LingoFeature`
/// hands to the status bar. Not itself an `NSObject` — `LingoFeature` keeps a
/// small `@objc` target object alive to receive the menu actions and forward
/// them here, per the module contract's "menu items need a target" note.
@MainActor
final class LingoController {
    private let popup = PopupController()

    /// When the translate hotkey last fired, for the double-press shortcut in
    /// `translateCurrentSelection()`.
    private var lastTranslateHotkeyPress: Date?
    private static let doublePressWindow: TimeInterval = 0.8

    // MARK: - Lifecycle

    func start() {
        TextCapture.configureAccessibilityTimeout()
        SettingsStore.importShortcutOverridesFromTransiIfNeeded()

        for action in LingoAction.allCases {
            HotkeyCenter.shared.bind(action.hotkeyAction) { [weak self] in
                self?.handle(action)
            }
        }

        // Opens the TLS connection ahead of the first real request; cheap
        // and safe to call from `start()` — it does nothing until a
        // translation is actually requested.
        TranslationCoordinator.shared.warmUpInBackground()
    }

    func stop() {
        HotkeyCenter.shared.unbindAll(featureID: "lingo")
        popup.close()
    }

    private func handle(_ action: LingoAction) {
        switch action {
        case .translateSelection: translateCurrentSelection()
        case .captureScreenshot: captureScreenshotAndTranslate()
        case .speakSelection: speakCurrentSelection()
        case .translateClipboard: translateClipboard()
        }
    }

    // MARK: - Core flows

    /// Point-translate: one hotkey, four sources tried in order — selection,
    /// then the UI element under the pointer, then OCR around the pointer,
    /// then the type-text input. Each step is a strictly weaker guess than the
    /// last, so the user never has to decide which capture mode they want.
    func translateCurrentSelection() {
        // Sampled once, at the moment the hotkey fires: it anchors the popup
        // *and* names the point we read text from, and those two must agree
        // even if the mouse moves while the capture runs.
        let mouseLocation = NSEvent.mouseLocation

        // Deliberate shortcut, not an accident of the fallback path: pressing
        // the hotkey again while the popup is still up jumps straight to the
        // input, so "⌥T ⌥T" is a two-tap way to type something to translate
        // without waiting out a capture that was never going to find text.
        let isDoublePress = popup.isPanelVisible
            && (lastTranslateHotkeyPress.map {
                Date().timeIntervalSince($0) < Self.doublePressWindow
            } ?? false)
        lastTranslateHotkeyPress = Date()
        if isDoublePress {
            popup.showComposing(near: mouseLocation)
            return
        }

        // Put the popup on screen before doing any work, so the hotkey always
        // has an immediate visible effect even when the capture needs a fallback.
        popup.showCapturing(near: mouseLocation)

        // Open the TLS connection while the selection is being read, so the
        // translation request doesn't pay for the handshake.
        TranslationCoordinator.shared.warmUpInBackground()

        Task { @MainActor in
            var captured = await TextCapture.selectedText()
            if captured == nil {
                // Nothing selected: read whatever the pointer is resting on —
                // a button, a label, an alert, or failing that OCR of the
                // pixels around it.
                captured = await PointerTextCapture.text(at: mouseLocation)
            }
            guard let text = captured else {
                // Nothing anywhere: fall into the input, so the one hotkey
                // covers "translate this" and "let me type something".
                popup.showComposing(near: mouseLocation)
                return
            }
            popup.showTranslating(text: text, near: mouseLocation)
            await popup.translateAndDisplay(text: text)
        }
    }

    func translateClipboard() {
        let mouseLocation = NSEvent.mouseLocation
        TranslationCoordinator.shared.warmUpInBackground()
        guard let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            popup.show(error: "Clipboard has no text.", near: mouseLocation)
            return
        }
        popup.showTranslating(text: text, near: mouseLocation)
        Task { @MainActor in
            await popup.translateAndDisplay(text: text)
        }
    }

    func typeToTranslate() {
        TranslationCoordinator.shared.warmUpInBackground()
        popup.showComposing(near: NSEvent.mouseLocation)
    }

    /// Reads the current selection aloud with an English voice. Language
    /// auto-detection mis-reads short English words ("Concise" as French, say),
    /// so this hotkey always pronounces English. Pressing the hotkey again on the
    /// same selection re-reads it slowly and a third press stops; SpeechService
    /// owns that cycle.
    func speakCurrentSelection() {
        let mouseLocation = NSEvent.mouseLocation
        Task { @MainActor in
            guard let text = await TextCapture.selectedText() else {
                popup.show(error: "No text selected.", near: mouseLocation)
                return
            }
            SpeechService.shared.speakEnglish(text)
        }
    }

    func captureScreenshotAndTranslate() {
        guard ScreenCaptureManager.shared.hasPermission else {
            ScreenCaptureManager.shared.requestPermissionIfNeeded()
            popup.show(
                error: "Screen Recording permission is needed for screenshot translate. "
                    + "Enable Bench in the list, then try again.",
                settingsPane: .screenRecording,
                near: NSEvent.mouseLocation)
            return
        }

        TranslationCoordinator.shared.warmUpInBackground()

        ScreenCaptureManager.shared.beginSelection { [weak self] image, point in
            guard let self else { return }
            guard let image else { return }
            Task { @MainActor in
                self.popup.showRecognizing(near: point)
                do {
                    let text = try await OCRService.recognizeText(in: image)
                    self.popup.showTranslating(text: text, near: point)
                    await self.popup.translateAndDisplay(text: text)
                } catch {
                    self.popup.show(error: error.localizedDescription, near: point)
                }
            }
        }
    }

    // MARK: - Menu

    /// The five action items, the Engine submenu, and the Translate To
    /// submenu, built fresh on every call (`LingoFeature.menuItems()` is
    /// called on every menu open, so there is no need to track a persistent
    /// `NSMenu`/`NSMenuDelegate` the way Transi's `AppDelegate` did).
    func menuItems(target: AnyObject, selectors: LingoMenuSelectors) -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        items.append(actionItem(.translateSelection, target: target, selector: selectors.translate))
        items.append(actionItem(.captureScreenshot, target: target, selector: selectors.captureScreenshot))
        items.append(actionItem(.speakSelection, target: target, selector: selectors.speakSelection))

        items.append(.separator())

        items.append(actionItem(.translateClipboard, target: target, selector: selectors.translateClipboard))

        // No hotkey of its own: ⌥T with nothing selected opens the input
        // directly, this item is the explicit path.
        let typeItem = NSMenuItem(
            title: "Type Text to Translate…", action: selectors.typeToTranslate, keyEquivalent: "")
        typeItem.target = target
        items.append(typeItem)

        items.append(.separator())

        let engineItem = NSMenuItem(title: "Engine", action: nil, keyEquivalent: "")
        engineItem.submenu = engineSubmenu(target: target, selector: selectors.selectEngine)
        items.append(engineItem)

        let translateToItem = NSMenuItem(title: "Translate To", action: nil, keyEquivalent: "")
        translateToItem.submenu = languageSubmenu(target: target, selector: selectors.selectTargetLanguage)
        items.append(translateToItem)

        return items
    }

    /// One action row, its key equivalent mirroring the live `ShortcutStore`
    /// binding. A binding whose key maps to a single character rides in
    /// `keyEquivalent`; anything else (arrows, F-keys) is appended to the
    /// title instead, since `NSMenuItem`'s key-equivalent model is
    /// single-character only.
    private func actionItem(_ action: LingoAction, target: AnyObject, selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: action.title, action: selector, keyEquivalent: "")
        item.target = target
        if let binding = ShortcutStore.shared.binding(for: action.id) {
            if let equivalent = binding.menuKeyEquivalent {
                item.keyEquivalent = equivalent
                item.keyEquivalentModifierMask = binding.eventFlags
            } else {
                item.title = "\(action.title)  \(binding.display)"
            }
        }
        return item
    }

    private func engineSubmenu(target: AnyObject, selector: Selector) -> NSMenu {
        let menu = NSMenu()
        let settings = SettingsStore.shared
        let primary = settings.orderedEnabledEngines.first
        for engine in settings.orderedEnabledEngines {
            let item = NSMenuItem(title: engine.displayName, action: selector, keyEquivalent: "")
            item.target = target
            item.representedObject = engine.rawValue
            item.state = engine == primary ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func languageSubmenu(target: AnyObject, selector: Selector) -> NSMenu {
        let menu = NSMenu()
        let settings = SettingsStore.shared
        for code in settings.enabledLanguages {
            let item = NSMenuItem(
                title: LanguageCatalog.language(for: code)?.displayName ?? code,
                action: selector, keyEquivalent: "")
            item.target = target
            item.representedObject = code
            item.state = settings.targetLanguage == code ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    // MARK: - Menu actions

    func selectTargetLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String,
              LanguageCatalog.byCode[code] != nil else { return }
        SettingsStore.shared.targetLanguage = code
    }

    /// Clicking an engine makes it primary: moved to the front of the order,
    /// relative order of the rest preserved. One source of truth shared with
    /// the Engines tab's drag-reorder.
    func selectEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let engine = EngineID(rawValue: raw) else { return }
        var order = SettingsStore.shared.engineOrder
        order.removeAll { $0 == engine }
        order.insert(engine, at: 0)
        SettingsStore.shared.engineOrder = order
    }
}

/// The `@objc` selectors `LingoFeature`'s menu target implements, so
/// `LingoController.menuItems(target:selectors:)` can build items without
/// itself being an `NSObject`.
struct LingoMenuSelectors {
    let translate: Selector
    let captureScreenshot: Selector
    let speakSelection: Selector
    let translateClipboard: Selector
    let typeToTranslate: Selector
    let selectEngine: Selector
    let selectTargetLanguage: Selector
}
