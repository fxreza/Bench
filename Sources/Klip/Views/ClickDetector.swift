import SwiftUI
import AppKit

/// A simple wrapper that detects clicks with modifier keys.
///
/// Phase 3B also makes it the **drag source** for clip rows. It has to be: the
/// overlay swallows `mouseDown`, so a SwiftUI `.onDrag` placed on the row below
/// it would never start. A drag begins once the pointer has travelled more than
/// `dragThreshold` points with the button held; anything short of that is a
/// plain click and behaves exactly as it did before (select / ⌘ / ⇧, with the
/// double-click recogniser still living in `ClipList`).
///
/// 5C makes it the row's **drop target** too, for reordering clips inside a
/// folder. The target has to live here rather than in a background view like
/// `SidebarDropTarget`: this overlay is the topmost view over the row, so it
/// is what AppKit hit-tests during a drag, and a sibling in the background
/// would never be found.
struct ClickModifierDetector: NSViewRepresentable {
    let onClickWithModifiers: (NSEvent.ModifierFlags) -> Void

    /// Where a reorder drop would insert the dragged clips relative to this row.
    enum InsertionEdge {
        case above
        case below
    }

    /// Asked **once per mouse-down, before `onClickWithModifiers` runs**, so the
    /// payload reflects the selection as it was when the press started. Return
    /// nil to make the row undraggable.
    var dragPayload: (() -> ClipDragRequest?)? = nil

    /// Called on the main actor when a drag actually starts, with the ids being
    /// dragged. `ClipList` uses it to put the multi-selection back after the
    /// mouse-down collapsed it.
    var onDragBegan: (([UUID]) -> Void)? = nil

    /// Called on right mouse-down, *before* the event travels on to the
    /// SwiftUI `.contextMenu` below. `ClipList` uses it to select the
    /// right-clicked row: doing that here instead of inside the menu's
    /// `ViewBuilder` keeps observable state out of the view-update pass
    /// (review 5A-19) while preserving the ordering the menu depends on.
    var onRightMouseDown: (() -> Void)? = nil

    /// Non-nil only in folder scope: accepts dragged clip ids and inserts them
    /// above or below this row. Return `true` if the drop was consumed.
    var onReorderDrop: (([UUID], InsertionEdge) -> Bool)? = nil

    /// Pointer travel, in points, that separates a click from a drag.
    static let dragThreshold: CGFloat = 4

    class ClickView: NSView, NSDraggingSource {
        var onClickWithModifiers: ((NSEvent.ModifierFlags) -> Void)?
        var dragPayload: (() -> ClipDragRequest?)?
        var onDragBegan: (([UUID]) -> Void)?
        var onRightMouseDown: (() -> Void)?
        var onReorderDrop: (([UUID], InsertionEdge) -> Bool)?

        private var mouseDownPoint: CGPoint?
        private var pendingDrag: ClipDragRequest?
        private var isDragging = false

        // MARK: Reorder drop target (5C)

        /// The insertion line, drawn by the overlay itself rather than handed
        /// back to SwiftUI: a `@State` round-trip per `draggingUpdated` would
        /// re-run the row's body on every mouse move across it.
        private let insertionLayer = CALayer()
        private var registeredForClips = false
        private var insertionEdge: InsertionEdge? {
            didSet {
                guard insertionEdge != oldValue else { return }
                insertionLayer.isHidden = insertionEdge == nil
                needsLayout = true
            }
        }

        override func layout() {
            super.layout()
            guard let edge = insertionEdge else { return }
            let height: CGFloat = 2
            let atTop = (edge == .above) != isFlipped
            insertionLayer.frame = CGRect(
                x: 0,
                y: atTop ? bounds.maxY - height : 0,
                width: bounds.width,
                height: height
            )
        }

        /// Registers (or unregisters) for dragged clip ids to match whether a
        /// reorder handler is currently installed. Idempotent.
        func refreshDropRegistration() {
            let wanted = onReorderDrop != nil
            guard wanted != registeredForClips else { return }
            registeredForClips = wanted
            if wanted {
                registerForDraggedTypes([ClipDragPayload.clipsType])
                if insertionLayer.superlayer == nil {
                    insertionLayer.backgroundColor = NSColor.controlAccentColor.cgColor
                    insertionLayer.cornerRadius = 1
                    insertionLayer.isHidden = true
                    layer?.addSublayer(insertionLayer)
                }
            } else {
                unregisterDraggedTypes()
                insertionEdge = nil
            }
        }

