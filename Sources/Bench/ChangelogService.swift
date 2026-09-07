// Ported from Snapper's Services/ChangelogService.swift (MIT, Copyright 2026
// Sam Reza), which came from Klip. Only the tag prefix changed.

import Foundation

// MARK: - Model

/// One block of a changelog entry's body.
///
/// SwiftUI on macOS 14 can only render *inline* Markdown - `AttributedString`
/// understands `**bold**`, `` `code` `` and links, but there is no block
/// renderer for headings, lists or rules. The deploy target here is 14.0, so
/// block structure is parsed out here and each block is rendered as its own
/// SwiftUI view; only the leftover inline spans are handed to
/// `AttributedString`.
enum ChangelogBlock: Equatable, Sendable {
    /// A `### Added` / `### Changed` / `### Fixed` subsection heading.
    case heading(String)
    /// A `-` bullet. Wrapped continuation lines are already folded in, so the
    /// text is the whole bullet on one logical line, still carrying its inline
    /// Markdown.
    case bullet(String)
    /// A run of ordinary prose (a blank-line-separated paragraph).
    case paragraph(String)
    /// A `---` horizontal rule.
    case rule
}

/// One `## 0.1.0 (2026-09-07)` section of `CHANGELOG.md`.
struct ChangelogEntry: Equatable, Sendable {
    /// The leading token of the heading, e.g. `0.1.0`. This is what
    /// `entry(for:)` matches against `CFBundleShortVersionString`.
    let version: String
    /// Whatever followed the version in the heading, parentheses stripped -
    /// usually a date. Nil when absent.
    let subtitle: String?
    /// The heading exactly as written, minus the `## `.
    let heading: String
    /// The parsed body.
    let blocks: [ChangelogBlock]
}

// MARK: - Service

/// Reads and parses the `CHANGELOG.md` that `scripts/build-app.sh` copies into
/// `Contents/Resources/`.
///
/// The post-update toast's "What's New" button and About's link render these
/// notes in-app rather than opening a browser. The bundled file is the primary
/// source; `UpdateService` also stashes the GitHub release `body` so a version
/// with no section in the bundled file still has something to show.
enum ChangelogService {

