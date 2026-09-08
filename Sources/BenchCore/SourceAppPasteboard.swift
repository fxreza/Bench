import AppKit

/// The private pasteboard flavor Bench uses to credit the app a copied image
/// actually came from.
///
/// Shot writes it next to the image data whenever it knows which app was
/// captured (window capture, area capture over a window, scrolling capture,
/// full-screen capture of whatever was frontmost). Klip reads it in
/// `ClipboardWatcher` and stores it as the clip's `sourceApp`, so the preview
/// pane's "From" row says "IINA" instead of "Bench" - the frontmost app at the
/// moment the pasteboard changes is Bench's own overlay or editor window.
///
/// The payload is the app's display name as plain UTF-8 data (no property
/// list, no trailing newline). Anything else on the pasteboard is untouched.
public nonisolated enum SourceAppPasteboard {

    /// Plain UTF-8 string data: the display name of the app the image came
    /// from, e.g. "IINA", "Google Chrome".
    public static let sourceAppNameType = NSPasteboard.PasteboardType("com.fxreza.bench.sourceAppName")

    /// Encodes `name` for `sourceAppNameType`; nil when it is blank.
    public static func data(for name: String?) -> Data? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return Data(trimmed.utf8)
    }

    /// Decodes a `sourceAppNameType` payload; nil when it is missing or blank.
    public static func name(from data: Data?) -> String? {
        guard let data, let raw = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
