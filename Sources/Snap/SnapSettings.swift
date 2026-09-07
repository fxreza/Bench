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
    }

    enum Defaults {
        static let gap: Double = 0

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

    private let defaults: UserDefaults

    init(defaults: UserDefaults = BenchDefaults.standard) {
        self.defaults = defaults
        gap = defaults.object(forKey: Key.gap) as? Double ?? Defaults.gap
        terminalScript = defaults.string(forKey: Key.terminalScript) ?? Defaults.terminalScript
        downloadsScript = defaults.string(forKey: Key.downloadsScript) ?? Defaults.downloadsScript
    }

    /// The gap as the geometry wants it: never negative, never so large that
    /// a quarter would vanish.
    var effectiveGap: CGFloat { CGFloat(min(max(gap, 0), 200)) }

    func resetTerminalScript() { terminalScript = Defaults.terminalScript }
    func resetDownloadsScript() { downloadsScript = Defaults.downloadsScript }
}
