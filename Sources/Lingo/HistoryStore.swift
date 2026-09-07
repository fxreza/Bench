import Foundation
import BenchCore

struct HistoryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let sourceText: String
    let translatedText: String
    let sourceCode: String?
    let targetCode: String
    let date: Date
}

/// Recent translations, persisted in UserDefaults and shown from the popup's
/// footer history button. Capped at `maxEntries`, newest first.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    static let maxEntries = 50

    @Published private(set) var entries: [HistoryEntry] = []

    private let defaults = BenchDefaults.standard
    private let storageKey = "lingo.translationHistory"

    private init() {
        // Copy-only, one-time: Transi also kept history as a UserDefaults
        // blob (no separate history file to move), so the same
        // preferences-copy machinery used for the rest of SettingsStore
        // covers it too.
        StandaloneImport.importDefaultsIfNeeded(
            sourceDomain: "com.fxreza.transi",
            keys: ["translationHistory": storageKey],
            flagKey: "lingo.importedHistoryFromTransi")

        if let data = defaults.data(forKey: storageKey),
           let stored = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = stored
        }
    }

    /// Called every time the popup's primary text settles. When the newest
    /// entry is the same lookup (same source and target), it is replaced in
    /// place instead of duplicated — retries, tone changes, and a later
    /// reserved-primary result all just refresh the stored translation.
    func record(source: String, translation: String, sourceCode: String?, targetCode: String) {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !translation.isEmpty else { return }

        let entry = HistoryEntry(
            id: entries.first?.sourceText == source && entries.first?.targetCode == targetCode
                ? entries[0].id : UUID(),
            sourceText: source,
            translatedText: translation,
            sourceCode: sourceCode,
            targetCode: targetCode,
            date: Date())

        if let first = entries.first, first.id == entry.id {
            entries[0] = entry
        } else {
            entries.insert(entry, at: 0)
            if entries.count > Self.maxEntries {
                entries.removeLast(entries.count - Self.maxEntries)
            }
        }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
