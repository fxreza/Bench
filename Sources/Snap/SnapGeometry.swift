import AppKit

/// The one place Snap converts between the two screen coordinate spaces
/// macOS makes it live in.
///
/// ## The two spaces
///
/// - **Cocoa**: `NSScreen.frame` / `visibleFrame`, `NSEvent.mouseLocation`.
///   Origin bottom-left of the **primary** screen (the one with the menu
///   bar), y grows *up*. Every screen's frame is expressed in this one
///   primary-anchored space, so a screen above the primary has positive y and
///   one below has negative y.
/// - **AX / CoreGraphics global**: `kAXPositionAttribute`,
///   `AXUIElementCopyElementAtPosition`, `CGEvent.location`. Origin
///   **top-left** of the primary screen, y grows *down*.
///
/// The conversion is a reflection about the primary screen's height, so the
/// same formula converts in both directions and applying it twice is the
/// identity - which is exactly what the tests check. Flip against the
/// *primary* screen's height, never against the screen the window happens to
/// be on: a secondary screen's frame is already stated in the
/// primary-anchored space.
enum SnapGeometry {
    /// `NSScreen.screens.first` is the primary screen (the one whose frame
    /// has origin zero). `maxY` is its height, the mirror line. Zero when
    /// there is no screen at all, in which case nothing can be placed anyway.
    static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    /// Cocoa rect -> AX rect. `y_ax = primaryHeight - y_cocoa_max`, because
    /// the AX origin is the *top* edge of the rectangle.
    static func flipRect(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.maxY,
            width: rect.width,
            height: rect.height)
    }

    /// Cocoa point -> AX point, and back: `y' = primaryHeight - y`.
    static func flipPoint(_ point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// The screen whose frame contains `cocoaRect`'s centre, falling back to
    /// the screen with the largest overlap, then to the main screen. Using
    /// the centre (rather than the origin) keeps a window that hangs over an
    /// edge on the screen it mostly occupies.
    static func screen(for cocoaRect: CGRect, screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        let center = CGPoint(x: cocoaRect.midX, y: cocoaRect.midY)
        if let hit = screens.first(where: { $0.frame.contains(center) }) { return hit }
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for screen in screens {
            let overlap = screen.frame.intersection(cocoaRect)
            guard !overlap.isNull else { continue }
            let area: CGFloat = overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        return best ?? NSScreen.main ?? screens.first
    }
}
