import AppKit
import Combine

/// Now-playing information for *any* app (Music, Spotify, IINA, YouTube in a
/// browser, ...) plus playback control.
///
/// Reading goes through the bundled mediaremote-adapter: a `/usr/bin/perl`
/// subprocess streaming newline-delimited JSON (see `MediaRemoteAdapter`).
/// Writing goes straight to MediaRemote in-process (see `MediaRemoteBridge`),
/// which is not entitlement-gated and saves a perl spawn per button press.
///
/// Usage from `AppDelegate`:
/// ```swift
/// nowPlaying = NowPlayingService()
/// nowPlaying.onTrackChange = { [weak self] info in self?.notch.showTrackPeek(info) }
/// nowPlaying.$info.sink { [weak self] info in self?.notch.nowPlaying = info }
/// nowPlaying.start()
/// ```
@MainActor
final class NowPlayingService: ObservableObject, MediaController {

    /// Nil when no app is reporting playable media.
    @Published private(set) var info: NowPlayingInfo?

    /// Fires when the track changes, and when playback starts after nothing
    /// was playing at all. Used for the notch "peek".
    var onTrackChange: ((NowPlayingInfo) -> Void)?

    /// Fires when `isPlaying` flips (same track).
    var onPlaybackStateChange: ((NowPlayingInfo) -> Void)?

    /// False when the bundled adapter is missing or has been given up on; the
    /// service then publishes nothing and commands still work in-process.
    private(set) var isStreaming = false

    // MARK: - Internals

    private let parser = MediaRemoteStreamParser()
    private var stream: MediaRemoteStreamProcess?
    private var restartWorkItem: DispatchWorkItem?
    private var consecutiveFailures = 0
    private var startedAt: Date?
    private var receivedAnyPayload = false
    private var stopped = true

    /// Trailing throttle so a burst of adapter updates cannot drive more than
    /// ~10 publishes per second (the adapter is asked to debounce as well).
    private var pendingTrack: MediaRemoteTrack??
    private var throttleWorkItem: DispatchWorkItem?
    private var lastPublish = Date.distantPast
    private static let minPublishInterval: TimeInterval = 0.1

    /// "Nothing is playing" is applied only after this grace period. The
    /// adapter emits an empty payload as the first line of every stream, so a
    /// restart would otherwise blank the notch and re-trigger the track peek.
    private var clearWorkItem: DispatchWorkItem?
    private static let clearGrace: TimeInterval = 0.4

    private var appNames: [String: String] = [:]

    /// `--micros` gives integer microsecond timestamps (the plain `timestamp`
    /// key is ISO 8601 with one-second resolution, too coarse to interpolate).
    private static let streamOptions = ["--micros", "--debounce=100"]

    private static let maxRestartDelay: TimeInterval = 30
    private static let maxConsecutiveFailures = 5

    private var terminateObserver: NSObjectProtocol?

    init() {
        // Make sure the perl subprocess goes away with the app even if nobody
        // calls stop(); it would otherwise linger until its next write fails.
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    deinit {
        if let terminateObserver {
            NotificationCenter.default.removeObserver(terminateObserver)
        }
        // `stream` owns the Process and terminates it in its own deinit.
    }

    // MARK: - Lifecycle

    func start() {
        guard stopped else { return }
        stopped = false
        consecutiveFailures = 0
        launch()
    }

    func stop() {
        stopped = true
        isStreaming = false
        restartWorkItem?.cancel()
        restartWorkItem = nil
        throttleWorkItem?.cancel()
        throttleWorkItem = nil
        clearWorkItem?.cancel()
        clearWorkItem = nil
        pendingTrack = nil
        stream?.stop()
        stream = nil
        parser.reset()
        if info != nil { info = nil }
    }

    private func launch() {
        guard !stopped, stream == nil else { return }
        guard let paths = MediaRemoteAdapter.paths else {
            isStreaming = false
            return
        }

        parser.reset()
        receivedAnyPayload = false
        startedAt = Date()

        let process = MediaRemoteStreamProcess(
            paths: paths,
            options: Self.streamOptions,
            onLine: { [weak self] line in
                // Runs on the stream reader queue: JSON parsing and artwork
                // decoding stay off the main thread.
                guard let self else { return }
                guard let update = self.parser.ingest(line: line) else { return }
                DispatchQueue.main.async { self.enqueue(update) }
            },
            onTerminate: { [weak self] status in
                DispatchQueue.main.async { self?.handleTermination(status: status) }
            })

        do {
            try process.start()
            stream = process
            isStreaming = true
        } catch {
            Log.media.error("failed to start mediaremote-adapter: \(error.localizedDescription, privacy: .public)")
            isStreaming = false
            scheduleRestart()
        }
    }

    private func handleTermination(status: Int32) {
        stream = nil
        isStreaming = false
        guard !stopped else { return }

        let ranFor = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        if receivedAnyPayload || ranFor > 10 {
            consecutiveFailures = 0
        } else {
            consecutiveFailures += 1
        }

        Log.media.error(
            "mediaremote-adapter exited (status \(status), after \(String(format: "%.1f", ranFor))s, failures \(self.consecutiveFailures))"
        )

        // The adapter README warns that repeated immediate non-zero exits mean
        // the adapter is broken (a macOS update closed the hole); stop rather
        // than spawn perl forever.
        guard consecutiveFailures < Self.maxConsecutiveFailures else {
            Log.media.error("mediaremote-adapter looks broken; giving up on now playing")
            stopped = true
            if info != nil { info = nil }
            return
        }
        scheduleRestart()
    }

    private func scheduleRestart() {
        restartWorkItem?.cancel()
        let delay = min(Self.maxRestartDelay, 0.5 * pow(2, Double(consecutiveFailures)))
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.launch() }
        }
        restartWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    // MARK: - Publishing