    /// The bundled changelog's contents, or nil if it was not shipped.
    ///
    /// Deliberately not cached: this is read at most a couple of times per
    /// launch, and a stale cache across an in-place update would be worse than
    /// the re-read.
    static func bundledMarkdown(bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "CHANGELOG", withExtension: "md") else {
            NSLog("[ChangelogService] No CHANGELOG.md in the bundle's Resources")
            return nil
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            NSLog("[ChangelogService] Failed to read \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    /// Every entry in the bundled changelog, in the file's own order (newest
    /// first, by convention); versions are never re-sorted, so a hand-written
    /// out-of-order section still renders where the author put it.
    static func allEntries(bundle: Bundle = .main) -> [ChangelogEntry] {
        guard let markdown = bundledMarkdown(bundle: bundle) else { return [] }
        return parse(markdown)
    }

    /// The entry for a specific version string, e.g. `"0.1.0"`. Matching
    /// tolerates a `v`/`bench-v` tag prefix on either side.
    static func entry(for version: String, in entries: [ChangelogEntry]) -> ChangelogEntry? {
        let wanted = normalizedVersion(version)
        guard !wanted.isEmpty else { return nil }
        return entries.first { normalizedVersion($0.version) == wanted }
    }

    /// Convenience: look a version up in the bundled changelog.
    static func entry(for version: String, bundle: Bundle = .main) -> ChangelogEntry? {
        entry(for: version, in: allEntries(bundle: bundle))
    }

    /// Flattens an entry's blocks into plain text, for a context with no
    /// block-Markdown renderer (e.g. `NSAlert.informativeText`).
    static func plainText(for entry: ChangelogEntry) -> String {
        var lines: [String] = []
        for block in entry.blocks {
            switch block {
            case .heading(let text): lines.append(text)
            case .bullet(let text): lines.append("• \(text)")
            case .paragraph(let text): lines.append(text)
            case .rule: lines.append("")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Parsing

    /// Splits a changelog document into entries.
    ///
    /// Anything before the first `## ` heading (the `# Changelog` title and any
    /// preamble) is dropped. A malformed or empty document simply yields no
    /// entries - a broken changelog must never be the reason a window fails.
    static func parse(_ markdown: String) -> [ChangelogEntry] {
        var entries: [ChangelogEntry] = []
        var currentHeading: String?
        var currentBody: [String] = []

        func flush() {
            guard let heading = currentHeading else { return }
            let (version, subtitle) = splitHeading(heading)
            entries.append(
                ChangelogEntry(
                    version: version,
                    subtitle: subtitle,
                    heading: heading,
                    blocks: parseBlocks(currentBody)))
            currentBody = []
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = stripHTMLComment(rawLine)
            // `## ` but not `### ` - version headings only.
            if line.hasPrefix("## "), !line.hasPrefix("### ") {
                flush()
                currentHeading = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if currentHeading == nil { continue }   // still in the preamble
            currentBody.append(line)
        }
        flush()
        return entries
    }

    /// Parses the body lines of one entry into blocks. Exposed so the GitHub
    /// release-note fallback goes through exactly the same renderer.
    static func parseBlocks(_ lines: [String]) -> [ChangelogBlock] {
        var blocks: [ChangelogBlock] = []
        var pendingBullet: String?
        var pendingParagraph: [String] = []

        func flushBullet() {
            if let bullet = pendingBullet {
                blocks.append(.bullet(bullet.trimmingCharacters(in: .whitespaces)))
                pendingBullet = nil
            }
        }
        func flushParagraph() {
            if !pendingParagraph.isEmpty {
                blocks.append(.paragraph(pendingParagraph.joined(separator: " ")))
                pendingParagraph = []
            }
        }
        func flushAll() { flushBullet(); flushParagraph() }

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                // A blank line closes whatever was open. Bullets are separated
                // by blank lines *and* some wrap across source lines with no
                // blank between them, so "blank ends the bullet, a plain line
                // continues it" handles both shapes.
                flushParagraph()
                flushBullet()
                continue
            }

            if isHorizontalRule(trimmed) {
                flushAll()
                blocks.append(.rule)
                continue
            }

            if trimmed.hasPrefix("#") {
                flushAll()
                let text = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(text))
                continue
            }

            if isBulletStart(trimmed) {
                flushAll()
                pendingBullet = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                continue
            }

            if pendingBullet != nil {
                // A wrapped continuation of the bullet above, joined with a
                // single space: the source wraps for readability, the rendered
                // text should reflow to the window's width.
                pendingBullet! += " " + trimmed
                continue
            }

            pendingParagraph.append(trimmed)
        }
        flushAll()

        // A `---` separating entries in the file lands at the end of the
        // preceding entry's body. It is a separator, not content, and the
        // window draws its own dividers.
        while blocks.last == ChangelogBlock.rule { blocks.removeLast() }
        return blocks
    }

    /// Parses a free-form Markdown string (a GitHub release `body`) into blocks.
    static func blocks(fromMarkdown markdown: String) -> [ChangelogBlock] {
        parseBlocks(markdown.components(separatedBy: .newlines).map(stripHTMLComment))
    }

    // MARK: - Line helpers

    /// `- foo` / `* foo` / `+ foo` (but not `**bold**` alone, and not `---`).
    private static func isBulletStart(_ trimmed: String) -> Bool {
        guard trimmed.count >= 2 else { return false }
        let first = trimmed[trimmed.startIndex]
        guard first == "-" || first == "*" || first == "+" else { return false }
        return trimmed[trimmed.index(after: trimmed.startIndex)] == " "
    }

    private static func isHorizontalRule(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        let set = Set(trimmed)
        return set.count == 1 && (set.first == "-" || set.first == "_" || set.first == "*")
    }

    /// Drops `<!-- … -->` markers so they never show up as prose.
    private static func stripHTMLComment(_ line: String) -> String {
        guard line.contains("<!--") else { return line }
        var result = ""
        var rest = Substring(line)
        while let open = rest.range(of: "<!--") {
            result += rest[rest.startIndex..<open.lowerBound]
            guard let close = rest.range(of: "-->", range: open.upperBound..<rest.endIndex) else {
                return result   // unterminated comment: everything after it is comment
            }
            rest = rest[close.upperBound...]
        }
        result += rest
        return result
    }

    /// `0.1.0 (2026-09-07)` -> (`0.1.0`, `2026-09-07`).
    private static func splitHeading(_ heading: String) -> (String, String?) {
        let parts = heading.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first else { return (heading, nil) }
        let version = String(first)
        guard parts.count > 1 else { return (version, nil) }
        let remainder = parts[1]
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "()[]"))
        return (version, remainder.isEmpty ? nil : remainder)
    }

    /// Strips a `v` / `bench-v` prefix so a tag and a bare version compare
    /// equal.
    static func normalizedVersion(_ raw: String) -> String {
        var v = raw.trimmingCharacters(in: .whitespaces)
        let lower = v.lowercased()
        if lower.hasPrefix("bench-v") {
            v = String(v.dropFirst("bench-v".count))
        } else if lower.hasPrefix("v") {
            v = String(v.dropFirst(1))
        }
        return v
    }
}
