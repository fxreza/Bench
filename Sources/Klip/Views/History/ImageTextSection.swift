import SwiftUI
import AppKit

/// The text Klip read out of an image, shown under the picture in the preview
/// pane: a hairline, the text (folded, see `FoldedImageText`) and a copy button
/// beside it.
///
/// Shown only when there is text (`ImageTextState.text`); the caller decides
/// that, so this never has an empty or "no text" state of its own.
struct ImageTextSection: View {
    let text: String
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Theme.separator)
                .frame(height: 0.5)

            HStack(alignment: .top, spacing: 8) {
                FoldedImageText(text: text)
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                // The tappable area used to be the glyph's own painted
                // pixels — a ~12 pt target with no padding and no
                // `contentShape`, which is half of why this button "did
                // nothing" (user item 11).
                Button(action: onCopy) {
                    Image(systemName: "doc.on.doc")
                        .font(Theme.icon(12, weight: Theme.iconWeight(enabled: true), preview: true))
                        .foregroundStyle(Theme.iconIdle)
                        .padding(5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .klipHelp("Copy text")
            }
            .padding(.top, 12)
        }
    }
}

/// The text of `ImageTextSection`, folded to `collapsedLineCount` lines with a
/// small "Show all" / "Show less" toggle when there is more.
///
/// Every screenshot now has OCR text, and a screenshot of a page can have a
/// lot of it. Shown in full it pushed Copied / From / Kind and the tags down
/// by a screenful for every image the selection stepped over, hence the fold.
/// The text stays selectable in both states.
///
/// ## Deciding whether the toggle exists, without a layout jump
///
/// Whether a text needs the toggle depends on how many lines it wraps to at
/// the pane's current width, which only layout knows. The obvious way to learn
/// it is to render, measure the text in a `GeometryReader` or preference, and
/// set `@State` from the result. That is one frame too late: the clip would
/// draw once without the toggle and once with it, and the rows below would
/// step down by a toggle's height the moment the measurement landed. The
/// preview pane's own comments (`PreviewPane.imageBody`,
/// `PreviewPane.historyActionIcons`) are about exactly that kind of second,
/// corrective layout pass being what made stepping between clips look like a
/// blink.
///
/// So the decision is made *inside* the single layout pass, by `ViewThatFits`:
/// its first candidate is the whole text at its natural height, its second is
/// the folded text plus the toggle, and it is offered a height of exactly the
/// second candidate (`collapsedBlockHeight`). A text that wraps to
/// `collapsedLineCount` lines or fewer fits the first candidate and is drawn
/// whole with no toggle; anything longer does not, and the second is used.
/// No state, no measuring callback, nothing to arrive late.
///
/// Why offering exactly the second candidate's height is enough to tell the
/// two cases apart: the first candidate only fits when the text is at most
/// `collapsedLineCount` lines, because one more line costs a full line pitch
/// (glyph height plus `lineSpacing`) while the toggle row plus its gap is
/// always a little less than that (its font is smaller and the gap is the same
/// as the line spacing). The heights come from AppKit's text measurement, which
/// agrees with SwiftUI's `Text` to the point (asserted in `ImageTextTests`
/// across font scales), so the budget is not a guess that drifts with the
/// user's "Preview text size" setting.
struct FoldedImageText: View {
    let text: String

    /// Folded height, in lines. "About 3-4 lines" in the brief: four is the
    /// most that keeps a typical screenshot's worth of words readable without
    /// the block dominating the pane.
    static let collapsedLineCount = 4

    /// `Text.lineSpacing` and the gap above the toggle. The same number on
    /// purpose: it is what keeps the toggle row shorter than one more line of
    /// text (see the type comment).
    static let lineSpacing: CGFloat = 4

    /// The user's choice for this clip. Not remembered across clips: the pane
    /// gives each clip its own section identity (`.id(item.id)` in
    /// `PreviewPane.imageBody`), so stepping to another screenshot starts
    /// folded instead of carrying one clip's "Show all" onto the next and
    /// resizing the pane as the selection moves.
    @State private var isExpanded: Bool

    init(text: String, startsExpanded: Bool = false) {
        self.text = text
        _isExpanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        if isExpanded {
            // Already expanded, so the text is known to be long: no fit test,
            // and "Show less" is always right.
            VStack(alignment: .leading, spacing: Self.lineSpacing) {
                textView(lineLimit: nil)
                toggle("Show less")
            }
        } else {
            ViewThatFits(in: .vertical) {
                // Fits in `collapsedLineCount` lines: the whole text, no toggle.
                textView(lineLimit: nil)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: Self.lineSpacing) {
                    textView(lineLimit: Self.collapsedLineCount)
                    toggle("Show all")
                }
            }
            // `ViewThatFits` fills the height it is offered when it falls
            // through to the second candidate, so this has to be that
            // candidate's exact height, not a looser cap (see the type
            // comment for why it is also what makes the choice correct).
            .frame(
                maxHeight: Self.collapsedBlockHeight(textSize: Self.textSize),
                alignment: .topLeading
            )
        }
    }

    private func textView(lineLimit: Int?) -> some View {
        Text(text)
            .font(.klip(.preview))
            .lineSpacing(Self.lineSpacing)
            .lineLimit(lineLimit)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func toggle(_ title: String) -> some View {
        Button {
            isExpanded.toggle()
        } label: {
            Text(title)
                .font(.system(size: Self.toggleSize(forTextSize: Self.textSize)))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Metrics

    /// The preview text's point size right now: its role's base size times the
    /// user's "Preview text size", the same product `Font.klip(.preview)` uses.
    private static var textSize: CGFloat {
        KlipFontRole.preview.baseSize * SettingsManager.shared.previewFontScale
    }

    /// The toggle is one step smaller than the text it belongs to.
    static func toggleSize(forTextSize textSize: CGFloat) -> CGFloat {
        (textSize * 0.85).rounded()
    }

    /// Height of `lines` lines of `.system(size:)` text with `lineSpacing`
    /// between them: what `Text` lays out, measured by AppKit. Line spacing
    /// goes between lines, not after the last, which is how SwiftUI's `Text`
    /// counts it too.
    static func textHeight(lines: Int, fontSize: CGFloat) -> CGFloat {
        guard lines > 0 else { return 0 }
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        // Only the line count matters to the height, not the glyphs.
        let sample = Array(repeating: "Ag", count: lines).joined(separator: "\n")
        let rect = NSAttributedString(
            string: sample,
            attributes: [.font: NSFont.systemFont(ofSize: fontSize), .paragraphStyle: style]
        ).boundingRect(
            with: NSSize(width: 10_000, height: 10_000),
            options: [.usesLineFragmentOrigin]
        )
        return rect.height
    }

    /// The folded block: `collapsedLineCount` lines of text, the gap, and the
    /// "Show all" row. This is both what the second `ViewThatFits` candidate
    /// measures and the budget the first is tested against.
    static func collapsedBlockHeight(textSize: CGFloat) -> CGFloat {
        textHeight(lines: collapsedLineCount, fontSize: textSize)
            + lineSpacing
            + textHeight(lines: 1, fontSize: toggleSize(forTextSize: textSize))
    }
}
