import Foundation

/// Feature flags for surfaces that are built and working but deliberately not
/// shown.
///
/// A flag here is not a half-finished feature or an experiment. It is a
/// complete one whose UI has been withdrawn, with every line of the
/// implementation left in place — model, store, search, sync and tests — so
/// that turning it back on is this one constant and nothing else.
enum Features {
    /// Tags: `ClipboardItem.tags`, the row chips, the Tags filter chip, the
    /// `#tag` search syntax, the preview pane's tag editor, ⌘T, and the
    /// "Clear Tag Filter" key.
    ///
    /// Off since 3.7.0. Folders cover the same ground for this history — a
    /// clip goes in one place and is found there — and every tag surface was
    /// a second, parallel way to file and filter that had to be kept in the
    /// head alongside the first. Nothing about tags was deleted: clips keep
    /// the tags they already carry, those tags still protect a clip from the
    /// history limit, they still sync, and searching still matches them.
    /// They are simply not shown or editable.
    ///
    /// Flip this to `true` and the whole surface comes back exactly as it
    /// was.
    static let tagsEnabled = false
}
