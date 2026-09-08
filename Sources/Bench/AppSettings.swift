import AppKit
import BenchCore

extension Notification.Name {
    /// Posted when `AppSettings.hideMenuBarIcon` changes, so
    /// `StatusBarController` can add or remove the status item.
    ///
    /// Lives here rather than in `BenchCore`'s `Notifications.swift` because
    /// only the app shell cares: no module ever hides the icon.
    static let benchStatusBarVisibilityChanged =
        Notification.Name("bench.statusBarVisibilityChanged")

    /// Posted when `AppSettings.menuBarSeparatorCount` changes, so
    /// `MenuBarSeparators` can add or remove status items to match.
    static let benchMenuBarSeparatorsChanged =
        Notification.Name("bench.menuBarSeparatorsChanged")
}

/// The app shell's own preferences - the ones that belong to no module.
///
/// Every key is prefixed `bench.` on `BenchDefaults.standard`, the same way
/// each module prefixes its own (see `docs/ARCHITECTURE.md`). The module
/// enable flags are not here: `FeatureRegistry` owns those.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = BenchDefaults.standard

    enum Key {
        static let hideMenuBarIcon = "bench.hideMenuBarIcon"
        static let autoCheckUpdates = "bench.autoCheckUpdates"
        static let includePrereleases = "bench.includePrereleases"
        static let hasCompletedOnboarding = "bench.hasCompletedOnboarding"
        static let suppressStandaloneQuitPrompt = "bench.suppressStandaloneQuitPrompt"
        static let menuBarSeparatorCount = "bench.menuBarSeparatorCount"
    }

    /// Hides the menu bar icon. The way back in is relaunching Bench, which
    /// opens Settings (`applicationShouldHandleReopen`).
    @Published var hideMenuBarIcon: Bool {
        didSet {
            guard oldValue != hideMenuBarIcon else { return }
            defaults.set(hideMenuBarIcon, forKey: Key.hideMenuBarIcon)
            NotificationCenter.default.post(name: .benchStatusBarVisibilityChanged, object: nil)
        }
    }

    /// Checks GitHub for a new release on launch, at most once a day.
    @Published var autoCheckUpdates: Bool {
        didSet { defaults.set(autoCheckUpdates, forKey: Key.autoCheckUpdates) }
    }

    /// Offers releases marked pre-release too.
    @Published var includePrereleases: Bool {
        didSet { defaults.set(includePrereleases, forKey: Key.includePrereleases) }
    }

    /// False until the end of the first launch: gates the launch-at-login
    /// registration and the Permissions pane that first launch opens.
    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Key.hasCompletedOnboarding) }
        set { defaults.set(newValue, forKey: Key.hasCompletedOnboarding) }
    }

    /// "Don't ask again" on the "Klip, Snapper and Transi are still running"
    /// alert.
    var suppressStandaloneQuitPrompt: Bool {
        get { defaults.bool(forKey: Key.suppressStandaloneQuitPrompt) }
        set { defaults.set(newValue, forKey: Key.suppressStandaloneQuitPrompt) }
    }

    /// How many thin vertical divider lines `MenuBarSeparators` keeps in the
    /// menu bar, 0 to 5. Clamped on write so a bad default or a stray
    /// `defaults write` can never ask for more items than the class expects.
    @Published var menuBarSeparatorCount: Int {
        didSet {
            let clamped = min(max(menuBarSeparatorCount, 0), 5)
            guard clamped == menuBarSeparatorCount else {
                menuBarSeparatorCount = clamped // re-enters didSet once, then settles
                return
            }
            guard oldValue != menuBarSeparatorCount else { return }
            defaults.set(menuBarSeparatorCount, forKey: Key.menuBarSeparatorCount)
            NotificationCenter.default.post(name: .benchMenuBarSeparatorsChanged, object: nil)
        }
    }

    private init() {
        // Update checking is on unless the user turned it off; everything else
        // defaults to false, which `bool(forKey:)` already gives.
        defaults.register(defaults: [Key.autoCheckUpdates: true])
        hideMenuBarIcon = defaults.bool(forKey: Key.hideMenuBarIcon)
        autoCheckUpdates = defaults.bool(forKey: Key.autoCheckUpdates)
        includePrereleases = defaults.bool(forKey: Key.includePrereleases)
        menuBarSeparatorCount = min(max(defaults.integer(forKey: Key.menuBarSeparatorCount), 0), 5)
    }
}
