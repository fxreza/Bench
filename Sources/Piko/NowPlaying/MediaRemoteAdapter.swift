import Foundation

// The MediaRemote framework stopped answering "what is playing" for unentitled
// processes in macOS 15.4. The workaround (ungive/mediaremote-adapter, see
// docs/research/tech-reference.md section 4) is to have /usr/bin/perl - a
// platform binary that mediaremoted knows as "com.apple.perl" - dlopen a small
// helper framework and print now-playing JSON on stdout.
//
// Both files ship verbatim inside the module bundle, at
// `Bench_Piko.bundle/Contents/Resources/Resources/MediaRemoteAdapter/`
// (`Package.swift` declares `.copy("Resources")`, so the source folder name
// `Resources` is itself part of the path). They are never linked against: the
// framework is only passed to the script as a path. The module bundle is the
// only source — there is no `/Applications` or `Bundle.main` fallback.

// MARK: - Resource lookup

enum MediaRemoteAdapter {
    static let perlPath = "/usr/bin/perl"

    struct Paths {
        var script: URL
        var framework: URL
    }

    /// Subdirectory inside the module bundle's resources.
    private static let subdirectory = "Resources/MediaRemoteAdapter"

    /// The bundled perl script and helper framework, or nil when either is
    /// missing (now playing is then simply off; playback control still works
    /// through `MediaRemoteBridge`).
    static let paths: Paths? = {
        guard let script = Bundle.module.url(
            forResource: "mediaremote-adapter", withExtension: "pl", subdirectory: subdirectory),
            let framework = Bundle.module.url(
                forResource: "MediaRemoteAdapter", withExtension: "framework", subdirectory: subdirectory)
        else {
            Log.media.error("mediaremote-adapter resources not found in the module bundle; now playing disabled")
            return nil
        }
        // The perl script dlopens <framework>/<name>, so that file has to exist.
        let binary = framework.appendingPathComponent("MediaRemoteAdapter")
        let fm = FileManager.default
        guard fm.isReadableFile(atPath: script.path), fm.isReadableFile(atPath: binary.path) else {
            Log.media.error("mediaremote-adapter resources are not readable; now playing disabled")
            return nil
        }
        return Paths(script: script, framework: framework)
    }()

    /// Arguments common to every invocation: script, framework, then command.
    static func arguments(_ command: [String], paths: Paths) -> [String] {
        [paths.script.path, paths.framework.path] + command
    }
}

// MARK: - Stream process

/// Runs `mediaremote-adapter.pl ... stream` and hands every JSON line to
/// `onLine` on its own reader queue. Restarting is the caller's job
/// (`onTerminate` fires once per process).
final class MediaRemoteStreamProcess {
    private let paths: MediaRemoteAdapter.Paths
    private let options: [String]
    private let onLine: (Data) -> Void
    private let onTerminate: (Int32) -> Void

    private var process: Process?
    private var buffer = Data()
    private let queue = DispatchQueue(label: "com.fxreza.piko.nowplaying.stream")

    /// Guards against unbounded growth if the adapter ever emits a line
    /// without a newline (artwork payloads are a few hundred KB).
    private static let maxLineBytes = 8 * 1024 * 1024

    init(
        paths: MediaRemoteAdapter.Paths,
        options: [String],
        onLine: @escaping (Data) -> Void,
        onTerminate: @escaping (Int32) -> Void
    ) {
        self.paths = paths
        self.options = options
        self.onLine = onLine
        self.onTerminate = onTerminate
    }

    var isRunning: Bool { process?.isRunning ?? false }

    func start() throws {
        guard process == nil else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: MediaRemoteAdapter.perlPath)
        process.arguments = MediaRemoteAdapter.arguments(["stream"] + options, paths: paths)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async { self?.consume(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            if let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                Log.media.error("mediaremote-adapter: \(text, privacy: .public)")
            }
        }

        process.terminationHandler = { [weak self] proc in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            let status = proc.terminationStatus
            self?.onTerminate(status)
        }

        try process.run()
        self.process = process
        Log.media.info("mediaremote-adapter stream started (pid \(process.processIdentifier))")
    }

    func stop() {
        guard let process else { return }
        self.process = nil
        process.terminationHandler = nil
        if process.isRunning { process.terminate() }
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        queue.async { [weak self] in self?.buffer.removeAll(keepingCapacity: false) }
    }

    /// Called on `queue`. Splits the byte stream into newline-delimited lines.
    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { onLine(Data(line)) }
        }
        if buffer.count > Self.maxLineBytes {
            Log.media.error("mediaremote-adapter line too long, dropping buffer")
            buffer.removeAll(keepingCapacity: false)
        }
    }

    deinit { stop() }
}

// MARK: - One-shot commands through the script

extension MediaRemoteAdapter {
    /// Fallback path for playback control when the in-process MediaRemote
    /// symbols are unavailable. Costs a perl spawn (~40-80 ms), so it is only
    /// used when `MediaRemoteBridge` cannot resolve its functions.
    static func runDetached(_ command: [String]) {
        guard let paths else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: perlPath)
        process.arguments = arguments(command, paths: paths)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            Log.media.error("mediaremote-adapter \(command.joined(separator: " "), privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
