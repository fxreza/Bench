import Foundation

/// A text clip's word and character counts, for the **Words** and
/// **Characters** rows in the preview pane's footer.
///
/// Words are what `enumerateSubstrings(.byWords)` finds, the same word
/// boundaries the system uses for double-click selection, so punctuation and
/// spaces never count and languages without spaces between words (Chinese,
/// Japanese, Thai) are still split into words. Characters are what a person
/// sees as one character (grapheme clusters): an emoji or "é" counts once,
/// whatever it is made of. Spaces and line breaks count, as in Pages' and
/// Word's "characters (with spaces)".
nonisolated struct TextStats: Equatable, Sendable {
    let words: Int
    let characters: Int

    static func count(_ text: String) -> TextStats {
        var words = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            words += 1
        }
        return TextStats(words: words, characters: text.count)
    }

    /// "1,187": grouped the way the Mac's region settings group numbers.
    static func formatted(_ value: Int) -> String {
        value.formatted(.number)
    }
}
