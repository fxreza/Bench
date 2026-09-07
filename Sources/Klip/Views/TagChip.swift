import SwiftUI

/// A small coloured pill for a user tag. Used in rows (tap to filter) and in
/// the preview pane's tag strip (tap the ✕ to remove).
///
/// **Two colour schemes.** On a normal (unselected) row the chip paints its
/// own hashed colour as the label over a 14% wash of itself — that reads fine
/// on the panel's grey. On the *selected* row the background is the accent
/// gradient, and a blue chip on a blue accent was invisible; a green one on
/// green likewise. `onAccent` switches the chip to white-on-ink instead: the
/// label's contrast then depends only on the ink wash, never on which accent
/// the user picked, so it survives all nine of them in both appearances.
struct TagChip: View {
    let label: String
    /// `true` when the chip sits on the accent-gradient (selected) row.
    var onAccent: Bool = false
    /// `true` where the chip must be able to shrink — the preview pane's
    /// wrapping tag strip, where a long tag name would otherwise push its own
    /// ✕ past the edge of the pane. The label truncates instead. Rows keep the
    /// default (`false`) so a chip in a row's subtitle is never squeezed by
    /// the timestamp beside it.
    var flexible: Bool = false
    var onTap: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil

    private var chipColor: Color { TagChip.color(for: label) }

    /// Ink wash behind an on-accent chip. Dark enough that white text clears
    /// AA on every accent, including the light ones (orange, green, yellow)
    /// where white-on-accent is weakest.
    static let onAccentFill = Color.black.opacity(0.34)
    /// Label / ✕ colour on an on-accent chip.
    static let onAccentLabel = Color.white

    static func color(for tag: String) -> Color {
        let palette: [Color] = [
            Color(red: 0.40, green: 0.62, blue: 1.00),
            Color(red: 0.36, green: 0.78, blue: 0.57),
            Color(red: 1.00, green: 0.65, blue: 0.30),
            Color(red: 0.93, green: 0.45, blue: 0.63),
            Color(red: 0.68, green: 0.50, blue: 0.93),
            Color(red: 0.35, green: 0.82, blue: 0.82),
        ]
        return palette[abs(tag.hashValue) % palette.count]
    }

    static func normalize(_ input: String) -> String {
        let lower = input.lowercased()
        let dashed = lower.replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
        let trimmed = dashed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(trimmed.prefix(32))
    }

    var body: some View {
        HStack(spacing: 2) {
            if let onTap = onTap {
                Button(action: onTap) { chipLabel }
                    .buttonStyle(.plain)
                    .klipHelp("Filter by #\(label)")
            } else {
                chipLabel
            }
            if let onRemove = onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.klip(.badge))
                        .fontWeight(.bold)
                        .foregroundStyle(onAccent ? Self.onAccentLabel.opacity(0.75) : chipColor.opacity(0.7))
                }
                .buttonStyle(.plain)
                .klipHelp("Remove tag")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(onAccent ? Self.onAccentFill : chipColor.opacity(0.14)))
        .overlay(
            Capsule().strokeBorder(
                onAccent ? Color.clear : chipColor.opacity(0.25),
                lineWidth: 0.5
            )
        )
        // `fixedSize` is what stops a chip being compressed in a row's
        // subtitle — but it also makes the chip ignore any width it is
        // offered, which is the opposite of what the wrapping strip needs.
        .fixedSize(horizontal: !flexible, vertical: true)
    }

    @ViewBuilder
    private var chipLabel: some View {
        let text = Text(label)
            .font(.klip(.badge))
            .foregroundStyle(onAccent ? Self.onAccentLabel : chipColor)
            .lineLimit(1)
            .truncationMode(.tail)
        if flexible {
            // A flexible chip's label can be truncated, so hovering it spells
            // the tag out in full.
            text.klipHelp("#\(label)")
        } else {
            text
        }
    }
}
