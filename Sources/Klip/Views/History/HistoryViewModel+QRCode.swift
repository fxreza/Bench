import AppKit
import SwiftUI

/// "Show QR Code" — puts the focused clip on screen as a QR code so a phone
/// can scan it out of Klip.
///
/// Opened by the preview pane's `qrcode` icon, the row context menu, or the
/// rebindable shortcut (⌘K by default). The card itself is
/// `Views/History/QRCodePrompt.swift`; what a clip encodes to, and the reason
/// when it encodes to nothing, is `Services/QRCodeService.swift`.
///
/// It is a `PromptCard` like every other in-panel dialog rather than a popover
/// or a window: the history panel closes as soon as it resigns key, so
/// anything that takes focus takes the panel with it.
extension HistoryViewModel {
    /// The clip the card is showing. Read from the store rather than captured,
    /// so an edit landing underneath the card is reflected in the code.
    var qrTarget: ClipboardItem? {
        guard let id = qrItemID else { return nil }
        return store.items.first(where: { $0.id == id })
    }

    /// What `qrTarget` encodes to, or why it does not.
    var qrPayload: Result<String, QRCodeService.Unavailable>? {
        guard let item = qrTarget else { return nil }
        return QRCodeService.payload(for: item, store: store)
    }

    /// Whether `item` has a QR code at all — drives the enabled state of the
    /// preview pane's icon and of the menu entry.
    func canShowQRCode(for item: ClipboardItem) -> Bool {
        if case .success = QRCodeService.payload(for: item, store: store) { return true }
        return false
    }

    /// The tooltip for a clip whose QR icon is off, or nil when it is on.
    func qrUnavailableReason(for item: ClipboardItem) -> String? {
        guard case .failure(let reason) = QRCodeService.payload(for: item, store: store) else { return nil }
        return reason.reason
    }

    /// Open the card on `id`. Refuses in the trash, where the clip is not in
    /// `store.items` for `qrTarget` to find — the same guard rename and tags
    /// use.
    func requestQRCode(id: UUID) {
        guard !isTrashScope else { return }
        guard store.items.contains(where: { $0.id == id }) else { return }
        if isEditing { exitEditMode() }
        showTagInput = false
        qrItemID = id
        showQRPrompt = true
    }

    /// ⌘K — the focused clip. A no-op with nothing selected, and in the trash.
    ///
    /// Deliberately opens on an unencodable clip too: the card then says *why*
    /// there is no code, which is more use than a key that looks broken.
    func keyShowQR() {
        guard !isEditing else { return }
        guard let item = selectedItem else { return }
        requestQRCode(id: item.id)
    }

    func cancelQRCode() {
        showQRPrompt = false
        qrItemID = nil
    }

    /// "Copy Image" — the rendered code onto the clipboard, so it can be
    /// pasted into a message or a document.
    ///
    /// `bufferIgnoreNextChange` keeps Klip's own watcher from filing the
    /// picture of a clip as a new clip.
    func copyQRImage(_ image: NSImage) {
        NotificationCenter.default.post(name: .bufferIgnoreNextChange, object: nil)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        showToast(text: "QR code copied", systemImage: "qrcode")
    }

    /// "Save PNG…" — routed out to `HistoryWindowController`, which has the
    /// panel and can stop it closing behind the save sheet.
    func saveQRImage(_ image: NSImage) {
        guard let data = QRCodeService.pngData(for: image) else {
            showToast(text: "Could not render the QR code", systemImage: "qrcode")
            return
        }
        onSaveQRCode(data, qrSuggestedFilename)
    }

    /// `QR-<clip name>` when the clip has a name, otherwise a timestamp —
    /// matching how "Save to Disk" names a text clip.
    private var qrSuggestedFilename: String {
        if let title = qrTarget?.displayTitle, !title.isEmpty {
            let safe = title.replacingOccurrences(of: "/", with: "-")
            return "QR-\(safe)"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "QR-\(formatter.string(from: Date()))"
    }
}
