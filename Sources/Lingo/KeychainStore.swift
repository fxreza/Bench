import Foundation
import BenchCore

/// API-key storage in a user-only file, NOT the Keychain — a deliberate
/// trade-off forced by the signing setup.
///
/// The Keychain gates silent access on the app's Team ID (its "partition").
/// Bench is signed with a self-signed local identity that has no Team ID, so
/// every rebuild looks like a different app to the keychain's partition check
/// and macOS demands the login-keychain *password* on each access — "Always
/// Allow" can never stick. The only real keychain fix is an Apple-issued
/// Developer ID; until one exists, a file under `BenchPaths.dataDirectory`
/// with 0600 permissions (readable by this user account only) is the honest
/// alternative: same on-disk exposure class as ~/.netrc or an .env file, and
/// zero prompts.
///
/// The type keeps its old name so call sites read unchanged; values are
/// cached in memory after the first read (engines read on every translate).
enum KeychainStore {
    enum Key: String {
        case geminiAPIKey = "gemini_api_key"
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [Key: String?] = [:]

    private static var directory: URL {
        BenchPaths.dataDirectory(feature: "Lingo")
    }

    private static func fileURL(for key: Key) -> URL {
        directory.appendingPathComponent(key.rawValue)
    }

    static func read(_ key: Key) -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cache[key] { return cached }

        if let value = fileValue(at: fileURL(for: key)), !value.isEmpty {
            cache[key] = value
            return value
        }

        // First run: copy the key once from Transi's own file store, if it
        // has one, never touching Transi's file itself.
        if !BenchDefaults.isTestInstance,
           let imported = fileValue(
                at: BenchPaths.standaloneApplicationSupport(named: "Transi")
                    .appendingPathComponent(key.rawValue)),
           !imported.isEmpty {
            _ = writeFile(imported, for: key)
            cache[key] = imported
            return imported
        }

        cache[key] = String?.none
        return nil
    }

    @discardableResult
    static func save(_ value: String, for key: Key) -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        let ok = writeFile(value, for: key)
        if ok { cache[key] = value }
        return ok
    }

    static func delete(_ key: Key) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        try? FileManager.default.removeItem(at: fileURL(for: key))
        cache[key] = String?.none
    }

    // MARK: - File I/O

    private static func fileValue(at url: URL) -> String? {
        (try? String(contentsOf: url, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Not lock-guarded itself — callers already hold `cacheLock`.
    @discardableResult
    private static func writeFile(_ value: String, for key: Key) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let url = fileURL(for: key)
            try Data(value.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            NSLog("KeychainStore: failed to save \(key.rawValue): \(error)")
            return false
        }
    }
}
