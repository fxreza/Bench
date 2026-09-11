import SwiftUI

/// Lets the borderless history panel be dragged around by any part of it
/// that nothing else claims: the title, the gaps around the search field
/// and filter chips, the action bar, the preview header.
///
/// `isMovableByWindowBackground` is not used on purpose: it would compete
/// with the clip rows' drag-and-drop and the sidebar/preview resizers.
/// SwiftUI's `WindowDragGesture` (macOS 15) is a plain gesture on the panel
/// root, so any child gesture, scroll view or AppKit-backed control wins over
/// it. Where the window ends up is `HistoryWindowController`'s business
/// (`windowDidMove`). On macOS 14 the window simply stays put.
struct WindowDragModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.gesture(WindowDragGesture())
        } else {
            content
        }
    }
}
