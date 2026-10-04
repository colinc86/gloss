import Core
import Foundation
import Testing
@testable import Viewers

/// Cell, block, scattered-cell, column, and row selection in the CSV grid, and the anchors they produce.
struct CSVGridSelectionTests {
    static let csv = "segment,distance_km,climb_m,surface,notes\nLot to fence,1.2,40,gravel,easy start\nFence to overlook,2.8,310,dirt,\"steep\nroots\"\nOverlook to view,0.9,25,rock,flat\n"

    private func grid() -> CSVGridController { CSVGridController(text: Self.csv, fileName: "segments.csv") }

    @Test func clicksSelectExtendAndToggleCells() {
        let grid = grid()
        grid.click(GridCell(row: 0, column: 1), extend: false, toggle: false)
        #expect(grid.selection == .cells([GridCell(row: 0, column: 1)]))
        #expect(grid.selectionSummary == "Cell B2")
        grid.click(GridCell(row: 1, column: 2), extend: true, toggle: false)
        #expect(grid.selection == .cells([GridCell(row: 0, column: 1), GridCell(row: 0, column: 2), GridCell(row: 1, column: 1), GridCell(row: 1, column: 2)]), "shift selects the block")
        grid.click(GridCell(row: 2, column: 4), extend: false, toggle: true)
        grid.click(GridCell(row: 0, column: 1), extend: false, toggle: true)
        #expect(grid.selection == .cells([GridCell(row: 0, column: 2), GridCell(row: 1, column: 1), GridCell(row: 1, column: 2), GridCell(row: 2, column: 4)]), "⌘ adds and removes")
        #expect(grid.selectionSummary == "4 cells")
    }

    @Test func dragsAddBlocksToAnExistingSelection() {
        let grid = grid()
        grid.click(GridCell(row: 2, column: 0), extend: false, toggle: false)
        let base: Set<GridCell> = [GridCell(row: 2, column: 0)]
        grid.click(GridCell(row: 0, column: 3), extend: false, toggle: true)
        grid.drag(to: GridCell(row: 1, column: 4), adding: base)
        #expect(grid.selection == .cells(base.union([GridCell(row: 0, column: 3), GridCell(row: 0, column: 4), GridCell(row: 1, column: 3), GridCell(row: 1, column: 4)])))
    }

    @Test func cellAnchorsCoverTheRecordsAndRememberTheCells() throws {
        let grid = grid()
        grid.click(GridCell(row: 0, column: 1), extend: false, toggle: false)
        grid.click(GridCell(row: 2, column: 4), extend: false, toggle: true)
        let anchor = try #require(grid.selectionAnchor())
        #expect(anchor.start.line == 2 && anchor.end.line == 5, "the multi-line record on lines 3-4 sits between")
        // The third record starts on line 5 because the second spans two lines.
        #expect(anchor.cells == CellSelection(cells: [CellRef(lineOffset: 0, column: 1), CellRef(lineOffset: 3, column: 4)]))
        #expect(Anchor.text(anchor).summary == "Cells B2, E5")
    }

    @Test func columnClicksSelectColumnsAndAnchorOnTheHeader() throws {
        let grid = grid()
        grid.clickColumn(4, extend: false, toggle: false)
        grid.clickColumn(1, extend: false, toggle: true)
        #expect(grid.selection == .columns([1, 4]))
        #expect(grid.selectionSummary == "Columns B (distance_km), E (notes)")
        let anchor = try #require(grid.selectionAnchor())
        #expect(anchor.start.line == 1 && anchor.cells == CellSelection(columns: [1, 4], headers: ["distance_km", "notes"]))
        grid.clickColumn(2, extend: true, toggle: false)
        #expect(grid.selection == .columns([1, 2, 3, 4]), "shift fills the columns in between")
        #expect(grid.isSelected(row: 2, column: 3) && !grid.isSelected(row: 2, column: 0))
    }

    @Test func rowClicksKeepPlainLineAnchors() throws {
        let grid = grid()
        grid.clickRow(1, extend: false)
        grid.clickRow(2, extend: true)
        #expect(grid.selection == .rows(1...2))
        #expect(grid.selectionSummary == "Lines 3-5")
        let anchor = try #require(grid.selectionAnchor())
        #expect(anchor.cells == nil && anchor.start.line == 3 && anchor.end.line == 5)
        grid.deselectAll()
        #expect(grid.selectionAnchor() == nil && !grid.hasSelection)
    }

