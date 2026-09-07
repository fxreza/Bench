import SwiftUI

// =============================================================================
// Klip's own hover tooltips — and why AppKit's are not an option here
// =============================================================================
//
// **The bug.** Every icon button in the history window carried a SwiftUI
// `.help("…")` string. The strings were correct and shortcut-aware, and *not
// one of them ever appeared on screen* — the user's report was blunt: no
// tooltip shows anywhere in the app. The eight preview-pane action icons
// (edit / copy / save image / OCR / pin / favourite / lock / delete) were the
// worst of it: eight unlabelled glyphs in a row with no way to learn what they
// do.
//
// **The cause.** `.help(_:)` compiles down to `NSView.toolTip`, and AppKit's
// tooltip machinery is driven by the tracking/mouse-moved plumbing of a
// *normal* window. The history window is not one. It is a borderless
// `NSPanel` created with `.nonactivatingPanel` at `.floating` level (see
// `Views/History/HistoryWindowController.swift` and
// `Views/History/HistoryPanel.swift`), which never becomes the active
// application's key window in the way the tooltip timer expects, so the timer
// effectively never fires.
//
// **Why we did not "just fix the panel".** The panel's two defining traits —
// non-activating, and click-outside-to-close — are load-bearing for the whole
// product: Klip must overlay whatever app you are pasting into without
// stealing focus from it. Trading that away for tooltips would be trading the
// feature for the garnish.
//
// **So: draw them ourselves.** `.klipHelp("…")` is a drop-in replacement for
// `.help("…")` that renders a Klip-styled card under the pointer.
//
// ⚠️ DO NOT "simplify" this back to `.help(_:)`. It will silently render
// nothing, exactly as before, and the regression is invisible to any test that
// does not involve a human hovering a real floating panel.
//
// -----------------------------------------------------------------------------
// Architecture: one window-level host layer, not a per-call-site `.overlay`
// -----------------------------------------------------------------------------
//
// A plain `.overlay` on each hovered view is the simpler design and it was the
// first thing tried. It does not survive this layout, for three separate
// reasons:
//
//  1. **Clipping.** `ClipRow`'s state badges live inside `ClipList`'s
//     `ScrollView`, which clips its content. A tooltip hanging below the last
//     visible row would be cut off mid-card.
//  2. **Z-order.** `HistoryContentView`'s root is an `HStack` of sidebar |
//     middle column | preview pane. Siblings paint in order, so a tooltip
//     overlaid on a *sidebar* button ("Create a folder") would be painted
//     *under* the middle column the moment it extended past the sidebar's
//     120-320pt width. Same for the action-bar legend's tooltip crossing into
//     the preview pane.
//  3. **Narrow panes.** The preview pane is 200-440pt wide and its eight
//     action icons sit in a row at its top-right — the very place a
//     centred-under-the-icon card needs to slide sideways to stay on screen,
//     which it can only do if it can measure the *window*, not the pane.
//
// So `.klipHelp` publishes (text, bounds-anchor) through a `PreferenceKey`,
// and `HistoryContentView` hosts a single `KlipTooltipHost` layer in its root
// that resolves the anchor into window coordinates and draws one card. That
// layer sits *inside* the root `.clipShape(RoundedRectangle(...))`, which is
// deliberate: tooltips stay within the rounded window, they never spill onto
// the desktop.

// MARK: - Public API

extension View {
    /// Klip's replacement for SwiftUI's `.help(_:)`.
    ///
    /// Shows a Klip-styled tooltip card the moment the pointer lands on the
    /// control, positioned by the window-level `KlipTooltipHost` layer. The
    /// card is purely decorative — it never takes hit tests — so it can
    /// neither eat a click nor break the hover that summons it.
    ///
    /// Also keeps the real `.help(_:)` underneath. That is not redundancy for
    /// its own sake: `.help` is what populates the view's accessibility help
    /// string, and VoiceOver users depend on it. It costs nothing visually
    /// because, per the note at the top of this file, AppKit never draws it in
    /// this panel — and in the one place it *would* draw (a normal window),
    /// having the system tooltip is the right outcome anyway.
    func klipHelp(_ text: String) -> some View {
        modifier(KlipTooltipModifier(text: text))
    }

    /// Installs the single window-level tooltip layer. Apply once, at the root
    /// of a window that contains `.klipHelp` call sites.
    ///
    /// Without it `.klipHelp` degrades to plain `.help` — no crash, no visual
    /// tooltip. That is the intended behaviour for views such as `TagChip`
    /// that are also used outside the history panel.
    func klipTooltipHost() -> some View {
        modifier(KlipTooltipHost())
    }
}

// MARK: - Hover tracking

// No delay: the card appears on the same event that reports the hover.
//
// It used to wait ~500ms, copying AppKit's initial tooltip delay. That delay
// exists to stop system tooltips firing while the pointer merely crosses a
// toolbar — but Klip's icons are the *only* label those controls have. Eight
// unlabelled glyphs in the preview pane's action row, three more in the action
// bar, and the answer to "what is this one?" arrived half a second after you
// had already moved on. Showing at once costs nothing here: the card is inert,
// it is drawn inside the window, and it disappears the instant the pointer
// leaves.

