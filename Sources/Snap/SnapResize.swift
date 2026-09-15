import CoreGraphics

/// The placements that depend on the window's present frame rather than on
/// the screen alone: Raycast's "Make Larger", "Make Smaller" and "Almost
/// Maximize". Pure, like `SnapLayout`: `CGRect` in, `CGRect` out, Cocoa
/// coordinates throughout, and the gap is honoured the same way (the usable
/// area is the visible frame inset by `gap` on every side).
enum SnapResize {
    /// Floor on "Make Smaller". The app's own minimum wins whenever it is
    /// larger; this only keeps a window from being stepped down to nothing
    /// when the app declares no minimum at all.
    static let minimumSize = CGSize(width: 100, height: 100)

    /// Grows (`delta` > 0) or shrinks (`delta` < 0) the window by `delta`
    /// points in each dimension, keeping its centre where it is, the way
    /// Raycast's Make Larger / Make Smaller do.
    ///
    /// The result never leaves the usable area: a window that would grow
    /// past an edge is pushed back inside, and one that would grow bigger
    /// than the area is capped to it. So repeated presses of Make Larger end
    /// at a maximized window, and repeated Make Smaller at `minimum`.
    static func stepped(
        _ frame: CGRect, by delta: CGFloat, in visible: CGRect, gap: CGFloat = 0,
        minimum: CGSize = minimumSize
    ) -> CGRect {
        let g = max(0, gap)
        let content = visible.insetBy(dx: g, dy: g)
        guard content.width > 0, content.height > 0 else { return frame }

        let width = min(max(frame.width + delta, minimum.width), content.width)
        let height = min(max(frame.height + delta, minimum.height), content.height)
        let x = min(max(frame.midX - width / 2, content.minX), content.maxX - width)
        let y = min(max(frame.midY - height / 2, content.minY), content.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Raycast's Almost Maximize: `fraction` of the usable area's width and
    /// height, centred, so a margin of desktop stays visible all around.
    /// A fraction of 1 is a plain maximize; anything below 0.1 is treated as
    /// 0.1 so the window cannot vanish.
    static func almostMaximized(in visible: CGRect, gap: CGFloat = 0, fraction: CGFloat) -> CGRect {
        let g = max(0, gap)
        let content = visible.insetBy(dx: g, dy: g)
        guard content.width > 0, content.height > 0 else { return visible }

        let f = min(max(fraction, 0.1), 1)
        let width = content.width * f
        let height = content.height * f
        return CGRect(x: content.midX - width / 2, y: content.midY - height / 2, width: width, height: height)
    }
}
