import Cocoa
import UniformTypeIdentifiers

/// Rich-vs-plain paste/copy mode (Phase 3D, decision D5).
///
/// `.rich` restores the full captured pasteboard flavors when available
/// (byte-perfect replay), else RTF + a plain-text fallback, else plain text.
/// `.plain` always writes only the plain-text string. Images and files ignore
/// the mode entirely — there is nothing "rich" to strip from either.
enum PasteMode: Equatable {
    case rich
    case plain
}

/// Handles pasting content into the frontmost application
class PasteController {

    /// Writes a `.text` item's plain/RTF/flavors payload onto `pasteboard`
    /// according to `mode`. Shared by `copyToClipboard` and `paste`.
    private static func writeText(_ item: ClipboardItem, store: ClipboardStore, mode: PasteMode, to pasteboard: NSPasteboard) {
        guard let text = store.fullText(for: item) else { return }

        if mode == .plain {
            pasteboard.setString(text, forType: .string)
            return
        }

        // Rich: prefer a byte-perfect replay of every captured pasteboard
        // flavor (Clipfield's `PasteboardFlavors.restore`); else fall back to
        // RTF + a plain-text sibling; else plain text alone.
        if let flavors = store.flavorsData(for: item), PasteboardFlavors.restore(flavors, to: pasteboard) {
            return
        }
        if let rtf = store.rtfData(for: item) {
            pasteboard.setData(rtf, forType: .rtf)
        }
        pasteboard.setString(text, forType: .string)
    }


    /// Get or create temp directory for paste operations
    private static func getTempDirectory() -> URL? {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("BufferPaste")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    /// Writes `data` verbatim to `fileName` under the paste temp directory
    /// and returns its URL — no decode, no re-encode. Used by
    /// `pasteMultiple`'s per-image batch, where `fileName` carries the
    /// item's original extension (6C: `image-0001.jpg`, not always `.png`).
    private static func saveImageToTemp(_ data: Data, fileName: String) -> URL? {
        guard let tempDir = getTempDirectory() else { return nil }
        let fileURL = tempDir.appendingPathComponent(fileName)
        do {
            try data.write(to: fileURL)
            return fileURL
        } catch {
            return nil
        }
    }

    /// Extension to give a temp/saved copy of `item`'s image, derived from
    /// its stored filename. Defaults to `png` for a malformed item with no
    /// filename. Not `private`: exercised directly by the 6C test suite
    /// alongside `writeImageData(for:store:to:)`, since Save to Disk's own
    /// entry points drive an `NSSavePanel` and can't run headlessly.
    static func imageFileExtension(for item: ClipboardItem) -> String {
        guard let filename = item.imageFilename else { return "png" }
        let ext = (filename as NSString).pathExtension.lowercased()
        return ext.isEmpty ? "png" : ext
    }

    /// Writes `item`'s original stored image bytes to `destination` — no
    /// decode, no re-encode. This is the actual byte-writing step behind
    /// `saveImageToDisk`/`saveToDisk`/Save All, pulled out from the
    /// `NSSavePanel` glue so it can be exercised directly in tests. Returns
    /// whether the write succeeded.
    @discardableResult
    static func writeImageData(for item: ClipboardItem, store: ClipboardStore, to destination: URL) -> Bool {
        guard let data = store.imageData(for: item) else { return false }
        do {
            try data.write(to: destination)
            return true
        } catch {
            print("[Buffer] Failed to save image to disk: \(error)")
            return false
        }
    }

    /// Writes a `.image` item's bytes onto `pasteboard`: the stored bytes,
    /// under their real UTI, as the primary type (6C — a captured JPEG stays
    /// `public.jpeg`, never silently becomes PNG), plus a TIFF representation
    /// decoded from those same bytes as a second type so apps that only
    /// accept PNG/TIFF still get a paste. For a stored PNG the primary type
    /// is `.png` and the TIFF fallback is exactly today's behavior. Neither
    /// type write touches the primary bytes — an app that understands the
    /// real UTI gets the original file exactly.
    ///
    /// Shared by `copyToClipboard` and `paste`, like `writeText` above.
    /// Deliberately not `private` — the watcher-test pattern (a private
    /// `NSPasteboard(name:)`) needs a paste/copy path that isn't hardwired to
    /// `NSPasteboard.general`.
    static func writeImage(_ item: ClipboardItem, store: ClipboardStore, to pasteboard: NSPasteboard) {
        guard let data = store.imageData(for: item) else { return }
        let uti = item.resolvedImageUTI ?? "public.png"
        pasteboard.setData(data, forType: NSPasteboard.PasteboardType(rawValue: uti))
        if let image = NSImage(data: data), let tiffData = image.tiffRepresentation {
            pasteboard.setData(tiffData, forType: .tiff)
        }
    }
    
    /// Copy a bare string to `pasteboard` — the OCR text under an image
    /// preview, and anything else that is text without being a clip.
    ///
    /// Goes through here rather than touching `NSPasteboard.general`
    /// directly so the `.bufferIgnoreNextChange` handshake happens *before*
    /// the write, exactly as `copyToClipboard`/`paste` do: the watcher polls
    /// every 500 ms, and a poll landing between the write and the flag would
    /// re-capture the app's own copy as a brand-new clip.
    ///
    /// Returns whether anything was written, so callers can decide whether
    /// to confirm to the user.
    @discardableResult
    static func copyPlainText(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        NotificationCenter.default.post(name: .bufferIgnoreNextChange, object: nil)
        pasteboard.clearContents()
        return pasteboard.setString(trimmed, forType: .string)
    }

    /// Copy item content back to system clipboard. `mode` only affects `.text`
    /// items — see `PasteMode`.
    static func copyToClipboard(_ item: ClipboardItem, store: ClipboardStore, mode: PasteMode = .rich) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.type {
        case .text:
            writeText(item, store: store, mode: mode, to: pasteboard)
        case .image:
            writeImage(item, store: store, to: pasteboard)
        case .file:
            writeFileURLs(for: [item], store: store, to: pasteboard)
        }
    }

