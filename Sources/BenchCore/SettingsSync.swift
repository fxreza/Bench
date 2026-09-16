import Foundation
import Combine

/// Something outside `UserDefaults` that should travel with the settings —
/// Lingo's API key file, for instance. Registered with
/// `SettingsSync.shared.register(_:)`; every call is made on the main actor.
///
/// A contributor's keys are namespaced like defaults keys (`lingo.secret.x`)
/// and must never collide with a real defaults key: the sync treats a key as
/// belonging to whichever contributor claims it, and to `UserDefaults`
/// otherwise. Post `.benchSyncedExtrasChanged` after changing a value so the
/// next push picks it up.
@MainActor
public protocol SettingsSyncContributor: AnyObject {
    var settingsSyncKeys: [String] { get }
    /// The current value (a property-list type), or `nil` when unset.
    func settingsSyncValue(forKey key: String) -> Any?
    /// A value arriving from another Mac; `nil` means it was removed there.
    func applySettingsSyncValue(_ value: Any?, forKey key: String)
}

/// iCloud Drive sync of the app's preferences, every module's included.
///
/// The local `UserDefaults` domain stays authoritative. This service mirrors
/// the synced part of it into
/// `iCloud Drive/Bench/Settings/devices/<deviceID>/settings.plist` and merges
/// what the other Macs put there, key by key:
///
/// ```
/// Bench/Settings/
///   devices/<deviceID>/settings.plist
///     version, device {id, name, pushedAt},
///     entries { key: {v: value, m: modified, o: origin device, d: deleted} }
/// ```
///
/// Each Mac only ever writes its own `devices/<id>/` file, so two Macs can
/// never clobber one another. An entry is a fact, "key was set to `v` at time
/// `m` on device `o`" (or removed, when `d` is true), and the merge rule is
/// the same everywhere: for each key, the entry with the latest `m` wins,
/// with `o` breaking a tie, so every Mac converges on the same answer no
/// matter the order it sees the files in.
///
/// Local edits are noticed through `UserDefaults.didChangeNotification` and
/// stamped with the time they were seen; that stamp, per key, lives in a
/// small state file next to the app's data so it survives relaunches.
///
/// What syncs: every key under a module prefix (`bench.`, `shot.`, `klip.`,
/// `lingo.`, `snap.`, `piko.`, `tap.`) except the handful that describe this
/// Mac rather than the user's choices (`excludedKeys`), plus whatever the
/// registered contributors offer. Modules observe
/// `.benchSettingsSyncApplied` and re-read their keys when a remote value
/// lands, so a change made on one Mac shows up live on the other.
///
/// Threading: cloud reads and writes happen on `ioQueue`; everything that
/// touches `state` or `UserDefaults` runs on the main actor.
@MainActor
public final class SettingsSync: ObservableObject {
    /// The app-wide instance. `AppDelegate` starts it after the features;
    /// Settings > General observes it. Tests build their own instances.
    public static let shared = SettingsSync()

    // MARK: - Keys

    public enum Key {
        public static let enabled = "bench.settingsSync.enabled"
        public static let deviceID = "bench.settingsSync.deviceID"
        public static let deviceName = "bench.settingsSync.deviceName"
        public static let lastPush = "bench.settingsSync.lastPush"
        public static let lastPull = "bench.settingsSync.lastPull"
    }

    /// Every defaults key under one of these travels, unless excluded below.
    public static let syncedPrefixes = ["bench.", "shot.", "klip.", "lingo.", "snap.", "piko.", "tap."]

    /// Keys that describe this Mac, not the user's choices: identities,
    /// timestamps, one-time import and migration flags, update bookkeeping.
    /// Each Mac keeps its own.
    public static let excludedKeys: Set<String> = [
        "bench.hasCompletedOnboarding", "bench.suppressStandaloneQuitPrompt",
        "bench.lastUpdateCheckDate", "bench.justUpdated", "bench.updateNotes", "bench.updateTag",
        "klip.sync.enabled", "klip.sync.deviceID", "klip.sync.deviceName",
        "klip.sync.lastPush", "klip.sync.lastPull",
        "klip.importedFromKlip", "klip.importedHotkeyFromKlip",
        "shot.importedFromSnapper", "shot.hotkeys",
        "lingo.importedFromTransi", "lingo.importedHistoryFromTransi",
        "lingo.importedShortcutsFromTransi", "lingo.didResetStickySourceLanguage",
        "piko.importedFromPiko",
    ]

