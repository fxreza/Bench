import AppKit

// Shared types used across modules. This file is the contract between the
// Notch UI, the HUD services, the now-playing service, the device monitors
// and the menu bar. Keep it dependency-free (AppKit only).

// MARK: - HUD (volume / brightness)

enum HUDKind: String, Codable {
    case volume
    case brightness

    /// Label shown in the leading wing of the HUD.
    var label: String {
        switch self {
        case .volume: return "Volume"
        case .brightness: return "Display"
        }
    }
}

struct HUDPayload: Equatable {
    var kind: HUDKind
    /// 0...1
    var level: Double
    var isMuted: Bool = false

    var percent: Int { Int((level * 100).rounded()) }

    var symbolName: String {
        switch kind {
        case .volume:
            if isMuted || level <= 0 { return "speaker.slash.fill" }
            if level < 0.34 { return "speaker.wave.1.fill" }
            if level < 0.67 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        case .brightness:
            return level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        }
    }
}

// MARK: - Now playing

struct NowPlayingInfo: Equatable {
    var title: String
    var artist: String
    var album: String
    var artwork: NSImage?
    /// Seconds. Nil when the source reports no duration (live streams).
    var duration: TimeInterval?
    /// Elapsed seconds at `elapsedTimestamp`. Interpolate with
    /// `elapsed + (now - elapsedTimestamp) * playbackRate` while playing.
    var elapsed: TimeInterval
    var elapsedTimestamp: Date
    var isPlaying: Bool
    var playbackRate: Double
    /// Bundle id of the source app (e.g. com.google.Chrome, com.colliderli.iina).
    var bundleIdentifier: String
    var appName: String

    /// Current interpolated position.
    func position(at now: Date = Date()) -> TimeInterval {
        guard isPlaying else { return elapsed }
        let p = elapsed + now.timeIntervalSince(elapsedTimestamp) * playbackRate
        if let duration { return min(max(0, p), duration) }
        return max(0, p)
    }

    /// Identity of the track, used to detect track changes.
    var trackKey: String { "\(bundleIdentifier)|\(title)|\(artist)|\(album)" }

    static func == (a: NowPlayingInfo, b: NowPlayingInfo) -> Bool {
        a.title == b.title && a.artist == b.artist && a.album == b.album
            && a.duration == b.duration && a.elapsed == b.elapsed
            && a.elapsedTimestamp == b.elapsedTimestamp && a.isPlaying == b.isPlaying
            && a.playbackRate == b.playbackRate && a.bundleIdentifier == b.bundleIdentifier
            && (a.artwork == nil) == (b.artwork == nil)
    }
}

enum MediaCommand {
    case play, pause, togglePlayPause, next, previous
    case seek(TimeInterval)
}

/// Implemented by the now-playing service; consumed by the player views.
protocol MediaController: AnyObject {
    func send(_ command: MediaCommand)
}

// MARK: - Devices (Bluetooth / audio)

enum DeviceKind: String {
    case airpods, airpodsPro, airpodsMax, beats, headphones, earbuds
    case keyboard, mouse, trackpad, gamepad, speaker, watch, phone, other

    /// SF Symbol used when no better artwork is available.
    var symbolName: String {
        switch self {
        case .airpods: return "airpods"
        case .airpodsPro: return "airpodspro"
        case .airpodsMax: return "airpodsmax"
        case .beats: return "beats.headphones"
        case .headphones: return "headphones"
        case .earbuds: return "earbuds"
        case .keyboard: return "keyboard.fill"
        case .mouse: return "computermouse.fill"
        case .trackpad: return "rectangle.and.hand.point.up.left.fill"
        case .gamepad: return "gamecontroller.fill"
        case .speaker: return "hifispeaker.fill"
        case .watch: return "applewatch"
        case .phone: return "iphone"
        case .other: return "wave.3.right.circle.fill"
        }
    }
}

struct DeviceEvent: Equatable {
    var name: String
    var kind: DeviceKind
    var isConnected: Bool
    /// 0...1 when known. AirPods report left/right/case separately.
    var battery: Double?
    var batteryLeft: Double?
    var batteryRight: Double?
    var batteryCase: Double?

    /// Best single battery figure for compact display.
    var displayBattery: Double? {
        if let battery { return battery }
        let parts = [batteryLeft, batteryRight].compactMap { $0 }
        return parts.min()
    }
}

// MARK: - Battery

struct BatteryStatus: Equatable {
    /// 0...1
    var level: Double
    var isCharging: Bool
    var isPluggedIn: Bool
    var percent: Int { Int((level * 100).rounded()) }
}

// MARK: - Notch activities

/// What the notch is currently showing. The Notch module owns the priority
/// and timing rules; other modules only ask for an activity to be shown.
enum NotchActivity: Equatable {
    case hud(HUDPayload)
    case device(DeviceEvent)
    case lowBattery(BatteryStatus)
    /// Brief "peek" when a track starts or changes: artwork + title.
    case trackPeek(NowPlayingInfo)
}

// MARK: - Geometry constants (from docs/research/alcove-measurements.md)

enum NotchMetrics {
    /// Extra width added to each side of the physical notch, per state.
    static let hoverExtraWidthPerSide: CGFloat = 8.5     // 220 -> 237 body
    static let hoverExtraHeight: CGFloat = 6             // 38 -> 44
    static let hudWingWidth: CGFloat = 92                // 220 -> 404
    static let nowPlayingWingWidth: CGFloat = 37         // 220 -> 294
    static let expandedWidth: CGFloat = 380
    static let expandedHeight: CGFloat = 178

    static let idleTopRadius: CGFloat = 3.5
    static let idleBottomRadius: CGFloat = 11
    static let hoverTopRadius: CGFloat = 4
    static let hoverBottomRadius: CGFloat = 11
    static let compactTopRadius: CGFloat = 6
    static let compactBottomRadius: CGFloat = 12.5
    static let expandedTopRadius: CGFloat = 18
    static let expandedBottomRadius: CGFloat = 40

    /// The window is always this size, centered on the notch, at the top of
    /// the screen; all states are drawn inside it (matches Alcove: 624 x 320).
    static let windowSize = CGSize(width: 624, height: 320)
}

enum NotchAnimation {
    /// Idle -> HUD / compact / expanded (measured: 85% at 0.17 s, settles ~0.45 s, no overshoot).
    static let expand = "spring(response: 0.38, dampingFraction: 0.85)"
    /// Collapse back (measured ~0.3 s, no bounce).
    static let collapse = "spring(response: 0.30, dampingFraction: 1.0)"
}
