// Adapted from Clipfield (MIT, Copyright 2026 Alex Jolley) —
// UI/Overlay/ClipRowView.swift.

import SwiftUI
import AppKit

/// One clipboard item in the list.
///
/// Replaces `Views/ClipboardItemRow.swift`. Layout is Clipfield's: a 38×38
/// badge, a two-line title, a subtitle (tag chips) and trailing state badges.
/// Every size goes through `CGFloat.klipScaled` and every font through
/// `Font.klip` so the whole row tracks the user's list text-size setting.
///
/// Click behaviour is **not** here — `ClipList` owns it: a single click only
/// selects, a double-click pastes (exactly what ↩ does, via `keyEnter`).
/// Clipfield's single-click-pastes is not adopted: a list you cannot look
/// through without pasting out of it is not a list.
struct ClipRow: View {
    let item: ClipboardItem
    let store: ClipboardStore
    /// The focused row (full accent gradient).
    let isPrimarySelection: Bool
    /// Part of a multi-selection (same gradient, dimmed).
    let isMultiSelected: Bool
    /// Whether the highlight change animates. False for key-driven selection
    /// moves (user item 4) — restarting the spring on every row while an
    /// arrow key repeats read as a blink.
    var animatesSelection: Bool = true
    var onTagTap: ((String) -> Void)? = nil

    /// Hover is the row's own state (5A-14). It used to live on `ClipList`,
    /// so moving the pointer across the list re-evaluated the *list's* body —
    /// which is where the 10,000-element `Array(items.enumerated())` copy was
    /// paid, on every hover transition.
    @State private var isHovered = false
    @State private var thumbnail: NSImage?
    /// QuickLook-generated 38×38 thumbnail for `.file` items (Phase 3F).
    /// `nil` while loading or when QuickLook has nothing for this file type —
    /// either way `badge` falls back to `fileIcon(store:)`.
    @State private var fileThumbnail: NSImage?

    private var isHighlighted: Bool { isPrimarySelection || isMultiSelected }
    private var badgeSize: CGFloat { .klipScaled(38) }
    private var secondaryColor: Color { isHighlighted ? Theme.onAccentSecondary : .secondary }

    var body: some View {
        HStack(spacing: 11) {
            badge

            VStack(alignment: .leading, spacing: 3) {
                // macOS 26 renders Text in lazy-list rows with a flipped
                // transform until the row is hovered or selected, so every
                // glyph draws upside-down in place. Rendering offscreen
                // bypasses the broken path. Same workaround as Maccy
                // (p0deje/Maccy#1113, fixed in their 2.5.1). It has to wrap
                // *every* Text in the row, so the named and unnamed layouts
                // each apply it to their own block.
                if let name = item.displayTitle {
                    namedTitle(name)
                } else {
                    Text(titleText)
                        .lineLimit(2)
                        .font(.klip(item.displayKind == .code ? .rowTitleMono : .rowTitle))
                        .foregroundStyle(isHighlighted ? Color.white : Color.primary)
                        .multilineTextAlignment(.leading)
                        .drawingGroup()
                }
                subtitle
            }

            Spacer(minLength: 6)

            trailingBadges
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(minHeight: .klipScaled(54))
        .background(rowBackground)
        .contentShape(RoundedRectangle(cornerRadius: Theme.rowCornerRadius))
        .animation(animatesSelection ? Theme.selectionSpring : nil, value: isPrimarySelection)
        .animation(animatesSelection ? Theme.selectionSpring : nil, value: isMultiSelected)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .onHover { hovering in
            guard isHovered != hovering else { return }
            isHovered = hovering
        }
        .task(id: item.id) {
            // Load thumbnail off the main thread, as before — now through a
            // cache (5A-10) and without `lockFocus` (5A-07).
            if item.type == .image && thumbnail == nil {
                thumbnail = await ImageThumbnailCache.thumbnail(for: item, store: store, size: badgeSize)
            }
            if item.type == .file && fileThumbnail == nil, let url = store.fileURLs(for: item).first {
                fileThumbnail = await FilePreview.thumbnail(for: url, itemID: item.id, size: badgeSize)
            }
        }
    }

    // MARK: - Title

    /// Collapse whitespace so multi-line clips still read as a compact preview.
    private var titleText: String {
        let text = item.previewText
        return text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// A named clip: the user's name takes the first line in semibold, and
    /// the clip's own content drops to a single dim line underneath. An
    /// unnamed clip never reaches here, so its row is unchanged.
    private func namedTitle(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name)
                .lineLimit(1)
                .font(.klip(.rowTitle))
                .fontWeight(.semibold)
                .foregroundStyle(isHighlighted ? Color.white : Color.primary)
            Text(titleText)
                .lineLimit(1)
                .font(.klip(item.displayKind == .code ? .rowTitleMono : .rowTitle))
                .foregroundStyle(isHighlighted ? Theme.onAccentSecondary : Color.secondary)
        }
        .multilineTextAlignment(.leading)
        .drawingGroup()
    }

