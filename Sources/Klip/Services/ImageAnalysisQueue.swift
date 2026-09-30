import Foundation
import Combine
import CoreGraphics

/// Reads image clips in the background, one at a time, so they can be found
/// by the text in them and by what they show (`ImageAnalysisService`), and,
/// when smart search has a model, by what they *mean* (`ImageEmbedding`,
/// the MobileCLIP index).
///
/// Two sources of work, one serial lane:
/// - **Urgent**: an image that was just captured (`ClipboardStore.add` calls
///   `onImageNeedsAnalysis` *after* the clip is in the list and its save is
///   scheduled) or one the UI asked for (`requestImageAnalysis`). Taken
///   before any backfill work and applied as soon as it finishes.
/// - **Backfill**: every image clip still missing `ocrText` or
///   `imageLabels`, or whose embedding is missing or was computed from
///   different bytes, walked newest first, starting `Timing.backfillDelay`
///   after launch so it never competes with startup. Analysis results are
///   buffered and applied in batches (`flushBatchSize` / `flushInterval`)
///   through `ClipboardStore.applyImageAnalyses`, so a history with hundreds
///   of screenshots costs a handful of list refreshes and history writes,
///   not one per image; embeddings go to the index, which coalesces its own
///   writes. A short `backfillPause` between images, and waiting while the
///   Mac is hot or in Low Power Mode, keep a long backfill from being
///   noticed.
///
/// One job does both halves for an image from a **single decode**: the
/// bitmap Vision reads is also what the image encoder gets (it center-crops
/// and resamples to 256x256 itself). An image that only lacks its embedding
/// (the usual case the first time smart search runs on an existing
/// history) is decoded small instead (`MobileCLIPEncoder.decodeShortSide`).
///
/// **Embeddings follow the history.** After the launch backfill, a change to
/// the history or the trash (debounced `reconcileDelay`) drops the
/// embeddings of clips that are gone and queues image clips that have none:
/// ones pulled from another Mac by sync (which arrive already analyzed, so
/// the capture hook never sees them) or restored from the trash after a
/// purge.
///
/// Vision and the encoder run on `workQueue` at `.utility` QoS, as do the
/// index checks (a `stat` per image); everything else here is main-thread
/// bookkeeping and cheap. Nothing on the capture, paste or panel path ever
/// waits for it.
///
/// Robustness:
/// - A clip deleted or evicted while it waited is skipped when its turn
///   comes, and a result for a clip that vanished mid-analysis is dropped
///   by `applyImageAnalyses` (and not stored in the index).
/// - A missing or undecodable file is recorded as analyzed-and-empty, so it
///   is not retried on every launch (sync still upgrades it from a Mac that
///   has the bytes, see `SyncMerge.analysisRank`); an undecodable one gets
///   an empty embedding for the same reason, until its bytes change.
/// - A Vision or encoder failure is *not* recorded - it may be transient -
///   but the clip is not retried again this session either, so a persistent
///   failure can never spin.
/// - `stop()` (Klip switched off, or quitting) applies whatever is buffered
///   before `KlipFeature` flushes the store, writes the index, and drops the
///   result of the image still in flight rather than waiting for it; that
///   one is simply read again next launch.
final class ImageAnalysisQueue {
    typealias Analyzer = @Sendable (URL) -> ImageAnalysisService.Outcome

    struct Timing {
        /// Wait after `start()` before walking the history.
        var backfillDelay: TimeInterval = 20
        /// Gap between two backfill images.
        var backfillPause: TimeInterval = 0.25
        /// Backfill results are applied once this many are buffered...
        var flushBatchSize = 40
        /// ...or once the oldest buffered one is this old, whichever first.
        var flushInterval: TimeInterval = 15
        /// How long a deferred backfill (hot Mac, Low Power Mode) waits
        /// before checking again.
        var deferRetry: TimeInterval = 60
        /// Quiet time after a history change before embeddings are brought
        /// in line with it (see the type's notes).
        var reconcileDelay: TimeInterval = 5

        static let standard = Timing()
    }

