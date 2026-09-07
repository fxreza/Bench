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
        static let titleBarDoubleClick = "snap.titlebarDoubleClick"
        static let titleBarDoubleClickRestores = "snap.titlebarDoubleClickRestores"
        static let terminalScript = "snap.script.terminal"
        static let downloadsScript = "snap.script.downloads"
    }

    enum Defaults {
        static let gap: Double = 0
        static let titleBarDoubleClick = true
        static let titleBarDoubleClickRestores = true

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

    /// Whether the title bar double-click tap is installed at all.
    @Published var titleBarDoubleClick: Bool {
        didSet { defaults.set(titleBarDoubleClick, forKey: Key.titleBarDoubleClick) }
    }

    /// On: a second double-click restores the window's previous size (the
    /// BTT cycle). Off: every double-click maximizes.
    @Published var titleBarDoubleClickRestores: Bool {
        didSet { defaults.set(titleBarDoubleClickRestores, forKey: Key.titleBarDoubleClickRestores) }
    }

    @Published var terminalScript: String {
        didSet { defaults.set(terminalScript, forKey: Key.terminalScript) }
    }

    @Published var downloadsScript: String {
        didSet { defaults.set(downloadsScript, forKey: Key.downloadsScript) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = BenchDefaults.standard) {
        self.defaults = defaults
        gap = defaults.object(forKey: Key.gap) as? Double ?? Defaults.gap
        titleBarDoubleClick = defaults.object(forKey: Key.titleBarDoubleClick) as? Bool
            ?? Defaults.titleBarDoubleClick
        titleBarDoubleClickRestores = defaults.object(forKey: Key.titleBarDoubleClickRestores) as? Bool
            ?? Defaults.titleBarDoubleClickRestores
        terminalScript = defaults.string(forKey: Key.terminalScript) ?? Defaults.terminalScript
        downloadsScript = defaults.string(forKey: Key.downloadsScript) ?? Defaults.downloadsScript
    }

    /// The gap as the geometry wants it: never negative, never so large that
    /// a quarter would vanish.
    var effectiveGap: CGFloat { CGFloat(min(max(gap, 0), 200)) }

    func resetTerminalScript() { terminalScript = Defaults.terminalScript }
    func resetDownloadsScript() { downloadsScript = Defaults.downloadsScript }
}
