import Foundation
import AppKit
import Combine
import CryptoKit
import UniformTypeIdentifiers
import BenchCore

/// Manages persistent storage of clipboard history
class ClipboardStore: ObservableObject {
    @Published var items: [ClipboardItem] = []

    /// Folders, always sorted by `sortIndex`.
    @Published private(set) var folders: [Folder] = []

    /// Deleted clips awaiting purge, newest deletion first (5D).
    ///
    /// A separate array, and a separate `trash.json`, rather than a flag on
    /// the items in `items`: every existing query — search, folder counts,
    /// eviction, the sync snapshot — reads `items`, and a tombstoned record
    /// living there would have to be excluded correctly by every one of them,
    /// forever. Keeping the trash out of that array makes "deleted clips are
    /// invisible everywhere" structural instead of a rule to remember.
    ///
    /// Deliberately **not** synced: `CloudDriveSync` snapshots `items`, so a
    /// delete still propagates to the other Macs as a tombstone (they remove
    /// their copy), while the recoverable copy stays on the Mac it was deleted
    /// on. A clipboard's trash is the last place passwords and screenshots
    /// should linger in iCloud for another month.
    @Published private(set) var trashedItems: [ClipboardItem] = []

    private func runOnMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread {
            action()
        } else {
            DispatchQueue.main.async(execute: action)
        }
    }

    /// Item cap, or `nil` when the user chose "Unlimited" (never evict).
    private var maxItems: Int? { SettingsManager.shared.historyLimit.maxItems }
    private let fileManager = FileManager.default
    private let saveQueue = DispatchQueue(label: "com.buffer.save", qos: .utility)

    /// Debounce window for history writes. Every public mutation schedules a
    /// save; bursts collapse into one atomic write.
    private static let saveDebounceInterval: TimeInterval = 0.3

    /// Hard ceiling on how long a mutation can sit unwritten (5A-13). A burst
    /// faster than `saveDebounceInterval` can postpone the trailing write
    /// indefinitely; this makes the worst-case loss on a SIGKILL bounded.
    static let saveMaxDelay: TimeInterval = 2.0

    // Guarded by `saveQueue`.
    private var pendingItems: [ClipboardItem]?
    private var pendingSaveWorkItem: DispatchWorkItem?
    /// When the oldest unwritten mutation was scheduled. `saveQueue` only.
    private var firstPendingMutationAt: Date?

    // MARK: - On-disk schema

    private static let historySchemaVersion = 2
    private static let foldersSchemaVersion = 1
    private static let trashSchemaVersion = 1

    private struct HistoryFile: Codable {
        var version: Int
        var items: [ClipboardItem]
    }

    private struct FoldersFile: Codable {
        var version: Int
        var folders: [Folder]
    }

    private struct TrashFile: Codable {
        var version: Int
        var items: [ClipboardItem]
    }

    // MARK: - Locations

    /// Where this store keeps its files. Fixed at init: the app passes
    /// nothing and gets `storageDirectoryURL`; tests pass a temp directory.
    private let storageDirectory: URL

    /// The app's storage root, `~/Library/Application Support/Bench/Klip`
    /// (or under `BENCH_DATA_DIR`). A `static` so Settings' "Open Storage
    /// Folder in Finder" button doesn't need a `ClipboardStore` instance to
    /// find it.
    static var storageDirectoryURL: URL {
        BenchPaths.dataDirectory(feature: "Klip")
    }

    private var historyFileURL: URL {
        storageDirectory.appendingPathComponent("history.json")
    }

    private var foldersFileURL: URL {
        storageDirectory.appendingPathComponent("folders.json")
    }

    private var trashFileURL: URL {
        storageDirectory.appendingPathComponent("trash.json")
    }

    private var imagesDirectory: URL {
        storageDirectory.appendingPathComponent("images", isDirectory: true)
    }

    private nonisolated var textsDirectory: URL {
        storageDirectory.appendingPathComponent("texts", isDirectory: true)
    }

    /// Copied-in file payloads, one subdirectory per item (Phase 3F).
    private var filesDirectory: URL {
        storageDirectory.appendingPathComponent("files", isDirectory: true)
    }

    /// Archived pasteboard flavors, one plist per item (Phase 3D).
    private var flavorsDirectory: URL {
        storageDirectory.appendingPathComponent("flavors", isDirectory: true)
    }

    /// `directory` overrides the storage root (tests); `nil` uses
    /// `storageDirectoryURL`.
    init(directory: URL? = nil) {
        self.storageDirectory = directory ?? Self.storageDirectoryURL
        ensureDirectoriesExist()
        loadHistory()
        backfillKindsIfNeeded()
        backfillContentKeysIfNeeded()   // 5B
        loadFolders()
        loadTrash()   // 5D
        purgeExpiredTrash()   // 5D
        loadSyncIgnore()   // Phase 4A
        trimToLimitAtLaunch()   // 5A-02
        sweepOrphanedAssets()   // 5A-08

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLimitChanged),
            name: .bufferHistoryLimitChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTrashRetentionChanged),
            name: .bufferTrashRetentionChanged,
            object: nil
        )
    }

    @objc private func handleTrashRetentionChanged() {
        runOnMain { [weak self] in self?.purgeExpiredTrash() }
    }

    @objc private func handleLimitChanged() {
        runOnMain { [weak self] in
            guard let self = self else { return }
            guard let limit = self.maxItems else { return }
            var trimmed = self.items
            // Same rule as performAdd: the cap counts non-protected items only.
            // Locked, pinned, bookmarked, tagged and foldered items are never
            // evicted and never count toward the limit.
            var unprotectedCount = trimmed.reduce(0) { $0 + ($1.isProtected ? 0 : 1) }
            guard unprotectedCount > limit else { return }
            var evicted: [UUID] = []   // Phase 4A
            while unprotectedCount > limit,
                  let idx = trimmed.lastIndex(where: { !$0.isProtected }) {
                self.deleteAssociatedFiles(for: trimmed[idx])
                evicted.append(trimmed[idx].id)   // Phase 4A
                trimmed.remove(at: idx)
                unprotectedCount -= 1
            }
            self.noteEvicted(evicted)   // Phase 4A: one batched sync-ignore write
            self.items = trimmed
            self.scheduleSave()
        }
    }

    // MARK: - Public API

    func add(_ item: ClipboardItem) {
        // Must be called on main thread for SwiftUI updates
        if Thread.isMainThread {
            performAdd(item)
        } else {
            DispatchQueue.main.sync {
                performAdd(item)
            }
        }
    }

    private func performAdd(_ item: ClipboardItem) {
        print("[Buffer] Store: Adding item, current count: \(items.count)")

        // 5B: copying something that is already in the history brings the
        // existing clip back to the top instead of adding a second identical
        // row — no matter how long ago it was captured or which app it came
        // from. A linear scan is enough: `add` runs once per copy, and a
        // string compare over the history costs orders of magnitude less than
        // the disk work the capture just did.
        if let key = item.contentKey,
           let existing = items.firstIndex(where: { $0.contentKey == key }) {
            resurface(at: existing, capturedAt: item.timestamp, discarding: item)
            return
        }

        // Insert at beginning (newest first)
        items.insert(item, at: 0)

        // The history limit caps **non-protected** items only. Protected items
        // (pinned, bookmarked, tagged, locked, foldered) are never evicted and
        // do not count toward the cap, so the total may exceed the limit by the
        // number of protected items. The clip that was just copied is therefore
        // always kept: an add can only ever push out an *older* non-protected item.
        if let limit = maxItems {
            var unprotectedCount = items.reduce(0) { $0 + ($1.isProtected ? 0 : 1) }
            // 5A-02: the eviction ids are collected here and handed to
            // `noteEvicted` **once** after the loop. Calling it per item made
            // every eviction re-encode and synchronously rewrite the whole
            // `sync-ignore.json` (measured at 118 s for a single `add()` on a
            // store 9,000 items over its cap).
            var evicted: [UUID] = []
            while unprotectedCount > limit,
                  let indexToRemove = items.lastIndex(where: { !$0.isProtected }) {
                let removed = items.remove(at: indexToRemove)
                deleteAssociatedFiles(for: removed)
                evicted.append(removed.id)
                unprotectedCount -= 1
            }
            noteEvicted(evicted)   // Phase 4A — one batched sync-ignore write
        }

        print("[Buffer] Store: New count: \(items.count)")

        scheduleSave()
    }

    /// Brings the clip at `index` back to the top of the history because its
    /// exact content was just copied again, and throws away the redundant
    /// payload the capture had already written to disk.
    ///
    /// Everything the user put on the clip survives: pin, bookmark, lock,
    /// tags, folder membership and — importantly — its manual position inside
    /// that folder, which is ordered by `folderSortIndex` and is not touched
    /// here. Only the date moves.
    private func resurface(at index: Int, capturedAt: Date, discarding incoming: ClipboardItem) {
        guard items.indices.contains(index) else { return }
        var existing = items.remove(at: index)
        existing.timestamp = capturedAt
        existing.updatedAt = Date()
        items.insert(existing, at: 0)

        // The bytes the capture just wrote are a duplicate of what the
        // surviving clip already points at. `referencedAssetNames` is passed
        // so a shared name (possible for a re-added item that reuses an id)
        // can never delete the survivor's payload out from under it.
        deleteAssociatedFiles(for: incoming, keeping: referencedAssetNames(in: items + trashedItems))

        print("[Buffer] Store: Duplicate content, resurfaced existing item")
        scheduleSave()
    }

    /// Fills in `contentKey` for every item captured before that field
    /// existed, so an old clip can still be recognised when its content is
    /// copied again. Text and file keys are pure field arithmetic; an image
    /// key needs its bytes back off disk, which is why the whole pass runs on
    /// a utility queue like `backfillKindsIfNeeded`.
    ///
    /// Deliberately does **not** call `touchItem`: a content key is derived
    /// data every device can compute for itself, and bumping `updatedAt` here
    /// would push the entire history through iCloud sync on first launch
    /// after updating.
    func backfillContentKeysIfNeeded() {
        let candidates = items.filter { $0.contentKey == nil }
        guard !candidates.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            var computed: [UUID: String] = [:]
            computed.reserveCapacity(candidates.count)
            for item in candidates {
                if let key = self.computedContentKey(for: item) { computed[item.id] = key }
            }
            guard !computed.isEmpty else { return }

            self.runOnMain {
                var changed = false
                for index in self.items.indices {
                    guard self.items[index].contentKey == nil,
                          let key = computed[self.items[index].id] else { continue }
                    self.items[index].contentKey = key
                    changed = true
                }
                if changed { self.scheduleSave() }
            }
        }
    }

    /// The content key an item *should* carry, recomputed from what is on
    /// disk. Called off the main thread — `fullText(for:)` and the image read
    /// are plain file reads against immutable directory URLs and touch no
    /// store state.
    private func computedContentKey(for item: ClipboardItem) -> String? {
        if let attachment = item.fileAttachment {
            return ClipboardItem.contentKey(
                forFileNames: [attachment.originalName] + attachment.additionalNames,
                byteSize: attachment.byteSize
            )
        }
        switch item.type {
        case .text:
            guard let text = fullText(for: item) else { return nil }
            return ClipboardItem.contentKey(forText: text)
        case .image:
            guard let filename = item.imageFilename,
                  let data = try? Data(contentsOf: imagesDirectory.appendingPathComponent(filename)) else { return nil }
            return ClipboardItem.contentKey(forImageData: data)
        case .file:
            // A `.file` item always carries an attachment and is keyed above.
            return nil
        }
    }

    /// Delete a single item. Returns `false` (and changes nothing) when the
    /// item is locked.
    @discardableResult
    func delete(_ item: ClipboardItem) -> Bool {
        var didDelete = false
        performOnMainSync { [weak self] in
            guard let self = self else { return }
            guard let index = self.items.firstIndex(where: { $0.id == item.id }) else { return }
            guard !self.items[index].isLocked else { return }
            let removed = self.items.remove(at: index)
            self.moveToTrash([removed])   // 5D: assets stay until the purge
            self.noteDeleted([removed.id])   // Phase 4A
            didDelete = true
            self.scheduleSave()
        }
        return didDelete
    }

    struct DeleteResult: Equatable {
        let deleted: Int
        let skippedLocked: Int
    }

    /// Delete multiple items in a single batch operation. Locked items are
    /// skipped and reported in `skippedLocked`.
    @discardableResult
    func delete(_ itemsToDelete: [ClipboardItem]) -> DeleteResult {
        var result = DeleteResult(deleted: 0, skippedLocked: 0)
        performOnMainSync { [weak self] in
            guard let self = self else { return }
            let requested = Set(itemsToDelete.map { $0.id })
            let removable = self.items.filter { requested.contains($0.id) && !$0.isLocked }
            let skipped = self.items.filter { requested.contains($0.id) && $0.isLocked }.count

            let removableIDs = Set(removable.map { $0.id })
            self.items.removeAll { removableIDs.contains($0.id) }
            self.moveToTrash(removable)   // 5D
            self.noteDeleted(Array(removableIDs))   // Phase 4A

            result = DeleteResult(deleted: removable.count, skippedLocked: skipped)
            self.scheduleSave()
        }
        return result
    }

    /// Toggle pin state for an item
    func togglePin(for item: ClipboardItem) {
        runOnMain { [weak self] in
            guard let self = self else { return }
            guard let index = self.items.firstIndex(where: { $0.id == item.id }) else { return }
            self.items[index].isPinned.toggle()
            self.touchItem(at: index)   // Phase 4A
            self.scheduleSave()
        }
    }

    /// Toggle bookmark state for an item (protected from eviction, stays in place)
    func toggleBookmark(for item: ClipboardItem) {
        runOnMain { [weak self] in
            guard let self = self else { return }
            guard let index = self.items.firstIndex(where: { $0.id == item.id }) else { return }
            self.items[index].isBookmarked.toggle()
            self.touchItem(at: index)   // Phase 4A
            self.scheduleSave()
        }
    }

    // MARK: - Lock

    /// Toggle lock state. A locked item can never be deleted or evicted.
    func toggleLock(_ item: ClipboardItem) {
        runOnMain { [weak self] in
            guard let self = self else { return }
            guard let index = self.items.firstIndex(where: { $0.id == item.id }) else { return }
            self.items[index].isLocked.toggle()
            self.touchItem(at: index)   // Phase 4A
            self.scheduleSave()
        }
    }

    /// Set the lock state on a batch of items.
    func setLocked(ids: Set<UUID>, locked: Bool) {
        guard !ids.isEmpty else { return }
        runOnMain { [weak self] in
            guard let self = self else { return }
            var changed = false
            for index in self.items.indices where ids.contains(self.items[index].id) {
                if self.items[index].isLocked != locked {
                    self.items[index].isLocked = locked
                    self.touchItem(at: index)   // Phase 4A
                    changed = true
                }
            }
            guard changed else { return }
            self.scheduleSave()
        }
    }

    /// Update text content for an editable text item
    func updateText(_ text: String, for item: ClipboardItem) {
        runOnMain { [weak self] in
            guard let self = self else { return }
            guard let index = self.items.firstIndex(where: { $0.id == item.id }) else { return }
            self.items[index].textContent = text
            self.touchItem(at: index)   // Phase 4A
            self.scheduleSave()
        }
    }

    /// Set (or clear) a clip's user-given name.
    ///
    /// Blank input clears the title back to `nil` rather than storing an
    /// empty string, so "rename to nothing" is how a name is removed and
    /// `displayTitle` never has to defend against `""`. The name is capped at
    /// `ClipboardItem.titleMaxLength`; the row shows one line of it.
    func setTitle(_ title: String?, for item: ClipboardItem) {
        runOnMain { [weak self] in
            guard let self = self else { return }
            guard let index = self.items.firstIndex(where: { $0.id == item.id }) else { return }
            let trimmed = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = trimmed.isEmpty ? nil : String(trimmed.prefix(ClipboardItem.titleMaxLength))
            guard self.items[index].title != resolved else { return }
            self.items[index].title = resolved
            self.touchItem(at: index)
            self.scheduleSave()
        }
    }

    var allTags: [String] {
        Array(Set(items.flatMap { $0.tags })).sorted()
    }

    func addTag(_ tag: String, to item: ClipboardItem) {
        runOnMain { [weak self] in
            guard let self = self else { return }
            guard let index = self.items.firstIndex(where: { $0.id == item.id }) else { return }
            guard !self.items[index].tags.contains(tag) else { return }
            self.items[index].tags.append(tag)
            self.touchItem(at: index)   // Phase 4A
            self.scheduleSave()
        }
    }

    func removeTag(_ tag: String, from item: ClipboardItem) {
        runOnMain { [weak self] in
            guard let self = self else { return }
            guard let index = self.items.firstIndex(where: { $0.id == item.id }) else { return }
            self.items[index].tags.removeAll { $0 == tag }
            self.touchItem(at: index)   // Phase 4A
            self.scheduleSave()
        }
    }

    /// Save extracted OCR text for an image item
    func setOCRText(_ text: String, for item: ClipboardItem) {
        runOnMain { [weak self] in
            guard let self = self else { return }
            guard let index = self.items.firstIndex(where: { $0.id == item.id }) else { return }
            self.items[index].ocrText = text
            self.touchItem(at: index)   // Phase 4A
            self.scheduleSave()
        }
    }

    /// Clear the history.
    ///
    /// With `keepProtected` (the default) everything protected survives:
    /// pinned, bookmarked, tagged, locked and foldered items. With
    /// `keepProtected: false` everything except **locked** items is deleted —
    /// a lock is absolute and outranks an explicit clear.
    @discardableResult
    func clear(keepProtected: Bool = true) -> DeleteResult {
        var result = DeleteResult(deleted: 0, skippedLocked: 0)
        performOnMainSync { [weak self] in
            guard let self = self else { return }
            let shouldDelete: (ClipboardItem) -> Bool = keepProtected
                ? { !$0.isProtected }
                : { !$0.isLocked }

            let doomed = self.items.filter(shouldDelete)
            let skipped = self.items.filter { $0.isLocked }.count
            self.items.removeAll(where: shouldDelete)
            self.moveToTrash(doomed)   // 5D
            self.noteDeleted(doomed.map { $0.id })   // Phase 4A

            result = DeleteResult(deleted: doomed.count, skippedLocked: skipped)
            self.scheduleSave()
        }
        return result
    }

    // ==========================================================================
    // MARK: - Trash (5D)
    //
    // Explicit deletes — a row, a multi-selection, Clear History, a folder
    // deleted with its clips — move here instead of vanishing. Cap eviction
    // does **not**: it is automatic housekeeping, and routing it through the
    // trash would grow an unbounded second history behind the user's back and
    // defeat the history limit they chose.
    //
    // A trashed clip keeps its on-disk assets so a restore is complete; they
    // are removed only when the record is purged for good.
    // ==========================================================================

    /// Clips whose retention window has expired, given `now`. Pure, so the
    /// window arithmetic is testable without waiting a month.
    static func expiredTrash(
        _ trashed: [ClipboardItem],
        retention: TrashRetention,
        now: Date = Date()
    ) -> [ClipboardItem] {
        guard let days = retention.days else { return [] }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        // A record with no deletion date cannot be aged; keep it rather than
        // purging something we cannot reason about.
        return trashed.filter { deleted in
            guard let at = deleted.deletedAt else { return false }
            return at <= cutoff
        }
    }

    /// Moves already-removed items into the trash, newest deletion first.
    /// Called by the delete paths **after** they have taken the items out of
    /// `items`; it never touches `items` itself.
    private func moveToTrash(_ removed: [ClipboardItem]) {
        guard !removed.isEmpty else { return }
        let now = Date()
        let stamped = removed.map { item -> ClipboardItem in
            var copy = item
            copy.deletedAt = now
            // A locked clip can't reach here (every delete path refuses one),
            // but a locked record inside the trash would be unpurgeable, so
            // the flag is dropped on the way in as a belt-and-braces measure.
            copy.isLocked = false
            return copy
        }
        trashedItems.insert(contentsOf: stamped, at: 0)
        saveTrash()
    }

    /// Puts trashed clips back into the history, **at the top**. Ids that are
    /// not in the trash are ignored; a restored clip keeps its folder only if
    /// that folder still exists.
    ///
    /// 5E: this used to insert each clip back into its chronological place,
    /// which is where it was when it was deleted — a clip deleted from 100
    /// rows down came back 100 rows down, and finding it again meant
    /// scrolling or searching for something you had just asked to get back.
    /// A restore now behaves exactly like re-copying the content does
    /// (`resurface`): the clip goes to row one and its `timestamp` moves to
    /// now. Moving the date is what makes the position survive — the history
    /// is timestamp-ordered, and a sync merge re-sorts it (`applyRemoteMerge`),
    /// so a clip parked at index 0 with a month-old date would silently drop
    /// back down the list at the next merge. Everything else the user gave the
    /// clip — tags, folder, folder position, pin, favorite — is untouched.
    @discardableResult
    func restoreFromTrash(ids: Set<UUID>) -> Int {
        var restored = 0
        performOnMainSync { [weak self] in
            guard let self = self, !ids.isEmpty else { return }
            let coming = self.trashedItems.filter { ids.contains($0.id) }
            guard !coming.isEmpty else { return }
            self.trashedItems.removeAll { ids.contains($0.id) }

            let now = Date()
            // Reversed so a multi-clip restore keeps the trash list's own
            // order once every insert has landed at index 0.
            for var item in coming.reversed() {
                item.deletedAt = nil
                if let folderID = item.folderID, !self.folders.contains(where: { $0.id == folderID }) {
                    // The folder was deleted while the clip sat in the trash.
                    item.folderID = nil
                    item.folderSortIndex = nil
                }
                item.timestamp = now
                item.updatedAt = now
                self.items.insert(item, at: 0)
                restored += 1
            }

            self.noteRestored(coming.map { $0.id })   // Phase 4A / 5D
            self.saveTrash()
            self.scheduleSave()
        }
        return restored
    }

    /// Permanently removes trashed records and their on-disk assets. This is
    /// the only path in the trash that destroys anything.
    @discardableResult
    func purgeFromTrash(ids: Set<UUID>) -> Int {
        var purged = 0
        performOnMainSync { [weak self] in
            guard let self = self, !ids.isEmpty else { return }
            let doomed = self.trashedItems.filter { ids.contains($0.id) }
            guard !doomed.isEmpty else { return }
            self.trashedItems.removeAll { ids.contains($0.id) }

            // A restored-then-recopied clip can share an asset name with a
            // live item; `keeping` makes sure a purge never deletes bytes
            // something still on screen points at.
            let keep = self.referencedAssetNames(in: self.items + self.trashedItems)
            for item in doomed {
                self.deleteAssociatedFiles(for: item, keeping: keep)
            }
            purged = doomed.count
            self.saveTrash()
        }
        return purged
    }

    /// Empties the trash completely.
    @discardableResult
    func emptyTrash() -> Int {
        purgeFromTrash(ids: Set(trashedItems.map { $0.id }))
    }

    /// Drops everything past the configured retention window. Runs at launch
    /// and whenever the setting changes; a "Forever" window purges nothing.
    @discardableResult
    func purgeExpiredTrash(now: Date = Date()) -> Int {
        let expired = Self.expiredTrash(
            trashedItems,
            retention: SettingsManager.shared.trashRetention,
            now: now
        )
        guard !expired.isEmpty else { return 0 }
        let count = purgeFromTrash(ids: Set(expired.map { $0.id }))
        if count > 0 { print("[Buffer] Trash: purged \(count) expired clip(s)") }
        return count
    }

    // MARK: Trash persistence

    private func loadTrash() {
        guard fileManager.fileExists(atPath: trashFileURL.path) else { return }
        guard let data = try? Data(contentsOf: trashFileURL) else {
            print("[Buffer] Failed to read trash.json")
            trashLoadWasClean = false
            return
        }
        guard let file = try? JSONDecoder().decode(TrashFile.self, from: data) else {
            // Same rule as the history: an unreadable trash file is left alone
            // and its assets are protected from the orphan sweep, rather than
            // being silently overwritten with an empty one.
            print("[Buffer] trash.json could not be decoded, leaving it untouched")
            trashLoadWasClean = false
            return
        }
        trashedItems = file.items
        print("[Buffer] Loaded \(file.items.count) trashed items")
    }

    /// Written straight through rather than debounced like the history: the
    /// trash changes only on an explicit delete, restore or purge, never in a
    /// burst.
    private func saveTrash() {
        let snapshot = trashedItems
        saveQueue.async { [weak self] in
            self?.saveTrashToDisk(snapshot)
        }
    }

    private func saveTrashToDisk(_ trashToSave: [ClipboardItem]) {
        do {
            let file = TrashFile(version: Self.trashSchemaVersion, items: trashToSave)
            let data = try JSONEncoder().encode(file)
            try data.write(to: trashFileURL, options: .atomic)
        } catch {
            print("[Buffer] Failed to save trash: \(error)")
        }
    }

    // MARK: - Content kind backfill

    /// Computes `kind` for every item that doesn't have one yet — history
    /// captured before Phase 3C, or anything restored/imported without it.
    /// Detection runs on a background utility queue so it never blocks
    /// launch; results are applied to `items` in a single batch on the main
    /// actor and then saved (debounced). Idempotent: once every item has a
    /// kind, a repeat call finds nothing to do and returns immediately.
    func backfillKindsIfNeeded() {
        let candidates = items.filter { $0.kind == nil }
        guard !candidates.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var computed: [UUID: ContentKind] = [:]
            computed.reserveCapacity(candidates.count)
            for item in candidates {
                computed[item.id] = ContentDetector.detect(for: item, fullText: nil)
            }

            self?.runOnMain {
                guard let self = self else { return }
                var changed = false
                for index in self.items.indices {
                    let id = self.items[index].id
                    guard self.items[index].kind == nil, let kind = computed[id] else { continue }
                    self.items[index].kind = kind
                    self.touchItem(at: index)   // Phase 4A
                    changed = true
                }
                if changed {
                    self.scheduleSave()
                }
            }
        }
    }

    // MARK: - Folders

    /// Create a folder. An empty/whitespace name becomes "Untitled Folder";
    /// duplicate names are allowed.
    @discardableResult
    func createFolder(name: String) -> Folder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "Untitled Folder" : trimmed
        var folder = Folder(name: finalName, sortIndex: 0)

        performOnMainSync { [weak self] in
            guard let self = self else { return }
            let nextIndex = (self.folders.map { $0.sortIndex }.max() ?? -1) + 1
            folder.sortIndex = nextIndex
            self.folders.append(folder)
            self.sortFolders()
            self.saveFolders()
        }
        return folder
    }

    func renameFolder(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "Untitled Folder" : trimmed
        runOnMain { [weak self] in
            guard let self = self else { return }
            guard let index = self.folders.firstIndex(where: { $0.id == id }) else { return }
            self.folders[index].name = finalName
            self.folders[index].updatedAt = Date()   // Phase 4A
            self.saveFolders()
        }
    }

    enum FolderDeleteMode {
        /// Keep the items, drop their folder membership.
        case moveItemsOut
        /// Delete the items too. With `includeLocked: false` locked items are
        /// left behind and the folder itself survives.
        case deleteItems(includeLocked: Bool)
    }

    struct FolderDeleteResult: Equatable {
        let folderDeleted: Bool
        let movedOut: Int
        let deleted: Int
        let skippedLocked: Int
    }

    @discardableResult
    func deleteFolder(id: UUID, mode: FolderDeleteMode) -> FolderDeleteResult {
        var result = FolderDeleteResult(folderDeleted: false, movedOut: 0, deleted: 0, skippedLocked: 0)
        performOnMainSync { [weak self] in
            guard let self = self else { return }
            guard self.folders.contains(where: { $0.id == id }) else { return }

            switch mode {
            case .moveItemsOut:
                var movedOut = 0
                for index in self.items.indices where self.items[index].folderID == id {
                    self.items[index].folderID = nil
                    self.items[index].folderSortIndex = nil   // 5C: no folder, no manual position
                    self.touchItem(at: index)   // Phase 4A
                    movedOut += 1
                }
                self.folders.removeAll { $0.id == id }
                result = FolderDeleteResult(folderDeleted: true, movedOut: movedOut, deleted: 0, skippedLocked: 0)

            case .deleteItems(let includeLocked):
                let inFolder = self.items.filter { $0.folderID == id }
                let lockedCount = inFolder.filter { $0.isLocked }.count
                let doomed = includeLocked ? inFolder : inFolder.filter { !$0.isLocked }

                let doomedIDs = Set(doomed.map { $0.id })
                self.items.removeAll { doomedIDs.contains($0.id) }
                self.moveToTrash(doomed)   // 5D
                self.noteDeleted(Array(doomedIDs))   // Phase 4A

                // Locked items left behind keep the folder alive; the UI asks
                // for explicit confirmation and calls again with includeLocked.
                let removeFolder = includeLocked || lockedCount == 0
                if removeFolder {
                    self.folders.removeAll { $0.id == id }
                }
                result = FolderDeleteResult(
                    folderDeleted: removeFolder,
                    movedOut: 0,
                    deleted: doomed.count,
                    skippedLocked: includeLocked ? 0 : lockedCount
                )
            }

            if result.folderDeleted {
                self.noteFolderDeleted(id)   // Phase 4A
            }
            self.saveFolders()
            self.scheduleSave()
        }
        return result
    }

    /// Move items into a folder (`folderID != nil`) or back out (`nil`).
    /// Filing an item into a folder also locks it — folder clips are locked by
    /// default. Moving out leaves the lock state untouched.
    func moveItems(ids: Set<UUID>, toFolder folderID: UUID?) {
        guard !ids.isEmpty else { return }
        runOnMain { [weak self] in
            guard let self = self else { return }
            if let folderID = folderID, !self.folders.contains(where: { $0.id == folderID }) { return }
            var changed = false
            // 5C: a clip arriving in a folder is placed at the top of that
            // folder's manual order, which is where a freshly filed clip is
            // expected to show up. Leaving it `nil` would instead drop it
            // below every hand-sorted row.
            let arrivalIndex = folderID.map { self.lowestFolderSortIndex(in: $0) - 1 }
            for index in self.items.indices where ids.contains(self.items[index].id) {
                self.items[index].folderID = folderID
                if folderID != nil {
                    self.items[index].isLocked = true
                    self.items[index].folderSortIndex = arrivalIndex
                } else {
                    // Out of the folder, the manual position means nothing.
                    self.items[index].folderSortIndex = nil
                }
                self.touchItem(at: index)   // Phase 4A
                changed = true
            }
            guard changed else { return }
            self.scheduleSave()
        }
    }

    func items(inFolder id: UUID) -> [ClipboardItem] {
        items.filter { $0.folderID == id }
    }

    /// Rewrites the manual order of `folderID`'s clips to match `orderedIDs`
    /// (5C). Members missing from `orderedIDs` keep their relative order at
    /// the end; ids belonging to another folder are ignored.
    ///
    /// The whole folder is renumbered `0, 1, 2, …` on every drop rather than
    /// squeezing a fractional index between two neighbours: folders are small,
    /// hand-curated sets, and dense integers keep the on-disk numbers readable
    /// and immune to the precision drift a long chain of midpoint inserts
    /// eventually hits.
    func setFolderOrder(_ orderedIDs: [UUID], in folderID: UUID) {
        runOnMain { [weak self] in
            guard let self = self else { return }
            var rank: [UUID: Int] = [:]
            for (offset, id) in orderedIDs.enumerated() { rank[id] = offset }

            // Members the caller did not mention keep their current relative
            // order, appended after everything it did.
            var tail = rank.count
            let unranked = self.items.enumerated()
                .filter { $0.element.folderID == folderID && rank[$0.element.id] == nil }
            for entry in Self.folderOrder(unranked.map { $0.element }) {
                rank[entry.id] = tail
                tail += 1
            }

            var changed = false
            for index in self.items.indices {
                guard self.items[index].folderID == folderID,
                      let position = rank[self.items[index].id] else { continue }
                let value = Double(position)
                guard self.items[index].folderSortIndex != value else { continue }
                self.items[index].folderSortIndex = value
                self.touchItem(at: index)   // Phase 4A
                changed = true
            }
            guard changed else { return }
            self.scheduleSave()
        }
    }

    /// The display order of a folder's clips: manual index first, then
    /// anything never hand-placed, newest first. Shared with
    /// `FilterState.apply` so the list and the store never disagree about
    /// what "the folder's order" is.
    static func folderOrder(_ items: [ClipboardItem]) -> [ClipboardItem] {
        items.sorted { a, b in
            switch (a.folderSortIndex, b.folderSortIndex) {
            case let (x?, y?):
                if x != y { return x < y }
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            case (nil, nil):
                break
            }
            if a.timestamp != b.timestamp { return a.timestamp > b.timestamp }
            return a.id.uuidString < b.id.uuidString
        }
    }

    /// Smallest manual index currently used in `folderID`, or `0` for a
    /// folder with no hand-placed clips.
    private func lowestFolderSortIndex(in folderID: UUID) -> Double {
        items.compactMap { $0.folderID == folderID ? $0.folderSortIndex : nil }.min() ?? 0
    }

    func folderCounts() -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for item in items {
            guard let folderID = item.folderID else { continue }
            counts[folderID, default: 0] += 1
        }
        return counts
    }

    /// Reorder folders to match `ids`. Ids not present are ignored; folders
    /// missing from `ids` keep their relative order at the end.
    func reorderFolders(_ ids: [UUID]) {
        runOnMain { [weak self] in
            guard let self = self else { return }
            var rank: [UUID: Int] = [:]
            for (offset, id) in ids.enumerated() { rank[id] = offset }
            let tailBase = ids.count

            let ordered = self.folders.enumerated().sorted { lhs, rhs in
                let l = rank[lhs.element.id] ?? (tailBase + lhs.offset)
                let r = rank[rhs.element.id] ?? (tailBase + rhs.offset)
                return l < r
            }.map { $0.element }

            self.folders = ordered.enumerated().map { offset, folder in
                var copy = folder
                guard copy.sortIndex != offset else { return copy }
                copy.sortIndex = offset
                copy.updatedAt = Date()   // Phase 4A
                return copy
            }
            self.saveFolders()
        }
    }

    // MARK: - Assets

    func image(for item: ClipboardItem) -> NSImage? {
        guard item.type == .image, let filename = item.imageFilename else { return nil }
        let url = imagesDirectory.appendingPathComponent(filename)
        return NSImage(contentsOf: url)
    }

    /// File URL of the stored image asset for `item`, or nil if it isn't an
    /// image item or carries no filename.
    func imageURL(for item: ClipboardItem) -> URL? {
        guard item.type == .image, let filename = item.imageFilename else { return nil }
        return imagesDirectory.appendingPathComponent(filename)
    }

    /// The exact bytes captured for `item`'s image, whatever format they were
    /// stored in (JPEG/PNG/HEIC/GIF/WebP/...). Paste/copy and Save to Disk
    /// read through this instead of decoding via `image(for:)`, so the
    /// original encoding never gets lost to an NSImage round-trip.
    func imageData(for item: ClipboardItem) -> Data? {
        guard let url = imageURL(for: item) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Writes `data` verbatim to `images/<uuid>.<fileExtension>` and returns
    /// the filename. `fileExtension` defaults to `png` for legacy callers
    /// (the fallback NSImage -> PNG conversion path and every pre-6C test
    /// fixture); real captures pass the extension matching the bytes'
    /// original format so nothing gets re-encoded.
    func saveImage(_ data: Data, fileExtension: String = "png") -> String? {
        let filename = UUID().uuidString + "." + fileExtension
        let url = imagesDirectory.appendingPathComponent(filename)

        do {
            try data.write(to: url, options: .atomic)
            return filename
        } catch {
            print("[Buffer] Failed to save image: \(error)")
            return nil
        }
    }

    /// Save large text to a file and return the filename
    func saveText(_ text: String) -> String? {
        let filename = UUID().uuidString + ".txt"
        let url = textsDirectory.appendingPathComponent(filename)

        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return filename
        } catch {
            print("[Buffer] Failed to save text file: \(error)")
            return nil
        }
    }

    // MARK: - Rich text / flavors (Phase 3D) — begin
    //
    // File helpers only; the model fields (`rtfFilename`, `flavorsFilename`)
    // and `deleteAssociatedFiles`'s cleanup of them predate this task. Kept in
    // its own delimited region since `ClipboardStore.swift` is also touched by
    // the concurrent iCloud-sync task (4A) elsewhere in the file.

    /// Save an RTF flavor to `texts/<itemID>.rtf`. Returns the filename to
    /// store on `ClipboardItem.rtfFilename`.
    func saveRTF(_ data: Data, itemID: UUID) -> String? {
        let filename = "\(itemID.uuidString).rtf"
        let url = textsDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
            return filename
        } catch {
            print("[Buffer] Failed to save RTF: \(error)")
            return nil
        }
    }

    /// Save the archived raw pasteboard flavors bundle to
    /// `flavors/<itemID>.plist`. Returns the filename to store on
    /// `ClipboardItem.flavorsFilename`.
    func saveFlavors(_ data: Data, itemID: UUID) -> String? {
        let filename = "\(itemID.uuidString).plist"
        let url = flavorsDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
            return filename
        } catch {
            print("[Buffer] Failed to save flavors: \(error)")
            return nil
        }
    }

    /// Load an item's RTF flavor as Data, if it has one.
    func rtfData(for item: ClipboardItem) -> Data? {
        guard let filename = item.rtfFilename else { return nil }
        return try? Data(contentsOf: textsDirectory.appendingPathComponent(filename))
    }

    /// Load an item's archived raw pasteboard flavors bundle, if it has one.
    func flavorsData(for item: ClipboardItem) -> Data? {
        guard let filename = item.flavorsFilename else { return nil }
        return try? Data(contentsOf: flavorsDirectory.appendingPathComponent(filename))
    }

    /// Drop an item's RTF/flavors backing, keeping only its plain text.
    /// Editing a rich item (3D deliverable 3) commits plain text and calls
    /// this so the stale rich files aren't left orphaned on disk, and the
    /// item stops advertising formatting it no longer carries.
    func clearRichFlavors(for item: ClipboardItem) {
        runOnMain { [weak self] in
            guard let self = self else { return }
            guard let index = self.items.firstIndex(where: { $0.id == item.id }) else { return }
            guard self.items[index].rtfFilename != nil || self.items[index].flavorsFilename != nil else { return }

            if let filename = self.items[index].rtfFilename {
                try? self.fileManager.removeItem(at: self.textsDirectory.appendingPathComponent(filename))
            }
            if let filename = self.items[index].flavorsFilename {
                try? self.fileManager.removeItem(at: self.flavorsDirectory.appendingPathComponent(filename))
            }
            self.items[index].rtfFilename = nil
            self.items[index].flavorsFilename = nil
            if self.items[index].kind == .richText {
                self.items[index].kind = .text
            }
            self.scheduleSave()
        }
    }

    // MARK: - Rich text / flavors (Phase 3D) — end

    /// Load full text content from file (lazy loading for large text)
    func fullText(for item: ClipboardItem) -> String? {
        guard let filename = item.textFilename else { return item.textContent }
        let url = textsDirectory.appendingPathComponent(filename)

        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            print("[Buffer] Failed to load text file: \(error)")
            return item.textContent // Fallback to inline preview
        }
    }

    /// Load a chunk of text content, reading only what's necessary.
    /// `nonisolated`: `HistoryViewModel` calls it from a detached task so a
    /// large file never blocks the main thread.
    nonisolated func textChunk(for item: ClipboardItem, charCount: Int) -> (text: String, totalBytes: Int, reachedEOF: Bool)? {
        if let filename = item.textFilename {
            // File-backed large text
            let url = textsDirectory.appendingPathComponent(filename)

            do {
                // Get total size from attributes without reading file
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let totalBytes = attributes[.size] as? Int ?? 0

                // Read a chunk that should contain enough characters
                // UTF-8 can be up to 4 bytes per character, so we read charCount * 4
                // to guarantee we have enough bytes for the requested characters
                let maximumBytesToRead = min(charCount * 4, totalBytes)

                let fileHandle = try FileHandle(forReadingFrom: url)
                defer { try? fileHandle.close() }

                let data = try fileHandle.read(upToCount: maximumBytesToRead) ?? Data()

                // Decode to string and take exact requested characters
                let fullChunkStr = String(decoding: data, as: UTF8.self)
                let exactChunkStr = String(fullChunkStr.prefix(charCount))

                // If the decoded string length is less than requested, we hit EOF
                let reachedEOF = fullChunkStr.count < charCount

                return (exactChunkStr, totalBytes, reachedEOF)

            } catch {
                // 5A-28: the backing file is gone. `fullText` already falls
                // back to the inline preview, so the chunked preview does too
                // rather than rendering an empty pane with no explanation.
                print("[Buffer] Failed to read text chunk, falling back to the inline preview: \(error)")
                let content = item.textContent ?? ""
                return (String(content.prefix(charCount)), content.utf8.count, content.count <= charCount)
            }
        } else {
            // Inline text
            let content = item.textContent ?? ""
            let totalBytes = content.utf8.count

            let prefix = String(content.prefix(charCount))
            let reachedEOF = content.count <= charCount

            return (prefix, totalBytes, reachedEOF)
        }
    }

    /// Get the total size of an item (in bytes) for UI display
    func itemSize(for item: ClipboardItem) -> Int? {
        if let attachment = item.fileAttachment {
            return Int(attachment.byteSize)
        }

        switch item.type {
        case .text:
            if let filename = item.textFilename {
                let url = textsDirectory.appendingPathComponent(filename)
                let attributes = try? fileManager.attributesOfItem(atPath: url.path)
                return attributes?[.size] as? Int
            } else {
                return item.textContent?.utf8.count
            }
        case .image:
            if let filename = item.imageFilename {
                let url = imagesDirectory.appendingPathComponent(filename)
                let attributes = try? fileManager.attributesOfItem(atPath: url.path)
                return attributes?[.size] as? Int
            }
        case .file:
            // Size lives on the attachment, handled above. A `.file` item with
            // no attachment is malformed; report nothing rather than guessing.
            return nil
        }
        return nil
    }

    /// Absolute on-disk URLs for a `.file` item's payload.
    ///
    /// Copied-in attachments resolve every name (`originalName` +
    /// `additionalNames`) under `files/<uuid>/`; reference attachments resolve
    /// the security-scoped bookmark first (it survives the original file being
    /// moved, as long as it's still on the same volume) and fall back to the
    /// plain `referencePath`. Anything that no longer exists on disk is
    /// silently skipped rather than returned as a dangling URL — callers that
    /// care whether something was dropped should check `fileIsMissing(_:)`.
    func fileURLs(for item: ClipboardItem) -> [URL] {
        guard let attachment = item.fileAttachment else { return [] }

        if let relative = attachment.storedRelativePath {
            let dir = storageDirectory.appendingPathComponent(relative, isDirectory: true)
            let names = [attachment.originalName] + attachment.additionalNames
            return names.compactMap { name in
                let url = dir.appendingPathComponent(name)
                return fileManager.fileExists(atPath: url.path) ? url : nil
            }
        }

        if let bookmark = attachment.bookmark {
            var isStale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale),
               fileManager.fileExists(atPath: resolved.path) {
                return [resolved]
            }
        }

        if let path = attachment.referencePath, fileManager.fileExists(atPath: path) {
            return [URL(fileURLWithPath: path)]
        }

        return []
    }

    /// True when a `.file` item's payload can no longer be found on disk —
    /// the reference was moved/deleted, or a copied-in file was removed from
    /// storage out of band. Callers use this to show a "file is missing"
    /// notice instead of silently doing nothing on paste/save.
    func fileIsMissing(_ item: ClipboardItem) -> Bool {
        guard item.fileAttachment != nil else { return false }
        return fileURLs(for: item).isEmpty
    }

    // MARK: - File capture (Phase 3F)

    /// Everything needed to decide copy-vs-reference and detect a repeat
    /// capture of the same files.
    fileprivate struct FileCaptureEntry {
        let url: URL
        let size: Int64
        let modificationDate: Date
        let isDirectory: Bool
    }

    /// Build a `.file` clipboard item from one or more file-system URLs found
    /// on the pasteboard (a Finder copy of any type/count — the single-image
    /// case is intercepted earlier by `ClipboardWatcher` and becomes an
    /// `.image` item instead).
    ///
    /// Copy policy: when the total size is within `SettingsManager.fileCopyCapMB`
    /// (`0` = unlimited) every file is copied into `files/<uuid>/<name>`,
    /// preserving original names (directories copied recursively). Above the
    /// cap — or if the copy fails for any reason — only a reference is kept:
    /// the first file's path plus a bookmark, so it survives a move as long as
    /// it stays on the same volume.
    ///
    /// Returns the item together with a stable fingerprint (SHA-256 of every
    /// path + size + modification date) so the caller can dedupe a repeat
    /// capture of the same files, the same way text/image content is deduped.
    /// Everything `makeFileItem` needs, computed **without copying anything**
    /// (5A-08): the caller fingerprints first, drops a repeat capture, and only
    /// then asks for the item. Copying first and deduping afterwards left a
    /// full second copy of every re-copied file orphaned under `files/`.
    struct FileCapturePlan {
        let fingerprint: String
        fileprivate let entries: [FileCaptureEntry]
        fileprivate let totalSize: Int64
    }

    /// Stats the URLs and computes the dedupe fingerprint. No I/O beyond
    /// metadata reads; safe to call for every capture.
    func planFileCapture(from urls: [URL]) -> FileCapturePlan? {
        guard !urls.isEmpty else { return nil }

        var entries: [FileCaptureEntry] = []
        var totalSize: Int64 = 0
        for url in urls {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            let size = isDir.boolValue ? directorySize(url) : fileSize(url)
            let mtime = modificationDate(url)
            entries.append(FileCaptureEntry(url: url, size: size, modificationDate: mtime, isDirectory: isDir.boolValue))
            totalSize += size
        }
        guard !entries.isEmpty else { return nil }

        let fingerprint = Self.fingerprint(for: entries.map { ($0.url.path, $0.size, $0.modificationDate) })
        return FileCapturePlan(fingerprint: fingerprint, entries: entries, totalSize: totalSize)
    }

    /// Convenience for callers that do not need to dedupe before copying
    /// (tests, and any single-shot capture).
    func makeFileItem(from urls: [URL], sourceApp: String?) -> (item: ClipboardItem, fingerprint: String)? {
        guard let plan = planFileCapture(from: urls) else { return nil }
        guard let item = makeFileItem(from: plan, sourceApp: sourceApp) else { return nil }
        return (item, plan.fingerprint)
    }

    func makeFileItem(from plan: FileCapturePlan, sourceApp: String?) -> ClipboardItem? {
        let entries = plan.entries
        let totalSize = plan.totalSize
        guard !entries.isEmpty else { return nil }

        let names = entries.map { $0.url.lastPathComponent }
        let firstName = names[0]
        let restNames = Array(names.dropFirst())
        let ext = (firstName as NSString).pathExtension
        let uti = ext.isEmpty ? nil : UTType(filenameExtension: ext)?.identifier

        let capMB = SettingsManager.shared.fileCopyCapMB
        let withinCap = capMB <= 0 ? true : totalSize <= Int64(capMB) * 1_048_576

        // Generated up front and threaded through to `copyIntoStorage` so the
        // `files/<uuid>/` directory name matches the item's own `id` — the
        // row badge, preview pane and `deleteAssociatedFiles` all key off
        // `item.id`, not a separately-generated one.
        let itemID = UUID()

        if withinCap, let attachment = copyIntoStorage(id: itemID, entries: entries, uti: uti, totalSize: totalSize) {
            return ClipboardItem(
                id: itemID,
                type: .file,
                sourceApp: sourceApp,
                kind: .file,
                fileAttachment: attachment,
                // 5B: keyed on the ORIGINAL names, not the uniquified stored
                // ones, so the same selection copied twice matches even when
                // `copyIntoStorage` had to rename a collision the second time.
                contentKey: ClipboardItem.contentKey(forFileNames: names, byteSize: totalSize)
            )
        }

        // Above the cap, or the copy failed: keep only a reference to the
        // first file (the model has room for one reference path).
        guard let primary = entries.first else { return nil }
        let bookmark = try? primary.url.bookmarkData()
        let attachment = FileAttachment(
            originalName: firstName,
            additionalNames: restNames,
            storedRelativePath: nil,
            referencePath: primary.url.path,
            bookmark: bookmark,
            uti: uti,
            byteSize: totalSize
        )
        return ClipboardItem(
            id: itemID,
            type: .file,
            sourceApp: sourceApp,
            kind: .file,
            fileAttachment: attachment,
            contentKey: ClipboardItem.contentKey(forFileNames: names, byteSize: totalSize)
        )
    }

    /// Copies every entry into a fresh `files/<id>/` directory (named after
    /// the item's own id, passed in by the caller), preserving original
    /// names. Returns `nil` (leaving nothing behind) if any copy fails, so
    /// the caller can fall back to a reference instead of leaving a
    /// half-copied directory around.
    ///
    /// 5A-09: two files with the same basename in one selection
    /// (`~/a/report.pdf` + `~/b/report.pdf`) used to make the second
    /// `copyItem` throw, which threw away the whole copy and degraded the clip
    /// to a reference to the *first* file only — the second was unrecoverable.
    /// Duplicate names are uniquified (`report (2).pdf`) instead, and the
    /// stored names are what the attachment records, so `fileURLs(for:)`
    /// resolves every file.
    private func copyIntoStorage(
        id uuid: UUID,
        entries: [FileCaptureEntry],
        uti: String?,
        totalSize: Int64
    ) -> FileAttachment? {
        let destDir = filesDirectory.appendingPathComponent(uuid.uuidString, isDirectory: true)
        var storedNames: [String] = []
        do {
            try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)
            var used = Set<String>()
            for entry in entries {
                let name = Self.uniqueName(entry.url.lastPathComponent, taken: &used)
                storedNames.append(name)
                try fileManager.copyItem(at: entry.url, to: destDir.appendingPathComponent(name))
            }
        } catch {
            print("[Buffer] Failed to copy files into storage, falling back to a reference: \(error)")
            try? fileManager.removeItem(at: destDir)
            return nil
        }
        guard let firstStored = storedNames.first else { return nil }

        return FileAttachment(
            originalName: firstStored,
            additionalNames: Array(storedNames.dropFirst()),
            storedRelativePath: "files/\(uuid.uuidString)",
            referencePath: nil,
            bookmark: nil,
            uti: uti,
            byteSize: totalSize
        )
    }

    /// `report.pdf` → `report (2).pdf` → `report (3).pdf` … Mirrors
    /// `PasteController.uniqueURL`'s naming so the two agree.
    static func uniqueName(_ name: String, taken: inout Set<String>) -> String {
        if !taken.contains(name) {
            taken.insert(name)
            return name
        }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            if !taken.contains(candidate) {
                taken.insert(candidate)
                return candidate
            }
            counter += 1
        }
    }

    private func fileSize(_ url: URL) -> Int64 {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return 0 }
        if let size = attributes[.size] as? Int64 { return size }
        if let size = attributes[.size] as? Int { return Int64(size) }
        return 0
    }

    private func modificationDate(_ url: URL) -> Date {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return Date(timeIntervalSince1970: 0)
        }
        return attributes[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey], options: [], errorHandler: nil) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Stable SHA-256 fingerprint of a file list's paths, sizes and
    /// modification dates — sorted by path first so capture order never
    /// changes the result. Same files copied twice in a row (e.g. an
    /// accidental double ⌘C in Finder) produce the same fingerprint, which is
    /// how `ClipboardWatcher` skips the repeat.
    static func fingerprint(for entries: [(path: String, size: Int64, modificationDate: Date)]) -> String {
        var hasher = SHA256()
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            hasher.update(data: Data(entry.path.utf8))
            hasher.update(data: withUnsafeBytes(of: entry.size.bigEndian) { Data($0) })
            let millis = Int64(entry.modificationDate.timeIntervalSince1970 * 1000)
            hasher.update(data: withUnsafeBytes(of: millis.bigEndian) { Data($0) })
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Saving

    /// Schedule a debounced write of the current items. Safe to call from the
    /// main thread after any mutation.
    private func scheduleSave() {
        notifySyncOfLocalMutation()   // Phase 4A
        let snapshot = items
        saveQueue.async { [weak self] in
            guard let self = self else { return }
            self.pendingItems = snapshot
            let now = Date()
            if self.firstPendingMutationAt == nil { self.firstPendingMutationAt = now }
            self.pendingSaveWorkItem?.cancel()

            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.pendingSaveWorkItem = nil
                self.firstPendingMutationAt = nil
                guard let toSave = self.pendingItems else { return }
                self.pendingItems = nil
                self.saveHistoryToDisk(toSave)
            }
            self.pendingSaveWorkItem = work

            // 5A-13: trailing debounce **with a maximum delay**. A mutation
            // source faster than the 300 ms window (a scripted burst, a remote
            // merge loop) would otherwise re-arm the timer forever and nothing
            // would ever reach disk; the oldest unwritten mutation can never be
            // more than `saveMaxDelay` old.
            let firstPending = self.firstPendingMutationAt ?? now
            let deadline = min(
                now.addingTimeInterval(Self.saveDebounceInterval),
                firstPending.addingTimeInterval(Self.saveMaxDelay)
            )
            let delay = max(0, deadline.timeIntervalSince(now))
            self.saveQueue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// Write any debounced history immediately and wait for it to land.
    /// Called from `applicationWillTerminate` and by tests before reading files.
    func flushPendingSave() {
        saveQueue.sync {
            self.pendingSaveWorkItem?.cancel()
            self.pendingSaveWorkItem = nil
            self.firstPendingMutationAt = nil
            if let toSave = self.pendingItems {
                self.pendingItems = nil
                self.saveHistoryToDisk(toSave)
            }
            // Phase 4A / 5A-03: the sync-ignore write is debounced too.
            self.pendingSyncIgnoreWorkItem?.cancel()
            self.pendingSyncIgnoreWorkItem = nil
            if let ignore = self.pendingSyncIgnore {
                self.pendingSyncIgnore = nil
                self.writeSyncIgnore(ignore.entries, to: ignore.url)
            }
        }
    }

    // MARK: - Private

    /// Runs `action` on the main thread and waits for it, so `@discardableResult`
    /// return values are meaningful for callers already on main.
    private func performOnMainSync(_ action: () -> Void) {
        if Thread.isMainThread {
            action()
        } else {
            DispatchQueue.main.sync(execute: action)
        }
    }

    private func sortFolders() {
        folders.sort { lhs, rhs in
            lhs.sortIndex == rhs.sortIndex ? lhs.createdAt < rhs.createdAt : lhs.sortIndex < rhs.sortIndex
        }
    }

    private func ensureDirectoriesExist() {
        try? fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: textsDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: flavorsDirectory, withIntermediateDirectories: true)
    }

    /// Rename a file that failed to decode so it is preserved for inspection
    /// instead of being silently overwritten by the next save.
    private func quarantine(_ url: URL, prefix: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: Date())
        var destination = url.deletingLastPathComponent()
            .appendingPathComponent("\(prefix).corrupt-\(stamp).json")

        // Collision within the same second — very unlikely, still cheap to handle.
        var suffix = 1
        while fileManager.fileExists(atPath: destination.path) {
            destination = url.deletingLastPathComponent()
                .appendingPathComponent("\(prefix).corrupt-\(stamp)-\(suffix).json")
            suffix += 1
        }

        do {
            try fileManager.moveItem(at: url, to: destination)
            print("[Buffer] Quarantined undecodable \(url.lastPathComponent) as \(destination.lastPathComponent)")
        } catch {
            print("[Buffer] Failed to quarantine \(url.lastPathComponent): \(error)")
        }
    }

    /// Same as `quarantine`, but keeps the original in place: used when the
    /// file decoded *partially* (5A-05) — the good records are loaded and will
    /// be re-saved over the original, so the raw bytes are preserved next to it
    /// instead of being lost by that rewrite.
    private func quarantineCopy(_ url: URL, prefix: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: Date())
        var destination = url.deletingLastPathComponent()
            .appendingPathComponent("\(prefix).corrupt-\(stamp).json")

        var suffix = 1
        while fileManager.fileExists(atPath: destination.path) {
            destination = url.deletingLastPathComponent()
                .appendingPathComponent("\(prefix).corrupt-\(stamp)-\(suffix).json")
            suffix += 1
        }

        do {
            try fileManager.copyItem(at: url, to: destination)
            print("[Buffer] Kept a copy of the partially-decodable \(url.lastPathComponent) as \(destination.lastPathComponent)")
        } catch {
            print("[Buffer] Failed to copy \(url.lastPathComponent) aside: \(error)")
        }
    }

    /// Decodes one element without letting its failure take the whole array
    /// down (5A-05). `value` is `nil` for a record that could not be decoded.
    private struct Failable<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            value = try? container.decode(T.self)
        }
    }

    private struct LenientHistoryFile: Decodable {
        var version: Int
        var items: [Failable<ClipboardItem>]
    }

    private struct LenientFoldersFile: Decodable {
        var version: Int
        var folders: [Failable<Folder>]
    }

    /// True when `history.json` decoded with nothing dropped and nothing
    /// quarantined. The launch-time orphan sweep only runs in that case: after
    /// a partial or failed load the store does not know about every asset it
    /// owns, and deleting the "unreferenced" ones would destroy real data.
    private var historyLoadWasClean = true
    /// Same guard as `historyLoadWasClean`, for `trash.json` (5D): an
    /// unreadable trash file must not let the orphan sweep delete the assets
    /// of clips that are still recoverable.
    private var trashLoadWasClean = true

    private func loadHistory() {
        guard fileManager.fileExists(atPath: historyFileURL.path) else {
            print("[Buffer] No history file found")
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: historyFileURL)
        } catch {
            print("[Buffer] Failed to read history: \(error)")
            historyLoadWasClean = false
            return
        }

        let decoder = JSONDecoder()

        // v2: { "version": 2, "items": [...] }
        if let file = try? decoder.decode(HistoryFile.self, from: data) {
            self.items = file.items
            print("[Buffer] Loaded \(file.items.count) items from history (v\(file.version))")
            return
        }

        // v1: a bare array. Re-saved in the v2 wrapper on the next write.
        if let legacy = try? decoder.decode([ClipboardItem].self, from: data) {
            self.items = legacy
            print("[Buffer] Loaded \(legacy.count) items from a v1 history file, upgrading to v2")
            scheduleSave()
            return
        }

        // 5A-05: one undecodable record must not cost the user the whole
        // history (including every locked clip). Retry per record, keep what
        // decodes, and preserve a copy of the raw file for inspection.
        if let lenient = try? decoder.decode(LenientHistoryFile.self, from: data) {
            let salvaged = lenient.items.compactMap { $0.value }
            let dropped = lenient.items.count - salvaged.count
            if !salvaged.isEmpty {
                self.items = salvaged
                historyLoadWasClean = false
                print("[Buffer] Loaded \(salvaged.count) items from history (v\(lenient.version)); skipped \(dropped) undecodable record(s)")
                quarantineCopy(historyFileURL, prefix: "history")
                scheduleSave()
                return
            }
        }
        if let lenientLegacy = try? decoder.decode([Failable<ClipboardItem>].self, from: data) {
            let salvaged = lenientLegacy.compactMap { $0.value }
            let dropped = lenientLegacy.count - salvaged.count
            if !salvaged.isEmpty {
                self.items = salvaged
                historyLoadWasClean = false
                print("[Buffer] Loaded \(salvaged.count) items from a v1 history file; skipped \(dropped) undecodable record(s)")
                quarantineCopy(historyFileURL, prefix: "history")
                scheduleSave()
                return
            }
        }

        print("[Buffer] Failed to decode history; starting empty")
        historyLoadWasClean = false
        quarantine(historyFileURL, prefix: "history")
    }

    private func saveHistoryToDisk(_ itemsToSave: [ClipboardItem]) {
        do {
            let file = HistoryFile(version: Self.historySchemaVersion, items: itemsToSave)
            let data = try JSONEncoder().encode(file)
            try data.write(to: historyFileURL, options: .atomic)
        } catch {
            print("[Buffer] Failed to save history: \(error)")
        }
    }

    private func loadFolders() {
        guard fileManager.fileExists(atPath: foldersFileURL.path) else {
            // Seed the versioned wrapper so the storage layout is complete and
            // self-describing from the first launch.
            saveFolders()
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: foldersFileURL)
        } catch {
            print("[Buffer] Failed to read folders: \(error)")
            return
        }

        let decoder = JSONDecoder()
        if let file = try? decoder.decode(FoldersFile.self, from: data) {
            self.folders = file.folders
            sortFolders()
            print("[Buffer] Loaded \(file.folders.count) folders (v\(file.version))")
            return
        }
        if let bare = try? decoder.decode([Folder].self, from: data) {
            self.folders = bare
            sortFolders()
            saveFolders()
            return
        }

        // 5A-05: same per-record leniency as the history file.
        if let lenient = try? decoder.decode(LenientFoldersFile.self, from: data) {
            let salvaged = lenient.folders.compactMap { $0.value }
            if !salvaged.isEmpty {
                self.folders = salvaged
                sortFolders()
                historyLoadWasClean = false
                print("[Buffer] Loaded \(salvaged.count) folders (v\(lenient.version)); skipped \(lenient.folders.count - salvaged.count) undecodable record(s)")
                quarantineCopy(foldersFileURL, prefix: "folders")
                saveFolders()
                return
            }
        }

        print("[Buffer] Failed to decode folders; starting with none")
        historyLoadWasClean = false
        quarantine(foldersFileURL, prefix: "folders")
    }

    /// Folders are tiny and mutated rarely, so they are written straight
    /// through (atomically) rather than debounced — but **asynchronously**
    /// (5A-24): `saveQueue` is also where the debounced 10,000-item history
    /// encode runs, so a synchronous hop blocked the UI for however long that
    /// write had left. Nothing needs the result; `flushPendingSave()` drains
    /// the queue when a caller (or a test) needs the bytes on disk.
    private func saveFolders() {
        notifySyncOfLocalMutation()   // Phase 4A
        let url = foldersFileURL
        let data: Data
        do {
            data = try JSONEncoder().encode(FoldersFile(version: Self.foldersSchemaVersion, folders: folders))
        } catch {
            print("[Buffer] Failed to encode folders: \(error)")
            return
        }
        saveQueue.async {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                print("[Buffer] Failed to save folders: \(error)")
            }
        }
    }

    /// Delete every on-disk asset belonging to an item: image, text file,
    /// copied file payload (`files/<uuid>/`), archived flavors
    /// (`flavors/<uuid>.plist`) and the RTF flavor (`texts/<uuid>.rtf`).
    private func deleteAssociatedFiles(for item: ClipboardItem, keeping referenced: Set<String> = []) {
        if item.type == .image, let filename = item.imageFilename, !referenced.contains("images/\(filename)") {
            try? fileManager.removeItem(at: imagesDirectory.appendingPathComponent(filename))
        }
        if let filename = item.textFilename, !referenced.contains("texts/\(filename)") {
            try? fileManager.removeItem(at: textsDirectory.appendingPathComponent(filename))
        }

        if !referenced.contains("files/\(item.id.uuidString)") {
            let itemFiles = filesDirectory.appendingPathComponent(item.id.uuidString, isDirectory: true)
            if fileManager.fileExists(atPath: itemFiles.path) {
                try? fileManager.removeItem(at: itemFiles)
            }
        }

        let flavors = item.flavorsFilename ?? "\(item.id.uuidString).plist"
        if !referenced.contains("flavors/\(flavors)") {
            let flavorsURL = flavorsDirectory.appendingPathComponent(flavors)
            if fileManager.fileExists(atPath: flavorsURL.path) {
                try? fileManager.removeItem(at: flavorsURL)
            }
        }

        let rtf = item.rtfFilename ?? "\(item.id.uuidString).rtf"
        if !referenced.contains("texts/\(rtf)") {
            let rtfURL = textsDirectory.appendingPathComponent(rtf)
            if fileManager.fileExists(atPath: rtfURL.path) {
                try? fileManager.removeItem(at: rtfURL)
            }
        }
    }

    /// Storage-relative names every one of `items` still points at — what a
    /// delete must not touch (5A-18).
    private func referencedAssetNames(in items: [ClipboardItem]) -> Set<String> {
        var referenced = Set<String>()
        for item in items {
            if let name = item.imageFilename { referenced.insert("images/\(name)") }
            if let name = item.textFilename { referenced.insert("texts/\(name)") }
            if let name = item.rtfFilename { referenced.insert("texts/\(name)") }
            if let name = item.flavorsFilename { referenced.insert("flavors/\(name)") }
            if let relative = item.fileAttachment?.storedRelativePath { referenced.insert(relative) }
        }
        return referenced
    }

    // ==========================================================================
    // MARK: - Phase 4A: iCloud Drive sync hooks (owned by task 4A)
    //
    // Everything the sync service needs from the store lives in this one block:
    // the `updatedAt` bump helper used by the mutations above, the two delete
    // paths it has to tell apart (explicit delete -> tombstone, cap eviction ->
    // sync-ignore), the merge application path, and the cloud-root override.
    // Nothing here does any cloud I/O — that is `Services/CloudDriveSync.swift`.
    // ==========================================================================

    /// Called after any local mutation was scheduled for persistence, so the
    /// sync service can debounce a push. Never fires while a remote merge is
    /// being applied (that would push straight back what was just pulled).
    var onLocalMutation: (() -> Void)?

    /// Ids removed by an **explicit** delete (single, batch, clear, folder
    /// delete). The sync service turns these into tombstones so the delete
    /// propagates. Evictions never come through here.
    var onItemsDeleted: (([UUID]) -> Void)?

    /// Ids put back from the trash (5D). The sync service retracts its own
    /// tombstone for them, so restoring a clip on this Mac does not have the
    /// next merge delete it all over again.
    var onItemsRestored: (([UUID]) -> Void)?

    /// A folder the user deleted, for `deletedFolders` tombstones.
    var onFolderDeleted: ((UUID) -> Void)?

    /// True while `applyRemoteMerge` is writing pulled state into the store.
    private var isApplyingRemoteMerge = false

    /// Ids this device evicted because of the history cap, with the date. They
    /// must not come back from another device's snapshot — an eviction is a
    /// local storage decision, not a delete. Pruned at 30 days
    /// (`SyncMerge.ignoreLifetime`), persisted in `sync-ignore.json`.
    private(set) var syncIgnoredIDs: [UUID: Date] = [:]

    private var syncIgnoreFileURL: URL {
        storageDirectory.appendingPathComponent("sync-ignore.json")
    }

    private struct SyncIgnoreEntry: Codable {
        let id: UUID
        let date: Date
    }

    private struct SyncIgnoreFile: Codable {
        var version: Int
        var ignored: [SyncIgnoreEntry]
    }

    /// The iCloud Drive container this Mac syncs through, or `nil` when iCloud
    /// Drive is not set up. `KLIP_CLOUD_ROOT` overrides it (the way an
    /// explicit `directory` overrides the local store), so manual tests and
    /// the test suite never touch the user's real iCloud Drive.
    static var cloudSyncRoot: URL? {
        if let override = ProcessInfo.processInfo.environment["KLIP_CLOUD_ROOT"], !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Storage locations the sync service mirrors

    var syncStorageRoot: URL { storageDirectory }
    var syncImagesDirectory: URL { imagesDirectory }
    var syncTextsDirectory: URL { textsDirectory }
    var syncFilesDirectory: URL { filesDirectory }
    var syncFlavorsDirectory: URL { flavorsDirectory }

    // MARK: Mutation bookkeeping

    /// Stamps an item as changed now. Called by every mutation above so a
    /// same-`id` conflict between two Macs resolves to the newer edit.
    private func touchItem(at index: Int) {
        guard items.indices.contains(index) else { return }
        items[index].updatedAt = Date()
    }

    private func notifySyncOfLocalMutation() {
        guard !isApplyingRemoteMerge else { return }
        onLocalMutation?()
    }

    private func noteDeleted(_ ids: [UUID]) {
        guard !ids.isEmpty, !isApplyingRemoteMerge else { return }
        onItemsDeleted?(ids)
    }

    private func noteRestored(_ ids: [UUID]) {
        guard !ids.isEmpty, !isApplyingRemoteMerge else { return }
        onItemsRestored?(ids)
    }

    private func noteFolderDeleted(_ id: UUID) {
        guard !isApplyingRemoteMerge else { return }
        onFolderDeleted?(id)
    }

    /// True when the sync-ignore list is worth maintaining at all (5A-03).
    ///
    /// `sync-ignore.json` only ever matters to `SyncMerge`, so on a Mac that has
    /// never turned iCloud sync on it is pure overhead — and it is paid on the
    /// main thread on *every* copy once the history sits at its cap. "Has ever
    /// been on" is judged by the setting itself, an existing `sync-ignore.json`,
    /// or a recorded push/pull (which only happen once a device directory has
    /// been created). Turning sync on mid-session flips this on immediately.
    private var syncBookkeepingNeeded: Bool {
        if syncIsEnabledNow {
            syncWasEverEnabled = true
            return true
        }
        return syncWasEverEnabled
    }

    private var syncIsEnabledNow: Bool {
        if let raw = ProcessInfo.processInfo.environment["KLIP_SYNC_ENABLED"], !raw.isEmpty {
            return raw == "1"
        }
        return SettingsManager.shared.syncEnabled
    }

    private lazy var syncWasEverEnabled: Bool = fileManager.fileExists(atPath: syncIgnoreFileURL.path)
        || SettingsManager.shared.syncLastPush != nil
        || SettingsManager.shared.syncLastPull != nil

    /// Records a cap eviction. Deliberately does **not** produce a tombstone:
    /// other devices keep their copy, this one just does not want it back.
    private func noteEvicted(_ ids: [UUID]) {
        guard !isApplyingRemoteMerge else { return }
        // 5A-03: nothing reads this list unless sync is (or has been) on, and
        // maintaining it costs a main-thread rewrite of the whole file on every
        // copy once the history sits at its cap.
        guard syncBookkeepingNeeded else { return }
        recordEvictions(ids)
    }

    /// Adds ids to the sync-ignore list unconditionally. `noteEvicted` is the
    /// guarded entry point for normal mutations; the merge path calls this one
    /// directly, because trimming a pulled history *is* an eviction even though
    /// it happens while a merge is being applied.
    private func recordEvictions(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let now = Date()
        for id in ids { syncIgnoredIDs[id] = now }
        pruneSyncIgnore(now: now)
        saveSyncIgnore()
    }

    /// A pull can legitimately bring in more clips than this Mac's history
    /// limit allows (the other Mac may keep 10,000 where this one keeps 1,000).
    /// Trim to the limit right away instead of leaving the store over its cap
    /// until the next copy, using exactly the same rule as `performAdd`:
    /// protected clips are never evicted and never count. The trimmed ids go
    /// into the sync-ignore list, so they do not come straight back on the next
    /// pull, and — because this is an eviction, not a delete — no tombstone is
    /// written, so the other Mac keeps its copy.
    private func trimToLimitAfterMerge() {
        guard let limit = maxItems else { return }
        var unprotectedCount = items.reduce(0) { $0 + ($1.isProtected ? 0 : 1) }
        guard unprotectedCount > limit else { return }

        var evicted: [UUID] = []
        while unprotectedCount > limit,
              let index = items.lastIndex(where: { !$0.isProtected }) {
            let removed = items.remove(at: index)
            deleteAssociatedFiles(for: removed)
            evicted.append(removed.id)
            unprotectedCount -= 1
        }
        recordEvictions(evicted)
    }

    /// Trims a store that is already over its cap at launch, once, in one pass
    /// (5A-02). Without this a `history.json` holding 10,000 clips under a
    /// 1,000 cap stayed over the cap forever, and the *next* copy paid for all
    /// 9,000 evictions inside a single `add()` on the main thread.
    private func trimToLimitAtLaunch() {
        guard let limit = maxItems else { return }
        var unprotectedCount = items.reduce(0) { $0 + ($1.isProtected ? 0 : 1) }
        guard unprotectedCount > limit else { return }

        var evicted: [UUID] = []
        while unprotectedCount > limit,
              let index = items.lastIndex(where: { !$0.isProtected }) {
            let removed = items.remove(at: index)
            deleteAssociatedFiles(for: removed)
            evicted.append(removed.id)
            unprotectedCount -= 1
        }
        print("[Buffer] Trimmed \(evicted.count) items over the history limit at launch")
        noteEvicted(evicted)
        scheduleSave()
    }

    /// Assets on disk that no item references any more, deleted once per launch
    /// on a utility queue (5A-08). Sources of orphans: a capture that was
    /// deduped after its bytes were written, a `kill -9` inside the save
    /// debounce, an interrupted merge.
    ///
    /// Deliberately conservative: it never runs when the history did not load
    /// cleanly (a partially decoded file does not know about all of its
    /// assets), and it skips anything modified in the last minute so a capture
    /// in flight can never be swept out from under itself.
    private func sweepOrphanedAssets() {
        guard historyLoadWasClean, trashLoadWasClean else {
            print("[Buffer] Orphan sweep skipped: the history or trash did not load cleanly")
            return
        }
        var referenced = Set<String>()
        // 5D: trashed clips still own their assets — they are only removed
        // when the record is purged — so they count as referenced here.
        for item in items + trashedItems {
            if let name = item.imageFilename { referenced.insert("images/\(name)") }
            if let name = item.textFilename { referenced.insert("texts/\(name)") }
            if let name = item.rtfFilename { referenced.insert("texts/\(name)") }
            if let name = item.flavorsFilename { referenced.insert("flavors/\(name)") }
            // `deleteAssociatedFiles` also probes these id-derived defaults, so
            // an item that carries the file without recording the name keeps it.
            referenced.insert("texts/\(item.id.uuidString).rtf")
            referenced.insert("flavors/\(item.id.uuidString).plist")
            referenced.insert("files/\(item.id.uuidString)")
            if let relative = item.fileAttachment?.storedRelativePath { referenced.insert(relative) }
        }

        let directories: [(String, URL)] = [
            ("images", imagesDirectory),
            ("texts", textsDirectory),
            ("files", filesDirectory),
            ("flavors", flavorsDirectory),
        ]
        let cutoff = Date().addingTimeInterval(-60)
        let manager = fileManager

        DispatchQueue.global(qos: .utility).async {
            var removed = 0
            var bytes: Int64 = 0
            for (label, directory) in directories {
                guard let contents = try? manager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.contentModificationDateKey, .totalFileAllocatedSizeKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for url in contents {
                    let relative = "\(label)/\(url.lastPathComponent)"
                    guard !referenced.contains(relative) else { continue }
                    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .totalFileAllocatedSizeKey])
                    if let modified = values?.contentModificationDate, modified > cutoff { continue }
                    bytes += Int64(values?.totalFileAllocatedSize ?? 0)
                    if (try? manager.removeItem(at: url)) != nil { removed += 1 }
                }
            }
            if removed > 0 {
                print("[Buffer] Orphan sweep: removed \(removed) unreferenced asset(s) (~\(bytes / 1024) KB)")
            }
        }
    }

    private func pruneSyncIgnore(now: Date) {
        let cutoff = now.addingTimeInterval(-SyncMerge.ignoreLifetime)
        syncIgnoredIDs = syncIgnoredIDs.filter { $0.value > cutoff }
    }

    private func loadSyncIgnore() {
        guard fileManager.fileExists(atPath: syncIgnoreFileURL.path) else { return }
        do {
            let data = try Data(contentsOf: syncIgnoreFileURL)
            let file = try JSONDecoder().decode(SyncIgnoreFile.self, from: data)
            syncIgnoredIDs = Dictionary(file.ignored.map { ($0.id, $0.date) }, uniquingKeysWith: max)
            pruneSyncIgnore(now: Date())
        } catch {
            print("[Klip] Sync: ignoring unreadable sync-ignore.json: \(error)")
        }
    }

    /// Debounce for the sync-ignore write, on the same principle as the history
    /// write: a burst of evictions must collapse into one file rewrite.
    private static let syncIgnoreDebounceInterval: TimeInterval = 0.3

    // `saveQueue` only.
    private var pendingSyncIgnore: (entries: [SyncIgnoreEntry], url: URL)?
    private var pendingSyncIgnoreWorkItem: DispatchWorkItem?

    /// Writes `sync-ignore.json` **asynchronously and debounced** (5A-02,
    /// 5A-03). It used to be a `saveQueue.sync` + full re-encode per evicted
    /// id, on the main thread — 24 ms per copy with 9,000 entries, and 118 s
    /// for one `add()` that evicted 9,000 items.
    private func saveSyncIgnore() {
        let entries = syncIgnoredIDs.map { SyncIgnoreEntry(id: $0.key, date: $0.value) }
        let url = syncIgnoreFileURL
        saveQueue.async { [weak self] in
            guard let self = self else { return }
            self.pendingSyncIgnore = (entries, url)
            self.pendingSyncIgnoreWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.pendingSyncIgnoreWorkItem = nil
                guard let pending = self.pendingSyncIgnore else { return }
                self.pendingSyncIgnore = nil
                self.writeSyncIgnore(pending.entries, to: pending.url)
            }
            self.pendingSyncIgnoreWorkItem = work
            self.saveQueue.asyncAfter(deadline: .now() + Self.syncIgnoreDebounceInterval, execute: work)
        }
    }

    /// `saveQueue` only.
    private func writeSyncIgnore(_ entries: [SyncIgnoreEntry], to url: URL) {
        do {
            let file = SyncIgnoreFile(
                version: 1,
                ignored: entries.sorted { $0.id.uuidString < $1.id.uuidString }
            )
            try JSONEncoder().encode(file).write(to: url, options: .atomic)
        } catch {
            print("[Klip] Sync: failed to write sync-ignore.json: \(error)")
        }
    }

    // MARK: Applying a pull

    /// Writes a merged result from `SyncMerge` into the store. Runs on the main
    /// actor, deletes the on-disk assets of items the merge dropped, and never
    /// re-triggers a push (the sync service decides that itself, so a pull can
    /// never ping-pong).
    func applyRemoteMerge(_ result: SyncMerge.Result) {
        performOnMainSync { [weak self] in
            guard let self = self else { return }
            self.isApplyingRemoteMerge = true
            defer { self.isApplyingRemoteMerge = false }

            // 5A-06 / 4B #3: a lock is absolute. `SyncMerge` already refuses to
            // let a tombstone delete a locked record; this is the second line
            // of defence — nothing a merge decided can drop a locked local clip
            // or its bytes, whatever produced the decision.
            var merged = result.items
            let survivingIDs = Set(merged.map { $0.id })
            let rescued = result.removedItems.filter { $0.isLocked && !survivingIDs.contains($0.id) }
            if !rescued.isEmpty {
                print("[Klip] Sync: kept \(rescued.count) locked clip(s) another Mac deleted")
                merged.append(contentsOf: rescued)
                merged.sort { lhs, rhs in
                    lhs.timestamp == rhs.timestamp
                        ? lhs.id.uuidString < rhs.id.uuidString
                        : lhs.timestamp > rhs.timestamp
                }
            }

            // 5A-18: an asset a *surviving* item still points at is never
            // deleted. Two records can share one `images/<name>.png` (that is
            // exactly what the image dedupe folds), and the fold's loser used
            // to take the survivor's file with it. Content-equal survivors
            // (the dedupe path) keep the loser's payload too — the bytes are
            // still the item's, just under the winner's id.
            let keptIDs = Set(merged.map { $0.id })
            // 5D: a locally trashed clip still owns its bytes.
            let referenced = self.referencedAssetNames(in: merged + self.trashedItems)
            let survivingContentKeys = Set(merged.compactMap { SyncMerge.dedupeKey($0) })
            for removed in result.removedItems where !keptIDs.contains(removed.id) {
                if let key = SyncMerge.dedupeKey(removed), survivingContentKeys.contains(key) { continue }
                self.deleteAssociatedFiles(for: removed, keeping: referenced)
            }

            self.items = merged
            self.folders = result.folders
            self.sortFolders()
            self.trimToLimitAfterMerge()
            self.scheduleSave()
            self.saveFolders()
        }
    }

    /// Marks attachments the push skipped for being over the size cap. Applied
    /// under the remote-merge guard because it is bookkeeping, not a user edit:
    /// it must not bump `updatedAt` or schedule another push (it is idempotent,
    /// so a later push simply finds the flag already set).
    func markSyncSkippedLarge(ids: Set<UUID>, skipped: Bool = true) {
        guard !ids.isEmpty else { return }
        performOnMainSync { [weak self] in
            guard let self = self else { return }
            var changed = false
            self.isApplyingRemoteMerge = true
            defer { self.isApplyingRemoteMerge = false }
            for index in self.items.indices where ids.contains(self.items[index].id) {
                guard self.items[index].fileAttachment != nil,
                      self.items[index].fileAttachment?.syncSkippedLarge != skipped else { continue }
                self.items[index].fileAttachment?.syncSkippedLarge = skipped
                changed = true
            }
            if changed { self.scheduleSave() }
        }
    }
}
