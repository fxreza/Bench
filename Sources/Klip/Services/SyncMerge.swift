import Foundation

/// A record of an **explicit** deletion, published in a device's
/// `tombstones.json` so the delete propagates instead of the item coming back
/// from another device's snapshot.
///
/// Evictions (the history-cap trim) deliberately never produce a tombstone —
/// they are a local storage decision, not an intent to delete everywhere. The
/// evicting device remembers them in its own `sync-ignore.json` instead
/// (`ClipboardStore.syncIgnoredIDs`).
struct SyncTombstone: Codable, Equatable {
    let id: UUID
    let deletedAt: Date

    init(id: UUID, deletedAt: Date) {
        self.id = id
        self.deletedAt = deletedAt
    }
}

/// One other device's published state, read from `Klip/devices/<deviceID>/`.
struct SyncDeviceSnapshot: Equatable {
    let deviceID: String
    let deviceName: String
    let lastPush: Date
    var items: [ClipboardItem]
    var folders: [Folder]
    var deleted: [SyncTombstone]
    var deletedFolders: [SyncTombstone]

    init(
        deviceID: String,
        deviceName: String,
        lastPush: Date = .distantPast,
        items: [ClipboardItem] = [],
        folders: [Folder] = [],
        deleted: [SyncTombstone] = [],
        deletedFolders: [SyncTombstone] = []
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.lastPush = lastPush
        self.items = items
        self.folders = folders
        self.deleted = deleted
        self.deletedFolders = deletedFolders
    }
}

/// The pure, side-effect-free half of iCloud Drive sync: given this device's
/// state plus every *other* device's snapshot, work out what the history and
/// folder list should look like. No file I/O, no store access, no clock reads
/// (`now` is passed in) — every rule below is directly testable
/// (`Tests/SyncMergeTests.swift`).
///
/// Rules, in the order they are applied:
///  1. Tombstones from all devices are unioned (newest `deletedAt` per id) and
///     pruned at `tombstoneLifetime` (30 days).
///  2. Same `id` across devices: the record with the newest `updatedAt` wins
///     **whole-record**; `tags` are the union across all copies.
///  3. A tombstone newer than the surviving record's `updatedAt` deletes it.
///     An older tombstone loses — the item was edited (or re-created) after the
///     delete, so the edit wins. A **locked** surviving record is never deleted
///     by a tombstone at all: unlock first, then delete (5A-06 / 4B #3).
///  4. Ids in this device's sync-ignore list (evicted here) are dropped when
///     they only exist remotely, so a cap-evicted clip never resurrects.
///  5. Content dedupe: a remote item whose content matches a local item's
///     (different ids) folds into it — the **older** record survives, flags are
///     OR-ed, tags unioned, and a folder membership from either side is kept.
///  6. Folders follow rules 1-3 with `deletedFolders`; an item pointing at a
///     folder that no longer exists keeps its lock and loses only its
///     `folderID`.
enum SyncMerge {
    /// Tombstones older than this are pruned on every merge/push. Long enough
    /// for a Mac that was off for a month to still see the delete.
    static let tombstoneLifetime: TimeInterval = 30 * 24 * 60 * 60

    /// Sync-ignore entries expire on the same schedule as tombstones.
    static let ignoreLifetime: TimeInterval = 30 * 24 * 60 * 60

    struct Input {
        var localItems: [ClipboardItem]
        var localFolders: [Folder]
        /// Explicit deletes this device recorded (its own `tombstones.json`).
        var localDeleted: [SyncTombstone]
        var localDeletedFolders: [SyncTombstone]
        /// Ids this device evicted by the history cap, with the eviction date.
        var ignoredIDs: [UUID: Date]
        /// Every *other* device's snapshot. This device's own files are never
        /// passed in — pulling its own push would be a no-op at best.
        var remotes: [SyncDeviceSnapshot]
        var now: Date

        init(
            localItems: [ClipboardItem],
            localFolders: [Folder] = [],
            localDeleted: [SyncTombstone] = [],
            localDeletedFolders: [SyncTombstone] = [],
            ignoredIDs: [UUID: Date] = [:],
            remotes: [SyncDeviceSnapshot] = [],
            now: Date = Date()
        ) {
            self.localItems = localItems
            self.localFolders = localFolders
            self.localDeleted = localDeleted
            self.localDeletedFolders = localDeletedFolders
            self.ignoredIDs = ignoredIDs
            self.remotes = remotes
            self.now = now
        }
    }