    // MARK: - Badge

    @ViewBuilder
    private var badge: some View {
        if item.type == .image {
            imageBadge
        } else if let swatch = item.swatchColor {
            RoundedRectangle(cornerRadius: Theme.badgeCornerRadius)
                .fill(swatch)
                .frame(width: badgeSize, height: badgeSize)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.badgeCornerRadius)
                        .strokeBorder(Theme.swatchStroke, lineWidth: 1)
                )
                .shadow(color: swatch.opacity(0.5), radius: 4, y: 1)
        } else if item.type == .file {
            // QuickLook thumbnail when available (a real pdf/csv/image
            // preview reads much better at this size than a generic icon),
            // else the Launch Services / UTI icon, else the generic badge.
            if let thumb = fileThumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: badgeSize, height: badgeSize)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.badgeCornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.badgeCornerRadius)
                            .strokeBorder(Theme.badgeStroke, lineWidth: 1)
                    )
            } else if let icon = item.fileIcon(store: store) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: badgeSize, height: badgeSize)
            } else {
                kindBadge
            }
        } else {
            kindBadge
        }
    }

    @ViewBuilder
    private var imageBadge: some View {
        if let img = thumbnail {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: badgeSize, height: badgeSize)
                .clipShape(RoundedRectangle(cornerRadius: Theme.badgeCornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.badgeCornerRadius)
                        .strokeBorder(Theme.badgeStroke, lineWidth: 1)
                )
        } else {
            RoundedRectangle(cornerRadius: Theme.badgeCornerRadius)
                .fill(Color.secondary.opacity(0.2))
                .frame(width: badgeSize, height: badgeSize)
        }
    }

    private var kindBadge: some View {
        let kind = item.displayKind
        return ZStack {
            RoundedRectangle(cornerRadius: Theme.badgeCornerRadius)
                .fill(isHighlighted ? Theme.badgeFillSelected : Theme.badgeFill(kind))
                .frame(width: badgeSize, height: badgeSize)
            Image(systemName: item.type == .file ? "doc" : kind.systemImage)
                .font(Theme.icon(15, weight: .medium))
                .foregroundStyle(isHighlighted ? Color.white : Theme.kindTint(kind))
        }
    }

    // MARK: - Subtitle

    /// Tag chips, and nothing else.
    ///
    /// The source app and a live "3 minutes ago" label used to lead this line.
    /// Both were removed: the preview pane's footer already carries
    /// the same two facts as static text ("From" and "Copied"), and the
    /// relative label was the app's last per-second timer. Every visible row
    /// re-rendered once a second, and because the panel's hosting view is
    /// built once at launch and only *ordered out* on close, that kept the
    /// SwiftUI view graph and a Core Animation commit running for an
    /// invisible window for as long as the app was up — around two thirds of
    /// Klip's idle CPU. Dropping both also gives the clip's own text the full
    /// row width.
    @ViewBuilder
    private var subtitle: some View {
        if Features.tagsEnabled, !item.tags.isEmpty {
            HStack(spacing: 5) {
                ForEach(item.tags.prefix(2), id: \.self) { tag in
                    TagChip(label: tag, onAccent: isHighlighted, onTap: { onTagTap?(tag) })
                }

                if item.tags.count > 2 {
                    Text("+\(item.tags.count - 2)")
                        .font(.klip(.badge))
                        .foregroundStyle(secondaryColor)
                }
            }
            .lineLimit(1)
            // The subtitle flips too — see the title's drawingGroup comment.
            // Buttons inside still hit-test; drawingGroup only changes how the
            // pixels are produced.
            .drawingGroup()
        }
    }

    // MARK: - Trailing state badges

    private var trailingBadges: some View {
        HStack(spacing: 6) {
            if item.isLocked {
                Image(systemName: "lock.fill")
                    .font(.klip(.badge))
                    .foregroundStyle(isHighlighted ? Color.white.opacity(0.95) : Theme.lockTint)
                    .klipHelp("Locked — cannot be deleted")
            }
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.klip(.badge))
                    .rotationEffect(.degrees(40))
                    .foregroundStyle(isHighlighted ? Color.white.opacity(0.95) : Theme.pinTint)
                    .klipHelp("Pinned")
            }
            if item.isBookmarked {
                Image(systemName: "star.fill")
                    .font(.klip(.badge))
                    .foregroundStyle(isHighlighted ? Color.white.opacity(0.95) : Theme.bookmarkTint)
                    .klipHelp("Favorite")
            }
        }
    }

    // MARK: - Background

    @ViewBuilder
    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: Theme.rowCornerRadius)
            .fill(fillStyle)
            .shadow(color: isPrimarySelection ? Theme.selectionGlow : .clear, radius: 6, y: 2)
    }

    private var fillStyle: AnyShapeStyle {
        if isPrimarySelection {
            return AnyShapeStyle(Theme.accentGradient)
        }
        if isMultiSelected {
            return AnyShapeStyle(Theme.accentGradient.opacity(Theme.multiSelectFillOpacity))
        }
        return AnyShapeStyle(isHovered ? Theme.rowHover : Color.clear)
    }

}

