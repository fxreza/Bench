import Foundation
import Combine

/// iCloud Drive file sync (Phase 4A, decision D7 — no CloudKit, no
/// entitlements, no sandbox).
///
/// The local store at `~/Library/Application Support/Bench/Klip` stays authoritative.
/// This service *mirrors* it into
/// `~/Library/Mobile Documents/com~apple~CloudDocs/Klip/` and merges what the
/// other Macs put there:
///
/// ```
/// Klip/
///   devices/<deviceID>/history.json     {"version":1,"device":{…},"items":[…]}
///   devices/<deviceID>/folders.json     {"version":1,"folders":[…]}
///   devices/<deviceID>/tombstones.json  {"version":1,"deleted":[…],"deletedFolders":[…]}
///   images/<uuid>.<ext>  texts/<uuid>.txt|.rtf  files/<uuid>/<name>  flavors/<uuid>.plist
///   (image `<ext>` is whatever was captured — jpg/png/heic/gif/webp/... — 6C)
/// ```
///
/// Each device only ever writes its own `devices/<id>/` directory, so two Macs
/// can never clobber one file. Assets are written once, keyed by uuid, so they
/// have no conflict either. Everything else is decided by `SyncMerge`, which is
/// pure and unit-tested.
///
/// Threading: every cloud read/write happens on `ioQueue` (reading a file
/// iCloud has not downloaded yet can block for a long time, hence the per-file
/// timeout), and every store read/write hops to the main actor.
final class CloudDriveSync: ObservableObject {
    /// The module-wide instance. `KlipFeature` attaches the store to it in
    /// `start()`; Settings observes it. Tests build their own instances instead.
    static let shared = CloudDriveSync()

    // MARK: - Status (for Settings > Sync and the Permissions row)

    struct DeviceInfo: Identifiable, Equatable {
        let id: String
        let name: String
        let lastPush: Date
    }

    @Published private(set) var lastPush: Date?
    @Published private(set) var lastPull: Date?
    /// Other devices seen in the cloud folder, newest push first.
    @Published private(set) var otherDevices: [DeviceInfo] = []
    @Published private(set) var isBusy = false
    /// Last failure, shown under the toggle. `nil` when the last cycle worked.
    @Published private(set) var lastError: String?

    // MARK: - Identity

    /// Appended to the stored device UUID for this Mac's snapshot directory.
    ///
    /// Bench imports Klip's preferences on first run, `sync.deviceID`
    /// included, and the standalone Klip may keep running (and syncing) on
    /// this same Mac. Two processes writing `devices/<uuid>/` would clobber
    /// each other's snapshot, so Bench's directory is `devices/<uuid>-bench/`
    /// and the two appear to every other Mac as two devices, which is what
    /// they are. Explicit `deviceID`s (tests, `KLIP_DEVICE_ID`) are used
    /// verbatim.
    static let deviceIDSuffix = "-bench"

    let deviceID: String
    private let deviceNameOverride: String?
    var deviceName: String { deviceNameOverride ?? SettingsManager.shared.syncDeviceName }

    /// Test-instance overrides, in the same spirit as `KLIP_CLOUD_ROOT`: two
    /// locally built instances share one UserDefaults
    /// domain, so without these they would fight over one device identity and
    /// one enabled flag. Never set in a normal user run.
    ///  - `KLIP_DEVICE_ID`, `KLIP_DEVICE_NAME`: this instance's sync identity.
    ///  - `KLIP_SYNC_ENABLED=1`: turn sync on without writing to UserDefaults.
    static func environmentOverride(_ key: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else { return nil }
        return value
    }

    /// Whether sync should be running, honouring the test override.
    var isEnabled: Bool {
        if let raw = Self.environmentOverride("KLIP_SYNC_ENABLED") { return raw == "1" }
        return SettingsManager.shared.syncEnabled
    }

    /// Attachment size cap in bytes, `nil` when unlimited.
    private let maxAttachmentBytesOverride: Int64?
    private var maxAttachmentBytes: Int64? {
        if let override = maxAttachmentBytesOverride { return override <= 0 ? nil : override }
        let mb = SettingsManager.shared.syncMaxAttachmentMB
        return mb <= 0 ? nil : Int64(mb) * 1024 * 1024
    }

    /// The content kinds allowed through sync (Settings > Sync). Applied on
    /// push and on pull, so a kind switched off neither leaves this Mac nor
    /// arrives from another one.
    private var syncedKinds: Set<ContentKind> {
        SettingsManager.shared.syncedKinds
    }

    // MARK: - Locations