    /// What one job produced for its clip.
    nonisolated struct JobResult: Sendable {
        /// `nil` when the clip did not need analysis.
        var analysis: ImageAnalysisService.Outcome?
        /// `nil` when no embedding was needed (current, no embedder, or the
        /// file was missing).
        var embedding: EmbeddingOutcome?
    }

    nonisolated enum EmbeddingOutcome: Sendable {
        case embedded([Float], ImageFingerprint)
        /// The bytes do not decode: stored as the empty embedding.
        case unreadable(ImageFingerprint)
        /// The encoder failed: nothing stored, not retried this session.
        case failed
    }

    private weak var store: ClipboardStore?
    /// An injected analyzer (tests) reads the file itself; the real
    /// `ImageAnalysisService` shares the job's decode with the encoder.
    private let analyzer: Analyzer
    private let analyzerIsInjected: Bool
    private let embedder: ImageEmbedding?
    private let timing: Timing
    private let shouldDeferBackfill: () -> Bool
    private let workQueue = DispatchQueue(label: "com.fxreza.bench.klip.image-analysis", qos: .utility)

    private var urgent: [UUID] = []
    private var backlog: [UUID] = []
    private var queued = Set<UUID>()
    private var inFlight: (id: UUID, urgent: Bool)?
    /// Bumped by `stop()`, so a result that comes back after a stop (or a
    /// stop + start) is recognised as stale and dropped.
    private var generation = 0
    private(set) var isRunning = false

    /// Finished backfill results not yet written to the store.
    private var pending: [UUID: ImageAnalysis] = [:]
    private var oldestPendingAt: Date?
    /// True once a buffered batch was applied without telling sync; cleared
    /// by the one notification sent when the backfill drains.
    private var owesSyncNotification = false

    /// Clips Vision failed on this session: not retried until next launch.
    private var failedThisSession = Set<UUID>()
    /// Clips the encoder failed on, or whose file was missing, this session.
    private var embeddingSkippedThisSession = Set<UUID>()

    private var pumpScheduled = false
    private var backfillWork: DispatchWorkItem?
    private var resumeWork: DispatchWorkItem?
    /// Set once the launch backfill has been queued; history changes before
    /// that are covered by it.
    private var backfillStarted = false
    private var historyObserver: AnyCancellable?
    private var reconcileWork: DispatchWorkItem?

    /// Called on the main thread each time the queue runs dry. Tests wait on
    /// it; the app does not need it.
    var onIdle: (() -> Void)?

    /// No job queued and none running.
    var isIdle: Bool { inFlight == nil && urgent.isEmpty && backlog.isEmpty }

    init(
        store: ClipboardStore,
        timing: Timing = .standard,
        analyzer: Analyzer? = nil,
        embedder: ImageEmbedding? = nil,
        shouldDeferBackfill: @escaping () -> Bool = ImageAnalysisQueue.systemIsBusy
    ) {
        self.store = store
        self.timing = timing
        self.analyzer = analyzer ?? { ImageAnalysisService.analyze(imageAt: $0) }
        self.analyzerIsInjected = analyzer != nil
        self.embedder = embedder
        self.shouldDeferBackfill = shouldDeferBackfill
    }

    /// The embedder, when it has a model to embed with.
    private var activeEmbedder: ImageEmbedding? {
        guard let embedder, embedder.canEmbed else { return nil }
        return embedder
    }

    // MARK: - Lifecycle

    /// Starts listening for new captures and schedules the launch backfill.
    func start() {
        guard !isRunning, let store else { return }
        isRunning = true
        store.onImageNeedsAnalysis = { [weak self] id in
            self?.enqueue(id, urgent: true)
        }
        let work = DispatchWorkItem { [weak self] in self?.enqueueBackfill() }
        backfillWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timing.backfillDelay, execute: work)

