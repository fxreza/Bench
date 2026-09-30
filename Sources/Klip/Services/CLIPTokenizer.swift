// CLIP's byte-level BPE tokenizer, for MobileCLIP's text encoder.
//
// Ported from Apple's ml-mobileclip demo app
// (ios_app/MobileCLIPExplore/Tokenizer/CLIPTokenizer.swift and
// GPT2ByteEncoder.swift, MIT, Copyright 2024 Apple Inc.), which is itself a
// modified copy of Hugging Face's swift-coreml-transformers tokenizer
// (Apache-2.0, Copyright 2019-2023 Hugging Face), and checked against the
// reference Python tokenizer it reimplements, OpenAI CLIP's
// `simple_tokenizer.py` (MIT, Copyright 2021 OpenAI). See ATTRIBUTION.md.
//
// Changes from Apple's port:
// - Only the first 48,894 merges are used, as in OpenAI's tokenizer. The
//   merges file Apple ships holds all 262,144; the vocabulary is built from
//   the first 48,894 only, so a later merge produces a token that is not in
//   the vocabulary, and Apple's `compactMap` silently dropped it:
//   "clipboard", "wireframe" or "skateboarder" encoded to nothing at all,
//   "mobileclip" to its last piece.
// - The vocabulary is derived from the merges exactly the way OpenAI builds
//   it (256 byte tokens, their 256 end-of-word forms, one token per merge,
//   the two special tokens) instead of decoding `clip-vocab.json`, and BPE
//   runs on token ids (a merge of ids `a b` with rank `r` *is* token
//   `512 + r`) instead of strings. Loading drops from ~30 MB of footprint
//   (JSON decoding, 262k split lines) to a couple of MB, and a word encodes
//   without building strings. `real_tokenizer_matchesReferenceIDs` checks
//   the derived vocabulary against `clip-vocab.json`.
// - Text is cleaned the way the reference does (NFC, curly quotes
//   straightened as ftfy does, whitespace collapsed) and special-token
//   strings typed by the user are removed rather than encoded.
// - Input longer than the context is truncated with the end token kept last
//   (open_clip's rule) instead of crashing.

import Foundation

