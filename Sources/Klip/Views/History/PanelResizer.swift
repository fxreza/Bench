// Adapted from Clipfield (MIT, Copyright 2026 Alex Jolley) — UI/Overlay/PanelResizer.swift

import SwiftUI
import AppKit

/// A thin draggable divider that resizes an adjacent fixed-width panel.
///
/// `side: .leading` means the panel being resized is to the divider's left
/// (the sidebar — dragging right widens it). `.trailing` means the panel is to
/// the right (the preview — dragging left widens it).
struct PanelResizer: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    var side: HorizontalEdge = .leading

    @State private var startWidth: Double?

    /// Which end of the 12pt strip the hairline is drawn at: the end touching
    /// the panel this divider resizes.
    ///
    /// It used to be centred, which put the line 6pt *outside* the panel it
    /// delimits — so every panel looked like it had 6pt more padding on its
    /// divider side than on its window side. The sidebar's rows sit 18pt from
    /// its own left edge and 18pt from its own right edge, but read as 18 and
    /// 24; the preview's image is centred to within half a point inside its
    /// pane, and read as off-centre by six. The content was never wrong — the
    /// line marking the boundary was in the wrong place.
    private var lineAlignment: Alignment {
        // `.leading` = the panel is to the left, so its edge is this strip's
        // leading edge; `.trailing` = the panel is to the right.
        side == .leading ? .leading : .trailing
    }

    var body: some View {
        Color.clear
            // Hit area is wider than the visible hairline: 12pt to grab, 1pt
            // to see.
            .frame(width: 12)
            .frame(maxHeight: .infinity)
            .overlay(alignment: lineAlignment) {
                Rectangle()
                    .fill(Theme.separator)
                    .frame(width: 1)
            }
            .contentShape(Rectangle())
            .onHover { inside in
                // Was `NSCursor.resizeLeftRight.push()` / `.pop()`. push/pop
                // maintains a stack, and SwiftUI can fire a spurious
                // `onHover(false)` during a view update with no matching
                // `true` before it (measured happening a lot over the image
                // preview, whose body re-lays-out on nearly every frame while
                // an image clip is selected). Each stray `false` popped the
                // stack without a matching push, so the resize cursor
                // silently stopped being applied over this divider — it
                // looked like the strip couldn't be grabbed, when actually
                // the geometry was fine and only the cursor feedback was
                // gone. `.set()` has no stack to unbalance: every call is
                // independent, so extra or out-of-order callbacks are
                // harmless.
                if inside {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = startWidth ?? width
                        if startWidth == nil { startWidth = width }
                        let translation = Double(value.translation.width)
                        let delta = side == .leading ? translation : -translation
                        // `translation` is continuous, so without `.rounded()`
                        // the pane lands on a fractional point boundary on every
                        // gesture event (574.4786993982766, not 574). Whole
                        // points are what AppKit hands SwiftUI during an edge
                        // resize, so this just makes the divider behave the same
                        // way.
                        //
                        // NOTE: this was first written to fix the ghosting/
                        // flicker seen while dragging a divider. It does not —
                        // that bug survives whole-point widths and is still
                        // open. Kept because whole points are correct anyway and
                        // because of the write reduction below; do not cite it
                        // as the flicker fix.
                        //
                        // It also cuts persistence churn by ~two orders of
                        // magnitude: `SettingsManager.sidebarWidth`/`previewWidth`
                        // write to UserDefaults from `didSet`, which used to fire
                        // on every event of every drag and now fires only when a
                        // whole point is crossed.
                        width = min(max(start + delta, range.lowerBound), range.upperBound)
                            .rounded()
                    }
                    .onEnded { _ in startWidth = nil }
            )
    }
}

