import AppKit
import Core
import SwiftUI
import Testing
@testable import Viewers

/// Cells, rows and columns of a rendered Markdown table are selected as in the CSV grid, and become notes anchored on
/// the table's source lines.
@MainActor
struct MarkdownTableSelectionTests {
    static let markdown = "# Fruit\n\nWhat we have.\n\n| Name | Qty |\n|------|----:|\n| apple | 3 |\n| pear | 5 |\n\nAfter.\n"

    @Test func aPipeTableRemembersEachRowsSourceLine() throws {
        let output = MarkdownRenderer.render(Self.markdown)
        let table = try #require(output.tables[0])
        #expect(table.rowLines == [5, 7, 8], "the header, then each body row; the delimiter row is no row")
        #expect(table.columns == 2)
        // cmark starts a header at the paragraph it grew out of; the row is the line above the delimiter.
        #expect(MarkdownRenderer.render("Results:\n| a | b |\n|---|---|\n| 1 | 2 |\n").tables[0]?.rowLines == [2, 4])
        #expect(MarkdownRenderer.render("- item\n  | p | q |\n  |---|---|\n  | 1 | 2 |\n").tables[0]?.rowLines == [2, 4])
        #expect(MarkdownRenderer.render("Only a header:\n| a | b |\n|---|---|\n").tables[0]?.rowLines == [2])
        let html = MarkdownRenderer.render("<table><tr><td>a</td><td>b</td></tr></table>\n")
        #expect(html.tables.isEmpty, "a table written in HTML has no lines to anchor on")
    }