    private func enqueue(_ update: MediaRemoteTrack?) {
        receivedAnyPayload = true
        pendingTrack = .some(update)

        let elapsed = Date().timeIntervalSince(lastPublish)
        if elapsed >= Self.minPublishInterval {
            flush()
        } else if throttleWorkItem == nil {
            let item = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.throttleWorkItem = nil
                    self?.flush()
                }
            }
            throttleWorkItem = item
            DispatchQueue.main.asyncAfter(
                deadline: .now() + (Self.minPublishInterval - elapsed), execute: item)
        }
    }

    private func flush() {
        guard let pending = pendingTrack else { return }
        pendingTrack = nil
        lastPublish = Date()
        apply(pending)
    }

    private func apply(_ track: MediaRemoteTrack?) {
        let previous = info

        guard let track else {
            scheduleClear()
            return
        }
        clearWorkItem?.cancel()
        clearWorkItem = nil

        var next = NowPlayingInfo(
            title: track.title,
            artist: track.artist,
            album: track.album,
            artwork: track.artwork,
            duration: track.duration,
            elapsed: track.elapsed,
            elapsedTimestamp: track.elapsedTimestamp,
            isPlaying: track.isPlaying,
            playbackRate: track.playbackRate,
            bundleIdentifier: track.bundleIdentifier,
            appName: "")
        next.appName = appName(for: track)

        let trackChanged = previous?.trackKey != next.trackKey
        let startedFromNothing = previous == nil && next.isPlaying
        let stateChanged = previous?.isPlaying != next.isPlaying

        if previous != next || previous?.appName != next.appName {
            info = next
        }

        if trackChanged || startedFromNothing {
            onTrackChange?(next)
        }
        if stateChanged && !trackChanged && previous != nil {
            onPlaybackStateChange?(next)
        }
    }

    private func scheduleClear() {
        guard info != nil, clearWorkItem == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.clearWorkItem = nil
                if self.info != nil { self.info = nil }
            }
        }
        clearWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.clearGrace, execute: item)
    }

    /// Localized name of the source app. The pid the adapter reports is the
    /// most reliable handle (browsers report per-profile bundle ids such as
    /// `com.google.Chrome.sam`); LaunchServices is the fallback.
    private func appName(for track: MediaRemoteTrack) -> String {
        if let cached = appNames[track.bundleIdentifier] { return cached }

        var name: String?
        if let pid = track.processIdentifier,
            let app = NSRunningApplication(processIdentifier: pid) {
            name = app.localizedName
        }
        if name == nil {
            name = NSRunningApplication.runningApplications(
                withBundleIdentifier: track.bundleIdentifier
            ).first?.localizedName
        }
        if name == nil {
            var identifier = track.bundleIdentifier
            while name == nil {
                if let url = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: identifier) {
                    name = FileManager.default.displayName(atPath: url.path)
                        .replacingOccurrences(of: ".app", with: "")
                    break
                }
                // com.google.Chrome.sam -> com.google.Chrome
                guard identifier.contains("."),
                    identifier.components(separatedBy: ".").count > 2
                else { break }
                identifier = identifier.components(separatedBy: ".").dropLast()
                    .joined(separator: ".")
            }
        }

        let resolved = name ?? track.bundleIdentifier
        appNames[track.bundleIdentifier] = resolved
        return resolved
    }

    // MARK: - MediaController

    /// Safe to call from any thread; MediaRemote is talked to in-process.
    nonisolated func send(_ command: MediaCommand) {
        switch command {
        case .play:
            MediaRemoteBridge.send(.play)
        case .pause:
            MediaRemoteBridge.send(.pause)
        case .togglePlayPause:
            MediaRemoteBridge.send(.togglePlayPause)
        case .next:
            MediaRemoteBridge.send(.nextTrack)
        case .previous:
            MediaRemoteBridge.send(.previousTrack)
        case .seek(let position):
            MediaRemoteBridge.setElapsedTime(position)
            // Move the scrubber immediately; the stream confirms in ~100 ms.
            Task { @MainActor [weak self] in self?.applyOptimisticSeek(position) }
        }
    }

    private func applyOptimisticSeek(_ position: TimeInterval) {
        guard var current = info else { return }
        current.elapsed = max(0, position)
        current.elapsedTimestamp = Date()
        info = current
    }
}
