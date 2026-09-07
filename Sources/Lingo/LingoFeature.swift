import AppKit
import SwiftUI
import BenchCore

/// Translate selected text, the pointer target, a screenshot, or the
/// clipboard — Google, Bing and Gemini side by side, ported from the
/// standalone Transi app.
///
/// The bits that used to live in Transi's `App.swift`/`AppDelegate.swift` —
/// building the status item itself, the app-wide Edit-menu shim, the local
/// ⌘, monitor, and the Accessibility/Screen-Recording onboarding prompts —
/// are `Bench`'s job now, not this module's; see `docs/ARCHITECTURE.md`.
/// What's left, the four translate/speak/screenshot/clipboard flows and the
/// dynamic Engine/Translate To submenus, lives in `LingoController`.
public final class LingoFeature: BenchFeature {
    public let id = "lingo"
    public let title = "Lingo"
    public let symbolName = "character.bubble"
    public let summary = "Translate selected text, the pointer target, a screenshot or the clipboard"
    public let requiredPermissions: [BenchPermission] = [.accessibility, .screenRecording, .automation]

    public var hotkeyActions: [HotkeyAction] {
        LingoAction.allCases.map(\.hotkeyAction)
    }

    private let controller = LingoController()
    /// `NSMenuItem.target` must be an `NSObject`; `LingoController` isn't
    /// one, so this small helper is what the status-item menu actually
    /// targets, forwarding straight back to the controller. Kept alive for
    /// the feature's whole lifetime — a menu whose target has been
    /// deallocated silently disables its items.
    private let menuTarget = LingoMenuTarget()

    public init() {
        menuTarget.controller = controller
    }

    public func start() { controller.start() }
    public func stop() { controller.stop() }

    public func menuItems() -> [NSMenuItem] {
        controller.menuItems(
            target: menuTarget,
            selectors: LingoMenuSelectors(
                translate: #selector(LingoMenuTarget.translate),
                captureScreenshot: #selector(LingoMenuTarget.captureScreenshot),
                speakSelection: #selector(LingoMenuTarget.speakSelection),
                translateClipboard: #selector(LingoMenuTarget.translateClipboard),
                typeToTranslate: #selector(LingoMenuTarget.typeToTranslate),
                selectEngine: #selector(LingoMenuTarget.selectEngine(_:)),
                selectTargetLanguage: #selector(LingoMenuTarget.selectTargetLanguage(_:))))
    }

    public func makeSettingsView() -> AnyView {
        AnyView(LingoSettingsView())
    }
}

/// The status-item menu's target for every Lingo action. A plain forwarding
/// shim — all the actual behavior lives in `LingoController`.
@MainActor
final class LingoMenuTarget: NSObject {
    weak var controller: LingoController?

    @objc func translate() { controller?.translateCurrentSelection() }
    @objc func captureScreenshot() { controller?.captureScreenshotAndTranslate() }
    @objc func speakSelection() { controller?.speakCurrentSelection() }
    @objc func translateClipboard() { controller?.translateClipboard() }
    @objc func typeToTranslate() { controller?.typeToTranslate() }
    @objc func selectEngine(_ sender: NSMenuItem) { controller?.selectEngine(sender) }
    @objc func selectTargetLanguage(_ sender: NSMenuItem) { controller?.selectTargetLanguage(sender) }
}

/// TabView shell for Lingo's Settings pane. Matches Transi's own tab set
/// minus General/Permissions/Appearance's theme half (all app-wide `Bench`
/// concerns now): Languages, Engines, Popup (Transi's `AppearanceTab`,
/// trimmed to its popup-only controls), Shortcuts.
private struct LingoSettingsView: View {
    var body: some View {
        TabView {
            LanguagesTab()
                .tabItem { Label("Languages", systemImage: "globe") }
            EnginesTab()
                .tabItem { Label("Engines", systemImage: "network") }
            AppearanceTab()
                .tabItem { Label("Popup", systemImage: "text.bubble") }
            Form {
                FeatureShortcutsSection(featureID: "lingo")
            }
            .formStyle(.grouped)
            .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 480, height: 420)
    }
}
