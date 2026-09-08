import AppKit
import Foundation
import Combine
import BenchCore

/// Snap's preferences, all under the `snap.` prefix in
/// `BenchDefaults.standard`.
///
/// Each property writes through on change, so a Settings toggle takes effect
/// on the next hotkey press without a save button. Defaults live in
/// `Defaults` below and are also what the two "Reset" buttons restore.
@MainActor
final class SnapSettings: ObservableObject {
    static let shared = SnapSettings()

    enum Key {
        static let gap = "snap.gap"
        static let terminalScript = "snap.script.terminal"
        static let downloadsScript = "snap.script.downloads"
        /// Path of the .app behind launcher `slot` (1-based), "" when unset.
        static func launcher(_ slot: Int) -> String { "snap.launcher.\(slot).path" }
        static let modifierDragEnabled = "snap.modifierDragEnabled"
        static let moveModifiers = "snap.moveModifiers"
        static let resizeModifiers = "snap.resizeModifiers"
        static let dragThreshold = "snap.dragThreshold"
        static let bringToFront = "snap.bringToFront"
    }

    enum Defaults {
        static let gap: Double = 0

        static let modifierDragEnabled = true
        /// BetterTouchTool's own defaults for "Moving & Resizing Modifier
        /// Keys": ⇧⌥ moves, ⇧⌃ resizes.
        static let moveModifiers: NSEvent.ModifierFlags = [.shift, .option]
        static let resizeModifiers: NSEvent.ModifierFlags = [.shift, .control]
        /// Points the pointer must travel before the window starts following
        /// it, so holding the combination still does nothing.
        static let dragThreshold: Double = 2
        /// Off, like BTT's "bring moving window to front": raising a window
        /// the user only nudged would steal focus mid-sentence.
        static let bringToFront = false

        /// BTT's "Run Script: New Terminal Window". Reuses a running Terminal
        /// (a `do script ""` opens a fresh window in it) and just activates a
        /// cold one, which already opens a window of its own.
        static let terminalScript = """
            if application "Terminal" is running then
                tell application "Terminal"
                    do script ""
                    activate
                end tell
            else
                tell application "Terminal"
                    activate
                end tell
            end if
            """

        /// BTT's "Run Script: Open Downloads in Finder".
        static let downloadsScript = """
            tell application "Finder"
                set newWindow to make new Finder window
                set target of newWindow to folder "Downloads" of home
                activate
            end tell
            """
    }

    /// Points left between a window and the screen edges, and between two
    /// windows side by side. 0 reproduces BetterTouchTool's flush tiling.
    @Published var gap: Double {
        didSet { defaults.set(gap, forKey: Key.gap) }
    }

    @Published var terminalScript: String {
        didSet { defaults.set(terminalScript, forKey: Key.terminalScript) }
    }

    @Published var downloadsScript: String {
        didSet { defaults.set(downloadsScript, forKey: Key.downloadsScript) }
    }

    /// How many "Open App" shortcuts Snap offers.
    nonisolated static let launcherSlots = 3

    /// One .app path per launcher slot, index 0 = slot 1; "" for an empty slot.
    @Published var launcherPaths: [String] {
        didSet {
            for (index, path) in launcherPaths.enumerated() {
                defaults.set(path, forKey: Key.launcher(index + 1))
            }
        }
    }

    /// The app behind `slot`, or nil when the slot is empty or the app is
    /// gone from disk (an uninstalled app reads as unset, not as an error).
    func launcherURL(_ slot: Int) -> URL? {
        guard (1...Self.launcherSlots).contains(slot) else { return nil }
        let path = launcherPaths[slot - 1]
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// The app's display name without ".app", for the menu and the pane.
    func launcherName(_ slot: Int) -> String? {
        guard let url = launcherURL(slot) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    func setLauncher(_ slot: Int, url: URL?) {
        guard (1...Self.launcherSlots).contains(slot) else { return }
        launcherPaths[slot - 1] = url?.path ?? ""
    }

    /// Master switch for the held-modifier move/resize gestures.
    @Published var modifierDragEnabled: Bool {
        didSet { defaults.set(modifierDragEnabled, forKey: Key.modifierDragEnabled) }
    }

    /// Held while moving the mouse to move the window under the pointer.
    /// Persisted as the raw `NSEvent.ModifierFlags` bit field.
    @Published var moveModifiers: NSEvent.ModifierFlags {
        didSet { defaults.set(moveModifiers.rawValue, forKey: Key.moveModifiers) }
    }

    /// Held while moving the mouse to resize the window under the pointer.
    @Published var resizeModifiers: NSEvent.ModifierFlags {
        didSet { defaults.set(resizeModifiers.rawValue, forKey: Key.resizeModifiers) }
    }

    @Published var dragThreshold: Double {
        didSet { defaults.set(dragThreshold, forKey: Key.dragThreshold) }
    }

    @Published var bringToFront: Bool {
        didSet { defaults.set(bringToFront, forKey: Key.bringToFront) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = BenchDefaults.standard) {
        self.defaults = defaults
        gap = defaults.object(forKey: Key.gap) as? Double ?? Defaults.gap
        terminalScript = defaults.string(forKey: Key.terminalScript) ?? Defaults.terminalScript
        downloadsScript = defaults.string(forKey: Key.downloadsScript) ?? Defaults.downloadsScript
        launcherPaths = (1...Self.launcherSlots).map { defaults.string(forKey: Key.launcher($0)) ?? "" }
        modifierDragEnabled = defaults.object(forKey: Key.modifierDragEnabled) as? Bool
            ?? Defaults.modifierDragEnabled
        moveModifiers = (defaults.object(forKey: Key.moveModifiers) as? UInt).map(NSEvent.ModifierFlags.init(rawValue:))
            ?? Defaults.moveModifiers
        resizeModifiers = (defaults.object(forKey: Key.resizeModifiers) as? UInt).map(NSEvent.ModifierFlags.init(rawValue:))
            ?? Defaults.resizeModifiers
        dragThreshold = defaults.object(forKey: Key.dragThreshold) as? Double ?? Defaults.dragThreshold
        bringToFront = defaults.object(forKey: Key.bringToFront) as? Bool ?? Defaults.bringToFront
    }

    /// The gap as the geometry wants it: never negative, never so large that
    /// a quarter would vanish.
    var effectiveGap: CGFloat { CGFloat(min(max(gap, 0), 200)) }

    /// The threshold as the gesture wants it: never negative, never so large
    /// that the gesture could not be triggered by a normal flick of the wrist.
    var effectiveDragThreshold: CGFloat { CGFloat(min(max(dragThreshold, 0), 100)) }

    func resetTerminalScript() { terminalScript = Defaults.terminalScript }
    func resetDownloadsScript() { downloadsScript = Defaults.downloadsScript }
}