    /// Prefixes that never travel: the sync's own switch and identity.
    public static let excludedPrefixes = ["bench.settingsSync."]

    /// Whether a defaults key takes part in sync.
    public static func isSynced(_ key: String) -> Bool {
        guard syncedPrefixes.contains(where: { key.hasPrefix($0) }) else { return false }
        guard !excludedKeys.contains(key) else { return false }
        return !excludedPrefixes.contains(where: { key.hasPrefix($0) })
    }

    // MARK: - Status

    public struct DeviceInfo: Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let lastPush: Date
    }

    @Published public private(set) var lastPush: Date?
    @Published public private(set) var lastPull: Date?
    /// Other Macs seen in the cloud folder, newest push first.
    @Published public private(set) var otherDevices: [DeviceInfo] = []
    @Published public private(set) var isBusy = false
    /// Last failure, shown under the toggle. `nil` when the last cycle worked.
    @Published public private(set) var lastError: String?

    /// The master switch. Writing it starts or stops the service.
    @Published public var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Key.enabled)
            settingChanged()
        }
    }

    /// Shown for this Mac in the other Macs' status line.
    @Published public var deviceName: String {
        didSet {
            guard deviceName != oldValue else { return }
            defaults.set(deviceName, forKey: Key.deviceName)
            schedulePush()
        }
    }

    public var isAvailable: Bool {
        guard let cloudRoot else { return false }
        return FileManager.default.fileExists(atPath: cloudRoot.path)
    }

    public var unavailableReason: String? {
        isAvailable ? nil : CloudDrive.unavailableReason
    }

    public var isActive: Bool { isRunning }

    // MARK: - Configuration

    public let deviceID: String
    private let defaults: UserDefaults
    /// The persistent domain `defaults` is backed by. Only keys actually
    /// stored there are synced, never values from `register(defaults:)`.
    private let domainName: String
    /// The iCloud Drive container, or a stand-in.
    let cloudRoot: URL?
    private let stateFile: URL
    private var contributors: [SettingsSyncContributor] = []

    // Derived from `let`s only, so the I/O queue can read them too.
    nonisolated var settingsRoot: URL? { cloudRoot.map { CloudDrive.folder(named: "Settings", in: $0) } }
    nonisolated private var devicesRoot: URL? { settingsRoot?.appendingPathComponent("devices", isDirectory: true) }
    nonisolated private var ownDeviceDir: URL? { devicesRoot?.appendingPathComponent(deviceID, isDirectory: true) }
    nonisolated private var ownFile: URL? { ownDeviceDir?.appendingPathComponent(Self.fileName) }

    nonisolated static let fileName = "settings.plist"
    nonisolated static let schemaVersion = 1

    /// Debounce after a local change before pushing (a burst of edits
    /// collapses into one push).
    public static let pushDebounceInterval: TimeInterval = 2.0
    /// Debounce after a directory-change event before pulling.
    public static let pullDebounceInterval: TimeInterval = 1.0
    /// Fallback poll, for the case where the `DispatchSource` misses an event.
    public static let pollInterval: TimeInterval = 60.0
    /// Per-file cloud read timeout. A file iCloud has not materialised yet is
    /// left for the next cycle rather than blocking the queue.
    nonisolated static let fileTimeout: TimeInterval = 20.0

    // MARK: - State

    /// One synced key as last seen: its value, when it was last set, and on
    /// which Mac. `value == nil` is a tombstone: the key was removed.
    ///
    /// `modified` is whole milliseconds since 1970: an integer survives every
    /// plist round trip exactly, where a `Date` or a `Double` can come back a
    /// few bits off and make one Mac's own entry look "newer" than itself.
    struct Entry {
        var value: Any?
        var modified: Int64
        var origin: String

        var isDeleted: Bool { value == nil }
        var modifiedDate: Date { Date(timeIntervalSince1970: Double(modified) / 1000) }

        /// Later edit wins; equal times fall back to the origin id so every
        /// Mac picks the same one.
        func isNewer(than other: Entry) -> Bool {
            if modified != other.modified { return modified > other.modified }
            return origin > other.origin
        }
    }

    /// The last known state of every synced key, tombstones included.
    private var state: [String: Entry] = [:]
    private var stateLoaded = false

    private let ioQueue = DispatchQueue(label: "com.fxreza.bench.settingsSync.io", qos: .utility)
    private let readQueue = DispatchQueue(label: "com.fxreza.bench.settingsSync.read", qos: .utility, attributes: .concurrent)

    private var isRunning = false
    private var pushDebounce: DispatchWorkItem?
    private var pullDebounce: DispatchWorkItem?
    private var rootWatcher: DispatchSourceFileSystemObject?
    private var deviceWatchers: [String: DispatchSourceFileSystemObject] = [:]
    private var pollTimer: Timer?
    private var lastRemoteFingerprint: String?
    private var defaultsObserver: NSObjectProtocol?
    private var extrasObserver: NSObjectProtocol?

    // MARK: - Init

    /// - Parameters:
    ///   - defaults: the preferences to sync; `BenchDefaults.standard` in the app.
    ///   - domainName: its persistent domain (`BenchDefaults.domainName`).
    ///   - cloudRoot: the iCloud Drive container; `CloudDrive.containerRoot`
    ///     in the app, a temp folder in tests.
    ///   - stateDirectory: where the per-key timestamps are kept.
    ///   - deviceID / deviceName: this Mac's identity; read from `defaults`
    ///     (minted once) when nil.
    public init(
        defaults: UserDefaults = BenchDefaults.standard,
        domainName: String = BenchDefaults.domainName,
        cloudRoot: URL? = CloudDrive.containerRoot,
        stateDirectory: URL = BenchPaths.dataDirectory(feature: "SettingsSync"),
        deviceID: String? = nil,
        deviceName: String? = nil
    ) {
        self.defaults = defaults
        self.domainName = domainName
        self.cloudRoot = cloudRoot
        self.stateFile = stateDirectory.appendingPathComponent("sync-state.plist")

        if let deviceID {
            self.deviceID = deviceID
        } else if let stored = defaults.string(forKey: Key.deviceID), !stored.isEmpty {
            self.deviceID = stored
        } else {
            let fresh = UUID().uuidString
            defaults.set(fresh, forKey: Key.deviceID)
            self.deviceID = fresh
        }
        if let deviceName {
            self.deviceName = deviceName
        } else if let stored = defaults.string(forKey: Key.deviceName), !stored.isEmpty {
            self.deviceName = stored
        } else {
            self.deviceName = Self.defaultDeviceName
        }
        self.isEnabled = defaults.bool(forKey: Key.enabled)
        self.lastPush = defaults.object(forKey: Key.lastPush) as? Date
        self.lastPull = defaults.object(forKey: Key.lastPull) as? Date
    }

    deinit {
        rootWatcher?.cancel()
        for watcher in deviceWatchers.values { watcher.cancel() }
        pollTimer?.invalidate()
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        if let extrasObserver { NotificationCenter.default.removeObserver(extrasObserver) }
    }

    public static var defaultDeviceName: String {
        let name = Host.current().localizedName ?? ""
        return name.isEmpty ? "This Mac" : name
    }

    /// Adds a source of extra synced values. Register before `startIfEnabled()`.
    public func register(_ contributor: SettingsSyncContributor) {
        contributors.append(contributor)
    }

    private func contributor(for key: String) -> SettingsSyncContributor? {
        contributors.first { $0.settingsSyncKeys.contains(key) }
    }

    // MARK: - Lifecycle

    /// Starts sync when it is both enabled and available, and keeps listening
    /// for local changes either way so the toggle can start it later.
    public func startIfEnabled() {
        if defaultsObserver == nil {
            defaultsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.localDefaultsChanged() }
            }
        }
        if extrasObserver == nil {
            extrasObserver = NotificationCenter.default.addObserver(
                forName: .benchSyncedExtrasChanged, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.localDefaultsChanged() }
            }
        }
        settingChanged()
    }

    private func settingChanged() {
        if isEnabled && isAvailable {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        guard !isRunning, isAvailable else { return }
        isRunning = true
        lastError = nil
        loadStateIfNeeded()

        ioQueue.async { [weak self] in
            guard let self else { return }
            self.ensureCloudDirectories()
            let remote = self.readRemoteSnapshots()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.isRunning else { return }
                    // Order matters on a Mac joining an existing set: with no
                    // entries of its own yet, every remote value is adopted
                    // first, and only the keys the other Macs never had are
                    // then stamped as this Mac's own edits.
                    self.merge(remote)
                    self.detectLocalChanges()
                    self.performPush()
                    self.startWatching()
                }
            }
        }
    }

    /// Stops watching. The cloud copy is left in place; removing it is an
    /// explicit user action.
    public func stop() {
        isRunning = false
        pushDebounce?.cancel()
        pushDebounce = nil
        pullDebounce?.cancel()
        pullDebounce = nil
        stopWatching()
    }

    /// User-facing "Sync now": a pull followed by a push.
    public func syncNow() {
        guard isAvailable else { return }
        loadStateIfNeeded()
        isBusy = true
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.ensureCloudDirectories()
            let remote = self.readRemoteSnapshots()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.merge(remote)
                    self.detectLocalChanges()
                    self.performPush { self.isBusy = false }
                }
            }
        }
    }

    /// Stops watching and gets the last local edits into iCloud Drive before
    /// the process goes away, waiting at most `budget` seconds.
    public func stopAndFlush(budget: TimeInterval = 2.0) {
        guard isRunning else { return }
        let pending = pushDebounce != nil
        stop()
        let changed = detectLocalChanges()
        guard pending || changed else { return }
        _ = pushSynchronously(budget: budget)
    }

    // MARK: - Synchronous entry points (quit, tests)

    /// Notices local edits and writes this Mac's file, on the calling thread
    /// but bounded by `budget` when given. Returns false when nothing could
    /// be written.
    @discardableResult
    public func pushSynchronously(budget: TimeInterval? = nil) -> Bool {
        guard isAvailable else { return false }
        loadStateIfNeeded()
        detectLocalChanges()
        pushDebounce?.cancel()
        pushDebounce = nil
        guard let data = ownFileData(), let ownFile else { return false }
        ensureCloudDirectories()
        let done = DispatchSemaphore(value: 0)
        var ok = false
        readQueue.async {
            ok = Self.writeCoordinated(data, to: ownFile)
            done.signal()
        }
        if let budget {
            guard done.wait(timeout: .now() + budget) == .success else { return false }
        } else {
            done.wait()
        }
        if ok { markPushed() }
        return ok
    }

    /// Reads every other Mac's file and applies what is newer, on the calling
    /// thread. Returns the keys that changed locally.
    @discardableResult
    public func pullSynchronously() -> [String] {
        guard isAvailable else { return [] }
        loadStateIfNeeded()
        ensureCloudDirectories()
        let remote = readRemoteSnapshots()
        return merge(remote)
    }

    /// Stamps any local edit made since the last look. Tests call this in
    /// place of the `UserDefaults.didChangeNotification` round trip.
    public func noteLocalChanges() {
        loadStateIfNeeded()
        detectLocalChanges()
    }

    /// Injects a status for previews and offscreen renders.
    public func previewState(lastPush: Date?, lastPull: Date?, devices: [DeviceInfo]) {
        self.lastPush = lastPush
        self.lastPull = lastPull
        self.otherDevices = devices
    }

    // MARK: - Local changes

    private func localDefaultsChanged() {
        guard isRunning else { return }
        detectLocalChanges()
    }

    /// The synced part of the defaults domain plus the contributors' values.
    private func currentValues() -> [String: Any] {
        var values: [String: Any] = [:]
        if let domain = defaults.persistentDomain(forName: domainName) {
            for (key, value) in domain where Self.isSynced(key) {
                values[key] = value
            }
        }
        for contributor in contributors {
            for key in contributor.settingsSyncKeys {
                if let value = contributor.settingsSyncValue(forKey: key) {
                    values[key] = value
                }
            }
        }
        return values
    }

    nonisolated static func stamp(_ date: Date = Date()) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    /// Compares the live values with `state` and stamps every difference
    /// with now and this Mac. Schedules a push when anything moved.
    @discardableResult
    private func detectLocalChanges() -> Bool {
        let now = Self.stamp()
        let live = currentValues()
        var changed = false
        for (key, value) in live {
            if let known = state[key], !known.isDeleted, Self.valuesEqual(known.value, value) { continue }
            state[key] = Entry(value: value, modified: now, origin: deviceID)
            changed = true
        }
        for (key, known) in state where !known.isDeleted && live[key] == nil {
            state[key] = Entry(value: nil, modified: now, origin: deviceID)
            changed = true
        }
        if changed {
            saveState()
            if isRunning { schedulePush() }
        }
        return changed
    }

    /// Property-list values compare through Foundation so numbers, strings,
    /// data, dates, arrays and dictionaries all work.
    nonisolated static func valuesEqual(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case let (x?, y?): return (x as AnyObject).isEqual(y as AnyObject)
        }
    }

    // MARK: - Merge

    /// Applies every remote entry that is newer than what this Mac knows.
    /// Returns the keys whose local value changed.
    @discardableResult
    private func merge(_ snapshots: [RemoteSnapshot]) -> [String] {
        var applied: [String] = []
        var devices: [DeviceInfo] = []
        for snapshot in snapshots {
            devices.append(DeviceInfo(id: snapshot.deviceID, name: snapshot.deviceName, lastPush: snapshot.pushedAt))
            for (key, remote) in snapshot.entries {
                let isExtra = contributor(for: key) != nil
                guard isExtra || Self.isSynced(key) else { continue }
                if let local = state[key], !remote.isNewer(than: local) { continue }
                state[key] = remote
                if isExtra {
                    contributor(for: key)?.applySettingsSyncValue(remote.value, forKey: key)
                } else if let value = remote.value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
                applied.append(key)
            }
        }
        otherDevices = devices.sorted { $0.lastPush > $1.lastPush }
        if !snapshots.isEmpty || lastPull == nil {
            lastPull = Date()
            defaults.set(lastPull, forKey: Key.lastPull)
        }
        if !applied.isEmpty {
            saveState()
            NotificationCenter.default.post(
                name: .benchSettingsSyncApplied, object: self, userInfo: ["keys": applied.sorted()])
        }
        return applied
    }

    // MARK: - Push

    private func schedulePush() {
        pushDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pushDebounce = nil
                self?.performPush()
            }
        }
        pushDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pushDebounceInterval, execute: work)
    }

    private func performPush(completion: (() -> Void)? = nil) {
        guard isAvailable, let ownFile, let data = ownFileData() else {
            completion?()
            return
        }
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.ensureCloudDirectories()
            let ok = Self.writeCoordinated(data, to: ownFile)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if ok {
                        self.markPushed()
                    } else {
                        self.lastError = "Could not write this Mac's settings to iCloud Drive."
                    }
                    completion?()
                }
            }
        }
    }

    private func markPushed() {
        lastPush = Date()
        defaults.set(lastPush, forKey: Key.lastPush)
        lastError = nil
    }

    /// This Mac's whole file, serialised on the main actor so the I/O queue
    /// never touches `state`.
    private func ownFileData() -> Data? {
        var entries: [String: Any] = [:]
        for (key, entry) in state {
            entries[key] = Self.encode(entry)
        }
        let plist: [String: Any] = [
            "version": Self.schemaVersion,
            "device": ["id": deviceID, "name": deviceName, "pushedAt": Date()],
            "entries": entries,
        ]
        return try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    nonisolated static func encode(_ entry: Entry) -> [String: Any] {
        var dict: [String: Any] = ["m": entry.modified, "o": entry.origin]
        if let value = entry.value {
            dict["v"] = value
        } else {
            dict["d"] = true
        }
        return dict
    }

    nonisolated static func decode(_ dict: [String: Any]) -> Entry? {
        guard let modified = (dict["m"] as? NSNumber)?.int64Value, let origin = dict["o"] as? String else { return nil }
        if dict["d"] as? Bool == true { return Entry(value: nil, modified: modified, origin: origin) }
        guard let value = dict["v"] else { return nil }
        return Entry(value: value, modified: modified, origin: origin)
    }

    // MARK: - Pull

    struct RemoteSnapshot {
        let deviceID: String
        let deviceName: String
        let pushedAt: Date
        let entries: [String: Entry]
    }

    private func schedulePull() {
        pullDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pullDebounce = nil
                self?.performPull()
            }
        }
        pullDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pullDebounceInterval, execute: work)
    }

    private func performPull() {
        guard isRunning, isAvailable else { return }
        ioQueue.async { [weak self] in
            guard let self else { return }
            let remote = self.readRemoteSnapshots()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.isRunning else { return }
                    self.merge(remote)
                    self.refreshDeviceWatchers()
                }
            }
        }
    }

    /// Every other Mac's file, parsed. A file that is still downloading is
    /// asked for and left for the next cycle; a corrupt one is skipped with a
    /// log line.
    nonisolated private func readRemoteSnapshots() -> [RemoteSnapshot] {
        guard let devicesRoot else { return [] }
        var snapshots: [RemoteSnapshot] = []
        for id in Self.otherDeviceIDs(in: devicesRoot, excluding: deviceID) {
            let dir = devicesRoot.appendingPathComponent(id, isDirectory: true)
            let file = dir.appendingPathComponent(Self.fileName)
            let fm = FileManager.default
            if !fm.fileExists(atPath: file.path) {
                let placeholder = dir.appendingPathComponent(".\(Self.fileName).icloud")
                if fm.fileExists(atPath: placeholder.path) {
                    try? fm.startDownloadingUbiquitousItem(at: file)
                }
                continue
            }
            guard let data = readWithTimeout(file) else { continue }
            guard let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
                  plist["version"] as? Int == Self.schemaVersion,
                  let device = plist["device"] as? [String: Any],
                  let deviceID = device["id"] as? String,
                  let rawEntries = plist["entries"] as? [String: Any]
            else {
                NSLog("[SettingsSync] Ignoring unreadable settings file for device \(id)")
                continue
            }
            var entries: [String: Entry] = [:]
            for (key, raw) in rawEntries {
                if let dict = raw as? [String: Any], let entry = Self.decode(dict) {
                    entries[key] = entry
                }
            }
            snapshots.append(RemoteSnapshot(
                deviceID: deviceID,
                deviceName: device["name"] as? String ?? deviceID,
                pushedAt: device["pushedAt"] as? Date ?? .distantPast,
                entries: entries))
        }
        return snapshots
    }

    nonisolated static func otherDeviceIDs(in devicesRoot: URL, excluding own: String) -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: devicesRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { $0.lastPathComponent }
            .filter { $0 != own }
            .sorted()
    }

    /// A coordinated read that gives up after `fileTimeout`: reading a file
    /// iCloud has not finished downloading can block for a long time.
    nonisolated private func readWithTimeout(_ url: URL) -> Data? {
        let done = DispatchSemaphore(value: 0)
        var result: Data?
        readQueue.async {
            var coordinatorError: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinatorError) { target in
                result = try? Data(contentsOf: target)
            }
            done.signal()
        }
        guard done.wait(timeout: .now() + Self.fileTimeout) == .success else {
            NSLog("[SettingsSync] Timed out reading \(url.lastPathComponent); will retry.")
            return nil
        }
        return result
    }

    // MARK: - Watching

    private func startWatching() {
        stopWatching()
        guard let devicesRoot else { return }
        rootWatcher = makeWatcher(for: devicesRoot) { [weak self] in
            self?.schedulePull()
            self?.refreshDeviceWatchers()
        }
        refreshDeviceWatchers()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollForRemoteChanges() }
        }
    }

    private func stopWatching() {
        rootWatcher?.cancel()
        rootWatcher = nil
        for watcher in deviceWatchers.values { watcher.cancel() }
        deviceWatchers.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func makeWatcher(for url: URL, onChange: @escaping () -> Void) -> DispatchSourceFileSystemObject? {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { onChange() } }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }

    /// One watcher per other Mac's directory: writing `devices/<id>/settings.plist`
    /// does not change `devices/` itself, so the root watcher alone would
    /// only ever see Macs appearing and disappearing.
    private func refreshDeviceWatchers() {
        guard isRunning, let devicesRoot else { return }
        let ids = Set(Self.otherDeviceIDs(in: devicesRoot, excluding: deviceID))
        for id in deviceWatchers.keys where !ids.contains(id) {
            deviceWatchers[id]?.cancel()
            deviceWatchers[id] = nil
        }
        for id in ids where deviceWatchers[id] == nil {
            let dir = devicesRoot.appendingPathComponent(id, isDirectory: true)
            deviceWatchers[id] = makeWatcher(for: dir) { [weak self] in
                guard let self else { return }
                self.schedulePull()
                // An atomic replace can retire the directory's descriptor;
                // rebuilding it is cheap and keeps the watch alive.
                self.deviceWatchers[id]?.cancel()
                self.deviceWatchers[id] = nil
                self.refreshDeviceWatchers()
            }
        }
    }

    private func pollForRemoteChanges() {
        guard isRunning, let devicesRoot else { return }
        ioQueue.async { [weak self] in
            guard let self else { return }
            let fingerprint = Self.fingerprint(of: devicesRoot)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard fingerprint != self.lastRemoteFingerprint else { return }
                    self.lastRemoteFingerprint = fingerprint
                    self.performPull()
                }
            }
        }
    }

    nonisolated static func fingerprint(of devicesRoot: URL) -> String {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: devicesRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return dirs.sorted { $0.path < $1.path }.map { dir -> String in
            let file = dir.appendingPathComponent(fileName)
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return "\(dir.lastPathComponent):\(date.timeIntervalSince1970)"
        }.joined(separator: "|")
    }

    // MARK: - Removing cloud data

    /// Deletes only `devices/<thisDeviceID>/`.
    public func removeThisDeviceFromCloud() {
        guard let dir = ownDeviceDir else { return }
        ioQueue.async { [weak self] in
            guard let self else { return }
            let ok = Self.removeCoordinated(dir)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if ok {
                        self.lastPush = nil
                        self.defaults.removeObject(forKey: Key.lastPush)
                    } else {
                        self.lastError = "Could not remove this Mac's settings from iCloud Drive."
                    }
                }
            }
        }
    }

    /// Deletes the whole `Bench/Settings/` folder from iCloud Drive. The
    /// settings on this Mac are untouched.
    public func removeAllCloudData() {
        guard let root = settingsRoot else { return }
        ioQueue.async { [weak self] in
            guard let self else { return }
            let ok = Self.removeCoordinated(root)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if ok {
                        self.lastPush = nil
                        self.lastPull = nil
                        self.otherDevices = []
                        self.defaults.removeObject(forKey: Key.lastPush)
                        self.defaults.removeObject(forKey: Key.lastPull)
                    } else {
                        self.lastError = "Could not remove the Settings folder from iCloud Drive."
                    }
                }
            }
        }
    }

    // MARK: - State file

    private func loadStateIfNeeded() {
        guard !stateLoaded else { return }
        stateLoaded = true
        guard let data = try? Data(contentsOf: stateFile),
              let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let raw = plist["entries"] as? [String: Any]
        else { return }
        for (key, value) in raw {
            if let dict = value as? [String: Any], let entry = Self.decode(dict) {
                state[key] = entry
            }
        }
    }

    private func saveState() {
        var entries: [String: Any] = [:]
        for (key, entry) in state { entries[key] = Self.encode(entry) }
        let plist: [String: Any] = ["version": Self.schemaVersion, "entries": entries]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0) else { return }
        try? FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: stateFile, options: .atomic)
    }

    // MARK: - Cloud file I/O

    /// Creates `Bench/Settings/devices/<id>/` **inside an existing** iCloud
    /// Drive container. Never creates the container itself: when it is not
    /// there, iCloud Drive is off, and a blind create would manufacture a
    /// look-alike local folder that nothing syncs.
    nonisolated private func ensureCloudDirectories() {
        guard let cloudRoot, FileManager.default.fileExists(atPath: cloudRoot.path) else { return }
        guard let ownDeviceDir else { return }
        try? FileManager.default.createDirectory(at: ownDeviceDir, withIntermediateDirectories: true)
    }

    nonisolated static func writeCoordinated(_ data: Data, to url: URL) -> Bool {
        var coordinatorError: NSError?
        var ok = false
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: .forReplacing, error: &coordinatorError
        ) { target in
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
                ok = true
            } catch {
                NSLog("[SettingsSync] Write failed: \(error)")
            }
        }
        return ok && coordinatorError == nil
    }

    nonisolated static func removeCoordinated(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        var coordinatorError: NSError?
        var ok = false
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: .forDeleting, error: &coordinatorError
        ) { target in
            do {
                try FileManager.default.removeItem(at: target)
                ok = true
            } catch {
                NSLog("[SettingsSync] Remove failed: \(error)")
            }
        }
        return ok && coordinatorError == nil
    }
}

