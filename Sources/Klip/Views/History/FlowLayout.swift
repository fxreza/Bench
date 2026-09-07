import SwiftUI

/// Left-to-right layout that wraps onto a new line when the next subview no
/// longer fits, like text does.
///
/// Written for the preview pane's tag strip, which used to be a horizontal
/// `ScrollView`. That put everything after the first line's worth of chips
/// out of reach: a couple of long tag names pushed each chip's ✕ and the
/// "Add tag" button off the right edge, so a tag could neither be removed nor
/// added without widening the whole window. Wrapping keeps every control on
/// screen at any pane width.
///
/// A subview wider than the container is re-proposed at exactly the container
/// width rather than being allowed to overhang — that is what keeps the ✕ at
/// the end of a very long tag inside the pane. The subview has to be willing
/// to shrink for that to bite (see `TagChip`'s `flexible` flag); one that
/// insists on its ideal size still overhangs, exactly as it would in an HStack.
struct FlowLayout: Layout {
    /// Horizontal gap between subviews on the same line.
    var spacing: CGFloat = 4
    /// Vertical gap between lines.
    var lineSpacing: CGFloat = 4

    /// One placed subview: which subview it is, and the size it will be
    /// placed at (its ideal size, or the container width when that was wider).
    struct Element: Equatable {
        let index: Int
        let size: CGSize
    }

    /// One line of the wrap.
    struct Row: Equatable {
        var elements: [Element] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let limit = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, maxWidth: limit)
        guard !rows.isEmpty else { return .zero }
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height }
            + lineSpacing * CGFloat(rows.count - 1)
        return CGSize(width: limit.isFinite ? min(width, limit) : width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for element in row.elements {
                subviews[element.index].place(
                    // Centre each subview on its line, so a taller one (the
                    // add-tag field) does not drag the chips beside it up.
                    at: CGPoint(x: x, y: y + (row.height - element.size.height) / 2),
                    proposal: ProposedViewSize(element.size)
                )
                x += element.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    /// Measures each subview, clamping any that is wider than the container,
    /// then hands the sizes to `pack`.
    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        let sizes: [CGSize] = subviews.indices.map { index in
            let ideal = subviews[index].sizeThatFits(.unspecified)
            guard maxWidth.isFinite, ideal.width > maxWidth else { return ideal }
            // Too wide for the container even on a line of its own: ask it
            // again at exactly the container width. A flexible subview
            // truncates and fits; a rigid one comes back the same size and is
            // clamped so the rest of the row still lands correctly.
            var clamped = subviews[index].sizeThatFits(
                ProposedViewSize(width: maxWidth, height: nil)
            )
            clamped.width = min(clamped.width, maxWidth)
            return clamped
        }
        return Self.pack(sizes, maxWidth: maxWidth, spacing: spacing)
    }

    /// Greedily wraps `sizes` into lines no wider than `maxWidth`, in order.
    ///
    /// Split out of `arrange` as a plain function over sizes so it is testable
    /// without a live view hierarchy — `Layout.Subviews` cannot be constructed
    /// outside a render pass. Same split, and the same reason, as
    /// `LegendRowPacking.packRows`.
    ///
    /// Nothing is ever dropped: unlike the legend, which truncates its lowest
    /// priority entries when out of room, every tag chip has to stay reachable,
    /// so this wraps as far as it needs to.
    static func pack(_ sizes: [CGSize], maxWidth: CGFloat, spacing: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for (index, size) in sizes.enumerated() {
            let needsBreak = !current.elements.isEmpty
                && maxWidth.isFinite
                && current.width + spacing + size.width > maxWidth
            if needsBreak {
                rows.append(current)
                current = Row()
            }

            current.width += current.elements.isEmpty ? size.width : spacing + size.width
            current.height = max(current.height, size.height)
            current.elements.append(Element(index: index, size: size))
        }

        if !current.elements.isEmpty { rows.append(current) }
        return rows
    }
}
