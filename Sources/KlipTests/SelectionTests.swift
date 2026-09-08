import Foundation
import BenchTestKit
@testable import Klip

// Shift+arrow selection (user request, 2026-09-07): the selection is the
// run between the anchor and the cursor, so walking back over rows
// deselects them. The old code only ever added rows.
enum SelectionTests {
    static let tests: [(String, () throws -> Void)] = [
        ("shiftDown_thenShiftUp_shrinksBackToTheAnchor", testDownThenUpShrinks),
        ("shiftUp_pastTheAnchor_extendsAbove", testPastAnchorExtendsAbove),
        ("shiftArrow_withNoSelection_selectsTheCurrentRowOnly", testEmptySelectionSelectsCurrent),
        ("shiftArrow_atTheEnd_isANoOp", testEndIsNoOp),
    ]

    // MARK: - Harness

    static func withViewModel<R>(rows: Int, _ body: (HistoryViewModel, [UUID]) throws -> R) throws -> R {
        try ClipboardStoreTests.withStore { store, _ in
            for index in 0..<rows {
                store.add(ClipboardItem(type: .text, textContent: "row \(index)"))
            }
            let viewModel = HistoryViewModel(store: store)
            viewModel.applyFilters(resetSelection: .keep)
            let ids = viewModel.filteredItems.map(\.id)
            try expectEqual(ids.count, rows, "every row should be listed")
            return try body(viewModel, ids)
        }
    }

    private static func selected(_ viewModel: HistoryViewModel, _ ids: [UUID], _ range: ClosedRange<Int>) throws {
        try expectEqual(viewModel.selectedIDs, Set(ids[range]), "expected rows \(range) selected")
    }

    // MARK: - Tests

    static func testDownThenUpShrinks() throws {
        try withViewModel(rows: 6) { viewModel, ids in
            viewModel.selectSingle(ids[1])

            viewModel.extendSelectionDown()
            viewModel.extendSelectionDown()
            viewModel.extendSelectionDown()
            try selected(viewModel, ids, 1...4)
            try expectEqual(viewModel.selectedIndex, 4)

            // Back up over two of them: they leave the selection again.
            viewModel.extendSelectionUp()
            try selected(viewModel, ids, 1...3)
            viewModel.extendSelectionUp()
            try selected(viewModel, ids, 1...2)
            viewModel.extendSelectionUp()
            try selected(viewModel, ids, 1...1)
            try expectEqual(viewModel.selectionAnchor, ids[1], "the anchor never moves while Shift is held")
        }
    }

    static func testPastAnchorExtendsAbove() throws {
        try withViewModel(rows: 6) { viewModel, ids in
            viewModel.selectSingle(ids[3])
            viewModel.extendSelectionDown()
            try selected(viewModel, ids, 3...4)

            // Up through the anchor and beyond: the run flips to above it.
            viewModel.extendSelectionUp()
            viewModel.extendSelectionUp()
            viewModel.extendSelectionUp()
            try selected(viewModel, ids, 1...3)
            try expectEqual(viewModel.selectedIndex, 1)

            // And back down shrinks that run too.
            viewModel.extendSelectionDown()
            try selected(viewModel, ids, 2...3)
        }
    }

    static func testEmptySelectionSelectsCurrent() throws {
        try withViewModel(rows: 3) { viewModel, ids in
            viewModel.clearSelection()
            viewModel.selectedIndex = 1
            viewModel.extendSelectionDown()
            try selected(viewModel, ids, 1...1)
            try expectEqual(viewModel.selectedIndex, 1, "the first Shift+arrow only claims the current row")
        }
    }

    static func testEndIsNoOp() throws {
        try withViewModel(rows: 3) { viewModel, ids in
            viewModel.selectSingle(ids[2])
            viewModel.extendSelectionDown()
            try selected(viewModel, ids, 2...2)
            try expectEqual(viewModel.selectedIndex, 2)

            viewModel.selectSingle(ids[0])
            viewModel.extendSelectionUp()
            try selected(viewModel, ids, 0...0)
            try expectEqual(viewModel.selectedIndex, 0)
        }
    }
}