private struct KlipTooltipModifier: ViewModifier {
    let text: String

    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            // Accessibility: see the doc comment on `klipHelp`.
            .help(text)
            // Set straight from the hover event rather than through a `Task`:
            // even a zero-length sleep is a run-loop hop, which is visible as
            // a flicker when the pointer sweeps along a row of icons.
            .onHover { hovering in
                isVisible = hovering
            }
            .onDisappear {
                // A row scrolled out of the LazyVStack (or a button whose
                // condition flipped) must not leave a tooltip stranded.
                isVisible = false
            }
            .anchorPreference(key: KlipTooltipKey.self, value: .bounds) { anchor in
                isVisible ? [KlipTooltipRequest(text: text, anchor: anchor)] : []
            }
    }
}

// MARK: - Preference plumbing

private struct KlipTooltipRequest: Equatable {
    let text: String
    let anchor: Anchor<CGRect>
}

/// `nonisolated` is required, not stylistic: the build passes
/// `-default-isolation MainActor` (see `scripts/build_local.sh`), which would
/// otherwise infer `@MainActor` for these static members and leave them unable
/// to satisfy `PreferenceKey`'s nonisolated requirements. Same pattern as the
/// worked example in `Views/History/ImageDimensions.swift`.
private struct KlipTooltipKey: PreferenceKey {
    nonisolated static let defaultValue: [KlipTooltipRequest] = []

    nonisolated static func reduce(value: inout [KlipTooltipRequest],
                                   nextValue: () -> [KlipTooltipRequest]) {
        value.append(contentsOf: nextValue())
    }
}

/// Reports the rendered card's size back up so the positioner can flip and
/// clamp it. Measuring rather than guessing matters because tooltip strings
/// here interpolate live shortcut glyphs (`ShortcutManager.displayString`), so
/// their width is not knowable ahead of time.
private struct KlipTooltipSizeKey: PreferenceKey {
    nonisolated static let defaultValue: CGSize = .zero

    nonisolated static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

// MARK: - Host layer

private struct KlipTooltipHost: ViewModifier {
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(KlipTooltipKey.self) { requests in
            GeometryReader { window in
                // `.last` rather than `.first`: if the pointer crosses two
                // controls fast enough that both delays fire, the most
                // recently laid-out one wins and only ever one card is drawn.
                if let request = requests.last {
                    KlipTooltipPositioner(request: request, window: window)
                }
            }
            // The whole layer is inert. A tooltip that could take a hit test
            // would cover the very control being hovered, cancel the hover
            // that produced it, and flicker forever.
            .allowsHitTesting(false)
        }
    }
}

private struct KlipTooltipPositioner: View {
    let request: KlipTooltipRequest
    let window: GeometryProxy

    /// Measured on the first layout pass. Until it lands the card is drawn at
    /// zero opacity, so nobody sees the unpositioned frame — one frame, at the
    /// point the pointer arrives.
    @State private var size: CGSize = .zero

    /// Keeps the card off the window's rounded corners and hairline border.
    private let margin: CGFloat = 6
    /// Gap between the hovered control and the card.
    private let gap: CGFloat = 6

    var body: some View {
        let target = window[request.anchor]
        let bounds = window.size

        KlipTooltipCard(text: request.text)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: KlipTooltipSizeKey.self, value: proxy.size)
                }
            )
            .onPreferenceChange(KlipTooltipSizeKey.self) { size = $0 }
            .offset(x: originX(target: target, bounds: bounds),
                    y: originY(target: target, bounds: bounds))
            .opacity(size == .zero ? 0 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Centred under the control, then clamped so a card on a 200pt-wide
    /// preview pane's right-hand icon row does not run off the window edge.
    private func originX(target: CGRect, bounds: CGSize) -> CGFloat {
        let ideal = target.midX - size.width / 2
        let maxX = max(margin, bounds.width - size.width - margin)
        return min(max(ideal, margin), maxX)
    }

    /// Below by default (macOS convention), flipped above when the card would
    /// otherwise cross the bottom of the window — which is exactly where the
    /// action bar's own toggles live.
    private func originY(target: CGRect, bounds: CGSize) -> CGFloat {
        let below = target.maxY + gap
        let above = target.minY - gap - size.height
        let fitsBelow = below + size.height <= bounds.height - margin
        let candidate = (fitsBelow || above < margin) ? below : above
        let maxY = max(margin, bounds.height - size.height - margin)
        return min(max(candidate, margin), maxY)
    }
}

// MARK: - The card

private struct KlipTooltipCard: View {
    let text: String

    /// Deliberately narrower than the 200pt minimum preview width so a long
    /// string truncates instead of spanning the whole window. All 15 current
    /// call sites are well under this.
    private let maxWidth: CGFloat = 240

    var body: some View {
        Text(text)
            .font(.klip(.caption))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Theme.badgeCornerRadius)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.badgeCornerRadius)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
            .shadow(color: Theme.promptShadow, radius: 6, y: 2)
            // `maxWidth` then `fixedSize` (in that order) gives
            // `min(idealWidth, maxWidth)`: short strings such as "Pinned" stay
            // short instead of every tooltip rendering at a uniform 240pt.
            .frame(maxWidth: maxWidth, alignment: .leading)
            .fixedSize()
    }
}
