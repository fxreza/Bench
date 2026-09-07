import AppKit
import BenchTestKit
@testable import BenchCore
@testable import Piko

// The pure parts of Piko: notch geometry, the mediaremote-adapter stream
// parser, the shared model helpers, and the settings defaults. Nothing here
// touches a window, an event tap or a subprocess.

// MARK: - Geometry

enum NotchGeometryTests {
    static let tests: [TestCase] = [
        ("derived measurements", {
            let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
            let notch = CGRect(x: 754, y: 1079, width: 220, height: 38)
            let geometry = NotchGeometry(screenFrame: screen, notchRect: notch, hasPhysicalNotch: true)
            try expectEqual(geometry.notchWidth, 220)
            try expectEqual(geometry.notchHeight, 38)
            try expectEqual(geometry.centerX, 864)
        }),
        ("current geometry is centred and flush with the top", {
            let geometry = NotchScreen.currentGeometry()
            try expect(geometry.notchWidth > 0, "notch has a width")
            try expect(geometry.notchHeight > 0, "notch has a height")
            try expectEqual(geometry.centerX, geometry.screenFrame.midX)
            try expectEqual(geometry.notchRect.maxY, geometry.screenFrame.maxY)
        }),
        ("pseudo notch on a screen without one", {
            // 190 x 32 centred at the top, per NotchGeometry.forScreen.
            let geometry = NotchScreen.currentGeometry()
            guard !geometry.hasPhysicalNotch else { return } // real notch here: nothing to assert
            try expectEqual(geometry.notchWidth, 190)
            try expectEqual(geometry.notchHeight, 32)
        }),
        ("window size is the measured Alcove panel", {
            try expectEqual(NotchMetrics.windowSize.width, 624)
            try expectEqual(NotchMetrics.windowSize.height, 320)
        }),
    ]
}

// MARK: - mediaremote-adapter stream parser

enum MediaRemoteStreamParserTests {

    /// A 2x2 PNG, so `NSImage(data:)` actually decodes.
    static let artworkBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEElEQVR4nGP4z8AARAwQCgAf7gP9i18U1AAAAABJRU5ErkJggg=="

    static func line(_ json: String) -> Data { Data(json.utf8) }

    /// A full (non-diff) payload, the shape `mediaremote-adapter.pl stream
    /// --micros` emits for a playing track.
    static let fullPayload = """
        {"diff":false,"payload":{"bundleIdentifier":"com.apple.Music","processIdentifier":501,\
        "title":"Bloom","artist":"Nils","album":"Spaces","playing":true,"playbackRate":1,\
        "durationMicros":240000000,"elapsedTimeMicros":30000000,"timestampEpochMicros":1700000000000000}}
        """

