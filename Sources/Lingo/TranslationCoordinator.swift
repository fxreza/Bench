import Foundation
import BenchCore

/// Fans one lookup out to every requested engine concurrently and streams the
/// results back as they land, so a slow engine never delays a fast one's card.
/// Owns the cross-engine result cache and the connection warm-up that used to
/// live in the single-engine `TranslationService`.
actor TranslationCoordinator {
    static let shared = TranslationCoordinator()

    /// One engine finishing (or failing). `isPrimary` marks the engine that
    /// currently wins the failover chain: the first engine in the caller's
    /// order with a success so far. A higher-priority engine finishing later
    /// re-wins with its own `isPrimary` update; the consumer just keeps the
    /// most recent `isPrimary == true` engine as its primary.
    struct Update: Sendable {
        let engine: EngineID
        let outcome: Result<EngineResult, TranslationError>
        let isPrimary: Bool
    }

    /// The engines that exist. Bing/Gemini join this table as they are
    /// implemented; the settings UI derives its rows from `EngineID`, so an
    /// enabled-but-unregistered engine is simply skipped here.
    private let engines: [EngineID: any TranslationEngine] = [
        .google: GoogleEngine(),
        .bing: BingEngine(),
        .gemini: GeminiEngine(),
    ]

    private var cache = [String: EngineResult]()
    private var cacheOrder = [String]()
    private let cacheLimit = 300

    private var lastWarmUp: Date?
    private let warmUpInterval: TimeInterval = 60

    // MARK: - Public API

    /// Streams per-engine results for `orderedEngines` (failover order).
    /// Engines that don't exist yet, don't support the language, or aren't
    /// configured are skipped silently EXCEPT an enabled-but-unconfigured
    /// engine (Gemini without a key), which yields `.notConfigured` so the
    /// popup can show its setup card.
    func translateAll(
        _ text: String, to target: String, from source: String,
        orderedEngines: [EngineID]
    ) -> AsyncStream<Update> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                await self.run(
                    text, to: target, from: source,
                    orderedEngines: orderedEngines, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Single-engine call for per-card retry and manual re-runs. Bypasses the
    /// cache on read (a retry should actually retry) but stores its success.
    func translate(
        _ text: String, to target: String, from source: String, using engineID: EngineID
    ) async throws -> EngineResult {
        guard let engine = engines[engineID] else { throw TranslationError.badResponse }
        let result = try await engine.translate(text, to: target, from: source)
        store(result, key: cacheKey(engineID, source, target, text))
        return result
    }

    /// Opens a TLS connection to the primary translate host so the next real
    /// request doesn't pay DNS + TCP + TLS setup. Called at launch and on each
    /// hotkey press, so the handshake overlaps the text-capture phase.
    nonisolated func warmUpInBackground() {
        Task { await warmUp() }
    }

    // MARK: - Fan-out

    private func run(
        _ text: String, to target: String, from source: String,
        orderedEngines: [EngineID],
        continuation: AsyncStream<Update>.Continuation
    ) async {
        // Position in the failover order decides primary; smaller wins.
        let rank = Dictionary(uniqueKeysWithValues: orderedEngines.enumerated().map { ($1, $0) })
        var runnable: [(EngineID, any TranslationEngine)] = []

        for id in orderedEngines {
            guard let engine = engines[id], engine.supports(language: target) else { continue }
            if !engine.isConfigured() {
                continuation.yield(Update(engine: id, outcome: .failure(.notConfigured), isPrimary: false))
                continue
            }
            // Cache hits resolve immediately, before any network fan-out.
            if let cached = cache[cacheKey(id, source, target, text)] {
                continuation.yield(Update(engine: id, outcome: .success(cached), isPrimary: true))
                // A cached result from a lower-priority engine may be
                // out-ranked later; consumers keep the latest primary, and a
                // cached higher-priority engine yields before a lower one
                // because this loop walks in order.
                runnable.removeAll { rank[$0.0] ?? .max > rank[id] ?? .max }
            } else {
                runnable.append((id, engine))
            }
        }

        guard !runnable.isEmpty else { continuation.finish(); return }

        var bestPrimaryRank = Int.max
        await withTaskGroup(of: (EngineID, Result<EngineResult, TranslationError>).self) { group in
            for (id, engine) in runnable {
                group.addTask {
                    do {
                        return (id, .success(try await engine.translate(text, to: target, from: source)))
                    } catch let error as TranslationError {
                        return (id, .failure(error))
                    } catch is CancellationError {
                        return (id, .failure(.network(CancellationError())))
                    } catch {
                        return (id, .failure(.network(error)))
                    }
                }
            }
            for await (id, outcome) in group {
                if Task.isCancelled { break }
                var isPrimary = false
                if case .success(let result) = outcome {
                    store(result, key: cacheKey(id, source, target, text))
                    let r = rank[id] ?? .max
                    if r < bestPrimaryRank {
                        bestPrimaryRank = r
                        isPrimary = true
                    }
                }
                continuation.yield(Update(engine: id, outcome: outcome, isPrimary: isPrimary))
            }
        }
        continuation.finish()
    }

    // MARK: - Warm-up

    private func warmUp() async {
        if let lastWarmUp, Date().timeIntervalSince(lastWarmUp) < warmUpInterval { return }
        lastWarmUp = Date()
        // A minimal real translate call: cheap, and primes the same connection
        // pool entry the next request will reuse. Reads the target straight
        // from UserDefaults (this runs off the main actor, so SettingsStore is
        // out of reach) rather than hardcoding a language.
        let target = BenchDefaults.standard.string(forKey: "lingo.targetLanguage") ?? "en"
        _ = try? await engines[.google]?.translate("a", to: target, from: LanguageCatalog.autoCode)
    }

    // MARK: - Cache

    private func cacheKey(_ engine: EngineID, _ source: String, _ target: String, _ text: String) -> String {
        // Tone is part of the key: a Casual and a Standard answer for the
        // same text are different results, and a tone switch must re-fetch
        // rather than replay the old register from cache. `cacheVariant` does
        // the same job for per-engine settings (Gemini's model and thinking
        // level).
        let variant = engines[engine]?.cacheVariant ?? ""
        return "\(engine.rawValue)|\(TranslationTone.current.rawValue)|\(variant)|\(source)|\(target)|\(text)"
    }

    private func store(_ result: EngineResult, key: String) {
        if cache[key] == nil {
            cacheOrder.append(key)
            if cacheOrder.count > cacheLimit {
                let evicted = cacheOrder.removeFirst()
                cache[evicted] = nil
            }
        }
        cache[key] = result
    }
}
