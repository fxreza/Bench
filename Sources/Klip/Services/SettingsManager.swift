import Foundation
import Combine
import BenchCore

/// How long a deleted clip stays in the trash before it is purged for good.
///
/// The raw value is the number of days; `0` means "keep forever" (the trash is
/// only ever emptied by hand). Modelled on the Finder's own Recently Deleted
/// setting, which is where the 30-day default comes from.
enum TrashRetention: Int, CaseIterable, Codable {
    case days7    = 7
    case days30   = 30
    case days90   = 90
    case forever  = 0

    static let `default`: TrashRetention = .days30

    /// Retention window, or `nil` when nothing ever expires.
    var days: Int? { self == .forever ? nil : rawValue }

    var label: String {
        switch self {
        case .days7:   return "7 days"
        case .days30:  return "30 days"
        case .days90:  return "90 days"
        case .forever: return "Forever"
        }
    }

    /// Reads a stored raw value, falling back to the default for an absent or
    /// unrecognised one. A stored `0` is a deliberate "forever", not a missing
    /// key, which is why the parameter is optional rather than an `Int`.
    static func from(storedRaw raw: Int?) -> TrashRetention {
        guard let raw = raw else { return .default }
        return TrashRetention(rawValue: raw) ?? .default
    }
}

/// How many items the history keeps before the oldest unprotected one is evicted.
///
/// The raw value is the item cap and is what lands in the `historyLimit`
/// UserDefaults key; `0` means no cap at all. Buffer 2.x stored 100/500/1000
/// here, so always read stored values through `from(storedRaw:)`.
enum HistoryLimit: Int, CaseIterable, Codable {
    case k1        = 1000
    case k5        = 5000
    case k10       = 10000
    case unlimited = 0

    static let `default`: HistoryLimit = .k10

    /// Item cap, or `nil` when unlimited (never evict).
    var maxItems: Int? { self == .unlimited ? nil : rawValue }

    var isUnlimited: Bool { self == .unlimited }

    var label: String {
        switch self {
        case .k1:        return "1,000"
        case .k5:        return "5,000"
        case .k10:       return "10,000"
        case .unlimited: return "Unlimited"
        }
    }

    var subtitle: String {
        switch self {
        case .k1:        return "Lightest footprint"
        case .k5:        return "Balanced"
        case .k10:       return "Recommended"
        case .unlimited: return "Keep everything"
        }
    }

    /// Maps a stored raw value onto a tier, absorbing the legacy Buffer 2.x
    /// values (100 / 500 / 1000) and anything unrecognised.
    ///
    /// nil or absent -> `.default`; 100/500/1000 -> `.k1`; 5000 -> `.k5`;
    /// 10000 -> `.k10`; 0 -> `.unlimited`; anything else -> `.default`.
    static func from(storedRaw: Int?) -> HistoryLimit {
        guard let raw = storedRaw else { return .default }
        switch raw {
        case 100, 500, 1000: return .k1
        case 5000:           return .k5
        case 10000:          return .k10
        case 0:              return .unlimited
        default:             return .default
        }
    }
}