    static let tests: [TestCase] = [
        ("full payload decodes", {
            let parser = MediaRemoteStreamParser()
            guard let result = parser.ingest(line: line(fullPayload)) else {
                throw TestFailure(message: "line was not understood", file: #file, line: #line)
            }
            guard let track = result else {
                throw TestFailure(message: "expected a track", file: #file, line: #line)
            }
            try expectEqual(track.title, "Bloom")
            try expectEqual(track.artist, "Nils")
            try expectEqual(track.album, "Spaces")
            try expectEqual(track.bundleIdentifier, "com.apple.Music")
            try expectEqual(track.processIdentifier, 501)
            try expectEqual(track.isPlaying, true)
            try expectEqual(track.playbackRate, 1)
            try expectEqual(track.duration, 240)
            try expectEqual(track.elapsed, 30)
            try expectEqual(track.elapsedTimestamp, Date(timeIntervalSince1970: 1_700_000_000))
            try expectEqual(track.trackKey, "com.apple.Music|Bloom|Nils|Spaces")
        }),
        ("a line that is not JSON is ignored", {
            let parser = MediaRemoteStreamParser()
            try expect(parser.ingest(line: line("not json at all")) == nil, "garbage returns nil")
            try expect(parser.ingest(line: line("{\"diff\":false}")) == nil, "no payload key returns nil")
        }),
        ("empty payload means nothing is playing", {
            let parser = MediaRemoteStreamParser()
            guard let result = parser.ingest(line: line("{\"diff\":false,\"payload\":{}}")) else {
                throw TestFailure(message: "line was not understood", file: #file, line: #line)
            }
            try expectNil(result)
        }),
        ("a title-less payload is not a track", {
            let parser = MediaRemoteStreamParser()
            let json = "{\"diff\":false,\"payload\":{\"bundleIdentifier\":\"com.apple.Music\",\"title\":\"\"}}"
            guard let result = parser.ingest(line: line(json)) else {
                throw TestFailure(message: "line was not understood", file: #file, line: #line)
            }
            try expectNil(result)
        }),
        ("a diff merges into the snapshot", {
            let parser = MediaRemoteStreamParser()
            _ = parser.ingest(line: line(fullPayload))
            let diff = "{\"diff\":true,\"payload\":{\"elapsedTimeMicros\":90000000}}"
            guard let result = parser.ingest(line: line(diff)), let track = result else {
                throw TestFailure(message: "expected a track", file: #file, line: #line)
            }
            try expectEqual(track.elapsed, 90)
            try expectEqual(track.title, "Bloom", "untouched keys survive the diff")
        }),
        ("null in a diff removes the key", {
            let parser = MediaRemoteStreamParser()
            _ = parser.ingest(line: line(fullPayload))
            let diff = "{\"diff\":true,\"payload\":{\"album\":null,\"durationMicros\":null}}"
            guard let result = parser.ingest(line: line(diff)), let track = result else {
                throw TestFailure(message: "expected a track", file: #file, line: #line)
            }
            try expectEqual(track.album, "")
            try expectNil(track.duration)
        }),
        ("paused tracks never claim to advance", {
            let parser = MediaRemoteStreamParser()
            _ = parser.ingest(line: line(fullPayload))
            let diff = "{\"diff\":true,\"payload\":{\"playing\":false}}"
            guard let result = parser.ingest(line: line(diff)), let track = result else {
                throw TestFailure(message: "expected a track", file: #file, line: #line)
            }
            try expectEqual(track.isPlaying, false)
            try expectEqual(track.playbackRate, 0)
        }),
        ("a playing track with no rate advances at 1x", {
            let parser = MediaRemoteStreamParser()
            let json = """
                {"diff":false,"payload":{"bundleIdentifier":"com.spotify.client","title":"Air",\
                "playing":true,"playbackRate":0}}
                """
            guard let result = parser.ingest(line: line(json)), let track = result else {
                throw TestFailure(message: "expected a track", file: #file, line: #line)
            }
            try expectEqual(track.playbackRate, 1)
        }),
        ("a zero duration is treated as unknown", {
            let parser = MediaRemoteStreamParser()
            let json = """
                {"diff":false,"payload":{"bundleIdentifier":"com.google.Chrome","title":"Live",\
                "playing":true,"durationMicros":0}}
                """
            guard let result = parser.ingest(line: line(json)), let track = result else {
                throw TestFailure(message: "expected a track", file: #file, line: #line)
            }
            try expectNil(track.duration)
        }),
        ("the parent bundle id wins over a per-profile helper", {
            let parser = MediaRemoteStreamParser()
            let json = """
                {"diff":false,"payload":{"bundleIdentifier":"com.google.Chrome.sam",\
                "parentApplicationBundleIdentifier":"com.google.Chrome","title":"Talk","playing":true}}
                """
            guard let result = parser.ingest(line: line(json)), let track = result else {
                throw TestFailure(message: "expected a track", file: #file, line: #line)
            }
            try expectEqual(track.bundleIdentifier, "com.google.Chrome")
        }),
        ("seconds keys are used when the micros keys are absent", {
            let parser = MediaRemoteStreamParser()
            let json = """
                {"diff":false,"payload":{"bundleIdentifier":"com.apple.Music","title":"Bloom",\
                "playing":true,"duration":181.5,"elapsedTime":12.25,\
                "timestamp":"2026-01-02T03:04:05Z"}}
                """
            guard let result = parser.ingest(line: line(json)), let track = result else {
                throw TestFailure(message: "expected a track", file: #file, line: #line)
            }
            try expectEqual(track.duration, 181.5)
            try expectEqual(track.elapsed, 12.25)
            let expected = ISO8601DateFormatter().date(from: "2026-01-02T03:04:05Z")
            try expectEqual(track.elapsedTimestamp, expected)
        }),
        ("artwork decodes once and survives a payload that omits it", {
            let parser = MediaRemoteStreamParser()
            let withArtwork = """
                {"diff":false,"payload":{"bundleIdentifier":"com.apple.Music","title":"Bloom",\
                "artist":"Nils","album":"Spaces","playing":true,"artworkData":"\(artworkBase64)"}}
                """
            guard let first = parser.ingest(line: line(withArtwork)), let track = first else {
                throw TestFailure(message: "expected a track", file: #file, line: #line)
            }
            try expectNotNil(track.artwork)

            // The adapter is not required to repeat artworkData on every update.
            let diff = "{\"diff\":true,\"payload\":{\"elapsedTimeMicros\":5000000}}"
            guard let second = parser.ingest(line: line(diff)), let updated = second else {
                throw TestFailure(message: "expected a track", file: #file, line: #line)
            }
            try expectNotNil(updated.artwork)
        }),
        ("reset forgets the snapshot", {
            let parser = MediaRemoteStreamParser()
            _ = parser.ingest(line: line(fullPayload))
            parser.reset()
            let diff = "{\"diff\":true,\"payload\":{\"elapsedTimeMicros\":5000000}}"
            guard let result = parser.ingest(line: line(diff)) else {
                throw TestFailure(message: "line was not understood", file: #file, line: #line)
            }
            try expectNil(result, "no title in the snapshot any more")
        }),
    ]
}

// MARK: - Models

enum ModelsTests {
    static let tests: [TestCase] = [
        ("HUD percent rounds", {
            try expectEqual(HUDPayload(kind: .volume, level: 0.0).percent, 0)
            try expectEqual(HUDPayload(kind: .volume, level: 0.435).percent, 44)
            try expectEqual(HUDPayload(kind: .brightness, level: 1.0).percent, 100)
        }),
        ("volume symbol follows the level", {
            try expectEqual(HUDPayload(kind: .volume, level: 0).symbolName, "speaker.slash.fill")
            try expectEqual(HUDPayload(kind: .volume, level: 0.8, isMuted: true).symbolName, "speaker.slash.fill")
            try expectEqual(HUDPayload(kind: .volume, level: 0.2).symbolName, "speaker.wave.1.fill")
            try expectEqual(HUDPayload(kind: .volume, level: 0.5).symbolName, "speaker.wave.2.fill")
            try expectEqual(HUDPayload(kind: .volume, level: 0.9).symbolName, "speaker.wave.3.fill")
        }),
        ("brightness symbol and labels", {
            try expectEqual(HUDPayload(kind: .brightness, level: 0.2).symbolName, "sun.min.fill")
            try expectEqual(HUDPayload(kind: .brightness, level: 0.7).symbolName, "sun.max.fill")
            try expectEqual(HUDKind.volume.label, "Volume")
            try expectEqual(HUDKind.brightness.label, "Display")
        }),
        ("now playing interpolates while playing", {
            let start = Date()
            let info = makeInfo(elapsed: 10, timestamp: start, isPlaying: true, rate: 1, duration: 100)
            try expectEqual(info.position(at: start.addingTimeInterval(5)), 15)
            // Never past the end.
            try expectEqual(info.position(at: start.addingTimeInterval(500)), 100)
        }),
        ("a paused track does not move", {
            let start = Date()
            let info = makeInfo(elapsed: 10, timestamp: start, isPlaying: false, rate: 0, duration: 100)
            try expectEqual(info.position(at: start.addingTimeInterval(60)), 10)
        }),
        ("a track without a duration is unbounded", {
            let start = Date()
            let info = makeInfo(elapsed: 0, timestamp: start, isPlaying: true, rate: 1, duration: nil)
            try expectEqual(info.position(at: start.addingTimeInterval(3600)), 3600)
        }),
        ("track key identifies a track", {
            let a = makeInfo(elapsed: 0, timestamp: Date(), isPlaying: true, rate: 1, duration: nil)
            var b = a
            b.elapsed = 99
            try expectEqual(a.trackKey, b.trackKey, "position is not part of the identity")
            b.title = "Other"
            try expect(a.trackKey != b.trackKey, "the title is")
        }),
        ("equality ignores artwork contents but not its presence", {
            let a = makeInfo(elapsed: 0, timestamp: Date(), isPlaying: true, rate: 1, duration: nil)
            var b = a
            try expectEqual(a, b)
            b.artwork = NSImage(size: NSSize(width: 1, height: 1))
            try expect(a != b, "gaining artwork is a change")
        }),
        ("device battery falls back to the lower earbud", {
            var event = DeviceEvent(name: "AirPods Pro", kind: .airpodsPro, isConnected: true)
            try expectNil(event.displayBattery)
            event.batteryLeft = 0.8
            event.batteryRight = 0.55
            try expectEqual(event.displayBattery, 0.55)
            event.battery = 0.9
            try expectEqual(event.displayBattery, 0.9, "an explicit figure wins")
        }),
        ("device symbols", {
            try expectEqual(DeviceKind.airpodsPro.symbolName, "airpodspro")
            try expectEqual(DeviceKind.other.symbolName, "wave.3.right.circle.fill")
        }),
        ("battery percent rounds", {
            try expectEqual(BatteryStatus(level: 0.196, isCharging: false, isPluggedIn: false).percent, 20)
            try expectEqual(BatteryStatus(level: 1, isCharging: true, isPluggedIn: true).percent, 100)
        }),
        ("notch state content keys", {
            try expectEqual(NotchState.idle.contentKey, "idle")
            try expectEqual(NotchState.nowPlaying.contentKey, "nowPlaying")
            try expectEqual(NotchState.expanded.contentKey, "expanded")
            let volume = NotchState.transient(.hud(HUDPayload(kind: .volume, level: 0.3)))
            let louder = NotchState.transient(.hud(HUDPayload(kind: .volume, level: 0.4)))
            try expectEqual(volume.contentKey, "hud.volume")
            try expectEqual(volume.contentKey, louder.contentKey, "a value change does not re-fade")
            try expect(volume.isTransient, "a HUD is transient")
            try expect(!NotchState.idle.isTransient, "idle is not")
            try expectNotNil(volume.activity)
        }),
    ]

    private static func makeInfo(
        elapsed: TimeInterval, timestamp: Date, isPlaying: Bool, rate: Double, duration: TimeInterval?
    ) -> NowPlayingInfo {
        NowPlayingInfo(
            title: "Bloom", artist: "Nils", album: "Spaces", artwork: nil,
            duration: duration, elapsed: elapsed, elapsedTimestamp: timestamp,
            isPlaying: isPlaying, playbackRate: rate,
            bundleIdentifier: "com.apple.Music", appName: "Music")
    }
}

// MARK: - Settings

enum SettingsTests {
    /// A private suite, so a test never reads or writes the user's real
    /// preferences (nor Bench's, nor the standalone Piko's).
    @MainActor
    static func makeSettings() -> (Settings, UserDefaults, String) {
        let name = "com.fxreza.bench.piko.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (Settings(defaults: defaults), defaults, name)
    }

    static let tests: [TestCase] = [
        ("every key carries the piko prefix", {
            for key in Settings.Key.allCases {
                try expectEqual(key.storageKey, "piko.\(key.rawValue)")
            }
            try expectEqual(Settings.Key.allCases.count, 10)
            try expectEqual(Settings.defaultValues.count, Settings.Key.allCases.count)
        }),
        ("factory defaults", {
            let (settings, _, name) = makeSettings()
            defer { UserDefaults.standard.removePersistentDomain(forName: name) }
            try expect(settings.volumeHUDEnabled, "volume HUD on")
            try expect(settings.brightnessHUDEnabled, "brightness HUD on")
            try expect(settings.nowPlayingEnabled, "now playing on")
            try expect(settings.connectivityEnabled, "devices on")
            try expect(settings.lowBatteryEnabled, "low battery on")
            try expect(settings.hideInFullscreen, "hidden in fullscreen")
            try expect(settings.hideInMissionControl, "hidden in Mission Control")
            try expectEqual(settings.hudDuration, 1.5)
            try expectEqual(settings.alertDuration, 3.0)
            try expectEqual(settings.lowBatteryThreshold, 0.2)
        }),
        ("changes are written under the prefixed key", {
            let (settings, defaults, name) = makeSettings()
            defer { UserDefaults.standard.removePersistentDomain(forName: name) }
            settings.volumeHUDEnabled = false
            settings.hudDuration = 2.5
            settings.lowBatteryThreshold = 0.35
            try expectEqual(defaults.bool(forKey: "piko.volumeHUDEnabled"), false)
            try expectEqual(defaults.double(forKey: "piko.hudDuration"), 2.5)
            try expectEqual(defaults.double(forKey: "piko.lowBatteryThreshold"), 0.35)
            try expectNil(defaults.object(forKey: "volumeHUDEnabled"), "no bare keys are written")
        }),
        ("stored values are read back", {
            let name = "com.fxreza.bench.piko.tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defer { UserDefaults.standard.removePersistentDomain(forName: name) }
            defaults.set(false, forKey: "piko.nowPlayingEnabled")
            defaults.set(4.0, forKey: "piko.hudDuration")
            let settings = Settings(defaults: defaults)
            try expect(!settings.nowPlayingEnabled, "stored off")
            try expectEqual(settings.hudDuration, 4.0)
        }),
        ("slider ranges contain their defaults", {
            try expect(Settings.hudDurationRange.contains(1.5), "hud duration default in range")
            try expect(Settings.alertDurationRange.contains(3.0), "alert duration default in range")
            try expect(Settings.lowBatteryRange.contains(0.2), "low battery default in range")
        }),
    ]
}

// MARK: - Bundled resources

enum BundledResourceTests {
    static let tests: [TestCase] = [
        ("the mediaremote adapter is inside the module bundle", {
            guard let paths = MediaRemoteAdapter.paths else {
                throw TestFailure(
                    message: "mediaremote-adapter not found in Bundle.module", file: #file, line: #line)
            }
            try expectEqual(paths.script.lastPathComponent, "mediaremote-adapter.pl")
            try expectEqual(paths.framework.lastPathComponent, "MediaRemoteAdapter.framework")
            try expectEqual(paths.script.deletingLastPathComponent().lastPathComponent, "MediaRemoteAdapter")
            try expect(
                FileManager.default.isExecutableFile(atPath: paths.script.path),
                "the perl script keeps its executable bit")
            // The script dlopens <framework>/MediaRemoteAdapter, which is the
            // top-level symlink into Versions/Current.
            let binary = paths.framework.appendingPathComponent("MediaRemoteAdapter")
            try expect(FileManager.default.isReadableFile(atPath: binary.path), "framework binary resolves")
            let versioned = paths.framework
                .appendingPathComponent("Versions/A/MediaRemoteAdapter")
            try expect(
                FileManager.default.isReadableFile(atPath: versioned.path),
                "the framework kept its Versions layout")
        }),
    ]
}

// MARK: - Feature contract

enum FeatureTests {
    static let tests: [TestCase] = [
        ("identity", {
            let feature = PikoFeature()
            try expectEqual(feature.id, "piko")
            try expectEqual(feature.title, "Piko")
            try expectEqual(feature.requiredPermissions, [BenchPermission.accessibility])
            try expect(feature.hotkeyActions.isEmpty, "Piko has no rebindable shortcuts")
        }),
        ("menu reflects the switches", {
            // Read-only: `menuItems()` reads the live `Settings.shared`, and a
            // test must not write to the preferences of the machine it runs on.
            //
            // Constructing `Settings.shared` still runs the one-time import
            // from the standalone Piko into this *runner's* own preferences
            // domain (never into `com.fxreza.piko`, which is only read), so
            // the domain is removed again at the end of this test.
            let feature = PikoFeature()
            let settings = Settings.shared
            defer {
                UserDefaults.standard.removePersistentDomain(
                    forName: ProcessInfo.processInfo.processName)
            }
            let items = feature.menuItems()

            try expectEqual(items.count, 6)
            try expectEqual(items.map(\.title), [
                "HUDs", "Now Playing", "Devices", "Battery", "", "Piko Settings…",
            ])
            try expect(items[4].isSeparatorItem, "a separator before Settings")
            for item in items where !item.isSeparatorItem {
                try expectNotNil(item.target, "\(item.title) needs a target to fire")
                try expectNotNil(item.action, "\(item.title) needs an action")
            }

            let expectedHUD: NSControl.StateValue
            switch (settings.volumeHUDEnabled, settings.brightnessHUDEnabled) {
            case (true, true): expectedHUD = .on
            case (false, false): expectedHUD = .off
            default: expectedHUD = .mixed
            }
            try expectEqual(items[0].state, expectedHUD)
            try expectEqual(items[1].state, settings.nowPlayingEnabled ? .on : .off)
            try expectEqual(items[2].state, settings.connectivityEnabled ? .on : .off)
            try expectEqual(items[3].state, settings.lowBatteryEnabled ? .on : .off)
            try expectEqual(items[5].state, NSControl.StateValue.off, "Settings is not a checkmark")
        }),
    ]
}