/// Turns text into the 77 token ids MobileCLIP's text encoder takes:
/// `<|startoftext|>`, the BPE ids of the lowercased text, `<|endoftext|>`,
/// then zeros.
///
/// Thread-safe (the word cache is locked), so `nonisolated` in a module
/// that defaults to the main actor. `MobileCLIPEncoder` keeps one alongside
/// the text model and drops both when search has been idle.
nonisolated final class CLIPTokenizer: @unchecked Sendable {
    static let contextLength = 77
    static let startToken: Int32 = 49_406
    static let endToken: Int32 = 49_407
    /// OpenAI's tokenizer keeps `49152 - 256 - 2` merges: the vocabulary is
    /// 256 byte tokens, their 256 end-of-word forms, one token per merge,
    /// and the two special tokens (49,408 in all).
    static let mergeCount = 49_152 - 256 - 2
    static let firstMergeToken = 512

    enum LoadError: Error, CustomStringConvertible {
        case unreadable(URL)
        case malformedMerges(String)

        var description: String {
            switch self {
            case .unreadable(let url): return "cannot read \(url.lastPathComponent)"
            case .malformedMerges(let reason): return "clip-merges.txt: \(reason)"
            }
        }
    }

    /// Rank of the merge of two adjacent token ids, keyed `a << 32 | b`.
    private let mergeRanks: [UInt64: Int32]

    private let cacheLock = NSLock()
    private var wordCache: [String: [Int32]] = [:]

    /// `mergeLimit` is OpenAI's `mergeCount` for the real file; tests pass
    /// a tiny merges file with fewer.
    init(mergesURL: URL, mergeLimit: Int = CLIPTokenizer.mergeCount) throws {
        guard let data = try? Data(contentsOf: mergesURL, options: .mappedIfSafe) else {
            throw LoadError.unreadable(mergesURL)
        }
        // Token string -> id while reading; only needed to resolve the
        // merges' halves, then dropped.
        var tokens: [String: Int32] = [:]
        tokens.reserveCapacity(Self.firstMergeToken + mergeLimit)
        for (token, character) in Self.characterForToken.enumerated() {
            tokens[String(character)] = Int32(token)
            tokens[String(character) + "</w>"] = Int32(256 + token)
        }

        var ranks: [UInt64: Int32] = [:]
        ranks.reserveCapacity(mergeLimit)
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var lineStart = 0
            var lineNumber = 0
            // Line 0 is the `#version` header; only the first `mergeLimit`
            // merges after it are read, so the other ~213k lines of Apple's
            // file never become strings.
            func take(_ end: Int) throws {
                defer { lineStart = end + 1; lineNumber += 1 }
                guard lineNumber > 0, end > lineStart else { return }
                let line = UnsafeRawBufferPointer(rebasing: bytes[lineStart..<end])
                guard let space = line.firstIndex(of: 0x20) else {
                    throw LoadError.malformedMerges("line \(lineNumber) is not a pair")
                }
                let first = String(decoding: UnsafeRawBufferPointer(rebasing: line[..<space]), as: UTF8.self)
                let second = String(decoding: UnsafeRawBufferPointer(rebasing: line[(space + 1)...]), as: UTF8.self)
                guard let a = tokens[first], let b = tokens[second] else {
                    throw LoadError.malformedMerges("line \(lineNumber) merges unknown tokens")
                }
                let rank = Int32(ranks.count)
                ranks[Self.pairKey(a, b)] = rank
                tokens[first + second] = Int32(Self.firstMergeToken) + rank
            }
            var index = 0
            while index < bytes.count, ranks.count < mergeLimit {
                if bytes[index] == 0x0A { try take(index) }
                index += 1
            }
            if ranks.count < mergeLimit, lineStart < bytes.count { try take(bytes.count) }   // no final newline
        }
        guard ranks.count == mergeLimit else { throw LoadError.malformedMerges("only \(ranks.count) merges") }
        mergeRanks = ranks
    }

    private static func pairKey(_ a: Int32, _ b: Int32) -> UInt64 {
        UInt64(UInt32(bitPattern: a)) << 32 | UInt64(UInt32(bitPattern: b))
    }

    // MARK: - Encoding

    /// The model input for `text`: exactly `contextLength` ids, start token
    /// first, end token after the text (or last, when the text was too long
    /// and got cut), zero padding.
    func tokenIDs(for text: String) -> [Int32] {
        var ids: [Int32] = [Self.startToken]
        ids.append(contentsOf: encode(text).prefix(Self.contextLength - 2))
        ids.append(Self.endToken)
        ids.append(contentsOf: repeatElement(0, count: Self.contextLength - ids.count))
        return ids
    }

    /// The BPE ids of `text`, without start/end tokens or padding.
    func encode(_ text: String) -> [Int32] {
        let cleaned = Self.clean(text)
        guard !cleaned.isEmpty else { return [] }
        var ids: [Int32] = []
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        for match in Self.wordPattern.matches(in: cleaned, range: range) {
            guard let wordRange = Range(match.range, in: cleaned) else { continue }
            ids.append(contentsOf: cachedIDs(for: String(cleaned[wordRange])))
        }
        return ids
    }

    /// OpenAI's `basic_clean` + `whitespace_clean` + lowercasing, minus the
    /// parts that only matter for scraped web text (mojibake repair, HTML
    /// entities): NFC, curly quotes straightened (ftfy's default
    /// `uncurl_quotes`, so "man’s" splits like "man's"), control characters
    /// dropped, whitespace runs collapsed to one space. Special-token strings
    /// are removed so typed text can never end the sequence early.
    static func clean(_ text: String) -> String {
        var text = text.precomposedStringWithCanonicalMapping
        for special in ["<|startoftext|>", "<|endoftext|>"] {
            text = text.replacingOccurrences(of: special, with: " ", options: .caseInsensitive)
        }
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            let mapped: Unicode.Scalar
            switch scalar {
            case "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}", "\u{2032}": mapped = "'"
            case "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", "\u{2033}": mapped = "\""
            default: mapped = scalar
            }
            if mapped.properties.isWhitespace || mapped.properties.generalCategory == .control {
                pendingSpace = !scalars.isEmpty
                continue
            }
            if pendingSpace {
                scalars.append(" ")
                pendingSpace = false
            }
            scalars.append(mapped)
        }
        return String(scalars).lowercased()
    }

    /// OpenAI's pre-tokenizer pattern (special tokens left out, see
    /// `clean`): English contractions, runs of letters, single digits, runs
    /// of anything else that is not a space.
    private static let wordPattern: NSRegularExpression = {
        // A literal that cannot fail to compile; `try!` states that.
        try! NSRegularExpression(
            pattern: #"'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+"#,
            options: [.caseInsensitive]
        )
    }()

    // MARK: - Byte-level BPE

    /// GPT-2's reversible byte -> printable character table, in vocabulary
    /// order: first the printable Latin-1 bytes (mapped to themselves), then
    /// the other 68 (mapped to U+0100 onwards). `tokenForByte[b]` is the id
    /// of byte `b`'s token; `characterForToken[id]` the character the merges
    /// file writes for it.
    private static let (tokenForByte, characterForToken): ([Int32], [Character]) = {
        var order = Array(33...126) + Array(161...172) + Array(174...255)
        var codes = order
        var next = 256
        for byte in 0...255 where !order.contains(byte) {
            order.append(byte)
            codes.append(next)
            next += 1
        }
        var tokenForByte = [Int32](repeating: 0, count: 256)
        for (token, byte) in order.enumerated() { tokenForByte[byte] = Int32(token) }
        return (tokenForByte, codes.map { Character(Unicode.Scalar(UInt32($0))!) })
    }()

    /// The whole vocabulary (token string -> id) as OpenAI builds it, which
    /// is what `clip-vocab.json` holds. Only for checks and tests: encoding
    /// never needs strings.
    func vocabulary() -> [String: Int32] {
        var strings = [String](repeating: "", count: Self.firstMergeToken + mergeRanks.count)
        for (token, character) in Self.characterForToken.enumerated() {
            strings[token] = String(character)
            strings[256 + token] = String(character) + "</w>"
        }
        // Each merge's halves are earlier tokens, so rank order resolves.
        for (pair, rank) in mergeRanks.sorted(by: { $0.value < $1.value }) {
            let a = Int(UInt32(truncatingIfNeeded: pair >> 32))
            let b = Int(UInt32(truncatingIfNeeded: pair))
            strings[Self.firstMergeToken + Int(rank)] = strings[a] + strings[b]
        }
        var vocabulary = Dictionary(uniqueKeysWithValues: strings.enumerated().map { ($1, Int32($0)) })
        vocabulary["<|startoftext|>"] = Self.startToken
        vocabulary["<|endoftext|>"] = Self.endToken
        return vocabulary
    }

    /// Ids for one pre-tokenized word, memoized: queries repeat the same
    /// few words (and the prompt templates always do).
    private func cachedIDs(for word: String) -> [Int32] {
        cacheLock.lock()
        let cached = wordCache[word]
        cacheLock.unlock()
        if let cached { return cached }

        let ids = bpe(Array(word.utf8))
        cacheLock.lock()
        if wordCache.count > 4_096 { wordCache.removeAll(keepingCapacity: true) }
        wordCache[word] = ids
        cacheLock.unlock()
        return ids
    }

    /// Standard CLIP BPE over token ids: start from one byte token per UTF-8
    /// byte, the last one in its end-of-word form, and repeatedly merge
    /// every occurrence of the adjacent pair with the lowest merge rank
    /// (left to right, non-overlapping) until no adjacent pair is a known
    /// merge. The merge of rank `r` produces token `512 + r`.
    func bpe(_ bytes: [UInt8]) -> [Int32] {
        guard !bytes.isEmpty else { return [] }
        var parts = bytes.map { Self.tokenForByte[Int($0)] }
        parts[parts.count - 1] += 256

        while parts.count > 1 {
            var best: (rank: Int32, index: Int)?
            for index in 0..<(parts.count - 1) {
                if let rank = mergeRanks[Self.pairKey(parts[index], parts[index + 1])], rank < (best?.rank ?? .max) {
                    best = (rank, index)
                }
            }
            guard let best else { break }
            let first = parts[best.index]
            let second = parts[best.index + 1]
            let merged = Int32(Self.firstMergeToken) + best.rank
            var next: [Int32] = []
            next.reserveCapacity(parts.count - 1)
            var index = 0
            while index < parts.count {
                if index < parts.count - 1, parts[index] == first, parts[index + 1] == second {
                    next.append(merged)
                    index += 2
                } else {
                    next.append(parts[index])
                    index += 1
                }
            }
            parts = next
        }
        return parts
    }
}
