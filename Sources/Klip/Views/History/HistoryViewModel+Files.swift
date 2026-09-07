import AppKit

/// File-clip methods for `HistoryViewModel` (Phase 3F). Kept in its own
/// extension file per the phase brief, separate from the hand-written state
/// block in `HistoryViewModel.swift` itself.
extension HistoryViewModel {
    // MARK: - Toast (3A duplicate — see the `// MARK: - 3F state` block)

    /// Show a transient banner message, auto-dismissing after `duration`.
    /// Currently used to report a missing file on copy/paste/save; the
    /// message is silently dropped if a newer toast replaced it before the
    /// timer fires.
    /// Thin wrapper over the shared toast (3A) for file-related notices.
    func showToast(_ text: String, duration: TimeInterval = 2.5) {
        showToast(text: text, systemImage: "doc.badge.ellipsis")
    }

    // MARK: - Save to disk

    /// ⌘S / the preview pane's save action, generalized to any item kind.
    /// Images save in their original stored format (6C — a captured JPEG
    /// saves as `.jpg`, never re-encoded to PNG), text saves as `.txt`,
    /// files save straight to a path (single) or into a chosen folder
    /// (multiple).
    func saveSelectedToDisk() {
        guard let item = selectedItem else { return }
        if store.fileIsMissing(item) {
            showToast("Some files are missing from disk")
            return
        }
        PasteController.saveToDisk(item, store: store)
    }

    /// Multi-selection "Save All…": every selected image/file/text goes into
    /// one chosen folder, with unique names so nothing silently overwrites
    /// another item that happens to produce the same filename.
    func saveAllSelected() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        let store = self.store

        if items.contains(where: { store.fileIsMissing($0) }) {
            showToast("Some files are missing from disk")
        }

        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.canCreateDirectories = true
        openPanel.title = "Select Folder to Save Items"
        openPanel.prompt = "Select"

        guard let window = NSApplication.shared.windows.first else { return }

        openPanel.beginSheetModal(for: window) { response in
            guard response == .OK, let folderURL = openPanel.url else { return }

            DispatchQueue.global(qos: .userInitiated).async {
                for (index, item) in items.enumerated() {
                    switch item.type {
                    case .image:
                        // 6C: write the original stored bytes under the
                        // original extension — no PNG re-encode.
                        guard let data = store.imageData(for: item) else { continue }
                        let ext = (item.imageFilename as NSString?)?.pathExtension.lowercased()
                        let safeExt = (ext?.isEmpty ?? true) ? "png" : ext!
                        let name = "image-\(String(format: "%04d", index + 1)).\(safeExt)"
                        let dest = PasteController.uniqueURL(for: name, in: folderURL)
                        do {
                            try data.write(to: dest)
                        } catch {
                            print("[Buffer] Save All: failed to write \(name): \(error)")
                        }

                    case .file:
                        for source in store.fileURLs(for: item) {
                            let dest = PasteController.uniqueURL(for: source.lastPathComponent, in: folderURL)
                            do {
                                try FileManager.default.copyItem(at: source, to: dest)
                            } catch {
                                print("[Buffer] Save All: failed to copy \(source.lastPathComponent): \(error)")
                            }
                        }

                    case .text:
                        guard let text = store.fullText(for: item), !text.isEmpty else { continue }
                        let name = "text-\(String(format: "%04d", index + 1)).txt"
                        let dest = PasteController.uniqueURL(for: name, in: folderURL)
                        do {
                            try text.write(to: dest, atomically: true, encoding: .utf8)
                        } catch {
                            print("[Buffer] Save All: failed to write \(name): \(error)")
                        }
                    }
                }
            }
        }
    }
}
