import CoreGraphics

/// Every placement Snap can give a window, and the arithmetic that turns one
/// into a rectangle. Pure: no AppKit, no Accessibility, no screens - just
/// `CGRect` in, `CGRect` out, which is what `SnapTests` exercises.
///
/// ## Coordinate space
///
/// `frame(in:gap:currentSize:)` works entirely in **Cocoa coordinates**:
/// bottom-left origin, y growing upwards, the space `NSScreen.visibleFrame`
/// is expressed in. "Top half" therefore sits at the *high* y end of the
/// visible frame. `WindowController` converts the result into the
/// top-left-origin space Accessibility wants, once, at the moment it writes
/// `kAXPositionAttribute`; see `SnapGeometry`.
///
/// ## The gap
///
/// `gap` (setting `snap.gap`, default 0) is the margin left between a window
/// and the screen edges *and* between two windows that sit side by side. So
/// the usable area is the visible frame inset by `gap` on all four sides, and
/// a half is `(content.width - gap) / 2` wide, not `content.width / 2`: the
/// gap between the two halves is subtracted once and shared.
enum SnapLayout: String, CaseIterable, Sendable {
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case leftThird
    case middleThird
    case rightThird
    case leftTwoThirds
    case centerTwoThirds
    case rightTwoThirds
    case maximize
    case center

    /// Menu and Settings title, matching the BetterTouchTool trigger names
    /// this module replaces.
    var title: String {
        switch self {
        case .leftHalf: return "Left Half"
        case .rightHalf: return "Right Half"
        case .topHalf: return "Top Half"
        case .bottomHalf: return "Bottom Half"
        case .topLeft: return "Top Left Quarter"
        case .topRight: return "Top Right Quarter"
        case .bottomLeft: return "Bottom Left Quarter"
        case .bottomRight: return "Bottom Right Quarter"
        case .leftThird: return "Left Third"
        case .middleThird: return "Middle Third"
        case .rightThird: return "Right Third"
        case .leftTwoThirds: return "Left Two Thirds"
        case .centerTwoThirds: return "Center Two Thirds"
        case .rightTwoThirds: return "Right Two Thirds"
        case .maximize: return "Maximize"
        case .center: return "Center"
        }
    }

    /// The hotkey action id this layout is bound to, `"snap.<case>"`.
    var actionID: String { "snap.\(rawValue)" }

    /// Whether the placement needs the window's present size. Only `.center`
    /// does; everything else is decided by the screen alone.
    var usesCurrentSize: Bool { self == .center }

    /// The rectangle this layout wants inside `visible` (a screen's visible
    /// frame, Cocoa coordinates).
    ///
    /// - Parameters:
    ///   - visible: the target screen's visible frame - the full frame minus
    ///     the menu bar and the Dock.
    ///   - gap: margin at the screen edges and between neighbouring windows.
    ///   - currentSize: the window's size right now. Only `.center` reads it;
    ///     a size larger than the content area is clamped to it, so centring
    ///     an oversized window also brings it fully on screen.
    func frame(in visible: CGRect, gap: CGFloat = 0, currentSize: CGSize = .zero) -> CGRect {
        let g = max(0, gap)
        let content = visible.insetBy(dx: g, dy: g)
        // A gap wider than the screen would produce a negative rectangle;
        // fall back to the whole visible frame rather than sending a window
        // to nowhere.
        guard content.width > 0, content.height > 0 else { return visible }

        let halfW = (content.width - g) / 2
        let halfH = (content.height - g) / 2
        let thirdW = (content.width - 2 * g) / 3
        let twoThirdsW = 2 * thirdW + g

        let left = content.minX
        let right = content.maxX - halfW
        let bottom = content.minY
        let top = content.maxY - halfH

        switch self {
        case .leftHalf:
            return CGRect(x: left, y: content.minY, width: halfW, height: content.height)
        case .rightHalf:
            return CGRect(x: right, y: content.minY, width: halfW, height: content.height)
        case .topHalf:
            return CGRect(x: content.minX, y: top, width: content.width, height: halfH)
        case .bottomHalf:
            return CGRect(x: content.minX, y: bottom, width: content.width, height: halfH)
        case .topLeft:
            return CGRect(x: left, y: top, width: halfW, height: halfH)
        case .topRight:
            return CGRect(x: right, y: top, width: halfW, height: halfH)
        case .bottomLeft:
            return CGRect(x: left, y: bottom, width: halfW, height: halfH)
        case .bottomRight:
            return CGRect(x: right, y: bottom, width: halfW, height: halfH)
        case .leftThird:
            return CGRect(x: content.minX, y: content.minY, width: thirdW, height: content.height)
        case .middleThird:
            return CGRect(x: content.minX + thirdW + g, y: content.minY, width: thirdW, height: content.height)
        case .rightThird:
            return CGRect(x: content.maxX - thirdW, y: content.minY, width: thirdW, height: content.height)
        case .leftTwoThirds:
            return CGRect(x: content.minX, y: content.minY, width: twoThirdsW, height: content.height)
        case .centerTwoThirds:
            // BTT ran "Left Two Thirds" and then "Center Window": a
            // two-thirds-wide, full-height window centred horizontally.
            return CGRect(x: content.midX - twoThirdsW / 2, y: content.minY, width: twoThirdsW, height: content.height)
        case .rightTwoThirds:
            return CGRect(x: content.maxX - twoThirdsW, y: content.minY, width: twoThirdsW, height: content.height)
        case .maximize:
            return content
        case .center:
            return centered(currentSize, in: content)
        }
    }

    /// Keeps `size`, centres it in `content`, and clamps a window bigger than
    /// the screen down to the content area. A zero or negative size (a window
    /// that refused to report one) falls back to filling `content`.
    private func centered(_ size: CGSize, in content: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return content }
        let w = min(size.width, content.width)
        let h = min(size.height, content.height)
        return CGRect(x: content.midX - w / 2, y: content.midY - h / 2, width: w, height: h)
    }
}

extension CGRect {
    /// Integral origin and size. Windows land on whole points; asking an app
    /// for 333.333 wide only invites its own rounding to disagree with the
    /// neighbour's.
    var snapRounded: CGRect {
        CGRect(
            x: origin.x.rounded(), y: origin.y.rounded(),
            width: size.width.rounded(), height: size.height.rounded())
    }
}
