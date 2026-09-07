import AppKit
import Foundation
import BenchTestKit
@testable import Klip

// Task 6B follow-up — the shortcut legend's up-to-two-row wrap, now with
// graceful truncation instead of a three-tier `ViewThatFits` fallback.
// `LegendRowPacking` (Views/History/ActionBar.swift) is a plain, View-free
// function specifically so this decision — "how many of these
// priority-ordered entries fit in two rows at this width, and which ones get
// dropped" — is unit testable without instantiating SwiftUI.

enum ActionBarLegendTests {
    static let tests: [(String, () throws -> Void)] = [
        ("packRows_emptyEntries_returnsNoRows", testEmpty),
        ("packRows_allEntriesFitOneRow_singleRow", testSingleRow),
        ("packRows_notEnoughRoomForThirdEntry_wrapsItToTheNextRow", testWrapsAfterBudget),
        ("packRows_maxWidthZero_putsEveryEntryOnItsOwnRowUpToMaxRows", testZeroWidth),
        ("packRows_oneEntryWiderThanMaxWidth_stillGetsItsOwnRowNotDropped", testOversizedEntry),
        ("packRows_narrowWidth_truncatesTailInsteadOfCollapsingToTwoEntries", testTruncatesAtNarrowWidth),
        ("packRows_narrowWidth_highestPriorityEntriesAlwaysSurvive", testHighPriorityEntriesSurvive),
        ("packRows_truncation_preservesEntryOrder", testTruncationPreservesOrder),
        ("packRows_wideWidth_fullSetFitsOnOneRow", testFullSetFitsOneRowAtWideWidth),
        ("packRows_mediumWidth_fullSetWrapsToTwoRows", testFullSetWrapsTwoRowsAtMediumWidth),
        ("itemWidth_includesKeyBadgePaddingAndTheKeyLabelGap", testItemWidthIncludesChrome),
    ]

    static let fontSize: CGFloat = 10

    /// Stand-in for `ActionBar.legendItems` — priority order matters here
    /// because truncation drops from the end, so this mirrors the shipped
    /// order: paste, paste plain, tags, pin, favorite, lock, edit, save to
    /// disk, tag, copy.
    static let priorityOrderedEntries: [LegendEntry] = [
        LegendEntry(key: "↩", label: "paste"),
        LegendEntry(key: "⌥↩", label: "paste plain"),
        LegendEntry(key: "#", label: "tags"),
        LegendEntry(key: "⌘P", label: "pin"),
        LegendEntry(key: "⌘D", label: "favorite"),
        LegendEntry(key: "⌘L", label: "lock"),
        LegendEntry(key: "⌘E", label: "edit"),
        LegendEntry(key: "⌘S", label: "save to disk"),
        LegendEntry(key: "⌘T", label: "tag"),
        LegendEntry(key: "⌘C", label: "copy"),
    ]

    /// Eight same-shape entries (single-digit keys, equal-length labels) so
    /// every entry measures to (as near as font metrics ever guarantee) the
    /// same width. That makes "how many fit per row" arithmetic exact rather
    /// than approximate, which the truncation tests below lean on to land on
    /// a precise, non-flaky entry count.
    static let uniformEntries: [LegendEntry] = (0..<8).map {
        LegendEntry(key: "⌘\($0)", label: "item\($0)")
    }

    static func testEmpty() throws {
        try expectEqual(LegendRowPacking.packRows([], fontSize: fontSize, maxWidth: 400).count, 0, "no entries means no rows")
    }

    /// Enough width for every entry (plus inter-item spacing) keeps them on
    /// one row.
    static func testSingleRow() throws {
        let entries = [
            LegendEntry(key: "↩", label: "paste"),
            LegendEntry(key: "⌥↩", label: "paste plain"),
            LegendEntry(key: "#", label: "tags"),
        ]
        let total = entries.reduce(CGFloat(0)) { $0 + LegendRowPacking.itemWidth($1, fontSize: fontSize) }
            + LegendRowPacking.itemSpacing * CGFloat(entries.count - 1)

        let rows = LegendRowPacking.packRows(entries, fontSize: fontSize, maxWidth: total + 1)

        try expectEqual(rows.count, 1, "everything fits comfortably on one row")
        try expectEqual(rows.first?.count, 3)
    }