/// How narrow the side panels are allowed to get.
///
/// These used to be literals — 120 for the sidebar, 200 for the preview — and
/// both were narrower than the content they hold. Dragged to the minimum, the
/// sidebar truncated "Favorites" to "Favor…" and wrapped "New Folder" onto two
/// lines, and the preview clipped its own header off both edges. A panel you
/// can shrink past its own contents is a panel with a broken setting in it, so
/// the floor is now measured from what each panel actually has to draw.
///
/// Both scale with the matching font-size setting, because the text they are
/// sized around does.
enum PaneMetrics {
    /// The width an SF Symbol actually renders at.
    ///
    /// Asked of the symbol itself rather than estimated from the point size.
    /// A flat multiplier has to be generous enough for the widest glyph in the
    /// set, which then pads every panel sized from it with slack that is
    /// invisible in the code and obvious on screen — the preview pane's floor
    /// came out about 12pt wider than the icons it was sized around. Falls
    /// back to an estimate only if the symbol is unavailable.
    private static func symbolWidth(_ name: String, size: CGFloat) -> CGFloat {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return size * 1.2 }
        return image.size.width
    }

    /// Widest of a set of symbols at `size` — for rows where which glyph is
    /// drawn depends on state (pinned or not, locked or not).
    private static func symbolWidth(_ names: [String], size: CGFloat) -> CGFloat {
        names.map { symbolWidth($0, size: size) }.max() ?? size * 1.2
    }

    private static func textWidth(_ text: String, size: CGFloat) -> CGFloat {
        (text as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: size)])
            .width
            .rounded(.up)
    }

    /// Fits the sidebar's own fixed rows: the widest label with its icon, its
    /// count badge and every scrap of padding around it. Folder names are not
    /// included — a folder called something enormous truncates, which is
    /// normal and is not a reason to force the whole panel wider.
    static func sidebarMinimum(listFontScale: Double) -> Double {
        let size = KlipFontRole.sidebar.baseSize * listFontScale
        // The icon sits in a fixed 16pt-wide slot (`Sidebar.row`), scaled.
        let iconSlot = CGFloat.klipScaled(16)
        // Row: 8pt outer + 10pt inner padding each side, icon slot, 9pt gap,
        // label, 4pt minimum gap, then a three-digit count.
        let row = 36 + iconSlot + 9 + textWidth("Favorites", size: size) + 4
            + textWidth("999", size: KlipFontRole.caption.baseSize * listFontScale)
        // "New Folder": 18pt padding each side, icon, 7pt gap, label.
        let newFolder = 36 + symbolWidth("plus.circle.fill", size: size) + 7
            + textWidth("New Folder", size: size)
        return Double(max(row, newFolder).rounded(.up))
    }

    /// Fits the preview pane's header action row, which is the widest thing in
    /// it that cannot wrap: nine icons, eight gaps, and 16pt of padding each
    /// side. `PreviewPane.header` already drops the icons onto their own line
    /// when the title will not fit beside them, so the title is not part of
    /// this — but the icon row itself has nowhere left to go.
    static func previewMinimum(previewFontScale: Double) -> Double {
        let size = 13 * previewFontScale
        // `PreviewPane.historyActionIcons`, in order — and it has to stay in
        // step with it: an icon added there and not here leaves the floor a
        // glyph too narrow, and the pane clips its own header and info values
        // off the right edge at the minimum. Where the glyph depends on state,
        // both are measured and the wider one wins, so the floor does not move
        // when a clip is pinned or locked.
        let icons: [[String]] = [
            ["square.and.pencil"],
            ["doc.on.doc"],
            ["arrow.down.to.line"],
            ["qrcode"],
            ["text.viewfinder", "ellipsis.circle"],
            ["pin", "pin.fill"],
            ["star", "star.fill"],
            ["lock.open", "lock.fill"],
            ["trash"],
        ]
        let glyphs = icons.reduce(CGFloat.zero) { $0 + symbolWidth($1, size: size) }
        let gaps = 12 * CGFloat(icons.count - 1)
        return Double((32 + glyphs + gaps).rounded(.up))
    }

    static func sidebarRange(listFontScale: Double) -> ClosedRange<Double> {
        let low = sidebarMinimum(listFontScale: listFontScale)
        return low...max(low, 320)
    }

    static func previewRange(previewFontScale: Double) -> ClosedRange<Double> {
        let low = previewMinimum(previewFontScale: previewFontScale)
        return low...max(low, 440)
    }
}
