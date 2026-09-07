import AppKit
import SwiftUI

/// Drag-and-drop plumbing for filing clips into folders (Phase 3B).
///
/// SwiftUI's `.onDrag` cannot be used on a clip row: the row's mouse events are
/// owned by the `ClickModifierDetector` overlay (it is what makes ⌘/⇧-click
/// visible to the view model), and an `.onDrag` modifier under that overlay
/// never sees a mouse-down. So the drag is started by AppKit from the overlay
/// itself (`ClickModifierDetector.ClickView.mouseDragged`) and the sidebar rows
/// are AppKit drop targets (`SidebarDropTarget`).
///
/// Reordering *folders* is not here: it is a SwiftUI `DragGesture` in
/// `Sidebar`, for the reason spelled out on `SidebarDropTarget`.
///
/// The payload is a private pasteboard type carrying newline-separated UUID
/// strings, so a drag that escapes the app is inert rather than pasting
/// something surprising into another application.
enum ClipDragPayload {
    /// Clip ids being dragged out of the list.
    static let clipsType = NSPasteboard.PasteboardType("com.fxreza.klip.clipids")

    // MARK: - Encoding

    /// `[uuid, uuid, …]` → `"uuid\nuuid\n…"`.
    static func encode(_ ids: [UUID]) -> String {
        ids.map { $0.uuidString }.joined(separator: "\n")
    }

    /// Inverse of `encode`. Unparseable lines are dropped, duplicates are
    /// collapsed and the original order is preserved.
    ///
    /// Splitting goes through `CharacterSet.newlines` on purpose: `"\r\n"` is a
    /// *single* Swift `Character`, so comparing characters against `"\n"` would
    /// silently glue two lines together.
    static func decode(_ string: String) -> [UUID] {
        var seen = Set<UUID>()
        var result: [UUID] = []
        for line in string.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let id = UUID(uuidString: trimmed), seen.insert(id).inserted else { continue }
            result.append(id)
        }
        return result
    }

    static func pasteboardItem(ids: [UUID]) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(encode(ids), forType: clipsType)
        return item
    }

    // MARK: - Reading

    static func ids(from pasteboard: NSPasteboard) -> [UUID] {
        guard let string = pasteboard.string(forType: clipsType) else { return [] }
        return decode(string)
    }
}

/// What `ClickModifierDetector` should put on the dragging pasteboard, captured
/// at mouse-down time (before the click handler mutates the selection) so the
/// click semantics are untouched.
struct ClipDragRequest {
    let ids: [UUID]
    let image: NSImage
}

// MARK: - Sidebar drop target

/// Invisible AppKit layer placed in the **background** of a sidebar row, so the
/// row can accept clips dragged out of the list.
///
/// It is deliberately *not* an overlay: `mouseDown` is forwarded to the next
/// responder so the row's SwiftUI tap gestures (select scope, double-click to
/// rename) and its `.contextMenu` keep working exactly as they do without it.
/// The view exists only so AppKit has something registered for dragged types
/// under the mouse.
///
/// **It cannot be a drag *source*.** This view used to start the folder
/// reorder drag from its own `mouseDragged`, and that never once fired: a
/// background view is behind the row's SwiftUI tap gestures, so SwiftUI's
/// hosting view takes the mouse-down and nothing below it hears about the
/// press. (Being found as a drag *destination* is a separate AppKit search
/// and does work — which is why filing clips into folders has always been
/// fine.) The clip rows get away with an AppKit drag source only because
/// `ClickModifierDetector` is an **overlay** that owns `mouseDown` outright
/// and re-implements clicking on top of it. Rather than do that to the
/// sidebar — where a row has to keep single-click select, double-click
/// rename and a context menu — folder reordering is a plain SwiftUI
/// `DragGesture`, in `Sidebar.folderDrag`, living in the same gesture system
/// as those taps.
struct SidebarDropTarget: NSViewRepresentable {
    /// Accept dragged clip ids (All + folder rows; Favorites does not).
    var acceptsClips: Bool = false
    /// Return true if the drop was consumed.
    var onDropClips: ([UUID]) -> Bool = { _ in false }
    /// Row-highlight feedback for the SwiftUI row.
    var onTargetChanged: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> DropView {
        let view = DropView()
        apply(to: view)
        view.refreshRegistration()
        return view
    }

    /// 3.0.1 audit (the `QLPreviewView` crash): everything this does during a
    /// SwiftUI update is assignment plus a drag-type registration that is
    /// idempotent and guarded by `refreshRegistration`'s early return. No
    /// framework call here can assert or block while the layout pass is in
    /// flight — unlike `-[QLPreviewView setPreviewItem:]`, which did both.
    func updateNSView(_ nsView: DropView, context: Context) {
        apply(to: nsView)
        nsView.refreshRegistration()
    }

    private func apply(to view: DropView) {
        view.acceptsClips = acceptsClips
        view.onDropClips = onDropClips
        view.onTargetChanged = onTargetChanged
    }

    final class DropView: NSView {
        var acceptsClips = false
        var onDropClips: (([UUID]) -> Bool)?
        var onTargetChanged: ((Bool) -> Void)?

        private var registeredClips = false
        private var isTargeted = false {
            didSet {
                guard isTargeted != oldValue else { return }
                onTargetChanged?(isTargeted)
            }
        }

        /// Registers (or unregisters) for dragged clip ids to match whether
        /// this row can take them, so AppKit shows the "no drop" cursor over
        /// rows that would reject the drag anyway. Idempotent.
        func refreshRegistration() {
            guard acceptsClips != registeredClips else { return }
            registeredClips = acceptsClips
            unregisterDraggedTypes()
            if acceptsClips { registerForDraggedTypes([ClipDragPayload.clipsType]) }
        }

        // MARK: Mouse — forwarded, never consumed

        override func mouseDown(with event: NSEvent) {
            // The SwiftUI row above owns click/double-click/right-click.
            super.mouseDown(with: event)
        }

        // MARK: NSDraggingDestination

        private func canAccept(_ info: NSDraggingInfo) -> Bool {
            acceptsClips && !ClipDragPayload.ids(from: info.draggingPasteboard).isEmpty
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            isTargeted = canAccept(sender)
            return isTargeted ? .move : []
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            isTargeted = canAccept(sender)
            return isTargeted ? .move : []
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            isTargeted = false
        }

        override func draggingEnded(_ sender: NSDraggingInfo) {
            isTargeted = false
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            canAccept(sender)
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            defer { isTargeted = false }
            let ids = ClipDragPayload.ids(from: sender.draggingPasteboard)
            guard acceptsClips, !ids.isEmpty else { return false }
            return onDropClips?(ids) ?? false
        }
    }
}