    /// A width budget that fits exactly the first two entries wraps the
    /// third onto row two rather than truncating or overflowing row one.
    static func testWrapsAfterBudget() throws {
        let a = LegendEntry(key: "↩", label: "paste")
        let b = LegendEntry(key: "⌥↩", label: "paste plain")
        let c = LegendEntry(key: "#", label: "tags")
        let widthA = LegendRowPacking.itemWidth(a, fontSize: fontSize)
        let widthB = LegendRowPacking.itemWidth(b, fontSize: fontSize)
        let maxWidth = widthA + LegendRowPacking.itemSpacing + widthB + 1

        let rows = LegendRowPacking.packRows([a, b, c], fontSize: fontSize, maxWidth: maxWidth)

        try expectEqual(rows.count, 2, "c does not fit alongside a and b, so it wraps to its own row")
        try expectEqual(rows[0].map { $0.label }, ["paste", "paste plain"])
        try expectEqual(rows[1].map { $0.label }, ["tags"])
    }

    /// At zero width nothing fits alongside anything else, so each surviving
    /// entry gets its own row — but only up to `maxRows`; the rest of the
    /// list is truncated instead of producing a third row.
    static func testZeroWidth() throws {
        let entries = [LegendEntry(key: "↩", label: "paste"), LegendEntry(key: "#", label: "tags")]

        let rows = LegendRowPacking.packRows(entries, fontSize: fontSize, maxWidth: 0)

        try expectEqual(rows.count, 2, "each entry gets its own row, and two entries fit within maxRows")
        try expectEqual(rows[0].map { $0.label }, ["paste"])
        try expectEqual(rows[1].map { $0.label }, ["tags"])
    }

    /// An entry wider than the whole budget must not be silently dropped or
    /// split when it still fits within `maxRows` — it gets a row of its own.
    static func testOversizedEntry() throws {
        let huge = LegendEntry(key: "⌘⇧⌥⌃X", label: "a very long label that will not fit")
        let small = LegendEntry(key: "↩", label: "paste")
        let hugeWidth = LegendRowPacking.itemWidth(huge, fontSize: fontSize)

        let rows = LegendRowPacking.packRows([huge, small], fontSize: fontSize, maxWidth: hugeWidth - 20)

        try expectEqual(rows.count, 2, "the oversized entry still gets its own row")
        try expectEqual(rows[0].map { $0.label }, ["a very long label that will not fit"])
        try expectEqual(rows[1].map { $0.label }, ["paste"])
    }

    /// The core behavior change: at a width too narrow for the full list even
    /// wrapped onto two rows, `packRows` no longer collapses to a wholly
    /// different two-entry "minimal" list. It keeps packing the *same*
    /// priority-ordered list and just stops once `maxRows` rows are full,
    /// dropping the tail.
    ///
    /// `uniformEntries` are sized so exactly 2 fit per row (see `maxWidth`
    /// below: room for 2 plus one inter-item gap, not a third), so with 8
    /// entries and 2 rows exactly 4 should survive and 4 should be dropped —
    /// well short of all 8, and well above the old two-entry minimal floor.
    static func testTruncatesAtNarrowWidth() throws {
        let entryWidth = LegendRowPacking.itemWidth(uniformEntries[0], fontSize: fontSize)
        let maxWidth = entryWidth * 2 + LegendRowPacking.itemSpacing + 1

        let rows = LegendRowPacking.packRows(uniformEntries, fontSize: fontSize, maxWidth: maxWidth)
        let flattened = rows.flatMap { $0 }

        try expectEqual(rows.count, LegendRowPacking.maxRows, "still uses both rows rather than giving up early")
        try expectEqual(flattened.count, 4, "2 rows x 2 entries fit; the other 4 are truncated")
        try expect(flattened.count > 2, "truncation keeps more than the old two-entry minimal tier")
    }

