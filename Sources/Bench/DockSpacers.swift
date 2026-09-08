import AppKit
import Combine

/// The Dock's own gap tiles, added and removed from Settings instead of by
/// hand-editing `com.apple.dock`.
///
/// macOS has two: `spacer-tile` (the width of an app icon) and
/// `small-spacer-tile` (half of that). Both are invisible gaps the user can
/// ⌘-drag between icons; the Dock draws nothing else - a visible line cannot
/// be added to the app section (on macOS 26 every app icon sits on a
/// generated squircle, so a "line icon" app shows up as a tile with a line
/// on it). Bench therefore manages exactly the tiles Apple provides.
///
/// Nothing is stored on Bench's side: the Dock's preference file is the
/// truth, so the steppers show whatever gaps are there already, including
/// ones the user added with `defaults write` years ago. Every change
/// rewrites `persistent-apps` and restarts the Dock, which is the only way
/// the Dock picks up its own preferences.
@MainActor
enum DockSpacers {
    enum Kind: String, CaseIterable, Identifiable {
        case normal = "spacer-tile"
        case small = "small-spacer-tile"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .normal: return "Dock gaps"
            case .small: return "Half-width Dock gaps"
            }
        }
    }

    /// More than this and the Dock is mostly holes.
    static let maximum = 8

    private static let domain = "com.apple.dock"
    private static let appsKey = "persistent-apps"

    /// How many gaps of `kind` the app section of the Dock holds right now.
    static func count(of kind: Kind) -> Int {
        tiles().filter { tileType($0) == kind.rawValue }.count
    }

    /// Adds or removes gaps of `kind` so the Dock holds `count` of them, then
    /// restarts the Dock. New gaps land at the right end of the app section;
    /// removal takes the most recently added ones first, so the gaps the
    /// user has already dragged into place are the last to go. Returns false
    /// when the Dock already had that many.
    @discardableResult
    static func setCount(_ count: Int, of kind: Kind) -> Bool {
        var tiles = tiles()
        let existing = tiles.indices.filter { tileType(tiles[$0]) == kind.rawValue }
        let target = max(0, min(count, maximum))
        guard existing.count != target else { return false }

        if existing.count > target {
            for index in existing.suffix(existing.count - target).reversed() {
                tiles.remove(at: index)
            }
        } else {
            for _ in 0..<(target - existing.count) {
                tiles.append(["tile-type": kind.rawValue, "tile-data": [String: Any]()])
            }
        }

        guard let defaults = UserDefaults(suiteName: domain) else { return false }
        defaults.set(tiles, forKey: appsKey)
        defaults.synchronize()
        restartDock()
        return true
    }

    // MARK: - Plumbing

    private static func tiles() -> [[String: Any]] {
        UserDefaults(suiteName: domain)?.array(forKey: appsKey) as? [[String: Any]] ?? []
    }

    private static func tileType(_ tile: [String: Any]) -> String? {
        tile["tile-type"] as? String
    }

    /// SIGTERM, the same thing `killall Dock` sends; launchd brings the Dock
    /// straight back with the new preferences. `NSRunningApplication.terminate`
    /// is not used: the Dock ignores the quit Apple event.
    private static func restartDock() {
        for dock in NSRunningApplication.runningApplications(withBundleIdentifier: domain) {
            kill(dock.processIdentifier, SIGTERM)
        }
    }
}

/// The two steppers' state for the General pane. Reads the live counts when
/// the pane appears, keeps re-reading them while it is visible (a gap the
/// user drags off the Dock shows up in the count within a second, the way a
/// menu bar line dragged off lowers its stepper), and applies a change after
/// a short pause, so clicking a stepper three times restarts the Dock once,
/// not three times.
///
/// Polling rather than watching the plist file: the Dock's preferences go
/// through cfprefsd, which may hold a write in memory for a while before the
/// file on disk changes, whereas `UserDefaults(suiteName:)` always answers
/// with the current value. One small array read every second while a
/// Settings pane is open costs nothing.
@MainActor
final class DockSpacerModel: ObservableObject {
    @Published var normal: Int = 0 { didSet { scheduleApply() } }
    @Published var small: Int = 0 { didSet { scheduleApply() } }
    /// True between a change and the Dock restart that applies it.
    @Published private(set) var isPending = false

    private var pending: DispatchWorkItem?
    private var loading = false
    private var poll: Timer?

    /// How long the steppers wait for another click before restarting the Dock.
    static let applyDelay: TimeInterval = 0.8
    /// How often the live counts are re-read while the pane is visible.
    static let pollInterval: TimeInterval = 1.0

    func reload() {
        // A count the user is still editing must not be overwritten by the
        // Dock's old value; `apply()` reloads once the change has landed.
        guard !isPending else { return }
        loading = true
        let liveNormal = DockSpacers.count(of: .normal)
        let liveSmall = DockSpacers.count(of: .small)
        if normal != liveNormal { normal = liveNormal }
        if small != liveSmall { small = liveSmall }
        loading = false
    }

    /// Called from the pane's `onAppear` / `onDisappear`.
    func startWatching() {
        reload()
        poll?.invalidate()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        timer.tolerance = Self.pollInterval * 0.5
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    func stopWatching() {
        poll?.invalidate()
        poll = nil
    }

    private func scheduleApply() {
        guard !loading else { return }
        pending?.cancel()
        isPending = true
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.apply() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.applyDelay, execute: work)
    }

    private func apply() {
        pending = nil
        // Each call restarts the Dock only when it changes something, and the
        // second call sees the first call's tiles, so two kinds changed at
        // once cost two restarts at most.
        DockSpacers.setCount(normal, of: .normal)
        DockSpacers.setCount(small, of: .small)
        isPending = false
        reload()
    }

    deinit {
        poll?.invalidate()
    }
}
