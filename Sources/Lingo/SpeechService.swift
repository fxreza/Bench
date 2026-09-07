import AVFoundation
import Foundation
import NaturalLanguage

/// Text-to-speech.
///
/// The default voice is Google Translate's `translate_tts` endpoint - the same
/// audio the Translate website plays - because the built-in macOS voices read
/// English noticeably worse. It needs no API key, but it is an unofficial
/// endpoint, so every failure path (offline, rate limited, or a language it
/// refuses) falls back to `AVSpeechSynthesizer`. Persian is one of those
/// refusals: `tl=fa` answers HTTP 400, so Persian always uses the macOS voice.
///
/// Asking for the same text again cycles how it is delivered: normal, slow,
/// stop. "Slow" is the slowest Google offers, about a third longer than normal;
/// the macOS fallback approximates the same target with a reduced rate.
@MainActor
final class SpeechService: NSObject {
    static let shared = SpeechService()

    private let synthesizer = AVSpeechSynthesizer()
    private let session: URLSession

    private var player: AVQueuePlayer?
    private var fetchTask: Task<Void, Never>?
    private var scratchFiles = [URL]()
    private var endObserver: NSObjectProtocol?

    /// `translate_tts` answers HTTP 400 above exactly 200 characters, so longer
    /// text is split into chunks and queued back to back.
    private static let chunkLimit = 200

    /// Google's `ttsspeed` is not continuous - it collapses into three buckets.
    /// Measured on a full sentence: no value and anything >= 0.4 give the same
    /// 3.02s, 0.2-0.3 give 3.55s (+17%), and <= 0.15 give 4.03s (+33%). This
    /// picks the slowest bucket, which is as slow as the endpoint goes.
    private static let slowSpeed = "0.1"

    /// The last text asked for and how many times in a row it has been asked
    /// for, which is what turns a repeat press into "slower" instead of "again".
    private var lastText: String?
    private var repeatCount = 0

    private enum SpeechError: Error { case unavailable }

    private override init() {
        let config = URLSessionConfiguration.ephemeral
        // Speech is interactive: better to drop to the macOS voice quickly than
        // to leave the user pressing a key that appears to do nothing.
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = [
            "User-Agent":
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
        ]
        session = URLSession(configuration: config)
        super.init()
    }

    // MARK: - Public API

    /// Speak English text aloud. Repeating the same text cycles normal, slow,
    /// then stop.
    func speakEnglish(_ text: String) {
        speakCycling(text, languageCode: "en-US")
    }

    /// Speak arbitrary text aloud, guessing the language when none is given so
    /// the synthesizer doesn't read, say, Persian with an English voice.
    func speak(_ text: String, languageCode: String? = nil, slow: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stopPlayback()
        lastText = trimmed
        repeatCount = slow ? 1 : 0
        startSpeaking(trimmed, languageCode: languageCode, slow: slow)
    }

    /// Stops any speech and forgets the cycle, so the next request starts again
    /// at normal speed.
    func stop() {
        stopPlayback()
        lastText = nil
        repeatCount = 0
    }

    var isSpeaking: Bool {
        if let player, player.timeControlStatus == .playing { return true }
        return synthesizer.isSpeaking
    }

    // MARK: - Normal / slow / stop cycle

    private func speakCycling(_ text: String, languageCode: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        repeatCount = (trimmed == lastText) ? repeatCount + 1 : 0

        // 0: normal, 1: slow, 2: stop. The stop also clears the cycle, so a
        // fourth press starts over at normal speed.
        guard repeatCount < 2 else {
            stop()
            return
        }

        lastText = trimmed
        stopPlayback()
        startSpeaking(trimmed, languageCode: languageCode, slow: repeatCount == 1)
    }

    // MARK: - Google voice