    /// The iCloud Drive container (or, under `KLIP_CLOUD_ROOT`, a stand-in).
    /// `nil` when iCloud Drive is not set up on this Mac.
    let cloudRoot: URL?

    /// True only when the container is actually on disk: iCloud Drive can be
    /// switched off in System Settings while Klip is running, and an injected
    /// root can be removed by a test.
    var isAvailable: Bool {
        guard let cloudRoot = cloudRoot else { return false }
        return FileManager.default.fileExists(atPath: cloudRoot.path)
    }

    /// Why sync cannot be turned on, or `nil` when it can.
    var unavailableReason: String? {
        isAvailable ? nil : "Sign in to iCloud and enable iCloud Drive in System Settings."
    }

    var klipRoot: URL? { cloudRoot?.appendingPathComponent("Klip", isDirectory: true) }
    private var devicesRoot: URL? { klipRoot?.appendingPathComponent("devices", isDirectory: true) }
    private var ownDeviceDir: URL? { devicesRoot?.appendingPathComponent(deviceID, isDirectory: true) }

    private enum AssetKind: String {
        case images, texts, files, flavors
    }

    private func cloudAssetDir(_ kind: AssetKind) -> URL? {
        klipRoot?.appendingPathComponent(kind.rawValue, isDirectory: true)
    }

    // MARK: - Wiring

    private var store: ClipboardStore?
    private let fileManager = FileManager.default
    private let ioQueue = DispatchQueue(label: "com.klip.sync.io", qos: .utility)
    /// Copies run on this queue so `ioQueue` can abandon one that hangs on a
    /// file iCloud has not finished downloading.
    private let copyQueue = DispatchQueue(label: "com.klip.sync.copy", qos: .utility, attributes: .concurrent)

    /// This device's own tombstones, loaded from its cloud directory at start
    /// and grown by explicit deletes. Published on every push. Touched from the
    /// main thread (store callbacks) and from `ioQueue` (push/pull), so every
    /// access goes through `tombstoneLock`.
    private var deletedItems: [UUID: SyncTombstone] = [:]
    private var deletedFolders: [UUID: SyncTombstone] = [:]
    private let tombstoneLock = NSLock()

    private func withTombstones<R>(_ body: (inout [UUID: SyncTombstone], inout [UUID: SyncTombstone]) -> R) -> R {
        tombstoneLock.lock()
        defer { tombstoneLock.unlock() }
        return body(&deletedItems, &deletedFolders)
    }

    /// Cloud asset paths already confirmed present, so a push does not re-stat
    /// every asset of a 10k-item history. Assets are write-once, so a cached
    /// "present" can never go stale within a run. `ioQueue` only.
    private var knownCloudAssets: Set<String> = []

    /// Serialises `performPush` (5A-16). `pushSynchronously(budget:)` uses the
    /// bounded `lock(before:)` so quitting can never wait on a slow cycle.
    private let pushLock = NSLock()

    private var pushDebounce: DispatchWorkItem?
    private var pullDebounce: DispatchWorkItem?
    private var watcher: DispatchSourceFileSystemObject?
    /// One watcher per *other* device directory. Writing
    /// `devices/<id>/history.json` does not change `devices/` itself, so the
    /// root watcher alone would only ever see devices appearing and
    /// disappearing — the 60 s poll would be the only thing catching edits.
    private var deviceWatchers: [String: DispatchSourceFileSystemObject] = [:]
    private var pollTimer: Timer?
    private var settingsObserver: NSObjectProtocol?
    private var lastRemoteFingerprint: String?
    private var isRunning = false

    /// Debounce after a local save before pushing (a burst of edits collapses
    /// into one push).
    static let pushDebounceInterval: TimeInterval = 2.0
    /// Debounce after a directory-change event before pulling.
    static let pullDebounceInterval: TimeInterval = 1.0
    /// Fallback poll, for the case where the `DispatchSource` misses an event.
    static let pollInterval: TimeInterval = 60.0
    /// Per-file cloud I/O timeout. A file iCloud has not materialised yet is
    /// left for the next cycle rather than blocking the queue.
    static let fileTimeout: TimeInterval = 20.0

    private static let schemaVersion = 1

    // MARK: - Init

    init(
        store: ClipboardStore? = nil,
        cloudRoot: URL? = nil,
        deviceID: String? = nil,
        deviceName: String? = nil,
        maxAttachmentBytes: Int64? = nil
    ) {
        self.store = store
        self.cloudRoot = cloudRoot ?? ClipboardStore.cloudSyncRoot
        self.deviceID = deviceID
            ?? Self.environmentOverride("KLIP_DEVICE_ID")
            ?? SettingsManager.shared.syncDeviceID + Self.deviceIDSuffix
        self.deviceNameOverride = deviceName ?? Self.environmentOverride("KLIP_DEVICE_NAME")
        self.maxAttachmentBytesOverride = maxAttachmentBytes
        self.lastPush = SettingsManager.shared.syncLastPush
        self.lastPull = SettingsManager.shared.syncLastPull
        if store != nil { wireStoreHooks() }
    }