    @Test func notesTintTheirCellsColumnsAndRows() {
        let grid = grid()
        let cellNote = NoteID.new(), columnNote = NoteID.new(), rowNote = NoteID.new()
        grid.cellSelections = [cellNote: CellSelection(cells: [CellRef(lineOffset: 0, column: 2)]), columnNote: CellSelection(columns: [0])]
        let index = grid.lineIndex
        grid.highlights = [
            TextHighlight(id: cellNote, range: index.contentRange(ofLine: 5), color: .blue, state: .draft),
            TextHighlight(id: columnNote, range: index.contentRange(ofLine: 1), color: .green, state: .draft),
            TextHighlight(id: rowNote, range: index.contentRange(ofLine: 2), color: .yellow, state: .draft),
        ]
        #expect(grid.highlight(row: 2, column: 2)?.id == cellNote)
        #expect(grid.highlight(row: 2, column: 3) == nil)
        #expect(grid.highlight(row: 1, column: 0)?.id == columnNote)
        #expect(grid.rowHighlight(0)?.id == rowNote && grid.rowHighlight(1) == nil, "only the row note tints a whole row")
    }

    @Test func rowDragsPivotOnWhereTheyStarted() {
        let grid = grid()
        grid.clickRow(2, extend: false)
        grid.clickRow(0, extend: true)
        #expect(grid.selection == .rows(0...2))
        grid.clickRow(1, extend: true)
        #expect(grid.selection == .rows(1...2), "reversing keeps the starting row, not the far end")
    }

    @Test func aCommandClickThatRemovesACellStaysRemovedWhenTheDragBegins() {
        let grid = grid()
        grid.click(GridCell(row: 0, column: 0), extend: false, toggle: false)
        grid.click(GridCell(row: 1, column: 1), extend: false, toggle: true)
        grid.click(GridCell(row: 1, column: 1), extend: false, toggle: true)
        // The view captures the base after the click, then drags only once the pointer reaches another cell.
        guard case .cells(let base) = grid.selection else { Issue.record("no cells"); return }
        #expect(base == [GridCell(row: 0, column: 0)])
    }

    @Test func arrowKeysMoveAndShiftArrowsGrowTheBlock() {
        let grid = grid()
        grid.moveSelection(rowBy: 1, columnBy: 0, extend: false)
        #expect(grid.selection == .cells([GridCell(row: 0, column: 0)]), "the first arrow press selects the first cell")
        grid.moveSelection(rowBy: 0, columnBy: 1, extend: false)
        #expect(grid.selection == .cells([GridCell(row: 0, column: 1)]))
        grid.moveSelection(rowBy: 1, columnBy: 0, extend: true)
        grid.moveSelection(rowBy: 0, columnBy: 1, extend: true)
        #expect(grid.selection == .cells(CSVGridController.block(from: GridCell(row: 0, column: 1), to: GridCell(row: 1, column: 2))))
        grid.moveSelection(rowBy: -5, columnBy: -5, extend: false)
        #expect(grid.selection == .cells([GridCell(row: 0, column: 0)]), "clamped to the grid")
    }
}

@MainActor
struct CSVColumnWidthTests {
    @Test func columnsFitTheirContentWithinBounds() {
        let prose = String(repeating: "a long sentence of notes ", count: 20)
        let grid = CSVGridController(text: "n,segment,notes\n1,Lot to fence,\(prose)\n2,Overlook to view,flat\n", fileName: "t.csv")
        let widths = grid.columnWidths
        #expect(widths.count == 3)
        #expect(widths[0] == 64)                  // a one-digit column stays at the minimum
        #expect(widths[1] > 64 && widths[1] < 320) // fits "Overlook to view"
        #expect(widths[2] == 320)                 // prose is capped
    }
}

@MainActor
struct CSVCopyTests {
    private let grid = CSVGridController(text: "a,b,c\n1,2,3\n4,\"5\tx\",6\n7,8,9\n", fileName: "t.csv")

    @Test func rowsCopyAsWholeRecords() {
        grid.clickRow(0, extend: false)
        grid.clickRow(1, extend: true)
        #expect(grid.copyText() == "1\t2\t3\n4\t5 x\t6")
    }

    @Test func columnsCopyWithTheirHeader() {
        grid.clickColumn(2, extend: false, toggle: false)
        #expect(grid.copyText() == "c\n3\n6\n9")
    }

    @Test func lineBreaksInsideValuesBecomeSpaces() {
        let crlf = CSVGridController(text: "a,b\r\n\"x\r\ny\",z\r\n", fileName: "t.csv")
        crlf.clickRow(0, extend: false)
        #expect(crlf.copyText() == "x y\tz")
    }

    @Test func scatteredCellsKeepTheirPlaces() {
        grid.click(GridCell(row: 0, column: 0), extend: false, toggle: false)
        grid.click(GridCell(row: 2, column: 2), extend: false, toggle: true)
        #expect(grid.copyText() == "1\t\t\n\t\t\n\t\t9")
    }
}