    struct Result: Equatable {
        /// The merged history, newest first.
        var items: [ClipboardItem]
        /// The merged folders, sorted the way the store sorts them.
        var folders: [Folder]
        /// Union of every device's tombstones, pruned — what this device should
        /// publish next push so deletes propagate transitively.
        var deleted: [SyncTombstone]
        var deletedFolders: [SyncTombstone]
        /// Ids that were not in `localItems` and are in `items` — their
        /// attachments still have to be copied down from the cloud.
        var arrivedItemIDs: [UUID]
        /// Local items that did not survive the merge (tombstoned elsewhere, or
        /// folded into a duplicate). Their on-disk assets can be deleted.
        var removedItems: [ClipboardItem]
        /// False when the merge is a no-op — nothing to apply, nothing to push.
        var changed: Bool
    }

    /// Origin of a candidate record: this Mac, or another device's id.
    private static let localOrigin = ""

    // MARK: - Entry point

    static func merge(_ input: Input) -> Result {
        let cutoff = input.now.addingTimeInterval(-tombstoneLifetime)

        // 1. Tombstones: union, newest wins per id, prune the old ones.
        let itemTombstones = mergeTombstones(
            [input.localDeleted] + input.remotes.map { $0.deleted },
            cutoff: cutoff
        )
        let folderTombstones = mergeTombstones(
            [input.localDeletedFolders] + input.remotes.map { $0.deletedFolders },
            cutoff: cutoff
        )

        // 2/6. Folders: newest `updatedAt` per id, then tombstones.
        var folderVersions: [UUID: [(origin: String, folder: Folder)]] = [:]
        for folder in input.localFolders {
            folderVersions[folder.id, default: []].append((localOrigin, folder))
        }
        for remote in input.remotes.sorted(by: { $0.deviceID < $1.deviceID }) {
            for folder in remote.folders {
                folderVersions[folder.id, default: []].append((remote.deviceID, folder))
            }
        }

        var mergedFolders: [Folder] = []
        for (_, versions) in folderVersions {
            guard let winner = versions.max(by: { lhs, rhs in
                if lhs.folder.updatedAt != rhs.folder.updatedAt {
                    return lhs.folder.updatedAt < rhs.folder.updatedAt
                }
                // Deterministic tie-break: local first, then lowest device id.
                return lhs.origin > rhs.origin
            })?.folder else { continue }
            if let tomb = folderTombstones[winner.id], tomb.deletedAt > winner.updatedAt { continue }
            mergedFolders.append(winner)
        }
        mergedFolders.sort { lhs, rhs in
            lhs.sortIndex == rhs.sortIndex ? lhs.createdAt < rhs.createdAt : lhs.sortIndex < rhs.sortIndex
        }
        let liveFolderIDs = Set(mergedFolders.map { $0.id })

        // 2. Items: collect every version of every id.
        var itemVersions: [UUID: [(origin: String, item: ClipboardItem)]] = [:]
        for item in input.localItems {
            itemVersions[item.id, default: []].append((localOrigin, item))
        }
        for remote in input.remotes.sorted(by: { $0.deviceID < $1.deviceID }) {
            for item in remote.items {
                itemVersions[item.id, default: []].append((remote.deviceID, item))
            }
        }

        let localIDs = Set(input.localItems.map { $0.id })
        let liveIgnores = input.ignoredIDs.filter { $0.value > cutoff }

        var candidates: [Candidate] = []
        candidates.reserveCapacity(itemVersions.count)

        for (id, versions) in itemVersions {
            guard var winner = versions.max(by: { lhs, rhs in
                if lhs.item.updatedAt != rhs.item.updatedAt {
                    return lhs.item.updatedAt < rhs.item.updatedAt
                }
                return lhs.origin > rhs.origin
            })?.item else { continue }

            // Tags are unioned across every copy, not taken from the winner
            // alone — tagging on two Macs at once must not lose either tag.
            winner.tags = unionTags(of: versions.map { $0.item }, startingWith: winner.tags)

            // 3. A newer tombstone deletes; an older one is outranked by the
            //    edit — **unless the surviving record is locked** (5A-06,
            //    4B #3). "A locked item can never be deleted or evicted" is
            //    enforced locally by `ClipboardStore.delete`; a delete that
            //    arrived from another Mac must not be able to go around it.
            //    The locked copy stays and is republished on the next push, so
            //    the deleting Mac gets it back. Unlocking bumps `updatedAt`
            //    past the old tombstone, so that tombstone stays inert; a
            //    delete made *after* the unlock carries a newer `deletedAt` and
            //    removes the record as usual.
            if let tomb = itemTombstones[id], tomb.deletedAt > winner.updatedAt, !winner.isLocked { continue }

            let origins = Set(versions.map { $0.origin })

            // 4. Evicted here and only known remotely: do not resurrect it.
            if !origins.contains(localOrigin), liveIgnores[id] != nil { continue }

            candidates.append(Candidate(item: winner, origins: origins, isLocal: localIDs.contains(id)))
        }

        // 5. Content dedupe across devices.
        candidates = dedupe(candidates)

        // 6. Items orphaned by a deleted folder keep their lock, lose the folder.
        var merged = candidates.map { $0.item }
        for index in merged.indices {
            if let folderID = merged[index].folderID, !liveFolderIDs.contains(folderID) {
                merged[index].folderID = nil
            }
        }

        merged.sort { lhs, rhs in
            lhs.timestamp == rhs.timestamp
                ? lhs.id.uuidString < rhs.id.uuidString
                : lhs.timestamp > rhs.timestamp
        }

        let mergedIDs = Set(merged.map { $0.id })
        let arrived = merged.filter { !localIDs.contains($0.id) }.map { $0.id }
        let removed = input.localItems.filter { !mergedIDs.contains($0.id) }

        let sortedLocalFolders = input.localFolders.sorted { lhs, rhs in
            lhs.sortIndex == rhs.sortIndex ? lhs.createdAt < rhs.createdAt : lhs.sortIndex < rhs.sortIndex
        }

        return Result(
            items: merged,
            folders: mergedFolders,
            deleted: itemTombstones.values.sorted { $0.id.uuidString < $1.id.uuidString },
            deletedFolders: folderTombstones.values.sorted { $0.id.uuidString < $1.id.uuidString },
            arrivedItemIDs: arrived,
            removedItems: removed,
            changed: merged != input.localItems || mergedFolders != sortedLocalFolders
        )
    }