        /// Which half of the row the pointer is in. Reads `isFlipped` instead
        /// of assuming it: this view never sets it, but it is hosted inside
        /// SwiftUI and the answer must not depend on that.
        private func edge(for info: NSDraggingInfo) -> InsertionEdge? {
            guard onReorderDrop != nil,
                  !ClipDragPayload.ids(from: info.draggingPasteboard).isEmpty else { return nil }
            let point = convert(info.draggingLocation, from: nil)
            let inTopHalf = isFlipped ? (point.y < bounds.midY) : (point.y > bounds.midY)
            return inTopHalf ? .above : .below
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            insertionEdge = edge(for: sender)
            return insertionEdge == nil ? [] : .move
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            insertionEdge = edge(for: sender)
            return insertionEdge == nil ? [] : .move
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            insertionEdge = nil
        }

        override func draggingEnded(_ sender: NSDraggingInfo) {
            insertionEdge = nil
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            edge(for: sender) != nil
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            defer { insertionEdge = nil }
            guard let edge = edge(for: sender), let handler = onReorderDrop else { return false }
            let ids = ClipDragPayload.ids(from: sender.draggingPasteboard)
            guard !ids.isEmpty else { return false }
            return handler(ids, edge)
        }

        override func mouseDown(with event: NSEvent) {
            mouseDownPoint = convert(event.locationInWindow, from: nil)
            isDragging = false
            // Snapshot the payload *before* the click mutates the selection, so
            // pressing on a row that is part of a multi-selection still drags
            // the whole selection even though the press collapses it.
            pendingDrag = dragPayload?()
            onClickWithModifiers?(event.modifierFlags)
        }

        /// Right-click: select the row first, then let the event continue up
        /// the responder chain so the SwiftUI `.contextMenu` opens exactly as
        /// it did before (5A-19).
        override func rightMouseDown(with event: NSEvent) {
            onRightMouseDown?()
            super.rightMouseDown(with: event)
        }

        override func mouseDragged(with event: NSEvent) {
            // Anything that is not a drag keeps the pre-3B behaviour of letting
            // the event travel on up the responder chain.
            guard !isDragging,
                  let origin = mouseDownPoint,
                  let request = pendingDrag,
                  !request.ids.isEmpty,
                  window != nil else {
                super.mouseDragged(with: event)
                return
            }

            let point = convert(event.locationInWindow, from: nil)
            guard hypot(point.x - origin.x, point.y - origin.y) > ClickModifierDetector.dragThreshold else {
                super.mouseDragged(with: event)
                return
            }
            isDragging = true

            let image = request.image
            let item = NSDraggingItem(pasteboardWriter: ClipDragPayload.pasteboardItem(ids: request.ids))
            item.setDraggingFrame(
                NSRect(
                    x: point.x - image.size.width / 2,
                    y: point.y - image.size.height / 2,
                    width: image.size.width,
                    height: image.size.height
                ),
                contents: image
            )
            let session = beginDraggingSession(with: [item], event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
            onDragBegan?(request.ids)
        }

        override func mouseUp(with event: NSEvent) {
            mouseDownPoint = nil
            pendingDrag = nil
            // The pre-3B view had no `mouseUp` override, so the event reached
            // the next responder. Keep it that way.
            super.mouseUp(with: event)
        }

        // MARK: NSDraggingSource

        /// In-app only: the payload is a private type, so letting it leave the
        /// app would just produce a rejected drag elsewhere.
        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }

        func draggingSession(
            _ session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            isDragging = false
            mouseDownPoint = nil
            pendingDrag = nil
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = ClickView()
        view.wantsLayer = true
        view.layer?.backgroundColor = .clear
        view.onClickWithModifiers = onClickWithModifiers
        view.dragPayload = dragPayload
        view.onDragBegan = onDragBegan
        view.onRightMouseDown = onRightMouseDown
        view.onReorderDrop = onReorderDrop
        view.refreshDropRegistration()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let clickView = nsView as? ClickView {
            clickView.onClickWithModifiers = onClickWithModifiers
            clickView.dragPayload = dragPayload
            clickView.onDragBegan = onDragBegan
            clickView.onRightMouseDown = onRightMouseDown
            clickView.onReorderDrop = onReorderDrop
            clickView.refreshDropRegistration()
        }
    }
}

// MARK: - Modifier Flags Extension
extension NSEvent.ModifierFlags {
    var hasCommand: Bool {
        self.contains(.command)
    }

    var hasShift: Bool {
        self.contains(.shift)
    }
}
