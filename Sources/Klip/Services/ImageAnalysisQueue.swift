import Foundation

/// Reads image clips in the background, one at a time, so they can be found
/// by the text in them and by what they show (`ImageAnalysisService`).
///
/// Two sources of work, one serial lane:
/// - **Urgent**: an image that was just captured (`ClipboardStore.add` calls
///   `onImageNeedsAnalysis` *after* the clip is in the list and its save is
///   scheduled) or one the UI asked for (`requestImageAnalysis`). Taken
///   before any backfill work and applied as soon as it finishes.
/// - **Backfill**: every image clip still missing `ocrText` or
///   `imageLabels`, walked newest first, starting `Timing.backfillDelay`
///   after launch so it never competes with startup. Results are buffered
///   and applied in batches (`flushBatchSize` / `flushInterval`) through
///   `ClipboardStore.applyImageAnalyses`, so a history with hundreds of
///   screenshots costs a handful of list refreshes and history writes, not
///   one per image. A short `backfillPause` between images, and waiting
///   while the Mac is hot or in Low Power Mode, keep a long backfill from
///   being noticed.
///
/// Vision runs on `workQueue` at `.utility` QoS; everything else here is
/// main-thread bookkeeping and cheap. Nothing on the capture, paste or panel
/// path ever waits for it.
///
/// Robustness:
/// - A clip deleted or evicted while it waited is skipped when its turn
///   comes, and a result for a clip that vanished mid-analysis is dropped
///   by `applyImageAnalyses`.
/// - A missing or undecodable file is recorded as analyzed-and-empty, so it
///   is not retried on every launch (sync still upgrades it from a Mac that
///   has the bytes, see `SyncMerge.analysisRank`).
/// - A Vision failure is *not* recorded - it may be transient - but the clip
///   is not retried again this session either, so a persistent failure can
///   never spin.
/// - `stop()` (Klip switched off, or quitting) applies whatever is buffered
///   before `KlipFeature` flushes the store, and drops the result of the
///   image still in flight rather than waiting for it; that one is simply
///   read again next launch.
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

        static let standard = Timing()
    }

    private weak var store: ClipboardStore?
    private let analyzer: Analyzer
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

    private var pumpScheduled = false
    private var backfillWork: DispatchWorkItem?
    private var resumeWork: DispatchWorkItem?

    /// Called on the main thread each time the queue runs dry. Tests wait on
    /// it; the app does not need it.
    var onIdle: (() -> Void)?

    /// No job queued and none running.
    var isIdle: Bool { inFlight == nil && urgent.isEmpty && backlog.isEmpty }

    init(
        store: ClipboardStore,
        timing: Timing = .standard,
        analyzer: @escaping Analyzer = { ImageAnalysisService.analyze(imageAt: $0) },
        shouldDeferBackfill: @escaping () -> Bool = ImageAnalysisQueue.systemIsBusy
    ) {
        self.store = store
        self.timing = timing
        self.analyzer = analyzer
        self.shouldDeferBackfill = shouldDeferBackfill
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
        store?.onImageNeedsAnalysis = nil
        urgent.removeAll()
        backlog.removeAll()
        queued.removeAll()
        inFlight = nil
        // The caller (`KlipFeature.stop`) flushes the store and does its own
        // quit-time sync push right after, so no separate notification.
        flush(notifySync: false)
        owesSyncNotification = false
    }

    // MARK: - Enqueueing

    /// Queues one clip. An urgent request for a clip already waiting in the
    /// backlog moves it to the urgent lane.
    func enqueue(_ id: UUID, urgent isUrgent: Bool) {
        guard isRunning, !failedThisSession.contains(id), inFlight?.id != id else { return }
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
    /// (the ones most likely to be searched for).
    func enqueueBackfill() {
        backfillWork = nil
        guard isRunning, let store else { return }
        let ids = store.items
            .filter { $0.needsImageAnalysis && !failedThisSession.contains($0.id) }
            .map { $0.id }
        if !ids.isEmpty {
            print("[Klip] Image analysis: \(ids.count) image clip(s) to read")
        }
        for id in ids { enqueue(id, urgent: false) }
        // Nothing to do still counts as the queue going idle.
        if ids.isEmpty { schedulePump() }
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
            // urgent request that got there first): nothing to do.
            guard let item = store.items.first(where: { $0.id == id }), item.needsImageAnalysis else {
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
                record(.empty, for: id, urgent: isUrgent)
                continue
            }

            run(id, url: url, urgent: isUrgent)
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

    private func run(_ id: UUID, url: URL, urgent isUrgent: Bool) {
        inFlight = (id, isUrgent)
        let generation = self.generation
        let analyzer = self.analyzer
        workQueue.async { [weak self] in
            let outcome = analyzer(url)
            DispatchQueue.main.async { [weak self] in
                self?.finish(id, outcome: outcome, urgent: isUrgent, generation: generation)
            }
        }
    }

    private func finish(_ id: UUID, outcome: ImageAnalysisService.Outcome, urgent isUrgent: Bool, generation: Int) {
        guard generation == self.generation, isRunning else { return }
        inFlight = nil

        switch outcome {
        case .analyzed(let analysis):
            record(analysis, for: id, urgent: isUrgent)
        case .unreadable:
            record(.empty, for: id, urgent: isUrgent)
        case .failed:
            failedThisSession.insert(id)
        }

        // Urgent work goes straight on; backfill leaves a small gap.
        if !urgent.isEmpty || backlog.isEmpty || timing.backfillPause <= 0 {
            schedulePump()
        } else {
            scheduleResume(after: timing.backfillPause)
        }
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
