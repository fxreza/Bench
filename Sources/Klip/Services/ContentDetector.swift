import Foundation

/// Classifies clipboard content into a `ContentKind`, ported from Clipfield's
/// `Tagging/SmartTagger.swift` (see `docs/analysis/clipfield.md` §3).
///
/// Pure and fast: no I/O, no shared state, and every entry point is
/// `nonisolated` so it can run off the main actor (at capture time, and in
/// `ClipboardStore.backfillKindsIfNeeded()`'s background batch) despite the
/// project's `-default-isolation MainActor` build flag.
enum ContentDetector {

    /// Detection never looks at more than this many UTF-8 bytes of a clip
    /// (review 5A-04).
    ///
    /// Every rule below is worst-case linear-or-worse in the input length —
    /// `isCode` alone runs a non-greedy `SELECT…FROM` regex, up to 22
    /// full-string `contains` scans and a `components(separatedBy:)` that
    /// allocates every line — so classifying a 14.9 MB log tail cost **5.0 s**
    /// of main-thread time at capture. Nothing a rule can decide needs more
    /// than the head of a clip: a link/email/phone/colour is a *whole-string*
    /// match and is rejected the moment the string is longer than the cap,
    /// and code evidence (JSON shape, a SQL clause, braces + a keyword or two
    /// indented lines) shows up in the first few lines or not at all.
    ///
    /// The one behaviour this gives up is `looksLikeJSON` on a > 64 KB
    /// document: a truncated object no longer ends in `}`, so a huge JSON
    /// blob is classified by the symbol/keyword/indentation rule instead of
    /// by `JSONSerialization` (which in turn would have had to parse the
    /// whole thing).
    nonisolated static let detectionInputLimit = 65_536

    /// Classifies a single string. Rules are evaluated, in order, on the
    /// *trimmed* text — the first match wins:
    ///  1. `.link`
    ///  2. `.email`
    ///  3. `.phone`
    ///  4. `.color`
    ///  5. `.code`
    ///  6. `.text` (default)
    nonisolated static func detect(text: String) -> ContentKind {
        // `utf8.count` is O(1) on a native Swift string, so an oversized clip
        // is capped before anything walks or copies it.
        let capped = text.utf8.count > detectionInputLimit
            ? String(decoding: text.utf8.prefix(detectionInputLimit), as: UTF8.self)
            : text
        let trimmed = capped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .text }