    /// Priority order is the truncation policy: whatever survives at a tight
    /// width must be a prefix of the full list, so the most important
    /// entries (paste, paste plain) are never the ones dropped.
    static func testHighPriorityEntriesSurvive() throws {
        let entryWidth = LegendRowPacking.itemWidth(priorityOrderedEntries[0], fontSize: fontSize)
        // Room for exactly one entry per row: still enough for both rows to
        // be used, never enough for the full ten.
        let narrowWidth = entryWidth + 1

        let rows = LegendRowPacking.packRows(priorityOrderedEntries, fontSize: fontSize, maxWidth: narrowWidth)
        let survivingLabels = rows.flatMap { $0 }.map { $0.label }

        try expect(survivingLabels.contains("paste"), "the highest-priority entry always survives truncation")
        try expectEqual(survivingLabels.first, "paste", "paste stays first — it is first in priority order")
    }

    /// Truncation must never reorder entries — the surviving entries are a
    /// prefix of `entries` in their original order, row-by-row.
    static func testTruncationPreservesOrder() throws {
        let entryWidth = LegendRowPacking.itemWidth(uniformEntries[0], fontSize: fontSize)
        // Room for exactly 3 per row: 6 of the 8 survive, 2 are truncated.
        let maxWidth = entryWidth * 3 + LegendRowPacking.itemSpacing * 2 + 1

        let rows = LegendRowPacking.packRows(uniformEntries, fontSize: fontSize, maxWidth: maxWidth)
        let survivingLabels = rows.flatMap { $0 }.map { $0.label }
        let expectedPrefix = Array(uniformEntries.map { $0.label }.prefix(survivingLabels.count))

        try expect(survivingLabels.count < uniformEntries.count, "sanity check: this width does truncate something")
        try expectEqual(survivingLabels, expectedPrefix, "surviving entries are an in-order prefix of the full list")
    }

    /// A width wide enough for the whole ten-entry list keeps it on one row —
    /// no truncation, no wrap, when there's genuinely enough room.
    static func testFullSetFitsOneRowAtWideWidth() throws {
        let total = priorityOrderedEntries.reduce(CGFloat(0)) { $0 + LegendRowPacking.itemWidth($1, fontSize: fontSize) }
            + LegendRowPacking.itemSpacing * CGFloat(priorityOrderedEntries.count - 1)

        let rows = LegendRowPacking.packRows(priorityOrderedEntries, fontSize: fontSize, maxWidth: total + 1)

        try expectEqual(rows.count, 1, "a wide enough window fits the full set on one line")
        try expectEqual(rows.first?.count, priorityOrderedEntries.count)
    }

    /// A width that fits exactly half the list per row wraps the full set
    /// onto exactly two rows without dropping anything — the same "fits on
    /// one line, otherwise wraps to a second line" behavior the user sees
    /// today, unchanged by the truncation fix. Uses `uniformEntries` (equal
    /// widths) so both rows are guaranteed to hold the same count and
    /// nothing spills into a would-be third row.
    static func testFullSetWrapsTwoRowsAtMediumWidth() throws {
        let half = uniformEntries.count / 2
        let halfRowWidth = LegendRowPacking.itemWidth(uniformEntries[0], fontSize: fontSize) * CGFloat(half)
            + LegendRowPacking.itemSpacing * CGFloat(half - 1)

        let rows = LegendRowPacking.packRows(uniformEntries, fontSize: fontSize, maxWidth: halfRowWidth + 1)
        let flattened = rows.flatMap { $0 }

        try expectEqual(rows.count, 2, "wraps to two rows rather than truncating when two rows are enough")
        try expectEqual(flattened.count, uniformEntries.count, "nothing is dropped when it all fits in two rows")
    }

    /// The measured width is more than the raw key + label text — it must
    /// include the key badge's padding and the key/label gap `legendItem`
    /// actually renders, or the wrap/truncation decisions would run too
    /// optimistic and clip a row.
    static func testItemWidthIncludesChrome() throws {
        let entry = LegendEntry(key: "↩", label: "paste")
        let font = NSFont.systemFont(ofSize: fontSize)
        let rawKeyWidth = ("↩" as NSString).size(withAttributes: [.font: font]).width
        let rawLabelWidth = ("paste" as NSString).size(withAttributes: [.font: font]).width

        let measured = LegendRowPacking.itemWidth(entry, fontSize: fontSize)

        try expect(
            measured > rawKeyWidth + rawLabelWidth,
            "the measurement adds the key badge's padding and the key/label gap, not just raw text widths"
        )
    }
}