    deinit {
        watcher?.cancel()
        pollTimer?.invalidate()
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Called once by `KlipFeature` with the module's store.
    func attach(store: ClipboardStore) {
        self.store = store
        wireStoreHooks()
    }

    private func wireStoreHooks() {
        store?.onLocalMutation = { [weak self] in self?.schedulePush() }
        store?.onItemsDeleted = { [weak self] ids in self?.recordDeletedItems(ids) }
        store?.onItemsRestored = { [weak self] ids in self?.retractDeletedItems(ids) }
        store?.onFolderDeleted = { [weak self] id in self?.recordDeletedFolder(id) }
    }

    // MARK: - Lifecycle

    /// Starts sync when it is both enabled and available, and keeps listening
    /// for the setting changing either way.
    func startIfEnabled() {
        if settingsObserver == nil {
            settingsObserver = NotificationCenter.default.addObserver(
                forName: .klipSyncSettingsChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncSettingsChanged() }
            }
        }
        syncSettingsChanged()
    }

    private func syncSettingsChanged() {
        if isEnabled && isAvailable {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        guard !isRunning else { return }
        guard isAvailable, store != nil else { return }
        isRunning = true
        lastError = nil

        ioQueue.async { [weak self] in
            guard let self = self else { return }
            self.ensureCloudDirectories()
            self.loadOwnTombstones()
            self.performPull()
            self.performPush()
            self.onMain { self.startWatching() }
        }
    }

    /// Stops watching. The cloud copy is left in place — removing it is an
    /// explicit user action (`removeThisDeviceFromCloud`).
    func stop() {
        isRunning = false
        pushDebounce?.cancel()
        pushDebounce = nil
        pullDebounce?.cancel()
        pullDebounce = nil
        watcher?.cancel()
        watcher = nil
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Enabled + available. The UI toggle binds through here so the service and
    /// the setting can never disagree.
    var isActive: Bool { isRunning }

    /// User-facing "Sync now": a pull followed by a push, off the main thread.
    func syncNow() {
        guard isAvailable, store != nil else { return }
        isBusy = true
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            self.ensureCloudDirectories()
            self.performPull()
            self.performPush()
            self.onMain { self.isBusy = false }
        }
    }

    /// Injects a status for previews and the offscreen render harness used to
    /// check the Sync tab without a screen. Never called at runtime — the real
    /// values only ever come from a push or a pull.
    func previewState(lastPush: Date?, lastPull: Date?, devices: [DeviceInfo]) {
        self.lastPush = lastPush
        self.lastPull = lastPull
        self.otherDevices = devices
    }

    // MARK: - Watching

    private func startWatching() {
        stopWatching()
        guard let devicesRoot = devicesRoot else { return }

        watcher = makeWatcher(for: devicesRoot) { [weak self] in
            guard let self = self else { return }
            // A device appeared or disappeared: pull, and re-arm the per-device
            // watchers so the new one is covered.
            self.schedulePull()
            self.refreshDeviceWatchers()
        }
        refreshDeviceWatchers()

        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollForRemoteChanges() }
        }
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
        for source in deviceWatchers.values { source.cancel() }
        deviceWatchers.removeAll()
    }

    private func makeWatcher(for url: URL, onChange: @escaping () -> Void) -> DispatchSourceFileSystemObject? {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .extend],
            queue: .main
        )
        source.setEventHandler { MainActor.assumeIsolated { onChange() } }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    /// Keeps one watcher per other device directory, adding watchers for
    /// devices that just appeared and dropping the ones that went away. Cheap
    /// and idempotent, so it can be called after every pull.
    private func refreshDeviceWatchers() {
        guard isRunning, let devicesRoot = devicesRoot else { return }
        let contents = (try? fileManager.contentsOfDirectory(
            at: devicesRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let ids = Set(contents.map { $0.lastPathComponent }).subtracting([deviceID])

        for id in deviceWatchers.keys where !ids.contains(id) {
            deviceWatchers[id]?.cancel()
            deviceWatchers[id] = nil
        }
        for id in ids where deviceWatchers[id] == nil {
            let dir = devicesRoot.appendingPathComponent(id, isDirectory: true)
            deviceWatchers[id] = makeWatcher(for: dir) { [weak self] in
                guard let self = self else { return }
                self.schedulePull()
                // An atomic replace can retire the directory's descriptor;
                // rebuilding it is cheap and keeps the watch alive.
                self.deviceWatchers[id]?.cancel()
                self.deviceWatchers[id] = nil
                self.refreshDeviceWatchers()
            }
        }
    }

    /// The 60 s fallback: only pulls when a remote file's modification date
    /// actually moved.
    private func pollForRemoteChanges() {
        guard isRunning else { return }
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            let fingerprint = self.remoteFingerprint()
            guard fingerprint != self.lastRemoteFingerprint else { return }
            self.lastRemoteFingerprint = fingerprint
            self.performPull()
        }
    }

    private func remoteFingerprint() -> String {
        guard let devicesRoot = devicesRoot else { return "" }
        guard let dirs = try? fileManager.contentsOfDirectory(
            at: devicesRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return "" }

        var parts: [String] = []
        for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where dir.lastPathComponent != deviceID {
            for name in ["history.json", "folders.json", "tombstones.json"] {
                let url = dir.appendingPathComponent(name)
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                parts.append("\(dir.lastPathComponent)/\(name)@\(date?.timeIntervalSince1970 ?? 0)")
            }
        }
        return parts.joined(separator: ";")
    }

    // MARK: - Debounced triggers

    private func schedulePush() {
        guard isRunning else { return }
        pushDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.ioQueue.async { self.performPush() }
        }
        pushDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pushDebounceInterval, execute: work)
    }

    private func schedulePull() {
        guard isRunning else { return }
        pullDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.ioQueue.async { self.performPull() }
        }
        pullDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pullDebounceInterval, execute: work)
    }

    // MARK: - Tombstones

    private func recordDeletedItems(_ ids: [UUID]) {
        let now = Date()
        withTombstones { items, _ in
            for id in ids { items[id] = SyncTombstone(id: id, deletedAt: now) }
        }
    }

    /// Undoes `recordDeletedItems` for clips the user put back from the trash
    /// (5D). Only this device's own tombstones are retracted — another Mac's
    /// tombstone for the same id still stands, because that delete really did
    /// happen there.
    private func retractDeletedItems(_ ids: [UUID]) {
        withTombstones { items, _ in
            for id in ids { items.removeValue(forKey: id) }
        }
    }

    private func recordDeletedFolder(_ id: UUID) {
        let now = Date()
        withTombstones { _, folders in
            folders[id] = SyncTombstone(id: id, deletedAt: now)
        }
    }

    private func loadOwnTombstones() {
        guard let dir = ownDeviceDir else { return }
        let url = dir.appendingPathComponent("tombstones.json")
        guard let file: TombstonesFile = decodeCloudFile(url, label: "tombstones.json") else { return }
        withTombstones { items, folders in
            for tomb in file.deleted { items[tomb.id] = tomb }
            for tomb in file.deletedFolders { folders[tomb.id] = tomb }
        }
    }

    // MARK: - Push

    /// Writes this device's three files and copies any asset the cloud does not
    /// have yet. Safe to call from any thread; store access hops to main.
    ///
    /// `budget` bounds the whole call (used by `applicationWillTerminate`):
    /// once it passes, remaining attachment copies are left for the next
    /// launch rather than blocking quit — `copyWithTimeout`'s 20 s *per file*
    /// could otherwise hold the main thread for minutes (5A-16).
    ///
    /// 4B #10: returns immediately when sync is off or iCloud Drive is not
    /// there. It used to call `ensureCloudDirectories()` unconditionally, which
    /// recreated the whole `Klip/` tree — and, on a Mac with iCloud Drive
    /// switched off, the container path itself — at quit time.
    @discardableResult
    func pushSynchronously(budget: TimeInterval? = nil) -> Bool {
        guard isEnabled, isAvailable, store != nil else { return false }
        let deadline = budget.map { Date().addingTimeInterval($0) }
        ensureCloudDirectories()
        return performPush(deadline: deadline)
    }

    @discardableResult
    private func performPush(deadline: Date? = nil) -> Bool {
        guard let store = store, let deviceDir = ownDeviceDir else { return false }
        guard isAvailable else { return false }

        // Serialises pushes so two cycles can never write one device file — or
        // mutate `knownCloudAssets` — at the same time (5A-16). A caller with a
        // deadline gives up rather than queueing behind an in-flight cycle, and
        // a main-thread caller never waits unboundedly: an in-flight `ioQueue`
        // push can be parked in `onMainSync`, which would otherwise deadlock.
        let lockDeadline = deadline ?? (Thread.isMainThread ? Date().addingTimeInterval(5) : Date.distantFuture)
        guard pushLock.lock(before: lockDeadline) else {
            report("Skipped the quit-time push: another sync cycle is still running.")
            return false
        }
        defer { pushLock.unlock() }

        let now = Date()
        let snapshot: (items: [ClipboardItem], folders: [Folder]) = onMainSync {
            (store.items, store.folders)
        }

        let (deleted, deletedFolderList) = withTombstones { items, folders -> ([SyncTombstone], [SyncTombstone]) in
            let prunedItems = SyncMerge.pruneTombstones(Array(items.values), now: now)
            let prunedFolders = SyncMerge.pruneTombstones(Array(folders.values), now: now)
            items = Dictionary(prunedItems.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            folders = Dictionary(prunedFolders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return (prunedItems, prunedFolders)
        }

        // Kinds the user switched off never leave this Mac: not their
        // metadata and not their bytes. They stay in the local history, and
        // their absence here is not a delete: the merge is a union over
        // explicit tombstones, so another Mac keeps its own copy.
        let syncable = SyncKindFilter.filter(snapshot.items, enabled: syncedKinds)

        // Assets first: an item must never be visible on another Mac before the
        // bytes it points at are there.
        let skipped = pushAssets(for: syncable, deadline: deadline)
        if !skipped.isEmpty {
            let ids = skipped
            onMain { store.markSyncSkippedLarge(ids: ids) }
        }

        var items = syncable
        if !skipped.isEmpty {
            for index in items.indices where skipped.contains(items[index].id) {
                items[index].fileAttachment?.syncSkippedLarge = true
            }
        }

        do {
            try createDirectory(deviceDir)
            let history = HistoryFile(
                version: Self.schemaVersion,
                device: DeviceStamp(id: deviceID, name: deviceName, lastPush: now),
                items: items
            )
            try writeCoordinated(encode(history), to: deviceDir.appendingPathComponent("history.json"))
            try writeCoordinated(
                encode(FoldersFile(version: Self.schemaVersion, folders: snapshot.folders)),
                to: deviceDir.appendingPathComponent("folders.json")
            )
            try writeCoordinated(
                encode(TombstonesFile(
                    version: Self.schemaVersion,
                    deleted: deleted,
                    deletedFolders: deletedFolderList
                )),
                to: deviceDir.appendingPathComponent("tombstones.json")
            )
        } catch {
            report("Push failed: \(error.localizedDescription)")
            return false
        }

        onMain {
            self.lastPush = now
            self.lastError = nil
            SettingsManager.shared.syncLastPush = now
        }
        return true
    }

    /// Copies every asset that is not in the cloud yet. Returns the ids whose
    /// file attachment was skipped for being over the size cap.
    private func pushAssets(for items: [ClipboardItem], deadline: Date? = nil) -> Set<UUID> {
        guard let store = store else { return [] }
        var skipped: Set<UUID> = []
        let cap = maxAttachmentBytes
        var abandoned = 0

        for item in items {
            for asset in assets(for: item, store: store) {
                guard !knownCloudAssets.contains(asset.cloud.path) else { continue }
                guard fileManager.fileExists(atPath: asset.local.path) else { continue }
                if let cap = cap, byteSize(of: asset.local) > cap {
                    if asset.isAttachmentPayload { skipped.insert(item.id) }
                    continue
                }
                if fileManager.fileExists(atPath: asset.cloud.path) {
                    knownCloudAssets.insert(asset.cloud.path)
                    continue
                }
                // 5A-16: out of budget (quit time). The metadata write below
                // still happens; these assets go up on the next launch.
                let remaining = deadline.map { $0.timeIntervalSinceNow }
                if let remaining = remaining, remaining <= 0 {
                    abandoned += 1
                    continue
                }
                try? createDirectory(asset.cloud.deletingLastPathComponent())
                let timeout = min(Self.fileTimeout, remaining ?? Self.fileTimeout)
                if copyWithTimeout(from: asset.local, to: asset.cloud, timeout: timeout) {
                    knownCloudAssets.insert(asset.cloud.path)
                } else {
                    report("Timed out copying \(asset.local.lastPathComponent) to iCloud Drive; will retry.")
                }
            }
        }
        if abandoned > 0 {
            print("[Klip] Sync: quit-time budget spent; \(abandoned) attachment(s) will sync on the next launch")
        }
        return skipped
    }

    // MARK: - Pull

    /// Reads every other device's files, merges, fetches the assets of anything
    /// new, and applies the result. Safe to call from any thread.
    @discardableResult
    func pullSynchronously() -> Bool {
        // 4B #10: same gate as `pushSynchronously` — never touch (or create)
        // the cloud tree when sync is off or iCloud Drive is unavailable.
        guard isEnabled, isAvailable, store != nil else { return false }
        ensureCloudDirectories()
        return performPull()
    }

    @discardableResult
    private func performPull() -> Bool {
        guard let store = store, isAvailable else { return false }

        let remotes = readRemoteSnapshots()
        let now = Date()

        let (ownDeleted, ownDeletedFolders) = withTombstones { items, folders in
            (Array(items.values), Array(folders.values))
        }

        let result: SyncMerge.Result = onMainSync {
            SyncMerge.merge(SyncMerge.Input(
                localItems: store.items,
                localFolders: store.folders,
                localDeleted: ownDeleted,
                localDeletedFolders: ownDeletedFolders,
                ignoredIDs: store.syncIgnoredIDs,
                remotes: remotes,
                now: now
            ))
        }

        // Tombstones travel transitively: this device republishes the union.
        withTombstones { items, folders in
            items = Dictionary(result.deleted.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            folders = Dictionary(result.deletedFolders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }

        let devices = remotes
            .map { DeviceInfo(id: $0.deviceID, name: $0.deviceName, lastPush: $0.lastPush) }
            .sorted { $0.lastPush > $1.lastPush }

        onMain {
            self.otherDevices = devices
            self.lastPull = now
            SettingsManager.shared.syncLastPull = now
            // A device that just showed up needs its own watcher.
            self.refreshDeviceWatchers()
        }

        guard result.changed else { return false }

        // Bytes before metadata: fetch what the new items point at *before*
        // they show up in the history.
        let arrived = Set(result.arrivedItemIDs)
        if !arrived.isEmpty {
            pullAssets(for: result.items.filter { arrived.contains($0.id) }, store: store)
        }

        onMain {
            store.applyRemoteMerge(result)
        }
        // Republish, so a delete another Mac made stops living on in this
        // device's snapshot. The merge is idempotent, so this converges after
        // one round rather than ping-ponging.
        performPush()
        return true
    }

    private func readRemoteSnapshots() -> [SyncDeviceSnapshot] {
        guard let devicesRoot = devicesRoot else { return [] }
        guard let dirs = try? fileManager.contentsOfDirectory(
            at: devicesRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var snapshots: [SyncDeviceSnapshot] = []
        let kinds = syncedKinds
        for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let id = dir.lastPathComponent
            guard id != deviceID else { continue }

            // A file that will not decode is skipped with a warning; the rest of
            // the device's data is still used, and the next push from that Mac
            // repairs it.
            let history: HistoryFile? = decodeCloudFile(dir.appendingPathComponent("history.json"), label: "\(id)/history.json")
            let folders: FoldersFile? = decodeCloudFile(dir.appendingPathComponent("folders.json"), label: "\(id)/folders.json")
            let tombs: TombstonesFile? = decodeCloudFile(dir.appendingPathComponent("tombstones.json"), label: "\(id)/tombstones.json")

            if history == nil && folders == nil && tombs == nil { continue }

            snapshots.append(SyncDeviceSnapshot(
                deviceID: id,
                deviceName: history?.device.name ?? id,
                lastPush: history?.device.lastPush ?? .distantPast,
                items: SyncKindFilter.filter(history?.items ?? [], enabled: kinds),
                folders: folders?.folders ?? [],
                deleted: tombs?.deleted ?? [],
                deletedFolders: tombs?.deletedFolders ?? []
            ))
        }
        return snapshots
    }

    private func pullAssets(for items: [ClipboardItem], store: ClipboardStore) {
        for item in items {
            for asset in assets(for: item, store: store) {
                guard !fileManager.fileExists(atPath: asset.local.path) else { continue }
                guard cloudFileExists(asset.cloud) else { continue }
                try? createDirectory(asset.local.deletingLastPathComponent())
                if !copyWithTimeout(from: asset.cloud, to: asset.local) {
                    report("Still downloading \(asset.cloud.lastPathComponent) from iCloud Drive; will retry.")
                }
            }
        }
    }

    // MARK: - Removing cloud data

    /// Deletes only `devices/<thisDeviceID>/`. Assets stay: another Mac's items
    /// may point at them.
    func removeThisDeviceFromCloud() {
        guard let dir = ownDeviceDir else { return }
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.removeCoordinated(dir)
                self.onMain {
                    self.lastPush = nil
                    SettingsManager.shared.syncLastPush = nil
                }
            } catch {
                self.report("Could not remove this device's cloud copy: \(error.localizedDescription)")
            }
        }
    }

    /// Deletes the whole `Klip/` folder from iCloud Drive — every device's
    /// snapshot and every synced asset. The local history is untouched.
    func removeAllCloudData() {
        guard let root = klipRoot else { return }
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.removeCoordinated(root)
                self.onMain {
                    self.lastPush = nil
                    self.lastPull = nil
                    self.otherDevices = []
                    SettingsManager.shared.syncLastPush = nil
                    SettingsManager.shared.syncLastPull = nil
                }
            } catch {
                self.report("Could not remove Klip's iCloud Drive folder: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Cloud file formats

    struct DeviceStamp: Codable {
        var id: String
        var name: String
        var lastPush: Date
    }

    /// Every cloud file carries the schema version it was written with, and
    /// every read enforces it (4B #7).
    protocol CloudFile: Decodable {
        var version: Int { get }
    }

    struct HistoryFile: Codable, CloudFile {
        var version: Int
        var device: DeviceStamp
        var items: [ClipboardItem]
    }

    struct FoldersFile: Codable, CloudFile {
        var version: Int
        var folders: [Folder]
    }

    struct TombstonesFile: Codable, CloudFile {
        var version: Int
        var deleted: [SyncTombstone]
        var deletedFolders: [SyncTombstone]
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    /// Reads and decodes a cloud file. A missing file is `nil` without noise; a
    /// corrupt one is `nil` **with** a warning and is otherwise ignored, so one
    /// bad file never takes sync down.
    private func decodeCloudFile<T: CloudFile>(_ url: URL, label: String) -> T? {
        guard cloudFileExists(url) else { return nil }
        guard let data = readCoordinated(url) else {
            report("Could not read \(label) from iCloud Drive; will retry.")
            return nil
        }
        do {
            let decoded = try JSONDecoder().decode(T.self, from: data)
            // 4B #7: a snapshot written by a newer Klip is ignored rather than
            // half-decoded. Logged once per run so a Mac that upgraded first
            // does not spam the console on every poll.
            guard decoded.version <= Self.schemaVersion else {
                if !didWarnAboutNewerSchema {
                    didWarnAboutNewerSchema = true
                    report("Ignoring \(label): it was written by a newer version of Klip (schema v\(decoded.version)). Update Klip on this Mac to sync it.")
                }
                return nil
            }
            return decoded
        } catch {
            report("Ignoring unreadable \(label) in iCloud Drive: \(error.localizedDescription)")
            return nil
        }
    }

    /// One "a newer Klip wrote this" warning per run.
    private var didWarnAboutNewerSchema = false

    // MARK: - Coordinated file I/O

    /// Creates `Klip/` and its subdirectories **inside an existing** iCloud
    /// Drive container. Never creates the container itself (4B #10): when
    /// `com~apple~CloudDocs` is not there, iCloud Drive is off and a
    /// `withIntermediateDirectories` create would silently manufacture a
    /// look-alike local folder that is not synced by anything.
    private func ensureCloudDirectories() {
        guard isAvailable else { return }
        guard let klipRoot = klipRoot, let devicesRoot = devicesRoot, let ownDeviceDir = ownDeviceDir else { return }
        try? createDirectory(klipRoot)
        try? createDirectory(devicesRoot)
        try? createDirectory(ownDeviceDir)
        for kind in [AssetKind.images, .texts, .files, .flavors] {
            if let dir = cloudAssetDir(kind) { try? createDirectory(dir) }
        }
    }

    private func createDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func writeCoordinated(_ data: Data, to url: URL) throws {
        var coordinatorError: NSError?
        var writeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url,
            options: .forReplacing,
            error: &coordinatorError
        ) { target in
            do {
                try data.write(to: target, options: .atomic)
            } catch {
                writeError = error
            }
        }
        if let error = coordinatorError ?? writeError { throw error }
    }

    private func readCoordinated(_ url: URL) -> Data? {
        var coordinatorError: NSError?
        var data: Data?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url,
            options: .withoutChanges,
            error: &coordinatorError
        ) { target in
            data = try? Data(contentsOf: target)
        }
        return data
    }

    private func removeCoordinated(_ url: URL) throws {
        var coordinatorError: NSError?
        var removeError: Error?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url,
            options: .forDeleting,
            error: &coordinatorError
        ) { target in
            do {
                if fileManager.fileExists(atPath: target.path) {
                    try fileManager.removeItem(at: target)
                }
            } catch {
                removeError = error
            }
        }
        if let error = coordinatorError ?? removeError { throw error }
    }

    /// True when the file is there, including when iCloud has only the
    /// placeholder so far — in which case the download is kicked off so the
    /// next cycle finds real bytes.
    private func cloudFileExists(_ url: URL) -> Bool {
        if fileManager.fileExists(atPath: url.path) {
            try? fileManager.startDownloadingUbiquitousItem(at: url)
            return true
        }
        // Not-yet-downloaded items appear as `.name.icloud` placeholders.
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        if fileManager.fileExists(atPath: placeholder.path) {
            try? fileManager.startDownloadingUbiquitousItem(at: url)
            return false
        }
        return false
    }

    /// Copies a file (or directory) with a hard timeout. A copy that has not
    /// finished in `fileTimeout` is abandoned and retried on the next cycle —
    /// reading a file iCloud has not materialised can otherwise block for
    /// minutes, and this queue must stay responsive.
    private func copyWithTimeout(from source: URL, to destination: URL, timeout: TimeInterval? = nil) -> Bool {
        let limit = timeout ?? Self.fileTimeout
        let semaphore = DispatchSemaphore(value: 0)
        var succeeded = false
        copyQueue.async {
            let fileManager = FileManager.default
            var coordinatorError: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(
                readingItemAt: source,
                options: .withoutChanges,
                error: &coordinatorError
            ) { target in
                do {
                    if fileManager.fileExists(atPath: destination.path) {
                        succeeded = true
                    } else {
                        try fileManager.copyItem(at: target, to: destination)
                        succeeded = true
                    }
                } catch {
                    succeeded = false
                }
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + limit) == .timedOut {
            return false
        }
        return succeeded
    }

    private func byteSize(of url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
        var total: Int64 = 0
        if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let child as URL in enumerator {
                let size = (try? child.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                total += Int64(size)
            }
        }
        return total
    }

    // MARK: - Asset mapping

    private struct AssetPair {
        let local: URL
        let cloud: URL
        /// True for a `.file` clip's copied-in payload — the thing the size cap
        /// and `syncSkippedLarge` are about.
        let isAttachmentPayload: Bool
    }

    /// Every on-disk asset an item owns, paired with its write-once cloud
    /// location. Keyed by uuid throughout, so two devices writing the same asset
    /// write identical bytes to the same path.
    private func assets(for item: ClipboardItem, store: ClipboardStore) -> [AssetPair] {
        var pairs: [AssetPair] = []

        if let filename = item.imageFilename, let dir = cloudAssetDir(.images) {
            pairs.append(AssetPair(
                local: store.syncImagesDirectory.appendingPathComponent(filename),
                cloud: dir.appendingPathComponent(filename),
                isAttachmentPayload: false
            ))
        }
        if let filename = item.textFilename, let dir = cloudAssetDir(.texts) {
            pairs.append(AssetPair(
                local: store.syncTextsDirectory.appendingPathComponent(filename),
                cloud: dir.appendingPathComponent(filename),
                isAttachmentPayload: false
            ))
        }
        if let filename = item.rtfFilename, let dir = cloudAssetDir(.texts) {
            pairs.append(AssetPair(
                local: store.syncTextsDirectory.appendingPathComponent(filename),
                cloud: dir.appendingPathComponent(filename),
                isAttachmentPayload: false
            ))
        }
        if let filename = item.flavorsFilename, let dir = cloudAssetDir(.flavors) {
            pairs.append(AssetPair(
                local: store.syncFlavorsDirectory.appendingPathComponent(filename),
                cloud: dir.appendingPathComponent(filename),
                isAttachmentPayload: false
            ))
        }
        // Copied-in file payloads live in their own per-item directory, which is
        // copied whole.
        if let attachment = item.fileAttachment, attachment.storedRelativePath != nil,
           let dir = cloudAssetDir(.files) {
            let name = item.id.uuidString
            pairs.append(AssetPair(
                local: store.syncFilesDirectory.appendingPathComponent(name, isDirectory: true),
                cloud: dir.appendingPathComponent(name, isDirectory: true),
                isAttachmentPayload: true
            ))
        }
        return pairs
    }

    // MARK: - Threading helpers

    /// Runs `body` on the main actor: inline when already there, asynchronously
    /// otherwise. The closure is `@MainActor` so touching the store or
    /// `SettingsManager` from it is statically correct even though the caller
    /// is usually `ioQueue`.
    private func onMain(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
        }
    }

    /// Main-actor read that the caller waits for. Never deadlocks: called from
    /// the main thread it just runs inline.
    private func onMainSync<R>(_ body: @MainActor () -> R) -> R {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { body() }
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { body() } }
    }

    private func report(_ message: String) {
        print("[Klip] Sync: \(message)")
        onMain { self.lastError = message }
    }
}
