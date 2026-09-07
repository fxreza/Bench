import AppKit

/// One decoded now-playing state, straight from the adapter payload. The
/// service turns this into a `NowPlayingInfo` (it adds the app name, which
/// needs NSWorkspace on the main thread).
struct MediaRemoteTrack {
    var bundleIdentifier: String
    var processIdentifier: pid_t?
    var title: String
    var artist: String
    var album: String
    var artwork: NSImage?
    var duration: TimeInterval?
    var elapsed: TimeInterval
    var elapsedTimestamp: Date
    var isPlaying: Bool
    var playbackRate: Double

    var trackKey: String { "\(bundleIdentifier)|\(title)|\(artist)|\(album)" }
}

/// Merges the adapter's `stream` output into a full snapshot and decodes it.
///
/// The stream is diffed by default: `diff == true` payloads carry only the
/// keys that changed, and a key that vanished arrives as `null`. A
/// `diff == false` payload replaces the snapshot wholesale; an empty one means
/// no player is reporting anything.
///
/// Not thread safe: the service confines it to the stream reader queue so JSON
/// parsing and artwork decoding stay off the main thread.
final class MediaRemoteStreamParser {
    private var snapshot: [String: Any] = [:]

    /// Decoded artwork per track key, so a burst of updates for the same track
    /// costs one base64 decode. Also survives the adapter dropping artwork
    /// from a payload (the README warns it is not reliably present).
    private var artworkCache: [String: NSImage] = [:]
    private var artworkOrder: [String] = []
    private static let artworkCacheLimit = 8

    /// Base64 string of the artwork currently in the snapshot, to skip
    /// re-decoding the same image.
    private var lastArtworkBase64: String?
    private var lastArtworkImage: NSImage?

    func reset() {
        snapshot = [:]
        lastArtworkBase64 = nil
        lastArtworkImage = nil
    }

    /// Feeds one JSON line. Returns `.some(track)` or `.some(nil)` when the
    /// state changed, and `nil` when the line carried nothing usable.
    func ingest(line: Data) -> MediaRemoteTrack?? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return nil
        }
        guard let payload = object["payload"] as? [String: Any] else { return nil }
        let isDiff = object["diff"] as? Bool ?? false

        if isDiff {
            for (key, value) in payload {
                if value is NSNull {
                    snapshot.removeValue(forKey: key)
                } else {
                    snapshot[key] = value
                }
            }
        } else {
            snapshot = payload
        }
        return .some(track(from: snapshot))
    }

    // MARK: - Decoding

    private func track(from payload: [String: Any]) -> MediaRemoteTrack? {
        // Mandatory keys, per the adapter README. Anything else means no
        // player is reporting usable media.
        guard let title = payload["title"] as? String, !title.isEmpty,
            let rawBundleID = payload["bundleIdentifier"] as? String, !rawBundleID.isEmpty
        else { return nil }

        let isPlaying = payload["playing"] as? Bool ?? false
        // Browsers report a per-profile helper id (com.google.Chrome.sam);
        // the parent id is the real app when the adapter can determine it.
        let bundleID = (payload["parentApplicationBundleIdentifier"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? rawBundleID

        // A diff can flip `playing` one payload before `playbackRate`, so
        // keep the two consistent rather than publishing a paused track that
        // still claims to advance.
        var rate = number(payload["playbackRate"]) ?? (isPlaying ? 1 : 0)
        if isPlaying, rate <= 0 { rate = 1 }
        if !isPlaying { rate = 0 }

        var duration = micros(payload["durationMicros"]) ?? number(payload["duration"])
        if let value = duration, value <= 0 { duration = nil }
        let elapsed = micros(payload["elapsedTimeMicros"]) ?? number(payload["elapsedTime"]) ?? 0

        var timestamp = Date()
        if let epochMicros = number(payload["timestampEpochMicros"]) {
            timestamp = Date(timeIntervalSince1970: epochMicros / 1_000_000)
        } else if let iso = payload["timestamp"] as? String,
            let parsed = Self.isoFormatter.date(from: iso) {
            timestamp = parsed
        }

        let artist = (payload["artist"] as? String) ?? ""
        let album = (payload["album"] as? String) ?? ""
        let key = "\(bundleID)|\(title)|\(artist)|\(album)"

        return MediaRemoteTrack(
            bundleIdentifier: bundleID,
            processIdentifier: (number(payload["processIdentifier"])).map { pid_t($0) },
            title: title,
            artist: artist,
            album: album,
            artwork: artwork(from: payload, trackKey: key),
            duration: duration,
            elapsed: max(0, elapsed),
            elapsedTimestamp: timestamp,
            isPlaying: isPlaying,
            playbackRate: rate)
    }

    private func artwork(from payload: [String: Any], trackKey: String) -> NSImage? {
        guard let base64 = payload["artworkData"] as? String, !base64.isEmpty else {
            return artworkCache[trackKey]
        }
        if base64 == lastArtworkBase64, let image = lastArtworkImage {
            cacheArtwork(image, for: trackKey)
            return image
        }
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
            let image = NSImage(data: data)
        else {
            return artworkCache[trackKey]
        }
        lastArtworkBase64 = base64
        lastArtworkImage = image
        cacheArtwork(image, for: trackKey)
        return image
    }

    private func cacheArtwork(_ image: NSImage, for key: String) {
        if artworkCache[key] == nil {
            artworkOrder.append(key)
            if artworkOrder.count > Self.artworkCacheLimit {
                let evicted = artworkOrder.removeFirst()
                artworkCache.removeValue(forKey: evicted)
            }
        }
        artworkCache[key] = image
    }

    private func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private func micros(_ value: Any?) -> Double? {
        number(value).map { $0 / 1_000_000 }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
