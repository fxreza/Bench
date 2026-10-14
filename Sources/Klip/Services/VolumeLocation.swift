import Darwin
import Foundation

/// Where a reference clip's original file lives, read from the kernel's mount
/// table alone.
///
/// `getfsstat(MNT_NOWAIT)` returns what the kernel already knows and never
/// waits on a file system, so this is safe on the main thread even when a
/// network share has stopped answering. Touching a path inside that share is
/// not: `stat`/`fileExists` waits for the SMB timeout, and resolving a
/// bookmark to a share that is not mounted tries to mount it first. On
/// 2026-10-07 two such bookmark resolutions, for a clip from a sleeping
/// Mac's share, froze Bench's main thread for two minutes; every shortcut
/// pressed meanwhile fired at once afterwards.
nonisolated enum VolumeLocation: Equatable {
    /// A local disk: the startup disk, a USB drive, a disk image.
    case local
    /// A mounted network share (SMB, NFS, AFP, WebDAV), named by its mount
    /// point. Mounted does not mean answering.
    case network(mountPoint: String)
    /// Under `/Volumes/<name>` with nothing mounted there.
    case unmounted

    var isNetwork: Bool {
        if case .network = self { return true }
        return false
    }

    struct Mount: Equatable {
        let point: String
        let isLocal: Bool
    }

    static func of(path: String) -> VolumeLocation {
        of(path: path, mounts: currentMounts(), readLink: readSymbolicLink)
    }

    /// `readLink` returns the target of the symbolic link at a path, or nil
    /// when it is not one. It is only asked about `/Volumes/<name>` entries
    /// that are not mount points, which live on the startup disk.
    static func of(path: String, mounts: [Mount], readLink: (String) -> String?) -> VolumeLocation {
        // A failed mount table read says nothing; keep the old behaviour.
        guard !mounts.isEmpty else { return .local }
        return resolve(path: path, mounts: mounts, readLink: readLink, hops: 0)
    }

    private static func resolve(path: String, mounts: [Mount], readLink: (String) -> String?, hops: Int) -> VolumeLocation {
        let owner = mounts
            .filter { path == $0.point || path.hasPrefix($0.point == "/" ? "/" : $0.point + "/") }
            .max { $0.point.count < $1.point.count }

        if let root = volumesRoot(of: path), (owner?.point.count ?? 0) < root.count {
            // Nothing is mounted at /Volumes/<name>. It can still be a link,
            // like "/Volumes/Macintosh HD" -> "/".
            if hops < 4, let target = readLink(root) {
                let base = target.hasPrefix("/") ? target : "/Volumes/" + target
                let rest = path.dropFirst(root.count)
                let joined = base.hasSuffix("/") ? base + rest.drop { $0 == "/" } : base + rest
                return resolve(path: joined.isEmpty ? "/" : joined, mounts: mounts, readLink: readLink, hops: hops + 1)
            }
            return .unmounted
        }

        guard let owner, !owner.isLocal else { return .local }
        return .network(mountPoint: owner.point)
    }

    /// "/Volumes/<name>" for a path inside it, else nil.
    private static func volumesRoot(of path: String) -> String? {
        let prefix = "/Volumes/"
        guard path.hasPrefix(prefix) else { return nil }
        let name = path.dropFirst(prefix.count).prefix { $0 != "/" }
        return name.isEmpty ? nil : prefix + name
    }

    static func currentMounts() -> [Mount] {
        let count = getfsstat(nil, 0, MNT_NOWAIT)
        guard count > 0 else { return [] }
        // Room for a volume mounted between the two calls. (`[statfs]` would
        // be ambiguous with the `statfs` function.)
        let buffer = UnsafeMutableBufferPointer<statfs>.allocate(capacity: Int(count) + 4)
        defer { buffer.deallocate() }
        let filled = getfsstat(buffer.baseAddress, Int32(buffer.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
        guard filled > 0 else { return [] }
        return buffer.prefix(Int(filled)).map { fs in
            var name = fs.f_mntonname
            let point = withUnsafeBytes(of: &name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            return Mount(point: point, isLocal: fs.f_flags & UInt32(MNT_LOCAL) != 0)
        }
    }

    private static func readSymbolicLink(_ path: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    }
}

/// Runs file work against a network share with a deadline, so a share that
/// stopped answering costs the caller at most `timeout` instead of the whole
/// SMB timeout. A share that missed the deadline is skipped without trying
/// for `quarantine`, so repeated actions do not each wait again and do not
/// pile up threads stuck in the kernel.
nonisolated enum NetworkShareProbe {
    static let timeout: TimeInterval = 1.5
    static let quarantine: TimeInterval = 30

    private static let lock = NSLock()
    nonisolated(unsafe) private static var unreachableUntil: [String: TimeInterval] = [:]

    /// The work's result, or nil when the share is quarantined or the work
    /// missed the deadline (it keeps running in the background and its
    /// result is dropped).
    static func run<T>(mountPoint: String, _ work: @escaping () -> T) -> T? {
        let now = ProcessInfo.processInfo.systemUptime
        let skip = lock.withLock { (unreachableUntil[mountPoint] ?? 0) > now }
        if skip { return nil }

        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = work()
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            lock.withLock { unreachableUntil[mountPoint] = now + timeout + quarantine }
            return nil
        }
        return box.value
    }

    private final class ResultBox<T>: @unchecked Sendable {
        var value: T?
    }
}
