import Foundation
import BenchCore

/// Offers Lingo's API keys to `SettingsSync`, so a key entered on one Mac
/// works on the others.
///
/// The keys live in `KeychainStore`'s user-only files, not in
/// `UserDefaults`, so the sync cannot see them on its own. Each travels
/// under `lingo.secret.<file name>` and is written back through
/// `KeychainStore` on arrival, which keeps the 0600 file and the in-memory
/// cache the engines read.
///
/// The value is written as plain text into the user's own iCloud Drive
/// folder; the user chose that over typing the key on every Mac.
@MainActor
final class LingoSecretsSync: SettingsSyncContributor {
    static let shared = LingoSecretsSync()

    static let keyPrefix = "lingo.secret."

    private init() {}

    private static func syncKey(_ key: KeychainStore.Key) -> String { keyPrefix + key.rawValue }

    private static func storeKey(_ syncKey: String) -> KeychainStore.Key? {
        guard syncKey.hasPrefix(keyPrefix) else { return nil }
        return KeychainStore.Key(rawValue: String(syncKey.dropFirst(keyPrefix.count)))
    }

    var settingsSyncKeys: [String] {
        [KeychainStore.Key.geminiAPIKey].map(Self.syncKey)
    }

    func settingsSyncValue(forKey key: String) -> Any? {
        guard let storeKey = Self.storeKey(key) else { return nil }
        return KeychainStore.read(storeKey)
    }

    func applySettingsSyncValue(_ value: Any?, forKey key: String) {
        guard let storeKey = Self.storeKey(key) else { return }
        if let value = value as? String, !value.isEmpty {
            KeychainStore.save(value, for: storeKey)
        } else {
            KeychainStore.delete(storeKey)
        }
    }
}