    @Test func cellsRowsAndColumnsBecomeAnchorsOnTheTablesLines() throws {
        let source = TextEditorController(text: Self.markdown, languageName: "markdown")
        let controller = MarkdownViewerController(source: source)

        // A block of cells: the rows' lines, with the cells' places.
        controller.selectTableCell(table: 0, row: 1, column: 1, extend: false, toggle: false)
        controller.selectTableCell(table: 0, row: 2, column: 1, extend: true, toggle: false)
        var anchor = try #require(controller.tableSelectionAnchor())
        #expect(anchor.start.line == 7 && anchor.end.line == 8)
        #expect(anchor.cells == CellSelection(cells: [CellRef(lineOffset: 0, column: 1), CellRef(lineOffset: 1, column: 1)]))
        var excerpt = CellExcerpt.make(anchor: anchor, cells: try #require(anchor.cells), content: Self.markdown, fileName: "stock.md")
        #expect(excerpt.description == "B7:B8")
        #expect(excerpt.lines == ["B7 (Qty): 3", "B8 (Qty): 5"])
        #expect(Anchor.text(anchor).summary == "Cells B7:B8")

        // A column: the header line, with the column's name.
        controller.selectTableColumn(table: 0, column: 0, extend: false, toggle: false)
        anchor = try #require(controller.tableSelectionAnchor())
        #expect(anchor.start.line == 5 && anchor.end.line == 5)
        #expect(anchor.cells == CellSelection(columns: [0], headers: ["Name"]))
        excerpt = CellExcerpt.make(anchor: anchor, cells: try #require(anchor.cells), content: Self.markdown, fileName: "stock.md")
        #expect(excerpt.description == "Column A \"Name\"")
        #expect(excerpt.lines == ["7: apple", "8: pear"])
        #expect(controller.tableSelectionCopyText() == "Name\napple\npear")

        // Rows next to each other are their lines, as any note on lines.
        controller.selectTableRow(table: 0, row: 1, extend: false, toggle: false)
        controller.selectTableRow(table: 0, row: 2, extend: true, toggle: false)
        anchor = try #require(controller.tableSelectionAnchor())
        #expect(anchor.start.line == 7 && anchor.end.line == 8 && anchor.cells == nil)
        #expect(controller.tableSelectionCopyText() == "apple\t3\npear\t5")

        // Rows apart are their cells.
        controller.selectTableRow(table: 0, row: 0, extend: false, toggle: false)
        controller.selectTableRow(table: 0, row: 2, extend: false, toggle: true)
        anchor = try #require(controller.tableSelectionAnchor())
        #expect(anchor.start.line == 5 && anchor.end.line == 8)
        #expect(anchor.cells?.cells.map(\.lineOffset) == [0, 0, 3, 3])

        // Cells apart copy as the block that holds them, with the gaps left empty.
        controller.selectTableCell(table: 0, row: 1, column: 1, extend: false, toggle: false)
        controller.selectTableCell(table: 0, row: 2, column: 0, extend: false, toggle: true)
        #expect(controller.tableSelectionCopyText() == "\t3\npear\t")

        // Text selected by a jump, or the source shown, lets the cells go.
        controller.scroll(toSource: NSRange(location: 0, length: 3), select: true)
        #expect(controller.tableSelection == nil && controller.tableSelectionAnchor() == nil)
        controller.selectTableCell(table: 0, row: 1, column: 0, extend: false, toggle: false)
        controller.mode = .source
        #expect(controller.tableSelection == nil)
    }

    @Test func aSelectionLastsWhileItsTableKeepsItsShape() {
        let source = TextEditorController(text: Self.markdown, languageName: "markdown")
        let controller = MarkdownViewerController(source: source)
        controller.selectTableCell(table: 0, row: 1, column: 0, extend: false, toggle: false)
        source.replaceAll(with: Self.markdown.replacingOccurrences(of: "apple", with: "plum"))
        controller.rebuildNow()
        #expect(controller.tableSelection != nil, "an edited cell keeps the selection")
        source.replaceAll(with: Self.markdown.replacingOccurrences(of: "| pear | 5 |\n", with: ""))
        controller.rebuildNow()
        #expect(controller.tableSelection == nil, "a row taken away lets it go")
    }

    @Test func aCellNoteIsDrawnOnItsCellNotAlongItsLines() throws {
        let source = TextEditorController(text: Self.markdown, languageName: "markdown")
        let controller = MarkdownViewerController(source: source)
        let id = NoteID.new()
        let lines = (Self.markdown as NSString).range(of: "| apple | 3 |\n| pear | 5 |")
        controller.cellSelections = [id: CellSelection(cells: [CellRef(lineOffset: 1, column: 0)])]
        source.highlights = [TextHighlight(id: id, range: lines, color: .yellow, state: .draft)]
        let ranges = controller.renderedHighlights().filter { $0.id == id }.map(\.range)
        #expect(ranges.map { (controller.rendered.string as NSString).substring(with: $0) } == ["pear"])

        let column = NoteID.new()
        controller.cellSelections[column] = CellSelection(columns: [1], headers: ["Qty"])
        source.highlights.append(TextHighlight(id: column, range: (Self.markdown as NSString).range(of: "| Name | Qty |"), color: .blue, state: .draft))
        let tinted = controller.renderedHighlights().filter { $0.id == column }.map { (controller.rendered.string as NSString).substring(with: $0.range) }
        #expect(tinted == ["Qty", "3", "5"])
    }

    @Test func rowsShareTheCellSelectorWithTheGrid() {
        var selector = GridSelector()
        selector.clickRow(1, extend: false)
        selector.toggleRow(3, columns: 2)
        #expect(selector.selection == .cells([GridCell(row: 1, column: 0), GridCell(row: 1, column: 1), GridCell(row: 3, column: 0), GridCell(row: 3, column: 1)]))
        selector.toggleRow(1, columns: 2)
        #expect(selector.selection == .cells([GridCell(row: 3, column: 0), GridCell(row: 3, column: 1)]), "⌘ on a selected row takes it away")
    }

    /// The page in a window, with its text view.
    private func host(_ controller: MarkdownViewerController) async throws -> (NSWindow, RenderedTextView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: MarkdownViewerView(controller: controller))
        hosting.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        window.displayIfNeeded()
        // The column settles once the view has its width.
        try await Task.sleep(for: .milliseconds(300))
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for subview in view.subviews { if let found = find(type, in: subview) { return found } }
            return nil
        }
        return (window, try #require(find(RenderedTextView.self, in: hosting)))
    }

    @Test func cellsAreFoundUnderThePointerAndPastTheTablesEdges() async throws {
        let controller = MarkdownViewerController(source: TextEditorController(text: Self.markdown, languageName: "markdown"))
        let (window, textView) = try await host(controller)
        defer { withExtendedLifetime(window) {} }
        let apple = try #require(textView.cellRect(TableCellPlace(table: 0, row: 1, column: 0)))
        let five = try #require(textView.cellRect(TableCellPlace(table: 0, row: 2, column: 1)))
        #expect(apple.maxX <= five.minX + 1 && apple.maxY <= five.minY + 1, "the second column right of the first, the third row below the second")
        #expect(textView.tableCell(at: NSPoint(x: apple.midX, y: apple.midY)) == TableCellPlace(table: 0, row: 1, column: 0))
        #expect(textView.tableCell(at: NSPoint(x: five.midX, y: five.midY)) == TableCellPlace(table: 0, row: 2, column: 1))
        #expect(textView.tableCell(at: NSPoint(x: apple.midX, y: five.maxY + 40)) == nil, "below the table is no cell")
        #expect(textView.nearestCell(in: 0, to: NSPoint(x: five.maxX + 200, y: five.maxY + 40)) == TableCellPlace(table: 0, row: 2, column: 1),
                "a drag past the table's corner keeps to its corner cell")

        // The hovered cell shows a handle for its column and one for its row.
        textView.updateTableHover(at: NSPoint(x: apple.midX, y: apple.midY))
        let handles = textView.handleRects()
        #expect(handles.map(\.handle) == [.column(table: 0, column: 0), .row(table: 0, row: 1)])
        let columnHandle = try #require(handles.first?.rect)
        #expect(textView.tableHandle(at: NSPoint(x: columnHandle.midX, y: columnHandle.midY)) == .column(table: 0, column: 0))

        // Where the Add Note button goes: beside the selected cells.
        controller.selectTableCell(table: 0, row: 1, column: 0, extend: false, toggle: false)
        controller.selectTableCell(table: 0, row: 2, column: 1, extend: true, toggle: false)
        #expect(try #require(controller.tableSelection).selection == .cells(GridSelector.block(from: GridCell(row: 1, column: 0), to: GridCell(row: 2, column: 1))))
        #expect(controller.tableSelectionRectProvider(try #require(controller.tableSelection)) != nil)
    }