// MARK: - Drag image (3B)

/// Builds the little card that follows the pointer while clip rows (or a
/// sidebar folder) are dragged.
///
/// It is *drawn* rather than snapshotted from the live view hierarchy: the row
/// is rendered by SwiftUI into the panel's shared layer, so there is no NSView
/// whose `cacheDisplay` would yield just that row. A drawn card also keeps the
/// image readable over any drop target and makes the multi-item case (a count
/// badge) trivial.
enum ClipRowDragImage {
    static let size = NSSize(width: 216, height: 40)

    /// - Parameters:
    ///   - title: single-line preview text; whitespace is collapsed.
    ///   - count: number of clips being dragged; > 1 adds the count badge.
    ///   - symbolName: SF Symbol drawn in the leading badge.
    static func make(title: String, count: Int, symbolName: String) -> NSImage {
        let collapsed = title
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        let image = NSImage(size: size, flipped: false) { rect in
            let card = rect.insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(roundedRect: card, xRadius: 9, yRadius: 9)

            NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
            path.fill()
            NSColor.labelColor.withAlphaComponent(0.18).setStroke()
            path.lineWidth = 1
            path.stroke()

            // Leading badge.
            let badgeRect = NSRect(x: card.minX + 8, y: card.midY - 11, width: 22, height: 22)
            let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: 6, yRadius: 6)
            NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
            badgePath.fill()
            if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
                let tinted = symbol.withSymbolConfiguration(config) ?? symbol
                tinted.draw(
                    in: badgeRect.insetBy(dx: 5, dy: 5),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 0.85
                )
            }

            // Title.
            let textRect = NSRect(
                x: badgeRect.maxX + 8,
                y: card.midY - 8,
                width: card.maxX - badgeRect.maxX - 16 - (count > 1 ? 22 : 0),
                height: 16
            )
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style,
            ]
            (collapsed as NSString).draw(in: textRect, withAttributes: attributes)

            // Count badge for a multi-row drag.
            if count > 1 {
                let label = "\(count)" as NSString
                let badgeFont = NSFont.systemFont(ofSize: 11, weight: .bold)
                let labelSize = label.size(withAttributes: [.font: badgeFont])
                let diameter = max(19, labelSize.width + 11)
                let circle = NSRect(
                    x: card.maxX - diameter - 7,
                    y: card.midY - diameter / 2,
                    width: diameter,
                    height: diameter
                )
                NSColor.controlAccentColor.setFill()
                NSBezierPath(ovalIn: circle).fill()
                label.draw(
                    at: NSPoint(
                        x: circle.midX - labelSize.width / 2,
                        y: circle.midY - labelSize.height / 2
                    ),
                    withAttributes: [.font: badgeFont, .foregroundColor: NSColor.white]
                )
            }
            return true
        }
        return image
    }

    /// Convenience for a clip drag: picks the symbol from the item's kind.
    static func make(for item: ClipboardItem, count: Int) -> NSImage {
        let symbol: String
        switch item.type {
        case .image: symbol = "photo"
        case .file: symbol = "doc"
        default: symbol = item.displayKind.systemImage
        }
        // A named clip is dragged by its name — that is what the user is
        // holding on to, and the folder they drop it in is where names live.
        let title = count > 1 ? "\(count) clips" : (item.displayTitle ?? item.previewText)
        return make(title: title, count: count, symbolName: symbol)
    }
}