    /// Write file items' payloads onto the pasteboard as file URLs, so the
    /// receiving app copies/attaches the files (Finder copies them in, Mail /
    /// Slack attach them). Each file becomes its own `NSPasteboardItem`
    /// carrying both the file URL type (what Finder/Mail/Slack look for) and
    /// a plain-text fallback of the path, the same pairing Finder itself
    /// offers, so apps that only read strings still get something useful.
    @discardableResult
    private static func writeFileURLs(for items: [ClipboardItem], store: ClipboardStore, to pasteboard: NSPasteboard) -> Bool {
        let urls = items.flatMap { store.fileURLs(for: $0) }
        return writeFileURLs(urls, to: pasteboard)
    }

    @discardableResult
    private static func writeFileURLs(_ urls: [URL], to pasteboard: NSPasteboard) -> Bool {
        guard !urls.isEmpty else { return false }
        let pasteboardItems: [NSPasteboardItem] = urls.map { url in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            item.setString(url.path, forType: .string)
            return item
        }
        pasteboard.writeObjects(pasteboardItems)
        return true
    }
    
    /// Paste item into the frontmost application. `mode` only affects `.text`
    /// items — see `PasteMode`.
    static func paste(_ item: ClipboardItem, store: ClipboardStore, previousApp: NSRunningApplication? = nil, mode: PasteMode = .rich) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.type {
        case .text:
            writeText(item, store: store, mode: mode, to: pasteboard)
        case .image:
            writeImage(item, store: store, to: pasteboard)
        case .file:
            writeFileURLs(for: [item], store: store, to: pasteboard)
        }