    /// A drag that began in a cell: text while it stays there, cells once it crosses into another. (Driving it
    /// through the text view's own tracking means posting mouse events to the app's shared queue, which upsets the
    /// tests running beside it; the tracking calls `setSelectedRanges`, which asks `cellDragRanges`.)
    @Test func aDragAcrossCellsSelectsCellsAndOneInsideACellSelectsText() async throws {
        let controller = MarkdownViewerController(source: TextEditorController(text: Self.markdown, languageName: "markdown"))
        let (window, textView) = try await host(controller)
        defer { withExtendedLifetime(window) {} }
        let apple = try #require(textView.cellRect(TableCellPlace(table: 0, row: 1, column: 0)))
        let five = try #require(textView.cellRect(TableCellPlace(table: 0, row: 2, column: 1)))
        let text = [NSValue(range: NSRange(location: 30, length: 3))]

        textView.cellDrag = (TableCellPlace(table: 0, row: 1, column: 0), false)
        #expect(textView.cellDragRanges(text, at: NSPoint(x: apple.maxX - 4, y: apple.midY)) == nil, "inside its cell the drag selects text")
        #expect(controller.tableSelection == nil)

        let caret = try #require(textView.cellDragRanges(text, at: NSPoint(x: five.midX, y: five.midY)))
        #expect(caret.map(\.rangeValue) == [NSRange(location: 30, length: 0)], "the text keeps only a caret")
        #expect(controller.tableSelection?.selection == .cells(GridSelector.block(from: GridCell(row: 1, column: 0), to: GridCell(row: 2, column: 1))))

        // Back into the first cell, the drag stays on cells: just that one now.
        _ = textView.cellDragRanges(text, at: NSPoint(x: apple.midX, y: apple.midY))
        #expect(controller.tableSelection?.selection == .cells([GridCell(row: 1, column: 0)]))
        // Past the table's corner, its corner cell.
        _ = textView.cellDragRanges(text, at: NSPoint(x: five.maxX + 300, y: five.maxY + 80))
        #expect(controller.tableSelection?.selection == .cells(GridSelector.block(from: GridCell(row: 1, column: 0), to: GridCell(row: 2, column: 1))))
        textView.cellDrag = nil
    }
}