        if isLink(trimmed) { return .link }
        if isEmail(trimmed) { return .email }
        if isPhone(trimmed) { return .phone }
        if isColor(trimmed) { return .color }
        if isCode(trimmed) { return .code }
        return .text
    }

    /// Classifies a full clipboard item. Image and file items map directly;
    /// text items fall back to `detect(text:)` on `fullText` when given, or
    /// on the item's own stored `textContent` otherwise — for file-backed
    /// large text that stored value is already the 500-char inline preview
    /// (see `ClipboardWatcher.previewLength`), which is good enough for
    /// classification without reading the backing file.
    nonisolated static func detect(for item: ClipboardItem, fullText: String?) -> ContentKind {
        if item.isFile { return .file }
        switch item.type {
        case .image:
            return .image
        case .file:
            return .file
        case .text:
            let text = fullText ?? item.textContent ?? ""
            return detect(text: text)
        }
    }

    // MARK: - Link

    /// Single line, and either an `NSDataDetector` link match spanning the
    /// *entire* string, or (as a fallback when the detector finds nothing at
    /// all) an explicit `http://`/`https://`/`ftp://`/`www.<dot>` prefix.
    /// `mailto:` is deliberately excluded — it is classified as `.email`
    /// instead (see `isEmail`), matching Clipfield's `SmartTagger`, which
    /// tags a mailto link as `.email` rather than `.link`.
    ///
    /// A detector match that does *not* span the whole string (e.g. a URL
    /// embedded in a sentence, or with trailing sentence punctuation the
    /// detector excludes from the match) means the text is not purely a
    /// link, so it is **not** treated as one — it falls through to the
    /// remaining rules instead.
    private nonisolated static func isLink(_ text: String) -> Bool {
        guard !text.isEmpty, !text.contains(where: { $0.isNewline }) else { return false }
        let lower = text.lowercased()
        guard !lower.hasPrefix("mailto:") else { return false }

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(text.startIndex..., in: text)
            if let match = detector.firstMatch(in: text, options: [], range: range) {
                if match.range == range, match.url?.scheme != "mailto" {
                    return true
                }
                return false
            }
        }

        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("ftp://") {
            return true
        }
        if lower.hasPrefix("www.") && lower.dropFirst(4).contains(".") {
            return true
        }
        return false
    }

    // MARK: - Email

    private nonisolated static let emailPattern = "^[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}$"

    /// The whole string matches a standard email regex, or is a `mailto:`
    /// URI wrapping one (excluded from `.link` above, so it lands here).
    private nonisolated static func isEmail(_ text: String) -> Bool {
        if matchesWhole(text, emailPattern, options: [.caseInsensitive]) { return true }
        if text.lowercased().hasPrefix("mailto:") {
            let remainder = String(text.dropFirst("mailto:".count))
            return matchesWhole(remainder, emailPattern, options: [.caseInsensitive])
        }
        return false
    }

    // MARK: - Phone

    /// An `NSDataDetector` phone-number match spanning the entire string,
    /// whose length falls within 7-20 characters (short numeric fragments
    /// and long prose containing a number are excluded either by length or
    /// because the match cannot span the whole string).
    private nonisolated static func isPhone(_ text: String) -> Bool {
        guard text.count >= 7, text.count <= 20 else { return false }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue) else {
            return false
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = detector.firstMatch(in: text, options: [], range: range) else { return false }
        return match.range == range
    }

    // MARK: - Color

    private nonisolated static let hexColorPattern = "^#([0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})$"
    private nonisolated static let functionalColorPattern = "^(rgb|rgba|hsl|hsla)\\(.+\\)$"

    private nonisolated static func isColor(_ text: String) -> Bool {
        guard text.count <= 64 else { return false }
        return matchesWhole(text, hexColorPattern, options: [.caseInsensitive])
            || matchesWhole(text, functionalColorPattern, options: [.caseInsensitive])
    }

    // MARK: - Code

    /// Ported from Clipfield's `looksLikeCode`. A single short line is never
    /// code unless it looks like a shell command (`$ `, `git `, `npm `,
    /// `brew `, `curl `, `ssh `). Multi-line text needs real structural
    /// evidence — a valid JSON object/array, a `SELECT ... FROM` query, or a
    /// brace/semicolon/arrow-style symbol together with either a language
    /// keyword or two-or-more indented lines — so ordinary prose (which may
    /// happen to contain a word like "class" or "return") is never flagged.
    private nonisolated static func isCode(_ text: String) -> Bool {
        let shellPrefixes = ["$ ", "git ", "npm ", "brew ", "curl ", "ssh "]
        let isMultiline = text.contains("\n")

        guard isMultiline else {
            return shellPrefixes.contains { text.hasPrefix($0) }
        }

        if looksLikeJSON(text) { return true }
        if hasSQLSelectFrom(text) { return true }

        let symbols = ["{", "}", ";", "=>", "->", "::", "()"]
        let keywords = [
            "func ", "def ", "class ", "import ", "return ", "const ", "let ", "var ",
            "public ", "private ", "function ", "#include", "package ", "struct ", "enum "
        ]
        let hasSymbol = symbols.contains { text.contains($0) }
        let hasKeyword = keywords.contains { text.contains($0) }

        let lines = text.components(separatedBy: "\n")
        let indentedLineCount = lines.filter { line in
            guard let first = line.first, first == " " || first == "\t" else { return false }
            return !line.trimmingCharacters(in: .whitespaces).isEmpty
        }.count
        let hasIndentation = indentedLineCount >= 2

        return hasSymbol && (hasKeyword || hasIndentation)
    }

    private nonisolated static func looksLikeJSON(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isObject = trimmed.hasPrefix("{") && trimmed.hasSuffix("}")
        let isArray = trimmed.hasPrefix("[") && trimmed.hasSuffix("]")
        guard isObject || isArray, let data = trimmed.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }

    /// `\bSELECT\b … \bFROM\b`, without the regex.
    ///
    /// The old implementation ran a non-greedy `\bSELECT\b[\s\S]*?\bFROM\b`
    /// over the whole clip, which is the single most expensive rule here
    /// (5A-04). This is the same predicate — the first `SELECT` word followed
    /// somewhere later by a `FROM` word; if no `FROM` follows the first
    /// `SELECT`, none follows a later one either — as two linear substring
    /// searches with explicit word-boundary checks.
    private nonisolated static func hasSQLSelectFrom(_ text: String) -> Bool {
        guard let select = wordRange(of: "SELECT", in: text, from: text.startIndex) else { return false }
        return wordRange(of: "FROM", in: text, from: select.upperBound) != nil
    }

    /// First case-insensitive occurrence of `word` in `text` at or after
    /// `start` that is delimited by non-word characters on both sides (regex
    /// `\b`: word characters are letters, digits and `_`).
    private nonisolated static func wordRange(
        of word: String,
        in text: String,
        from start: String.Index
    ) -> Range<String.Index>? {
        var searchStart = start
        while true {
            guard let found = text.range(
                of: word,
                options: [.caseInsensitive],
                range: searchStart..<text.endIndex
            ) else { return nil }
            let beforeOK = found.lowerBound == text.startIndex
                || !isWordCharacter(text[text.index(before: found.lowerBound)])
            let afterOK = found.upperBound == text.endIndex
                || !isWordCharacter(text[found.upperBound])
            if beforeOK && afterOK { return found }
            guard found.lowerBound < text.endIndex else { return nil }
            searchStart = text.index(after: found.lowerBound)
        }
    }

    private nonisolated static func isWordCharacter(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }

    // MARK: - Regex helper

    private nonisolated static func matchesWhole(
        _ text: String,
        _ pattern: String,
        options: NSRegularExpression.Options = []
    ) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
}