    // MARK: - Tombstones

    /// Union of every device's tombstone list: newest `deletedAt` per id,
    /// anything older than `cutoff` dropped.
    static func mergeTombstones(_ lists: [[SyncTombstone]], cutoff: Date) -> [UUID: SyncTombstone] {
        var result: [UUID: SyncTombstone] = [:]
        for list in lists {
            for tomb in list where tomb.deletedAt > cutoff {
                if let existing = result[tomb.id], existing.deletedAt >= tomb.deletedAt { continue }
                result[tomb.id] = tomb
            }
        }
        return result
    }

    /// Convenience for the push path: prune a single list.
    static func pruneTombstones(_ list: [SyncTombstone], now: Date) -> [SyncTombstone] {
        let cutoff = now.addingTimeInterval(-tombstoneLifetime)
        return mergeTombstones([list], cutoff: cutoff)
            .values
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    // MARK: - Dedupe

    private struct Candidate {
        var item: ClipboardItem
        var origins: Set<String>
        var isLocal: Bool
    }

    /// Content key used to spot the same clip captured under two different ids
    /// on two Macs. `nil` means "never dedupe this one" (no comparable content).
    /// The key is `ClipboardItem.contentHash` — process-local, which is fine
    /// because both sides are hashed inside this one merge — and a collision is
    /// caught by `sameContent` before anything is folded.
    static func dedupeKey(_ item: ClipboardItem) -> String? {
        if let attachment = item.fileAttachment {
            // 5A-17: keyed on what `sameContent` actually compares. It used to
            // be `contentHash`, which for a copied-in attachment hashes
            // `files/<item-uuid>` — unique by construction, so the same file
            // copied on two Macs never folded and every synced file
            // accumulated one record (and one payload) per device.
            guard !attachment.originalName.isEmpty else { return nil }
            let names = ([attachment.originalName] + attachment.additionalNames).joined(separator: "\u{1}")
            return "file:\(names):\(attachment.byteSize)"
        }
        switch item.type {
        case .text:
            guard let text = item.textContent, !text.isEmpty else { return nil }
            return "txt:\(item.contentHash):\(text.count)"
        case .image:
            guard let filename = item.imageFilename else { return nil }
            return "img:\(filename)"
        case .file:
            // Unreachable in practice: a `.file` item always carries an
            // attachment and is keyed above. Kept as the defensive answer for
            // a malformed record — never dedupe something with no content.
            return nil
        }
    }

    /// Guards against a `contentHash` collision folding two unrelated clips.
    private static func sameContent(_ lhs: ClipboardItem, _ rhs: ClipboardItem) -> Bool {
        guard lhs.type == rhs.type else { return false }
        if let l = lhs.fileAttachment, let r = rhs.fileAttachment {
            return l.originalName == r.originalName
                && l.additionalNames == r.additionalNames
                && l.byteSize == r.byteSize
        }
        if (lhs.fileAttachment == nil) != (rhs.fileAttachment == nil) { return false }
        switch lhs.type {
        case .text:  return lhs.textContent == rhs.textContent
        case .image: return lhs.imageFilename == rhs.imageFilename
        case .file:  return false
        }
    }

    /// Folds duplicate content coming from a *different* device into one
    /// record. Two clips that only ever existed on this Mac are never folded —
    /// copying the same text twice is a legitimate pair of history entries.
    private static func dedupe(_ candidates: [Candidate]) -> [Candidate] {
        var groups: [String: [Int]] = [:]
        for (index, candidate) in candidates.enumerated() {
            guard let key = dedupeKey(candidate.item) else { continue }
            groups[key, default: []].append(index)
        }

        var dropped = Set<Int>()
        var result = candidates

        for (_, indices) in groups where indices.count > 1 {
            // Process in a stable order so the outcome never depends on the
            // dictionary's iteration order.
            let ordered = indices.sorted {
                let a = candidates[$0].item, b = candidates[$1].item
                return a.timestamp == b.timestamp
                    ? a.id.uuidString < b.id.uuidString
                    : a.timestamp < b.timestamp
            }

            for (offset, winnerIndex) in ordered.enumerated() {
                guard !dropped.contains(winnerIndex) else { continue }
                for loserIndex in ordered.dropFirst(offset + 1) {
                    guard !dropped.contains(loserIndex) else { continue }
                    guard sameContent(result[winnerIndex].item, result[loserIndex].item) else { continue }
                    // Only fold across devices: two records that both already
                    // exist on this Mac stay two records (copying the same
                    // text twice is a legitimate pair of history entries), and
                    // so do two records that only ever existed on the same
                    // other device.
                    let winnerOrigins = result[winnerIndex].origins
                    let loserOrigins = result[loserIndex].origins
                    let bothLocal = winnerOrigins.contains(localOrigin) && loserOrigins.contains(localOrigin)
                    guard !bothLocal, winnerOrigins != loserOrigins else { continue }
                    result[winnerIndex] = fold(result[loserIndex], into: result[winnerIndex])
                    dropped.insert(loserIndex)
                }
            }
        }

        return result.enumerated().filter { !dropped.contains($0.offset) }.map { $0.element }
    }

    /// The older record survives; flags are OR-ed, tags unioned, a folder
    /// membership from either side is kept, and metadata the survivor lacks is
    /// filled in from the duplicate.
    private static func fold(_ loser: Candidate, into winner: Candidate) -> Candidate {
        var merged = winner
        merged.item.isPinned = winner.item.isPinned || loser.item.isPinned
        merged.item.isBookmarked = winner.item.isBookmarked || loser.item.isBookmarked
        merged.item.isLocked = winner.item.isLocked || loser.item.isLocked
        merged.item.tags = unionTags(of: [winner.item, loser.item], startingWith: winner.item.tags)
        merged.item.folderID = winner.item.folderID ?? loser.item.folderID
        if merged.item.ocrText == nil { merged.item.ocrText = loser.item.ocrText }
        if merged.item.kind == nil { merged.item.kind = loser.item.kind }
        merged.item.updatedAt = max(winner.item.updatedAt, loser.item.updatedAt)
        merged.origins.formUnion(loser.origins)
        merged.isLocal = winner.isLocal || loser.isLocal
        return merged
    }

    /// Order-stable tag union: `base` keeps its order, everything new is
    /// appended in the order the copies were visited.
    private static func unionTags(of items: [ClipboardItem], startingWith base: [String]) -> [String] {
        var seen = Set(base)
        var result = base
        for item in items {
            for tag in item.tags where !seen.contains(tag) {
                seen.insert(tag)
                result.append(tag)
            }
        }
        return result
    }
}
