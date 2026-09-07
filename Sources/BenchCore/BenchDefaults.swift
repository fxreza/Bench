import Foundation

/// The preferences store for this process.
///
/// A copy launched with `BENCH_DATA_DIR` set (see `scripts/run_app.sh`) shares
/// the production bundle identifier, so `UserDefaults.standard` would read
/// and write the same domain as the installed app. Such a copy gets its own
/// suite instead, so a test harness can never change the user's real
/// preferences.
///
/// Every module namespaces its keys with its own prefix (`shot.`, `klip.`,
/// `lingo.`, `snap.`), and the app itself uses `bench.`, because the four
/// standalone apps all used bare keys such as `launchAtLogin` or
/// `hotkeyKeyCode` that would collide in one domain.
public enum BenchDefaults {
    public static let testSuiteName = "com.fxreza.bench.test"

    public static var isTestInstance: Bool {
        ProcessInfo.processInfo.environment["BENCH_DATA_DIR"] != nil
    }

    public static let standard: UserDefaults = {
        if isTestInstance, let suite = UserDefaults(suiteName: testSuiteName) { return suite }
        return .standard
    }()
}

/// Where each module keeps its files.
public enum BenchPaths {
    /// `~/Library/Application Support/Bench`, or `BENCH_DATA_DIR` when set.
    public static var rootDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["BENCH_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Bench", isDirectory: true)
    }

    /// `~/Library/Application Support/Bench/<Feature>`, created on first use.
    public static func dataDirectory(feature: String) -> URL {
        let url = rootDirectory.appendingPathComponent(feature, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The Application Support folder of one of the standalone apps Bench
    /// grew out of (`Klip`, `Snapper`, `Transi`), for one-time imports. Never
    /// written to.
    public static func standaloneApplicationSupport(named name: String) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent(name, isDirectory: true)
    }
}

/// One-time, copy-only import of a standalone app's settings into Bench's
/// namespaced keys. The standalone domain is read, never written or deleted,
/// so Klip, Snapper and Transi keep working untouched next to Bench.
public enum StandaloneImport {
    /// Copies `keys` (old key -> new key) from the preferences domain
    /// `sourceDomain` into `BenchDefaults.standard`, filling in only keys
    /// that Bench does not have yet, and only once per `flagKey`.
    ///
    /// Skipped for test instances so a harness never inherits real settings.
    /// Returns the number of keys copied.
    @discardableResult
    public static func importDefaultsIfNeeded(
        sourceDomain: String,
        keys: [String: String],
        flagKey: String
    ) -> Int {
        guard !BenchDefaults.isTestInstance else { return 0 }
        let defaults = BenchDefaults.standard
        guard !defaults.bool(forKey: flagKey) else { return 0 }
        defer { defaults.set(true, forKey: flagKey) }

        guard let source = UserDefaults.standard.persistentDomain(forName: sourceDomain) else { return 0 }
        var copied = 0
        for (oldKey, newKey) in keys {
            guard let value = source[oldKey], defaults.object(forKey: newKey) == nil else { continue }
            defaults.set(value, forKey: newKey)
            copied += 1
        }
        return copied
    }

    /// Copies the contents of a standalone app's Application Support folder
    /// into `destination` when the destination is still empty. Copy only:
    /// the source is left exactly as it was. Returns true when a copy
    /// happened.
    @discardableResult
    public static func importDirectoryIfEmpty(from source: URL, to destination: URL) -> Bool {
        guard !BenchDefaults.isTestInstance else { return false }
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return false }
        let existing = (try? fm.contentsOfDirectory(atPath: destination.path)) ?? []
        guard existing.filter({ !$0.hasPrefix(".") }).isEmpty else { return false }
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: source, to: destination)
            return true
        } catch {
            NSLog("[StandaloneImport] copy from \(source.path) failed: \(error)")
            return false
        }
    }
}