        if activeEmbedder != nil {
            // `dropFirst` on each: the current values are what the launch
            // backfill covers.
            historyObserver = store.$items.dropFirst().map { _ in () }
                .merge(with: store.$trashedItems.dropFirst().map { _ in () })
                .sink { [weak self] in self?.scheduleReconcile() }
        }
    }

    /// Stops taking work and applies what is buffered. Safe to call twice.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation += 1
        backfillWork?.cancel()
        backfillWork = nil
        resumeWork?.cancel()
        resumeWork = nil
        reconcileWork?.cancel()
        reconcileWork = nil
        historyObserver = nil
        backfillStarted = false
        store?.onImageNeedsAnalysis = nil
        urgent.removeAll()
        backlog.removeAll()
        queued.removeAll()
        inFlight = nil
        // The caller (`KlipFeature.stop`) flushes the store and does its own
        // quit-time sync push right after, so no separate notification.
        flush(notifySync: false)
        owesSyncNotification = false
        embedder?.flushEmbeddings()
    }

    // MARK: - Enqueueing

    /// Queues one clip. An urgent request for a clip already waiting in the
    /// backlog moves it to the urgent lane.
    func enqueue(_ id: UUID, urgent isUrgent: Bool) {
        guard isRunning, inFlight?.id != id else { return }
        if isUrgent {
            if queued.contains(id) {
                guard !urgent.contains(id) else { return }
                backlog.removeAll { $0 == id }
            }
            urgent.append(id)
        } else {
            guard !queued.contains(id) else { return }
            backlog.append(id)
        }
        queued.insert(id)
        schedulePump()
    }

    /// Queues every image clip still missing its analysis, newest first
    /// (the ones most likely to be searched for). With an embedder, it then
    /// checks every image clip's embedding off the main thread (dropping
    /// those of deleted clips first) and queues the ones that are missing or
    /// stale.
    func enqueueBackfill() {
        backfillWork = nil
        guard isRunning, let store else { return }
        backfillStarted = true
        let ids = store.items
            .filter { $0.needsImageAnalysis && !failedThisSession.contains($0.id) }
            .map { $0.id }
        if !ids.isEmpty {
            print("[Klip] Image analysis: \(ids.count) image clip(s) to read")
        }
        for id in ids { enqueue(id, urgent: false) }

        if let embedder = activeEmbedder {
            let candidates = store.items.compactMap { item -> (UUID, URL)? in
                guard item.type == .image, let url = store.imageURL(for: item) else { return nil }
                return (item.id, url)
            }
            let live = Set(store.items.map(\.id)).union(store.trashedItems.map(\.id))
            let generation = self.generation
            workQueue.async { [weak self] in
                embedder.retainEmbeddings(for: live)
                let stale = candidates.filter { id, url in
                    guard let fingerprint = ImageFingerprint.of(fileAt: url) else { return false }
                    return embedder.embeddingNeeded(for: id, fingerprint: fingerprint)
                }.map(\.0)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isRunning, generation == self.generation else { return }
                    if !stale.isEmpty {
                        print("[Klip] Smart search: \(stale.count) image clip(s) to embed")
                    }
                    self.enqueueForEmbedding(stale)
                }
            }
            return
        }
        // Nothing to do still counts as the queue going idle.
        if ids.isEmpty { schedulePump() }
    }

    private func enqueueForEmbedding(_ ids: [UUID]) {
        let wanted = ids.filter { !embeddingSkippedThisSession.contains($0) }
        for id in wanted { enqueue(id, urgent: false) }
        if wanted.isEmpty { schedulePump() }
    }

    // MARK: - Following the history

    private func scheduleReconcile() {
        guard isRunning, backfillStarted else { return }
        reconcileWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reconcile() }
        reconcileWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timing.reconcileDelay, execute: work)
    }

    /// Drops the embeddings of clips that are gone and queues image clips
    /// that have none. Only an id lookup per image (no file access), so it
    /// is cheap enough to run after any change.
    func reconcile() {
        reconcileWork = nil
        guard isRunning, let store, let embedder = activeEmbedder else { return }
        let live = Set(store.items.map(\.id)).union(store.trashedItems.map(\.id))
        let images = store.items.filter { $0.type == .image }.map(\.id)
        let generation = self.generation
        workQueue.async { [weak self] in
            embedder.retainEmbeddings(for: live)
            let missing = embedder.missingEmbeddings(among: images)
            // Newest first, like the backfill.
            let ordered = images.filter { missing.contains($0) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRunning, generation == self.generation else { return }
                self.enqueueForEmbedding(ordered)
            }
        }
    }

    // MARK: - Running

    /// Coalesces pump requests into one on a later run-loop turn, so an
    /// `add()` that enqueues returns before any of this runs.
    private func schedulePump() {
        guard !pumpScheduled else { return }
        pumpScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pumpScheduled = false
            self.pump()
        }
    }

    private func pump() {
        guard isRunning, inFlight == nil, let store else { return }
        resumeWork?.cancel()
        resumeWork = nil

        while let job = nextJob() {
            let (id, isUrgent) = (job.id, job.urgent)
            // Deleted, evicted, or read meanwhile (by a sync pull, or an
            // urgent request that got there first): nothing to do. Whether
            // the embedding is current is checked on the work queue.
            guard let item = store.items.first(where: { $0.id == id }) else {
                queued.remove(id)
                continue
            }
            let analyze = item.needsImageAnalysis && !failedThisSession.contains(id)
            let embed = item.type == .image && activeEmbedder != nil && !embeddingSkippedThisSession.contains(id)
            guard analyze || embed else {
                queued.remove(id)
                continue
            }

            if !isUrgent, shouldDeferBackfill() {
                // Leave it at the head of the backlog and look again later;
                // what is already done should not wait with it.
                backlog.insert(id, at: 0)
                flush(notifySync: true)
                scheduleResume(after: timing.deferRetry)
                return
            }
            queued.remove(id)

            guard let url = store.imageURL(for: item),
                  FileManager.default.fileExists(atPath: url.path) else {
                // Nothing to embed until the bytes arrive (next launch).
                embeddingSkippedThisSession.insert(id)
                if analyze { record(.empty, for: id, urgent: isUrgent) }
                continue
            }

            run(id, url: url, analyze: analyze, embed: embed, urgent: isUrgent)
            return
        }

        // Ran dry.
        flush(notifySync: true)
        onIdle?()
    }

    private func nextJob() -> (id: UUID, urgent: Bool)? {
        if !urgent.isEmpty { return (urgent.removeFirst(), true) }
        if !backlog.isEmpty { return (backlog.removeFirst(), false) }
        return nil
    }

    private func run(_ id: UUID, url: URL, analyze: Bool, embed: Bool, urgent isUrgent: Bool) {
        inFlight = (id, isUrgent)
        let generation = self.generation
        let analyzer = self.analyzer
        let injected = analyzerIsInjected
        let embedder = embed ? activeEmbedder : nil
        workQueue.async { [weak self] in
            // An injected analyzer (tests) reads the file itself; the real
            // one runs inside `work` on the shared decode.
            let injectedOutcome = analyze && injected ? analyzer(url) : nil
            let result = Self.work(
                id: id, url: url,
                analyze: analyze && !injected, analyzed: injectedOutcome,
                embedder: embedder
            )
            DispatchQueue.main.async { [weak self] in
                self?.finish(id, result: result, urgent: isUrgent, generation: generation)
            }
        }
    }

    /// One job, on the work queue: analysis if asked for, and the embedding
    /// if the index does not have one for these exact bytes, from one decode
    /// when both run. `analyzed` is an injected analyzer's result (tests),
    /// already computed from the URL.
    nonisolated static func work(
        id: UUID,
        url: URL,
        analyze: Bool,
        analyzed: ImageAnalysisService.Outcome?,
        embedder: ImageEmbedding?
    ) -> JobResult {
        autoreleasepool {
            var result = JobResult(analysis: analyzed)
            // Taken before decoding: if the file changes mid-job, the stored
            // fingerprint is the old one and the next check re-embeds.
            let fingerprint = embedder != nil ? ImageFingerprint.of(fileAt: url) : nil
            let needsEmbedding = fingerprint.map { embedder!.embeddingNeeded(for: id, fingerprint: $0) } ?? false

            var decoded: CGImage?
            var didDecode = false
            if analyze {
                decoded = ImageAnalysisService.downsampledImage(at: url)
                didDecode = true
                result.analysis = decoded.map { ImageAnalysisService.analyze(image: $0, name: url.lastPathComponent) } ?? .unreadable
            }

            if needsEmbedding, let embedder, let fingerprint {
                if !didDecode {
                    decoded = ImageAnalysisService.downsampledImage(at: url, maxShortSide: MobileCLIPEncoder.decodeShortSide)
                }
                if let image = decoded {
                    result.embedding = embedder.computeEmbedding(for: image).map { .embedded($0, fingerprint) } ?? .failed
                } else {
                    result.embedding = .unreadable(fingerprint)
                }
            }
            return result
        }
    }

    private func finish(_ id: UUID, result: JobResult, urgent isUrgent: Bool, generation: Int) {
        guard generation == self.generation, isRunning else { return }
        inFlight = nil

        switch result.analysis {
        case .analyzed(let analysis)?:
            record(analysis, for: id, urgent: isUrgent)
        case .unreadable?:
            record(.empty, for: id, urgent: isUrgent)
        case .failed?:
            failedThisSession.insert(id)
        case nil:
            break
        }

        switch result.embedding {
        case .embedded(let vector, let fingerprint)?:
            if clipExists(id) { embedder?.storeEmbedding(vector, fingerprint: fingerprint, for: id) }
        case .unreadable(let fingerprint)?:
            if clipExists(id) { embedder?.storeEmbedding(nil, fingerprint: fingerprint, for: id) }
        case .failed?:
            embeddingSkippedThisSession.insert(id)
        case nil:
            break
        }

        // Urgent work goes straight on; backfill leaves a small gap after
        // real work (not after a job that found nothing to do).
        let didWork = result.analysis != nil || result.embedding != nil
        if !didWork || !urgent.isEmpty || backlog.isEmpty || timing.backfillPause <= 0 {
            schedulePump()
        } else {
            scheduleResume(after: timing.backfillPause)
        }
    }

    /// In the history or the trash: an embedding for a clip deleted while
    /// it was being computed is not stored.
    private func clipExists(_ id: UUID) -> Bool {
        guard let store else { return false }
        return store.items.contains { $0.id == id } || store.trashedItems.contains { $0.id == id }
    }

    private func scheduleResume(after delay: TimeInterval) {
        resumeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pump() }
        resumeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Applying results

    /// Buffers one result, and applies the buffer when it is due: at once
    /// for an urgent clip (someone is about to look at it), otherwise by
    /// batch size or age.
    private func record(_ analysis: ImageAnalysis, for id: UUID, urgent isUrgent: Bool) {
        pending[id] = analysis
        if oldestPendingAt == nil { oldestPendingAt = Date() }
        if isUrgent {
            flush(notifySync: true)
        } else if pending.count >= timing.flushBatchSize
                    || Date().timeIntervalSince(oldestPendingAt ?? Date()) >= timing.flushInterval {
            flush(notifySync: false)
        }
    }

    /// Writes the buffered results to the store in one mutation.
    ///
    /// Backfill batches are saved locally but do not each ping iCloud sync:
    /// every push rewrites this Mac's whole `history.json` in iCloud Drive,
    /// and a backfill would otherwise do that every few seconds for minutes.
    /// One notification goes out when the queue runs dry (and any push in
    /// between, from a copy or an edit, carries the results so far anyway).
    private func flush(notifySync: Bool) {
        if !pending.isEmpty, let store {
            let results = pending
            pending.removeAll()
            oldestPendingAt = nil
            let changed = store.applyImageAnalyses(results, notifySync: notifySync)
            if changed > 0, !notifySync { owesSyncNotification = true }
            if changed > 0, notifySync { owesSyncNotification = false }
        }
        if notifySync, owesSyncNotification {
            owesSyncNotification = false
            store?.noteBackgroundChangeForSync()
        }
    }

    // MARK: - System state

    /// Backfill waits while the Mac is thermally constrained or in Low Power
    /// Mode. Captures and explicit requests are not deferred: one image is
    /// a fraction of a second of work.
    nonisolated static func systemIsBusy() -> Bool {
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { return true }
        switch info.thermalState {
        case .serious, .critical: return true
        default: return false
        }
    }
}
