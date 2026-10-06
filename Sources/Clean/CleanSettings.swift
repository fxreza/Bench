import Combine
import Foundation
import OSLog
import BenchCore

nonisolated enum CleanLog {
    static let log = Logger(subsystem: "com.fxreza.bench", category: "clean")
}

/// Clean's preferences, under the `clean.` prefix in `BenchDefaults.standard`.
///
/// Only what the user asked to choose: how dark the screens go, how long a
/// button has to be held to unlock, and whether the unlock square is on
/// screen the whole time. Everything else (what is blocked, keeping the
/// display awake) is fixed, not a setting.
@MainActor
final class CleanSettings: ObservableObject {
    static let shared = CleanSettings()

    enum Key {
        static let darkness = "clean.darkness"
        static let holdSeconds = "clean.holdSeconds"
        static let showIndicator = "clean.showIndicator"
    }

    static let defaultDarkness = 0.9
    static let defaultHoldSeconds = 3
    static let holdSecondsRange = 1...10

    /// Opacity of the black cover over every screen, 0...1.
    @Published var darkness: Double {
        didSet { defaults.set(darkness, forKey: Key.darkness) }
    }

    /// Seconds a trackpad or mouse button has to stay down to unlock.
    @Published var holdSeconds: Int {
        didSet { defaults.set(holdSeconds, forKey: Key.holdSeconds) }
    }

    /// True: the square is on screen for the whole lock. False: it appears
    /// only while a button is held, as in KeyboardCleanTool.
    @Published var showIndicator: Bool {
        didSet { defaults.set(showIndicator, forKey: Key.showIndicator) }
    }

    private let defaults: UserDefaults
    private var syncObserver: NSObjectProtocol?

    init(defaults: UserDefaults = BenchDefaults.standard) {
        self.defaults = defaults
        darkness = Self.storedDarkness(defaults)
        holdSeconds = Self.storedHoldSeconds(defaults)
        showIndicator = defaults.object(forKey: Key.showIndicator) as? Bool ?? true
        syncObserver = SettingsSync.observeApplied(prefix: "clean.") { [weak self] _ in
            self?.reloadFromDefaults()
        }
    }

    func reloadFromDefaults() {
        let storedDarkness = Self.storedDarkness(defaults)
        if storedDarkness != darkness { darkness = storedDarkness }
        let storedHold = Self.storedHoldSeconds(defaults)
        if storedHold != holdSeconds { holdSeconds = storedHold }
        let storedShow = defaults.object(forKey: Key.showIndicator) as? Bool ?? true
        if storedShow != showIndicator { showIndicator = storedShow }
    }

    private static func storedDarkness(_ defaults: UserDefaults) -> Double {
        guard let value = defaults.object(forKey: Key.darkness) as? Double else { return defaultDarkness }
        return min(max(value, 0), 1)
    }

    private static func storedHoldSeconds(_ defaults: UserDefaults) -> Int {
        guard let value = defaults.object(forKey: Key.holdSeconds) as? Int else { return defaultHoldSeconds }
        return min(max(value, holdSecondsRange.lowerBound), holdSecondsRange.upperBound)
    }
}

/// Whether the lock is on. Published for the Settings pane.
@MainActor
final class CleanStatus: ObservableObject {
    static let shared = CleanStatus()

    @Published var isLocked = false

    private init() {}
}
