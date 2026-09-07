import CoreGraphics

/// Pure placement math for the capture overlay chrome (size label, tool strip,
/// options row, action strip) around a selection rectangle.
///
/// Everything is in **view coordinates**: `screen` is the overlay view's
/// bounds, y grows downward (flipped view), so `minY` is the top edge.
/// `obstructions` are rects the chrome must not overlap - the notch / safe-area
/// band at the top of the display.
///
/// Rules (in order):
/// * **Label** centred above the selection; if that does not fit (screen edge
///   or an obstruction) it goes below the selection, and the strips are pushed
///   down to make room. If the below stack does not fit either, the label goes
///   inside the selection at the top, and finally inside at the bottom.
/// * **Tool strip** centred under the selection with the **options row**
///   directly under it; if they do not fit below they go above the selection;
///   if neither fits (near full-screen selection) they go inside the selection
///   at the bottom.
/// * **Action strip** to the right of the selection, vertically centred and
///   clamped to the screen; if it does not fit on the right it goes left, and
///   if neither fits it goes inside the selection at the right edge. It is
///   nudged vertically if it would cover the label.
///
/// Every rect is clamped to `screen`.
nonisolated enum SelectionLayout {

    /// Gap between the selection and a piece of chrome.
    static let gap: CGFloat = 8
    /// Gap between the tool strip and the options row.
    static let optionsGap: CGFloat = 6

    struct Placement: Equatable, Sendable {
        var label: CGRect = .zero
        var toolStrip: CGRect = .zero
        var optionsRow: CGRect = .zero
        var actionStrip: CGRect = .zero
    }

    /// Pass `.zero` for a piece of chrome that is hidden; its rect comes back
    /// zero-sized and is ignored by the other rules.
    static func place(screen: CGRect,
                      selection: CGRect,
                      label: CGSize,
                      toolStrip: CGSize,
                      optionsRow: CGSize,
                      actionStrip: CGSize,
                      obstructions: [CGRect] = []) -> Placement {

        let sel = selection.standardized
        let hasOptions = optionsRow.height > 0 && optionsRow.width > 0
        let stripsHeight = toolStrip.height + (hasOptions ? optionsGap + optionsRow.height : 0)
        let stripsWidth = max(toolStrip.width, optionsRow.width)

        // MARK: label candidates
        let labelX = centred(label.width, on: sel.midX, in: screen)
        let labelAbove = CGRect(x: labelX, y: sel.minY - gap - label.height, width: label.width, height: label.height)
        let labelBelow = CGRect(x: labelX, y: sel.maxY + gap, width: label.width, height: label.height)
        let labelInsideTop = CGRect(x: labelX, y: sel.minY + gap, width: label.width, height: label.height)
        let labelInsideBottom = CGRect(x: labelX, y: sel.maxY - gap - label.height, width: label.width, height: label.height)

        let labelAboveFits = label.height <= 0
            || (labelAbove.minY >= screen.minY && !intersects(labelAbove, obstructions))
        let labelFitsInside = label.height + gap * 2 <= sel.height

        // MARK: strips
        // When the label has to sit below the selection the strips start below it.
        let stripsBelowY = labelAboveFits ? sel.maxY + gap : labelBelow.maxY + gap
        let stripsAboveY = sel.minY - gap - stripsHeight
        let stripsAboveRect = CGRect(x: centred(stripsWidth, on: sel.midX, in: screen),
                                     y: stripsAboveY, width: stripsWidth, height: stripsHeight)

        var stripsY: CGFloat
        var labelRect: CGRect

        if stripsHeight <= 0 {
            // No strips at all (region picker with a hidden strip): label only.
            stripsY = sel.maxY + gap
            labelRect = labelAboveFits ? labelAbove
                : (labelBelow.maxY <= screen.maxY ? labelBelow
                   : (labelFitsInside ? labelInsideTop : labelInsideBottom))
        } else if stripsBelowY + stripsHeight <= screen.maxY {
            stripsY = stripsBelowY
            labelRect = labelAboveFits ? labelAbove : labelBelow
        } else if stripsAboveY >= screen.minY && !intersects(stripsAboveRect, obstructions) {
            stripsY = stripsAboveY
            if labelBelow.maxY <= screen.maxY {
                labelRect = labelBelow
            } else if labelFitsInside {
                labelRect = labelInsideTop
            } else {
                labelRect = labelInsideBottom
            }
        } else {
            // Neither side has room: chrome lives inside the selection.
            stripsY = sel.maxY - gap - stripsHeight
            if labelAboveFits {
                labelRect = labelAbove
            } else if labelFitsInside {
                labelRect = labelInsideTop
            } else {
                labelRect = labelInsideBottom
            }
        }

        var p = Placement()
        p.label = clamp(labelRect, to: screen)
        p.toolStrip = clamp(CGRect(x: centred(toolStrip.width, on: sel.midX, in: screen),
                                   y: stripsY, width: toolStrip.width, height: toolStrip.height), to: screen)
        if hasOptions {
            p.optionsRow = clamp(CGRect(x: centred(optionsRow.width, on: sel.midX, in: screen),
                                        y: p.toolStrip.maxY + optionsGap,
                                        width: optionsRow.width, height: optionsRow.height), to: screen)
        } else {
            p.optionsRow = CGRect(x: p.toolStrip.midX, y: p.toolStrip.maxY, width: 0, height: 0)
        }

        // MARK: action strip
        let actionY = min(max(sel.midY - actionStrip.height / 2, screen.minY), max(screen.minY, screen.maxY - actionStrip.height))
        var action: CGRect
        if sel.maxX + gap + actionStrip.width <= screen.maxX {
            action = CGRect(x: sel.maxX + gap, y: actionY, width: actionStrip.width, height: actionStrip.height)
        } else if sel.minX - gap - actionStrip.width >= screen.minX {
            action = CGRect(x: sel.minX - gap - actionStrip.width, y: actionY, width: actionStrip.width, height: actionStrip.height)
        } else {
            action = CGRect(x: sel.maxX - gap - actionStrip.width, y: actionY, width: actionStrip.width, height: actionStrip.height)
        }
        action = clamp(action, to: screen)
        if actionStrip.height > 0, label.height > 0, action.intersects(p.label) {
            var moved = action
            moved.origin.y = p.label.maxY + gap
            if moved.maxY > screen.maxY {
                moved.origin.y = p.label.minY - gap - moved.height
            }
            action = clamp(moved, to: screen)
        }
        p.actionStrip = action
        return p
    }

    // MARK: - helpers

    /// Left edge of a `width`-wide box centred on `x` and kept inside `screen`.
    private static func centred(_ width: CGFloat, on x: CGFloat, in screen: CGRect) -> CGFloat {
        guard width < screen.width else { return screen.minX }
        return min(max(x - width / 2, screen.minX), screen.maxX - width)
    }

    private static func clamp(_ rect: CGRect, to screen: CGRect) -> CGRect {
        var r = rect
        r.origin.x = r.width < screen.width ? min(max(r.origin.x, screen.minX), screen.maxX - r.width) : screen.minX
        r.origin.y = r.height < screen.height ? min(max(r.origin.y, screen.minY), screen.maxY - r.height) : screen.minY
        return r
    }

    private static func intersects(_ rect: CGRect, _ obstructions: [CGRect]) -> Bool {
        obstructions.contains { $0.intersects(rect) }
    }
}
