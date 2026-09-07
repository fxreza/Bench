import AppKit
import QuickLookUI

/// Drives the system Quick Look panel for the focused clip (Space, or ⌘Y).
///
/// Quick Look previews *files*, so every clip has to resolve to at least one
/// URL first:
///
/// - `.file` clips already have real ones on disk (all of them, so the panel's
///   own arrows walk a multi-file clip);
/// - `.image` clips hand over the original stored bytes, not a thumbnail;
/// - `.text` clips are written to a throwaway `.txt` inside a private temp
///   directory, named after the clip so the panel's title bar reads as
///   something recognisable. That directory is deleted the moment the panel
///   closes.
///
/// **Focus.** `QLPreviewPanel` takes key focus when it opens and `HistoryPanel`
/// closes itself on `resignKey`, so without `HistoryPanel.isQuickLookPresenting`
/// pressing Space would open the preview and dismiss the history window
/// underneath it in the same breath. The flag is raised here for the lifetime
/// of the preview and lowered again from `endPreviewPanelControl`.
@MainActor
final class QuickLookController: NSObject {
    static let shared = QuickLookController()

    private var urls: [URL] = []
    private var tempDirectory: URL?
    private weak var host: HistoryPanel?

    private override init() { super.init() }

    /// Whether the shared panel is on screen. `sharedPreviewPanelExists()` is
    /// checked first so merely *asking* never allocates the panel.
    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    /// Opens Quick Look on `item`, or closes it if it is already up — Space on
    /// an open preview dismisses it, matching Finder.
    ///
    /// Returns `false` when the clip resolves to nothing previewable (an empty
    /// text clip, or a file clip whose files have been moved or deleted), so
    /// the caller can say so rather than leaving the key looking broken.
    @discardableResult
    func toggle(item: ClipboardItem, store: ClipboardStore, host: HistoryPanel?) -> Bool {
        if isVisible {
            QLPreviewPanel.shared().orderOut(nil)
            return true
        }

        let resolved = previewURLs(for: item, store: store)
        guard !resolved.isEmpty else { return false }

        urls = resolved
        self.host = host
        host?.isQuickLookPresenting = true

        let panel = QLPreviewPanel.shared()!
        // Set here *and* from `HistoryPanel.beginPreviewPanelControl`: the
        // responder-chain hand-off is what keeps the panel pointed at this
        // object across a reopen, but assigning up front means the first
        // `reloadData` already has something to read.
        panel.dataSource = self
        // The history window is a `.floating` panel, so a preview at the
        // default window level opens *behind* the list it was summoned from.
        // One level up puts it in front while leaving the list visible
        // underneath, which is where Esc goes back to.
        panel.level = (host?.level ?? .floating).rawValue >= NSWindow.Level.floating.rawValue
            ? NSWindow.Level(rawValue: (host?.level ?? .floating).rawValue + 1)
            : .floating
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
        return true
    }

    func close() {
        guard isVisible else { return }
        QLPreviewPanel.shared().orderOut(nil)
    }

    /// Called from `HistoryPanel.endPreviewPanelControl` when the panel gives
    /// control back: drop the temp file and hand key focus to the history
    /// window, which would otherwise be left on screen but unfocused.
    func didEndControl() {
        let host = self.host
        host?.isQuickLookPresenting = false
        // The panel is about to become key again; that must not read as the
        // history window being opened afresh (which resets scope and filters).
        host?.suppressNextBecomeKey = true
        self.host = nil
        urls = []
        discardTempDirectory()

        DispatchQueue.main.async {
            // Not when the user dismissed Quick Look by switching away from
            // Klip entirely — re-keying here would drag the app back to the
            // front behind their back.
            guard NSApp.isActive, let host, host.isVisible else { return }
            host.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Resolving a clip to previewable URLs

    private func previewURLs(for item: ClipboardItem, store: ClipboardStore) -> [URL] {
        let fileManager = FileManager.default
        switch item.type {
        case .file:
            return store.fileURLs(for: item).filter { fileManager.fileExists(atPath: $0.path) }

        case .image:
            guard let url = store.imageURL(for: item),
                  fileManager.fileExists(atPath: url.path) else { return [] }
            return [url]

        case .text:
            guard let text = store.fullText(for: item), !text.isEmpty else { return [] }
            guard let url = writeTemporaryText(text, named: temporaryName(for: item)) else { return [] }
            return [url]
        }
    }

    /// Quick Look titles a URL by its last path component, so the temp file is
    /// named after the clip rather than something like `clip.txt`.
    private func temporaryName(for item: ClipboardItem) -> String {
        let raw = item.displayTitle ?? item.previewText
        let firstLine = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let cleaned = firstLine
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = String(cleaned.prefix(60)).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Clip" : trimmed
    }

    private func writeTemporaryText(_ text: String, named name: String) -> URL? {
        discardTempDirectory()
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("KlipQuickLook-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory
                .appendingPathComponent(name)
                .appendingPathExtension("txt")
            try text.write(to: url, atomically: true, encoding: .utf8)
            tempDirectory = directory
            return url
        } catch {
            try? fileManager.removeItem(at: directory)
            return nil
        }
    }

    private func discardTempDirectory() {
        guard let directory = tempDirectory else { return }
        tempDirectory = nil
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - QLPreviewPanelDataSource

extension QuickLookController: QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        // `NSURL` conforms to `QLPreviewItem` natively. `[safe:]` because the
        // panel can ask for an index once more after the list has been torn
        // down on close.
        urls[safe: index] as NSURL?
    }
}
