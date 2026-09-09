import Combine
import Foundation
import BenchCore

/// Tap's preferences, under the `tap.` prefix in `BenchDefaults.standard`.
///
/// One setting so far: what a three-finger gesture does. It writes through on
/// change and `TapFeature` follows the publisher, so the picker takes effect
/// on the next click without a save button or a restart.
@MainActor
final class TapSettings: ObservableObject {
    static let shared = TapSettings()

    enum Key {
        static let middleClickMode = "tap.middleClickMode"
        static let fnClick = "tap.fnClick"
    }

    /// What counts as a middle click. The raw values are persisted, so they
    /// are frozen.
    enum MiddleClickMode: String, CaseIterable, Identifiable, Sendable {
        /// Nothing at all: no event tap, no multitouch callback.
        case off
        /// A physical trackpad click with three fingers down (default).
        case click
        /// Three fingers touched and lifted quickly, without clicking.
        case tap
        case both

        static let `default`: MiddleClickMode = .click

        var id: String { rawValue }

        var title: String {
            switch self {
            case .off: return "Off"
            case .click: return "Three-finger click"
            case .tap: return "Three-finger tap"
            case .both: return "Click or tap"
            }
        }

        /// Whether a physical click with three fingers down is rewritten.
        var convertsClick: Bool { self == .click || self == .both }
        /// Whether the quick-touch gesture is watched for.
        var detectsTap: Bool { self == .tap || self == .both }
    }

    @Published var mode: MiddleClickMode {
        didSet { defaults.set(mode.rawValue, forKey: Key.middleClickMode) }
    }

    /// Whether holding **fn** and clicking normally is also a middle click.
    ///
    /// Independent of `mode` on purpose: the two triggers answer different
    /// problems. Three fingers is the fast one, but it rests on the trackpad
    /// driver agreeing that three fingers are down, and on this Mac it
    /// sometimes will not (see `ContactFilter.Stage.isDown`). fn+click counts
    /// nothing - one finger, one key - so it cannot misfire that way.
    ///
    /// fn is the modifier with nothing to lose: macOS and the browsers spend
    /// ⌘ (new tab), ⇧ (new window), ⌥ (download) and ⌃ (secondary click) on a
    /// click already, and rewriting any of those would take a behaviour away.
    /// Nothing claims fn+click, so this only adds one.
    ///
    /// On by default. It conflicts with nothing, and it is the trigger that
    /// works when the trackpad will not cooperate.
    @Published var fnClickEnabled: Bool {
        didSet { defaults.set(fnClickEnabled, forKey: Key.fnClick) }
    }

    /// The settings as the engine wants them.
    var triggers: MiddleClickTriggers {
        MiddleClickTriggers(mode: mode, fnClick: fnClickEnabled)
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = BenchDefaults.standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Key.middleClickMode)
        mode = stored.flatMap(MiddleClickMode.init(rawValue:)) ?? .default
        fnClickEnabled = defaults.object(forKey: Key.fnClick) as? Bool ?? true
    }
}

/// Everything that can produce a middle click, resolved from the settings.
///
/// The trackpad gesture and fn+click are separate switches rather than more
/// cases on `MiddleClickMode`, so every combination is reachable: both, one,
/// the other, or neither.
struct MiddleClickTriggers: Equatable {
    var mode: TapSettings.MiddleClickMode
    var fnClick: Bool

    /// Whether a physical click with three fingers down is rewritten.
    var convertsClick: Bool { mode.convertsClick }
    /// Whether the quick three-finger touch is watched for.
    var detectsTap: Bool { mode.detectsTap }
    /// Whether anything at all is on.
    var isOff: Bool { mode == .off && !fnClick }

    /// Whether the event tap has to be installed. Needed for either click
    /// conversion, and in `tap` mode as well - a physical click there has to
    /// cancel the pending tap gesture.
    var needsEventTap: Bool { !isOff }
}

/// Why Tap cannot work on this Mac, if it cannot. Published separately from
/// the settings because it is discovered at `start()` and is not persisted;
/// `TapSettingsView` shows it instead of pretending the picker does anything.
@MainActor
final class TapStatus: ObservableObject {
    static let shared = TapStatus()

    /// Nil when everything is fine.
    @Published var unavailableReason: String?
    /// False while Accessibility has not been granted; the module then does
    /// nothing at all and the Permissions pane is where the user fixes it.
    @Published var accessibilityMissing = false

    var isAvailable: Bool { unavailableReason == nil }

    private init() {}
}
