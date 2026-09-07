import Foundation
import Combine
import BenchCore

/// User settings, backed by UserDefaults. One toggle per feature, one HUD
/// duration for volume/display, one alert duration for everything else
/// (devices, low battery, track peeks), one low-battery threshold.
///
/// In Bench every key carries the `piko.` prefix and lives in
/// `BenchDefaults.standard`; launch-at-login and update settings are the
/// app's, not the module's. On first run the standalone Piko's preferences
/// are copied over, read-only, so a user who already had Piko keeps their
/// switches.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    /// Bare keys, as the standalone app wrote them. `storageKey` is what Bench
    /// actually reads and writes.
    enum Key: String, CaseIterable {
        case volumeHUDEnabled, brightnessHUDEnabled, nowPlayingEnabled
        case connectivityEnabled, lowBatteryEnabled
        case hudDuration, alertDuration, lowBatteryThreshold
        case hideInFullscreen, hideInMissionControl

        var storageKey: String { "piko.\(rawValue)" }
    }

    /// Preferences domain of the standalone Piko, read once on first run.
    static let standaloneDomain = "com.fxreza.piko"
    static let importFlagKey = "piko.importedFromPiko"

    @Published var volumeHUDEnabled: Bool { didSet { save(.volumeHUDEnabled, volumeHUDEnabled) } }
    @Published var brightnessHUDEnabled: Bool { didSet { save(.brightnessHUDEnabled, brightnessHUDEnabled) } }
    @Published var nowPlayingEnabled: Bool { didSet { save(.nowPlayingEnabled, nowPlayingEnabled) } }
    @Published var connectivityEnabled: Bool { didSet { save(.connectivityEnabled, connectivityEnabled) } }
    @Published var lowBatteryEnabled: Bool { didSet { save(.lowBatteryEnabled, lowBatteryEnabled) } }
    /// Seconds the volume / display HUD stays visible after its last update.
    @Published var hudDuration: Double { didSet { save(.hudDuration, hudDuration) } }
    /// Seconds a device, low-battery or track-peek alert stays visible.
    @Published var alertDuration: Double { didSet { save(.alertDuration, alertDuration) } }
    /// 0...1
    @Published var lowBatteryThreshold: Double { didSet { save(.lowBatteryThreshold, lowBatteryThreshold) } }
    @Published var hideInFullscreen: Bool { didSet { save(.hideInFullscreen, hideInFullscreen) } }
    @Published var hideInMissionControl: Bool { didSet { save(.hideInMissionControl, hideInMissionControl) } }

    static let hudDurationRange: ClosedRange<Double> = 0.5...5.0
    static let alertDurationRange: ClosedRange<Double> = 1.0...10.0
    static let lowBatteryRange: ClosedRange<Double> = 0.05...0.5

    /// Factory values, also used as the registration domain.
    static let defaultValues: [String: Any] = [
        Key.volumeHUDEnabled.storageKey: true,
        Key.brightnessHUDEnabled.storageKey: true,
        Key.nowPlayingEnabled.storageKey: true,
        Key.connectivityEnabled.storageKey: true,
        Key.lowBatteryEnabled.storageKey: true,
        Key.hudDuration.storageKey: 1.5,
        Key.alertDuration.storageKey: 3.0,
        Key.lowBatteryThreshold.storageKey: 0.2,
        Key.hideInFullscreen.storageKey: true,
        Key.hideInMissionControl.storageKey: true,
    ]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = BenchDefaults.standard) {
        self.defaults = defaults
        // Copy-only, once: the standalone Piko's domain is never written to.
        // Must run before the values below are read.
        if defaults === BenchDefaults.standard {
            StandaloneImport.importDefaultsIfNeeded(
                sourceDomain: Self.standaloneDomain,
                keys: Dictionary(uniqueKeysWithValues: Key.allCases.map { ($0.rawValue, $0.storageKey) }),
                flagKey: Self.importFlagKey)
        }
        defaults.register(defaults: Self.defaultValues)

        volumeHUDEnabled = defaults.bool(forKey: Key.volumeHUDEnabled.storageKey)
        brightnessHUDEnabled = defaults.bool(forKey: Key.brightnessHUDEnabled.storageKey)
        nowPlayingEnabled = defaults.bool(forKey: Key.nowPlayingEnabled.storageKey)
        connectivityEnabled = defaults.bool(forKey: Key.connectivityEnabled.storageKey)
        lowBatteryEnabled = defaults.bool(forKey: Key.lowBatteryEnabled.storageKey)
        hudDuration = defaults.double(forKey: Key.hudDuration.storageKey)
        alertDuration = defaults.double(forKey: Key.alertDuration.storageKey)
        lowBatteryThreshold = defaults.double(forKey: Key.lowBatteryThreshold.storageKey)
        hideInFullscreen = defaults.bool(forKey: Key.hideInFullscreen.storageKey)
        hideInMissionControl = defaults.bool(forKey: Key.hideInMissionControl.storageKey)
    }

    private func save(_ key: Key, _ value: Any) {
        defaults.set(value, forKey: key.storageKey)
    }
}
