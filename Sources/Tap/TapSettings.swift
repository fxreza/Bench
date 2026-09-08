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

    private let defaults: UserDefaults

    init(defaults: UserDefaults = BenchDefaults.standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Key.middleClickMode)
        mode = stored.flatMap(MiddleClickMode.init(rawValue:)) ?? .default
    }
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
