import AppKit

/// Where the physical notch is on a screen, in that screen's coordinate space
/// (AppKit, origin bottom-left) and as a top-left-origin rect for drawing.
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    /// Physical notch, AppKit coordinates (bottom-left origin).
    var notchRect: CGRect
    var hasPhysicalNotch: Bool

    var notchWidth: CGFloat { notchRect.width }
    var notchHeight: CGFloat { notchRect.height }
    /// Horizontal center of the notch in screen coordinates.
    var centerX: CGFloat { notchRect.midX }

    /// Never hardcode: 220x38 at "More Space", 185x32 at default scaling on
    /// the same MacBook Pro. Falls back to a pseudo-notch on external displays.
    static func forScreen(_ screen: NSScreen) -> NotchGeometry {
        let frame = screen.frame
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           screen.safeAreaInsets.top > 0 {
            let rect = CGRect(x: left.maxX, y: left.minY, width: right.minX - left.maxX, height: left.height)
            return NotchGeometry(screenFrame: frame, notchRect: rect, hasPhysicalNotch: true)
        }
        // No notch: draw a 190 x 32 island centered at the top of the screen
        // (menu bar is 24-25 pt there; the island hangs below it).
        let height: CGFloat = 32
        let width: CGFloat = 190
        let rect = CGRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height)
        return NotchGeometry(screenFrame: frame, notchRect: rect, hasPhysicalNotch: false)
    }

    /// Prefer the built-in display with a notch, else the main screen.
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }
}