/// Manages user preferences for Klip. Single source of truth: every setting
/// is a `@Published` property that writes its UserDefaults key immediately
/// (via `didSet`) and posts the notification the rest of the module relies
/// on (`.bufferHistoryLimitChanged`, `.bufferTrashRetentionChanged`,
/// `.klipSyncSettingsChanged`) exactly when the value actually changes. Views
/// bind to `SettingsManager.shared` directly (`@ObservedObject`) — there is
/// no separate view-model layer and no explicit "Save" step; settings apply
/// immediately, the same way native macOS Settings behave.
///
/// `isLoaded` suppresses persistence/notifications while `init` is populating
/// properties from previously-saved values, so loading a setting is never
/// mistaken for the user changing it.
///
/// Inside Bench every key carries the `klip.` prefix (`Key.name`) and lives in
/// `BenchDefaults.standard`, next to the other modules' keys. What is *not*
/// here any more, because the app owns it: launch at login, the menu bar
/// icon, update checks, onboarding, the accent colour and light/dark choice
/// (`AppearanceSettings.shared`), and the global open-Klip hotkey
/// (`ShortcutStore.shared`, action id `klip.toggleHistory`).
@MainActor
final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    /// Every UserDefaults key this manager reads or writes, unprefixed, as
    /// the standalone Klip stored it. `KlipFeature` hands this list to
    /// `StandaloneImport` on first run; `Key.name(_:)` is the prefixed form.
    static let standaloneKeys: [String] = [
        "historyLimit", "trashRetention",
        "fontScale.list", "fontScale.preview", "appearance.showPreview",
        "sidebarCollapsed", "sidebarWidth", "previewWidth", "windowWidth", "windowHeight",
        "search.keepBetweenOpens", "window.keepOpen",
        "files.copyCapMB", "paste.alwaysPlain",
        "sync.enabled", "sync.maxAttachmentMB", "sync.kinds", "sync.deviceName",
        "sync.deviceID", "sync.lastPush", "sync.lastPull",
    ]

    enum Key {
        static let prefix = "klip."
        static func name(_ unprefixed: String) -> String { prefix + unprefixed }
    }

    private let defaults = BenchDefaults.standard
    private var isLoaded = false

    // Prefixed accessors: every read and write below goes through these, so
    // the `klip.` namespace is applied in exactly one place.
    private func set(_ value: Any?, forKey key: String) {
        defaults.set(value, forKey: Key.name(key))
    }

    private func removeObject(forKey key: String) {
        defaults.removeObject(forKey: Key.name(key))
    }

    private func object(forKey key: String) -> Any? {
        defaults.object(forKey: Key.name(key))
    }

    private func bool(forKey key: String) -> Bool {
        defaults.bool(forKey: Key.name(key))
    }

    private func string(forKey key: String) -> String? {
        defaults.string(forKey: Key.name(key))
    }

    private func array(forKey key: String) -> [Any]? {
        defaults.array(forKey: Key.name(key))
    }

    @Published var historyLimit: HistoryLimit = .default {
        didSet {
            guard isLoaded, historyLimit != oldValue else { return }
            set(historyLimit.rawValue, forKey: "historyLimit")
            NotificationCenter.default.post(name: .bufferHistoryLimitChanged, object: nil)
        }
    }
    /// How long deleted clips are kept before the trash purges them (5D).
    @Published var trashRetention: TrashRetention = .default {
        didSet {
            guard isLoaded, trashRetention != oldValue else { return }
            set(trashRetention.rawValue, forKey: "trashRetention")
            NotificationCenter.default.post(name: .bufferTrashRetentionChanged, object: nil)
        }
    }


    // MARK: - Appearance / layout (new in Phase 1C; consumed by Phase 2+)

    /// Scales list-row fonts (`fontScale.list`), range 0.8...1.6.
    @Published var listFontScale: Double = 1.0 {
        didSet {
            guard isLoaded, listFontScale != oldValue else { return }
            set(listFontScale, forKey: "fontScale.list")
        }
    }
    /// Scales preview-pane fonts (`fontScale.preview`), range 0.8...1.6.
    @Published var previewFontScale: Double = 1.0 {
        didSet {
            guard isLoaded, previewFontScale != oldValue else { return }
            set(previewFontScale, forKey: "fontScale.preview")
        }
    }
    @Published var showPreviewPane: Bool = true {
        didSet {
            guard isLoaded, showPreviewPane != oldValue else { return }
            set(showPreviewPane, forKey: "appearance.showPreview")
        }
    }
    @Published var sidebarCollapsed: Bool = false {
        didSet {
            guard isLoaded, sidebarCollapsed != oldValue else { return }
            set(sidebarCollapsed, forKey: "sidebarCollapsed")
        }
    }
    @Published var sidebarWidth: Double = 180 {
        didSet {
            guard isLoaded, sidebarWidth != oldValue else { return }
            set(sidebarWidth, forKey: "sidebarWidth")
        }
    }
    @Published var previewWidth: Double = 300 {
        didSet {
            guard isLoaded, previewWidth != oldValue else { return }
            set(previewWidth, forKey: "previewWidth")
        }
    }
    @Published var windowWidth: Double? = nil {
        didSet {
            guard isLoaded, windowWidth != oldValue else { return }
            if let windowWidth {
                set(windowWidth, forKey: "windowWidth")
            } else {
                removeObject(forKey: "windowWidth")
            }
        }
    }
    @Published var windowHeight: Double? = nil {
        didSet {
            guard isLoaded, windowHeight != oldValue else { return }
            if let windowHeight {
                set(windowHeight, forKey: "windowHeight")
            } else {
                removeObject(forKey: "windowHeight")
            }
        }
    }

    // MARK: - Window behaviour

    /// Whether the search field keeps what was typed in it between opens.
    ///
    /// Off (the default) the field is empty every single time Klip opens, so
    /// a query typed to find one clip never silently hides the rest of the
    /// history the next time round. On, the query survives until it is
    /// cleared by hand.
    ///
    /// Before this setting existed the behaviour was a fixed 90-second rule
    /// in `HistoryWindowController`: reopen inside the window and the query
    /// came back, reopen later and it did not. That was invisible and
    /// unpredictable from the outside — the same action gave two different
    /// results depending on a clock nobody could see — so the timer is gone
    /// and this switch decides it outright.
    @Published var keepSearchBetweenOpens: Bool = false {
        didSet {
            guard isLoaded, keepSearchBetweenOpens != oldValue else { return }
            set(keepSearchBetweenOpens, forKey: "search.keepBetweenOpens")
        }
    }

    /// Keep Open: the history window stays on screen after a paste, and stops
    /// closing when it loses focus.
    ///
    /// Deliberately *not* called "pin". A clip's pin (`ClipboardItem.isPinned`)
    /// floats that clip to the top of the list and is a property of the clip;
    /// this is a property of the window. Two things called pin in one window
    /// is exactly the confusion the separate name avoids — see the toggle in
    /// `ActionBar` and `.toggleKeepOpen` in `ShortcutManager`.
    ///
    /// The panel is already `.floating`, so "always on top" was never the
    /// missing piece: what closed the window was `pasteItem` calling `close()`
    /// and `HistoryPanel.resignKey`. Both stand down while this is on.
    @Published var keepWindowOpen: Bool = false {
        didSet {
            guard isLoaded, keepWindowOpen != oldValue else { return }
            set(keepWindowOpen, forKey: "window.keepOpen")
        }
    }

    // MARK: - Files (Phase 3F)

    /// Cap, in megabytes, under which a copied file's bytes are copied into
    /// storage; `0` means unlimited (always copy). Above the cap only a
    /// reference + bookmark is kept. Key `files.copyCapMB`, default 50.
    @Published var fileCopyCapMB: Int = 50 {
        didSet {
            guard isLoaded, fileCopyCapMB != oldValue else { return }
            set(fileCopyCapMB, forKey: "files.copyCapMB")
        }
    }

    // MARK: - Paste (Phase 3D, decision D5)

    /// When on, an unmarked Copy/Paste writes plain text only (today's
    /// pre-3D behavior) and the explicit "Paste/Copy as Plain Text" actions
    /// swap to "... with Formatting" instead — the same key/menu item always
    /// gives you the mode you didn't just get by default. Key
    /// `paste.alwaysPlain`, default false (rich by default, per D5).
    @Published var alwaysPastePlain: Bool = false {
        didSet {
            guard isLoaded, alwaysPastePlain != oldValue else { return }
            set(alwaysPastePlain, forKey: "paste.alwaysPlain")
        }
    }

    // ==========================================================================
    // MARK: - Phase 4A: iCloud Drive sync (owned by task 4A)
    //
    // Keys (each under the `klip.` prefix): sync.enabled, sync.maxAttachmentMB,
    // sync.deviceID, sync.deviceName, sync.lastPush, sync.lastPull. `deviceID` is a stable UUID minted on first
    // access; `deviceName` defaults to this Mac's name and is user-editable.
    // ==========================================================================

    /// Master switch for iCloud Drive sync. Default off — sync is opt-in.
    @Published var syncEnabled: Bool = false {
        didSet {
            guard isLoaded, syncEnabled != oldValue else { return }
            set(syncEnabled, forKey: "sync.enabled")
            NotificationCenter.default.post(name: .klipSyncSettingsChanged, object: nil)
        }
    }

    /// Attachments larger than this (in MB) stay local-only. `0` = no cap.
    @Published var syncMaxAttachmentMB: Int = 50 {
        didSet {
            guard isLoaded, syncMaxAttachmentMB != oldValue else { return }
            set(syncMaxAttachmentMB, forKey: "sync.maxAttachmentMB")
            NotificationCenter.default.post(name: .klipSyncSettingsChanged, object: nil)
        }
    }

    /// Which content kinds sync. Everything by default; a kind switched off
    /// is neither uploaded from this Mac nor taken from another one.
    @Published var syncedKinds: Set<ContentKind> = SyncKindFilter.all {
        didSet {
            guard isLoaded, syncedKinds != oldValue else { return }
            set(syncedKinds.map { $0.rawValue }.sorted(), forKey: "sync.kinds")
            NotificationCenter.default.post(name: .klipSyncSettingsChanged, object: nil)
        }
    }

    /// Name shown for this Mac in the other devices' sync status line.
    @Published var syncDeviceName: String = SettingsManager.defaultDeviceName {
        didSet {
            guard isLoaded, syncDeviceName != oldValue else { return }
            set(syncDeviceName, forKey: "sync.deviceName")
            NotificationCenter.default.post(name: .klipSyncSettingsChanged, object: nil)
        }
    }

    /// Stable identity of this Mac's sync folder. Minted once and never shown
    /// to the user.
    var syncDeviceID: String {
        if let existing = string(forKey: "sync.deviceID"), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        set(fresh, forKey: "sync.deviceID")
        return fresh
    }

    /// Timestamps of the last successful push/pull, for the status line.
    var syncLastPush: Date? {
        get { object(forKey: "sync.lastPush") as? Date }
        set { set(newValue, forKey: "sync.lastPush") }
    }

    var syncLastPull: Date? {
        get { object(forKey: "sync.lastPull") as? Date }
        set { set(newValue, forKey: "sync.lastPull") }
    }

    static var defaultDeviceName: String {
        let name = Host.current().localizedName ?? ""
        return name.isEmpty ? "This Mac" : name
    }

    // ==================== end Phase 4A settings ====================

    private init() {
        // Load history limit. Read as an object, not `integer(forKey:)`, so an
        // absent key is distinguishable from a stored 0 (= unlimited).
        self.historyLimit = HistoryLimit.from(storedRaw: object(forKey: "historyLimit") as? Int)
        
        // Load trash retention. Read as an object for the same reason as the
        // history limit above: a stored 0 means "forever", not "unset".
        self.trashRetention = TrashRetention.from(storedRaw: object(forKey: "trashRetention") as? Int)

        // Load appearance / layout settings
        if let raw = object(forKey: "fontScale.list") as? Double {
            self.listFontScale = raw
        }
        if let raw = object(forKey: "fontScale.preview") as? Double {
            self.previewFontScale = raw
        }
        if object(forKey: "appearance.showPreview") != nil {
            self.showPreviewPane = bool(forKey: "appearance.showPreview")
        }
        if object(forKey: "sidebarCollapsed") != nil {
            self.sidebarCollapsed = bool(forKey: "sidebarCollapsed")
        }
        if let raw = object(forKey: "sidebarWidth") as? Double {
            self.sidebarWidth = raw
        }
        if let raw = object(forKey: "previewWidth") as? Double {
            self.previewWidth = raw
        }
        self.windowWidth = object(forKey: "windowWidth") as? Double
        self.windowHeight = object(forKey: "windowHeight") as? Double

        if let raw = object(forKey: "files.copyCapMB") as? Int {
            self.fileCopyCapMB = raw
        }

        self.alwaysPastePlain = bool(forKey: "paste.alwaysPlain")

        // Window behaviour. Both default to false via `bool(forKey:)` on an
        // absent key, which is the wanted default for each.
        self.keepSearchBetweenOpens = bool(forKey: "search.keepBetweenOpens")
        self.keepWindowOpen = bool(forKey: "window.keepOpen")
        // --- Phase 4A: iCloud Drive sync ---
        self.syncEnabled = bool(forKey: "sync.enabled")
        if let raw = object(forKey: "sync.maxAttachmentMB") as? Int {
            self.syncMaxAttachmentMB = raw
        }
        if let name = string(forKey: "sync.deviceName"), !name.isEmpty {
            self.syncDeviceName = name
        }
        // Absent key = every kind syncs, so an update from a build without
        // this setting keeps syncing exactly what it synced before.
        if let raw = array(forKey: "sync.kinds") as? [String] {
            self.syncedKinds = Set(raw.compactMap { ContentKind(rawValue: $0) })
        }
        // --- end Phase 4A ---

        isLoaded = true
    }
}

/// Preset tiers offered by the Files cap picker (Phase 3F, D6). The stored
/// value (`SettingsManager.fileCopyCapMB`) is a plain `Int`, so any custom
/// number the user types is valid too — `matching(_:)` returns `nil` for a
/// value that isn't one of these presets, which the settings UI reads as
/// "Custom" and shows the numeric field instead of highlighting a tile.
enum FileCopyCapTier: Int, CaseIterable, Identifiable {
    case mb1 = 1
    case mb5 = 5
    case mb10 = 10
    case mb50 = 50
    case mb100 = 100
    case mb500 = 500
    case unlimited = 0

    var id: Int { rawValue }

    /// The `fileCopyCapMB` value this tier writes; `0` means unlimited.
    var megabytes: Int { rawValue }

    var label: String {
        switch self {
        case .mb1:        return "1 MB"
        case .mb5:        return "5 MB"
        case .mb10:       return "10 MB"
        case .mb50:       return "50 MB"
        case .mb100:      return "100 MB"
        case .mb500:      return "500 MB"
        case .unlimited:  return "Unlimited"
        }
    }

    static func matching(_ megabytes: Int) -> FileCopyCapTier? {
        allCases.first { $0.megabytes == megabytes }
    }
}

