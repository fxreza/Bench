// Pure-geometry tests for Views/Overlay/SelectionLayout.swift.
//
// Self-contained on purpose: the checks below are private to this file so the
// suite can also be compiled on its own (a throwaway main) without
// Tests/TestRunner.swift. Register it by adding `SelectionLayoutTests.suite`
// to `SnapperTestSuites.all` in Tests/Suites.swift.

import CoreGraphics
import Foundation
@testable import Shot

enum SelectionLayoutTests {

    static let suite: (String, [(String, () throws -> Void)]) = ("SelectionLayoutTests", tests)

    // MARK: - fixtures

    private static let screen = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private static let label = CGSize(width: 90, height: 24)
    private static let toolStrip = CGSize(width: 420, height: 36)
    private static let optionsRow = CGSize(width: 300, height: 30)
    private static let actionStrip = CGSize(width: 34, height: 260)

    private static func place(_ selection: CGRect,
                              obstructions: [CGRect] = [],
                              options: CGSize = optionsRow) -> SelectionLayout.Placement {
        SelectionLayout.place(screen: screen,
                              selection: selection,
                              label: label,
                              toolStrip: toolStrip,
                              optionsRow: options,
                              actionStrip: actionStrip,
                              obstructions: obstructions)
    }

    // MARK: - checks (private so they cannot clash with TestRunner.swift)

    private struct LayoutFailure: Error, CustomStringConvertible {
        let message: String
        let file: StaticString
        let line: UInt
        var description: String { "\(message) (\(file):\(line))" }
    }

    private static func check(_ condition: Bool, _ message: @autoclosure () -> String,
                              file: StaticString = #file, line: UInt = #line) throws {
        if !condition { throw LayoutFailure(message: message(), file: file, line: line) }
    }

    private static func checkClose(_ a: CGFloat, _ b: CGFloat, _ message: String,
                                   file: StaticString = #file, line: UInt = #line) throws {
        if abs(a - b) > 0.01 {
            throw LayoutFailure(message: "\(message): \(a) != \(b)", file: file, line: line)
        }
    }

    private static func checkInside(_ r: CGRect, _ container: CGRect, _ what: String,
                                    file: StaticString = #file, line: UInt = #line) throws {
        if !container.insetBy(dx: -0.01, dy: -0.01).contains(r) {
            throw LayoutFailure(message: "\(what) \(r) escapes \(container)", file: file, line: line)
        }
    }

    /// Every piece of chrome must stay on screen and never cover the label.
    private static func checkInvariants(_ p: SelectionLayout.Placement,
                                        file: StaticString = #file, line: UInt = #line) throws {
        try checkInside(p.label, screen, "label", file: file, line: line)
        try checkInside(p.toolStrip, screen, "tool strip", file: file, line: line)
        try checkInside(p.optionsRow, screen, "options row", file: file, line: line)
        try checkInside(p.actionStrip, screen, "action strip", file: file, line: line)
        try check(!p.actionStrip.intersects(p.label), "action strip overlaps the label", file: file, line: line)
        try check(!p.toolStrip.intersects(p.label), "tool strip overlaps the label", file: file, line: line)
        try check(!p.optionsRow.intersects(p.label), "options row overlaps the label", file: file, line: line)
    }

    // MARK: - tests

