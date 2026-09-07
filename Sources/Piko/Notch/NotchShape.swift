import SwiftUI

/// The notch silhouette: a straight top edge that starts `topRadius` outside
/// the body on each side, two *concave* corners that flare up into the menu
/// bar, vertical sides, and two convex bottom corners of `bottomRadius`.
///
/// The rect handed to `path(in:)` therefore includes the flares: its width is
/// the body width plus `topRadius` on each side (see
/// `NotchShape.flaredWidth(body:topRadius:)`). Both radii are animatable, so
/// the shape morphs between states instead of cross-fading.
///
/// Measured against `docs/research/alcove-measurements.md`: with body 220 and
/// `topRadius` 3.5 the left edge runs 915 / 916.5 / 917.5 / 918 over the first
/// rows (doc: 915 / 916.5 / 917.5 / 918), and with body 380 / `topRadius` 18
/// it runs 820 / 831 / 835 / 838 (doc: 820 / 831 / 834.5 / 838).
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    init(topRadius: CGFloat, bottomRadius: CGFloat) {
        self.topRadius = topRadius
        self.bottomRadius = bottomRadius
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        Self.path(in: rect, topRadius: topRadius, bottomRadius: bottomRadius)
    }

    /// Total width of the drawn shape for a body of `body` points: the flares
    /// live outside the body on both sides.
    static func flaredWidth(body: CGFloat, topRadius: CGFloat) -> CGFloat {
        body + topRadius * 2
    }

    /// Shared with the AppKit hit-testing layer, which needs the same outline
    /// without going through SwiftUI.
    static func path(in rect: CGRect, topRadius: CGFloat, bottomRadius: CGFloat) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0 else { return path }

        // Clamp so the four corners can never overlap each other.
        let top = min(max(topRadius, 0), rect.width / 4, rect.height / 2)
        let bottom = min(max(bottomRadius, 0), rect.height, max(0, rect.width / 2 - top))

        // Body edges: the flares sit between rect.minX..left and right..rect.maxX.
        let left = rect.minX + top
        let right = rect.maxX - top

        // Each corner is a true quarter-circle inscribed between the two edges
        // it joins; for the top corners the circle sits *outside* the body,
        // which is what makes them concave.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: left, y: rect.minY),
                    tangent2End: CGPoint(x: left, y: rect.maxY),
                    radius: top)
        path.addArc(tangent1End: CGPoint(x: left, y: rect.maxY),
                    tangent2End: CGPoint(x: right, y: rect.maxY),
                    radius: bottom)
        path.addArc(tangent1End: CGPoint(x: right, y: rect.maxY),
                    tangent2End: CGPoint(x: right, y: rect.minY),
                    radius: bottom)
        path.addArc(tangent1End: CGPoint(x: right, y: rect.minY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.minY),
                    radius: top)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