    private func startSpeaking(_ text: String, languageCode: String?, slow: Bool) {
        let language = Self.googleLanguage(languageCode ?? Self.detectLanguageCode(text))
        let chunks = Self.chunk(text)

        fetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                var files = [URL]()
                for (index, chunk) in chunks.enumerated() {
                    let data = try await self.fetchAudio(
                        chunk, language: language, slow: slow,
                        index: index, total: chunks.count, textLength: text.count)
                    try Task.checkCancellation()
                    files.append(try Self.writeScratchFile(data))
                }
                try Task.checkCancellation()
                self.play(files)
            } catch is CancellationError {
                // Superseded by a newer request; that request owns playback now.
            } catch {
                self.speakWithSystemVoice(text, languageCode: languageCode, slow: slow)
            }
        }
    }

    private func fetchAudio(
        _ text: String, language: String, slow: Bool,
        index: Int, total: Int, textLength: Int
    ) async throws -> Data {
        var components = URLComponents(string: "https://translate.google.com/translate_tts")!
        var items = [
            URLQueryItem(name: "ie", value: "UTF-8"),
            URLQueryItem(name: "client", value: "tw-ob"),
            URLQueryItem(name: "tl", value: language),
            URLQueryItem(name: "q", value: text),
            // The website sends these on split text; they keep the intonation
            // continuous across chunks instead of restarting each one.
            URLQueryItem(name: "total", value: String(total)),
            URLQueryItem(name: "idx", value: String(index)),
            URLQueryItem(name: "textlen", value: String(textLength)),
        ]
        if slow {
            items.append(URLQueryItem(name: "ttsspeed", value: Self.slowSpeed))
        }
        components.queryItems = items

        let (data, response) = try await session.data(from: components.url!)
        guard let http = response as? HTTPURLResponse,
            (200...299).contains(http.statusCode),
            !data.isEmpty
        else {
            // Also the path for languages the endpoint has no voice for.
            throw SpeechError.unavailable
        }
        return data
    }

    // MARK: - Playback

    private func play(_ files: [URL]) {
        guard !files.isEmpty else { return }
        scratchFiles = files

        let items = files.map { AVPlayerItem(url: $0) }
        let queue = AVQueuePlayer(items: items)
        player = queue
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: items.last, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.finishPlayback() }
        }
        queue.play()
    }

    /// Tears down playback but keeps the cycle, so pressing again after the
    /// audio has finished still means "slower" rather than "start over".
    private func finishPlayback() {
        player = nil
        removeEndObserver()
        discardScratchFiles()
    }

    private func stopPlayback() {
        fetchTask?.cancel()
        fetchTask = nil
        player?.pause()
        finishPlayback()
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    private func removeEndObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
    }

    private func discardScratchFiles() {
        for file in scratchFiles {
            try? FileManager.default.removeItem(at: file)
        }
        scratchFiles = []
    }

    private static func writeScratchFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transi-tts-\(UUID().uuidString).mp3")
        try data.write(to: url)
        return url
    }

    // MARK: - macOS fallback voice

    private func speakWithSystemVoice(_ text: String, languageCode: String?, slow: Bool) {
        let utterance = AVSpeechUtterance(string: text)
        let code = languageCode ?? Self.detectLanguageCode(text)
        if let code, let voice = AVSpeechSynthesisVoice(language: code) {
            utterance.voice = voice
        }
        // 1 / 1.33 = 0.75, matching the Google path's slowest bucket.
        utterance.rate =
            slow
            ? AVSpeechUtteranceDefaultSpeechRate * 0.75
            : AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    // MARK: - Helpers

    /// BCP-47 code for the dominant language, or `nil` when the sample is too
    /// short or too mixed to call.
    private static func detectLanguageCode(_ text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }

    /// Google's endpoint wants a bare language code ("en"), not a BCP-47 tag
    /// carrying a region ("en-US").
    private static func googleLanguage(_ code: String?) -> String {
        guard let code, let base = code.split(separator: "-").first else { return "en" }
        return base.lowercased()
    }

    /// Splits text into pieces of at most `chunkLimit` characters, cutting at a
    /// sentence end where there is one and a word boundary otherwise, so the
    /// seams land where a reader would pause anyway.
    private static func chunk(_ text: String) -> [String] {
        guard text.count > chunkLimit else { return [text] }

        var chunks = [String]()
        var remaining = Substring(text)
        while !remaining.isEmpty {
            if remaining.count <= chunkLimit {
                chunks.append(String(remaining))
                break
            }

            let window = remaining.prefix(chunkLimit)
            var cut =
                window.lastIndex(where: { ".!?".contains($0) }).map(window.index(after:))
                ?? window.lastIndex(where: \.isWhitespace)
                ?? window.endIndex
            // A break at the very start would never consume anything.
            if cut == remaining.startIndex { cut = window.endIndex }

            let piece = remaining[..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { chunks.append(piece) }
            remaining = remaining[cut...]
        }
        return chunks
    }
}