        // Reactivate previous app, then simulate paste after it has focus
        bringForward(previousApp)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Post ignore notification right before paste
            NotificationCenter.default.post(name: .bufferIgnoreNextChange, object: nil)
            simulatePaste()
        }
    }
    
    /// Paste multiple items into the frontmost application.
    /// Text items are joined with newlines; images and files go out together as
    /// file URLs (like a Finder multi-select).
    ///
    /// `mode` is accepted for API symmetry with `paste(_:mode:)` but does not
    /// currently change anything: joining several items' *rich* text into one
    /// paste is out of scope (Phase 3D task brief), so the joined text is
    /// always plain, exactly as before — this is called out in the paste
    /// menu's help text.
    static func pasteMultiple(_ items: [ClipboardItem], store: ClipboardStore, previousApp: NSRunningApplication? = nil, mode: PasteMode = .rich) {
        guard !items.isEmpty else { return }

        let pasteboard = NSPasteboard.general

        // Separate items by type
        let textItems = items.filter { $0.type == .text }
        let imageItems = items.filter { $0.type == .image }
        let fileItems = items.filter { $0.type == .file }
        let hasURLItems = !imageItems.isEmpty || !fileItems.isEmpty

        /// Writes every image (as a PNG in the temp dir) and every file payload
        /// onto the pasteboard as one batch of file URLs, then pastes.
        func writeURLBatchAndPaste() {
            // 5A-21: tell the watcher to ignore this change *before* the
            // pasteboard is written, exactly as the single-item path does.
            // `simulatePasteWithCustomDelay` posts the same flag, but only
            // 50 ms later — and the watcher polls every 500 ms, so a poll
            // landing in that window captured the app's own paste as a new
            // (text) clip.
            NotificationCenter.default.post(name: .bufferIgnoreNextChange, object: nil)
            pasteboard.clearContents()

            var urls: [URL] = []
            for (index, imageItem) in imageItems.enumerated() {
                if let data = store.imageData(for: imageItem) {
                    let paddedNumber = String(format: "%04d", index + 1)
                    let fileName = "image-\(paddedNumber).\(imageFileExtension(for: imageItem))"
                    if let fileURL = saveImageToTemp(data, fileName: fileName) {
                        urls.append(fileURL)
                    }
                }
            }
            urls.append(contentsOf: fileItems.flatMap { store.fileURLs(for: $0) })

            if writeFileURLs(urls, to: pasteboard) {
                simulatePasteWithCustomDelay(0.05)
            }
        }

        // If we have text items, paste them first
        if !textItems.isEmpty {
            pasteboard.clearContents()
            let joinedText = textItems.compactMap { store.fullText(for: $0) }.joined(separator: "\n")
            pasteboard.setString(joinedText, forType: .string)

            // If all items are text, paste once and done
            if !hasURLItems {
                bringForward(previousApp)
                simulatePasteWithCustomDelay(0.1)
                return
            }

            // Paste text first, then images/files together after
            bringForward(previousApp)
            simulatePasteWithCustomDelay(0.1)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                writeURLBatchAndPaste()
            }
        } else if hasURLItems {
            // Images/files only - paste all together at once (like Finder multi-select)
            bringForward(previousApp)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                writeURLBatchAndPaste()
            }
        }
    }
    
    /// Simulate Command + V keystroke
    /// Hands activation back to the app the paste is meant for.
    ///
    /// macOS 14 retired `.activateIgnoringOtherApps` (it "has no effect");
    /// `activate(from:options:)` is the cooperative-activation replacement:
    /// Bench, which is active while the history panel is key, explicitly
    /// yields to the target app.
    private static func bringForward(_ app: NSRunningApplication?) {
        guard let app else { return }
        _ = app.activate(from: .current, options: [])
    }

    private static func simulatePaste() {
        // Content is already on the pasteboard by the time this runs (today's
        // behavior, unchanged) — without Accessibility access the synthesized
        // ⌘V below won't reach the frontmost app, so let the UI know it still
        // needs a manual ⌘V.
        if !AXIsProcessTrusted() {
            NotificationCenter.default.post(name: .klipPasteNeedsAccessibility, object: nil)
        }

        let source = CGEventSource(stateID: .hidSystemState)
        
        // Key code for 'V' is 9
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        
        // Add Command modifier
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        
        // Post the events
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }
    
    /// Simulate Command + V keystroke with custom delay
    private static func simulatePasteWithCustomDelay(_ delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            // Post ignore notification right before paste
            NotificationCenter.default.post(name: .bufferIgnoreNextChange, object: nil)
            simulatePaste()
        }
    }
    
    /// Save an image item to disk using NSSavePanel, writing its original
    /// stored bytes exactly — no NSImage decode/re-encode round-trip (6C).
    /// The save panel's allowed type and appended extension come from the
    /// item's stored filename/UTI, so a captured JPEG saves as a `.jpg` file
    /// with the exact bytes that were captured.
    static func saveImageToDisk(for item: ClipboardItem, store: ClipboardStore) {
        guard store.imageData(for: item) != nil else { return }
        let ext = imageFileExtension(for: item)

        DispatchQueue.main.async {
            let panel = NSSavePanel()
            panel.allowedContentTypes = UTType(filenameExtension: ext).map { [$0] } ?? [.png]

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let timestamp = formatter.string(from: Date())

            panel.nameFieldStringValue = "Image-\(timestamp)"
            panel.canCreateDirectories = true

            if panel.runModal() == .OK, let url = panel.url {
                writeImageData(for: item, store: store, to: url)
            }
        }
    }

    // MARK: - Save to disk, generalized (Phase 3F)

    /// Save one item to disk, whatever its kind: images write their original
    /// stored bytes under their original extension (6C — no PNG conversion),
    /// text as a `.txt` file, and files either straight to a chosen path
    /// (single file) or into a chosen folder (multiple files in one
    /// attachment). This is what ⌘S ("Save to Disk") and the multi-select
    /// "Save All…" button use.
    static func saveToDisk(_ item: ClipboardItem, store: ClipboardStore) {
        switch item.type {
        case .image:
            saveImageToDisk(for: item, store: store)
        case .text:
            saveTextToDisk(item, store: store)
        case .file:
            saveFileToDisk(item, store: store)
        }
    }

    private static func saveTextToDisk(_ item: ClipboardItem, store: ClipboardStore) {
        let text = store.fullText(for: item) ?? item.textContent ?? ""
        DispatchQueue.main.async {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.plainText]

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            panel.nameFieldStringValue = "Clip-\(formatter.string(from: Date()))"
            panel.canCreateDirectories = true

            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                print("[Buffer] Failed to save text to disk: \(error)")
            }
        }
    }

    private static func saveFileToDisk(_ item: ClipboardItem, store: ClipboardStore) {
        let urls = store.fileURLs(for: item)
        guard !urls.isEmpty else { return }

        DispatchQueue.main.async {
            if urls.count == 1, let source = urls.first {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = source.lastPathComponent
                panel.canCreateDirectories = true
                guard panel.runModal() == .OK, let destination = panel.url else { return }

                do {
                    try copyReplacingItem(at: source, to: destination)
                } catch {
                    print("[Buffer] Failed to save file to disk: \(error)")
                }
            } else {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.title = "Select Folder to Save Files"
                panel.prompt = "Select"
                guard panel.runModal() == .OK, let folder = panel.url else { return }

                for source in urls {
                    let destination = uniqueURL(for: source.lastPathComponent, in: folder)
                    do {
                        try FileManager.default.copyItem(at: source, to: destination)
                    } catch {
                        print("[Buffer] Failed to save \(source.lastPathComponent): \(error)")
                    }
                }
            }
        }
    }

    /// Copies `source` over `destination`, replacing what is already there
    /// **only once the copy has succeeded** (review 5A-23).
    ///
    /// "Save to Disk" for a single file used to `removeItem(at: destination)`
    /// and then `copyItem`: if the copy failed — the source had vanished,
    /// permissions, a full disk — the user's existing file at that path was
    /// already gone and nothing replaced it. The copy now lands on a hidden
    /// sibling name first and is swapped in with `replaceItemAt`, so a
    /// failure leaves the original untouched.
    static func copyReplacingItem(
        at source: URL,
        to destination: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: destination.path) else {
            try fileManager.copyItem(at: source, to: destination)
            return
        }

        let staging = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".klip-save-\(UUID().uuidString)-\(destination.lastPathComponent)")
        try fileManager.copyItem(at: source, to: staging)
        do {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    /// Returns a URL for `name` inside `directory` that doesn't collide with
    /// an existing file — `"Report.pdf"` becomes `"Report 2.pdf"`,
    /// `"Report 3.pdf"`, and so on until a free name is found. Used by
    /// single/multi file save and by "Save All…" so nothing is silently
    /// overwritten when several selected items would otherwise produce the
    /// same filename.
    static func uniqueURL(for name: String, in directory: URL, fileManager: FileManager = .default) -> URL {
        var candidate = directory.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: candidate.path) else { return candidate }

        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))

        var counter = 2
        repeat {
            let newName = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(newName)
            counter += 1
        } while fileManager.fileExists(atPath: candidate.path)

        return candidate
    }
}