    static let tests: [(String, () throws -> Void)] = [

        ("normalPlacement", {
            // Selection well inside the screen: label above, strips below, actions right.
            let sel = CGRect(x: 400, y: 300, width: 600, height: 400)
            let p = place(sel)
            try checkInvariants(p)
            try check(p.label.maxY <= sel.minY, "label should sit above the selection, got \(p.label)")
            try checkClose(p.label.maxY, sel.minY - SelectionLayout.gap, "label gap above the selection")
            try checkClose(p.label.midX, sel.midX, "label centred on the selection")
            try check(p.toolStrip.minY >= sel.maxY, "tool strip should sit below the selection, got \(p.toolStrip)")
            try checkClose(p.toolStrip.minY, sel.maxY + SelectionLayout.gap, "tool strip gap below the selection")
            try checkClose(p.optionsRow.minY, p.toolStrip.maxY + SelectionLayout.optionsGap, "options row under the tool strip")
            try checkClose(p.toolStrip.midX, sel.midX, "tool strip centred")
            try check(p.actionStrip.minX >= sel.maxX, "action strip should be right of the selection, got \(p.actionStrip)")
            try checkClose(p.actionStrip.minX, sel.maxX + SelectionLayout.gap, "action strip gap")
            try checkClose(p.actionStrip.midY, sel.midY, "action strip vertically centred")
        }),

        ("selectionAtTopEdgePutsLabelBelow", {
            // No room above: the label drops below the selection and the strips
            // are pushed further down so they do not collide with it.
            let sel = CGRect(x: 400, y: 0, width: 600, height: 300)
            let p = place(sel)
            try checkInvariants(p)
            try check(p.label.minY >= sel.maxY, "label should drop below the selection, got \(p.label)")
            try checkClose(p.label.minY, sel.maxY + SelectionLayout.gap, "label gap below the selection")
            try check(p.toolStrip.minY >= p.label.maxY, "tool strip should sit under the label, got \(p.toolStrip)")
            try check(p.optionsRow.minY >= p.toolStrip.maxY, "options row under the tool strip")
        }),

        ("selectionAtBottomEdgePutsStripsAbove", {
            // No room below: strips flip above the selection, label moves inside.
            let sel = CGRect(x: 400, y: 600, width: 600, height: 400)
            let p = place(sel)
            try checkInvariants(p)
            try check(p.optionsRow.maxY <= sel.minY, "strips should sit above the selection, got \(p.optionsRow)")
            try checkClose(p.optionsRow.maxY, sel.minY - SelectionLayout.gap, "options row gap above the selection")
            try check(p.toolStrip.maxY <= p.optionsRow.minY, "tool strip above the options row")
            try check(sel.contains(p.label), "label should move inside the selection, got \(p.label)")
            try check(!p.label.intersects(p.toolStrip), "label must not cover the tool strip")
        }),

        ("selectionAtRightEdgeFlipsActionStripLeft", {
            let sel = CGRect(x: 1000, y: 300, width: 600, height: 400)
            let p = place(sel)
            try checkInvariants(p)
            try check(p.actionStrip.maxX <= sel.minX, "action strip should flip to the left, got \(p.actionStrip)")
            try checkClose(p.actionStrip.maxX, sel.minX - SelectionLayout.gap, "action strip gap on the left")
        }),

        ("fullScreenSelectionPutsEverythingInside", {
            let sel = screen
            let p = place(sel)
            try checkInvariants(p)
            try checkInside(p.label, sel, "label")
            try checkInside(p.toolStrip, sel, "tool strip")
            try checkInside(p.optionsRow, sel, "options row")
            try checkInside(p.actionStrip, sel, "action strip")
            try checkClose(p.optionsRow.maxY, sel.maxY - SelectionLayout.gap, "strips pinned to the bottom inside")
            try checkClose(p.actionStrip.maxX, sel.maxX - SelectionLayout.gap, "action strip pinned to the right inside")
        }),

        ("topObstructionPushesLabelBelow", {
            // A notch / safe-area band across the top of the display: the label
            // would fit above the selection geometrically but not visually.
            let sel = CGRect(x: 400, y: 60, width: 600, height: 400)
            let band = CGRect(x: 0, y: 0, width: 1600, height: 40)
            let free = place(sel)
            try check(free.label.maxY <= sel.minY, "without the band the label belongs above")

            let p = place(sel, obstructions: [band])
            try checkInvariants(p)
            try check(!p.label.intersects(band), "label must avoid the obstruction, got \(p.label)")
            try check(p.label.minY >= sel.maxY, "label should drop below the selection, got \(p.label)")
            try check(p.toolStrip.minY >= p.label.maxY, "tool strip stays under the label")
        }),

        ("hiddenOptionsRowCollapses", {
            // The options capsule is hidden for the select tool: zero size, and
            // the tool strip keeps its normal gap below the selection.
            let sel = CGRect(x: 400, y: 300, width: 600, height: 400)
            let p = place(sel, options: .zero)
            try checkInvariants(p)
            try checkClose(p.optionsRow.height, 0, "options row collapsed")
            try checkClose(p.toolStrip.minY, sel.maxY + SelectionLayout.gap, "tool strip gap below the selection")
        }),
    ]
}
