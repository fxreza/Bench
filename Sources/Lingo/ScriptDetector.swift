import Foundation

/// Cheap, local language guess based on which script the text is written in.
///
/// Used to decide the auto-flip target *before* any network call. Previously
/// this was a binary Arabic-vs-Latin classifier for the fa/en pair; it now
/// buckets by script, and the caller intersects multi-language buckets with
/// the user's enabled languages. `nil` still means "ask the server", so
/// ambiguous input keeps the old server-verdict behaviour.
enum ScriptDetector {

    /// Returns a language code only for scripts that map to a single language
    /// in the catalog: kana → ja, hangul → ko, thai → th, greek → el,
    /// hebrew → he. Han with no kana best-efforts to zh-CN (documented risk:
    /// all-kanji Japanese fragments misread as Chinese). Multi-language
    /// scripts (latin, arabic, cyrillic, devanagari) return `nil` — resolve
    /// those via `detectScriptBucket` + the enabled-language set, or the
    /// server.
    static func detect(_ text: String) -> String? {
        let counts = scriptCounts(text)
        let total = counts.values.reduce(0, +)
        guard total >= 2 else { return nil }

        // Any meaningful kana marks Japanese even when Han dominates —
        // ordinary Japanese prose is mostly kanji with kana in between.
        if let kana = counts[.kana], kana >= 2,
           Double(kana + (counts[.cjkHan] ?? 0)) >= Double(total) * 0.7 {
            return "ja"
        }

        guard let (bucket, count) = counts.max(by: { $0.value < $1.value }),
              Double(count) >= Double(total) * 0.7 else { return nil }

        switch bucket {
        case .hangul: return "ko"
        case .thai: return "th"
        case .greek: return "el"
        case .hebrew: return "he"
        case .kana: return "ja"
        case .cjkHan: return "zh-CN"
        default: return nil
        }
    }

    /// The dominant script bucket (≥70% of letters), including the
    /// multi-language buckets `detect` refuses to call. The caller intersects
    /// this with the enabled languages: exactly one enabled language using
    /// the bucket means the guess is safe locally, anything else falls
    /// through to the server. For the default fa+en install this reproduces
    /// the old behaviour exactly (arabic ∩ {fa,en} = fa, latin ∩ {fa,en} = en).
    static func detectScriptBucket(_ text: String) -> LanguageCatalog.Script? {
        let counts = scriptCounts(text)
        let total = counts.values.reduce(0, +)
        guard total >= 2,
              let (bucket, count) = counts.max(by: { $0.value < $1.value }),
              Double(count) >= Double(total) * 0.7 else { return nil }
        return bucket
    }

    // MARK: - Counting

    private static func scriptCounts(_ text: String) -> [LanguageCatalog.Script: Int] {
        var counts: [LanguageCatalog.Script: Int] = [:]
        for scalar in text.unicodeScalars {
            guard let bucket = bucket(for: scalar.value) else { continue }
            counts[bucket, default: 0] += 1
        }
        return counts
    }

    private static func bucket(for value: UInt32) -> LanguageCatalog.Script? {
        switch value {
        // Basic Latin letters, Latin-1 letters (minus × ÷), Latin Extended-A/B.
        case 0x0041...0x005A, 0x0061...0x007A:
            return .latin
        case 0x00C0...0x00FF where value != 0x00D7 && value != 0x00F7:
            return .latin
        case 0x0100...0x024F:
            return .latin
        // Arabic, Arabic Supplement, Arabic Extended-A, and the two
        // presentation-forms blocks. Persian shares all of these.
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF,
             0xFB50...0xFDFF, 0xFE70...0xFEFF:
            return .arabic
        case 0x0400...0x04FF, 0x0500...0x052F:
            return .cyrillic
        case 0x0590...0x05FF:
            return .hebrew
        case 0x0370...0x03FF, 0x1F00...0x1FFF:
            return .greek
        case 0x0900...0x097F:
            return .devanagari
        case 0x0E00...0x0E7F:
            return .thai
        case 0x3040...0x309F, 0x30A0...0x30FF:
            return .kana
        case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F:
            return .hangul
        case 0x4E00...0x9FFF, 0x3400...0x4DBF:
            return .cjkHan
        default:
            return nil
        }
    }
}
