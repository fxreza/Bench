import Foundation

/// Where Bench keeps its files in iCloud Drive.
///
/// Everything the app mirrors into the cloud lives under one folder,
/// `~/Library/Mobile Documents/com~apple~CloudDocs/Bench/`, with one
/// subfolder per thing that syncs:
///
/// ```
/// Bench/
///   Klip/        clipboard history (Klip's `CloudDriveSync`)
///   Settings/    every module's preferences (`SettingsSync`)
/// ```
///
/// No CloudKit, no entitlements, no sandbox: the container is a plain folder
/// that macOS keeps in sync, so the app only ever reads and writes files.
///
/// `BENCH_CLOUD_ROOT` replaces the container with any directory (created on
/// demand), so two locally built instances can share one stand-in without
/// touching the real iCloud Drive.
public enum CloudDrive {
    /// The folder inside the container that holds everything of Bench's.
    public static let folderName = "Bench"

    /// The iCloud Drive container (or, under `BENCH_CLOUD_ROOT`, a stand-in).
    /// `nil` when iCloud Drive is not set up on this Mac.
    public static var containerRoot: URL? {
        if let override = ProcessInfo.processInfo.environment["BENCH_CLOUD_ROOT"], !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// `<container>/Bench`.
    public static func benchRoot(in container: URL) -> URL {
        container.appendingPathComponent(folderName, isDirectory: true)
    }

    /// `<container>/Bench/<name>`, e.g. `Bench/Klip` or `Bench/Settings`.
    public static func folder(named name: String, in container: URL) -> URL {
        benchRoot(in: container).appendingPathComponent(name, isDirectory: true)
    }

    /// True only when the container is actually on disk: iCloud Drive can be
    /// switched off in System Settings while the app is running.
    public static var isAvailable: Bool {
        guard let root = containerRoot else { return false }
        return FileManager.default.fileExists(atPath: root.path)
    }

    /// Why sync cannot be turned on, or `nil` when it can.
    public static var unavailableReason: String? {
        isAvailable ? nil : "Sign in to iCloud and enable iCloud Drive in System Settings."
    }

    /// One-time move of a folder that used to sit at the top of iCloud Drive
    /// into `Bench/`: Klip's history synced to `iCloud Drive/Klip` before the
    /// app grew the shared folder.
    ///
    /// Moves `<container>/<name>` to `<container>/Bench/<name>` when the old
    /// folder exists and the new one does not. A rename inside the container
    /// keeps every file's contents, downloaded or not, and iCloud propagates
    /// the rename to the other Macs, so the folder is never copied and never
    /// duplicated. Returns true when a move happened.
    @discardableResult
    public static func migrateLegacyFolder(named name: String, in container: URL) -> Bool {
        let fm = FileManager.default
        let legacy = container.appendingPathComponent(name, isDirectory: true)
        let destination = folder(named: name, in: container)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: legacy.path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        guard !fm.fileExists(atPath: destination.path) else { return false }
        do {
            try fm.createDirectory(at: benchRoot(in: container), withIntermediateDirectories: true)
            var coordinatorError: NSError?
            var moveError: Error?
            NSFileCoordinator(filePresenter: nil).coordinate(
                writingItemAt: legacy, options: .forMoving,
                writingItemAt: destination, options: .forReplacing,
                error: &coordinatorError
            ) { source, target in
                do {
                    try fm.moveItem(at: source, to: target)
                } catch {
                    moveError = error
                }
            }
            if let error = coordinatorError ?? moveError { throw error }
            NSLog("[CloudDrive] Moved iCloud Drive/\(name) into iCloud Drive/\(folderName)/\(name)")
            return true
        } catch {
            NSLog("[CloudDrive] Could not move iCloud Drive/\(name) into \(folderName)/: \(error)")
            return false
        }
    }
}