// MARK: - Observing applied changes

public extension SettingsSync {
    /// Calls `handler` on the main actor whenever a remote value for a key
    /// starting with `prefix` has just been written to `UserDefaults`, with
    /// the affected keys. The store that owns the prefix re-reads them.
    static func observeApplied(prefix: String, handler: @escaping @MainActor ([String]) -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: .benchSettingsSyncApplied, object: nil, queue: .main
        ) { note in
            let keys = (note.userInfo?["keys"] as? [String] ?? []).filter { $0.hasPrefix(prefix) }
            guard !keys.isEmpty else { return }
            MainActor.assumeIsolated { handler(keys) }
        }
    }
}

// MARK: - Status line

/// The one-line sync summary, as a pure function so it can be tested without
/// SwiftUI: "Last push 2 min ago · last pull 1 min ago · 2 devices:
/// MacBook, Studio".
public enum CloudSyncStatusLine {
    public static func text(
        enabled: Bool,
        available: Bool,
        lastPush: Date?,
        lastPull: Date?,
        devices: [String],
        now: Date = Date()
    ) -> String {
        guard available else { return "iCloud Drive is not available on this Mac." }
        guard enabled else { return "Sync is off." }

        var parts: [String] = []
        parts.append(lastPush.map { "Last push \(ago(from: $0, to: now))" } ?? "Not pushed yet")
        parts.append(lastPull.map { "last pull \(ago(from: $0, to: now))" } ?? "not pulled yet")

        if devices.isEmpty {
            parts.append("no other devices yet")
        } else {
            let noun = devices.count == 1 ? "device" : "devices"
            parts.append("\(devices.count) \(noun): \(devices.joined(separator: ", "))")
        }
        return parts.joined(separator: " · ")
    }

    /// Coarse relative time — the status line is glanced at, not read.
    public static func ago(from date: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<10: return "just now"
        case ..<60: return "\(Int(seconds)) sec ago"
        case ..<3600:
            let minutes = Int(seconds / 60)
            return "\(minutes) min ago"
        case ..<86400:
            let hours = Int(seconds / 3600)
            return "\(hours) hour\(hours == 1 ? "" : "s") ago"
        default:
            let days = Int(seconds / 86400)
            return "\(days) day\(days == 1 ? "" : "s") ago"
        }
    }
}
