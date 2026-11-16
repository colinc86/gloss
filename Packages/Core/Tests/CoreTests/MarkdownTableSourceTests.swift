import Foundation
import Testing
@testable import Core

/// Notes on a Markdown table's cells and columns: its rows read from the source, packets, and re-anchoring.
struct MarkdownTableSourceTests {
    static let markdown = "# Trail\n\nSegments so far.\n\n| Segment | Distance | Surface |\n|:--------|---------:|---------|\n| Lot to fence | 1.2 km | gravel |\n| Fence to overlook | 2.8 km | dirt \\| roots |\n\nMore later.\n"

    private func anchor(_ text: String, lines: ClosedRange<Int>, cells: CellSelection) -> TextAnchor {
        let index = LineIndex(text)
        let start = index.contentRange(ofLine: lines.lowerBound).location
        let end = index.contentRange(ofLine: lines.upperBound)
        var anchor = ReAnchorer.make(from: NSRange(location: start, length: NSMaxRange(end) - start), in: text, index: index, hash: "h")
        anchor.cells = cells
        return anchor
    }

    private func moved(_ result: ReAnchorResult) -> (anchor: TextAnchor, review: Bool)? {
        switch result {
        case .moved(.text(let anchor)): (anchor, false)
        case .movedNeedsReview(.text(let anchor)): (anchor, true)
        default: nil
        }
    }

    @Test func rowsSplitIntoCellsAsGitHubSplitsThem() {
        #expect(MarkdownTableSource.cells("| a | b |") == ["a", "b"])
        #expect(MarkdownTableSource.cells("a | b") == ["a", "b"], "the outer pipes are optional")
        #expect(MarkdownTableSource.cells("| dirt \\| roots | `x` |") == ["dirt | roots", "`x`"], "an escaped pipe stays in its cell")
        #expect(MarkdownTableSource.cells("| a \\* b |") == ["a \\* b"], "other escapes stay as written")
        #expect(MarkdownTableSource.cells("> | quoted | row |") == ["quoted", "row"], "a quote's marker is not a cell")
        #expect(MarkdownTableSource.cells("| | empty |") == ["", "empty"])
        #expect(MarkdownTableSource.cells("| a | b \\\\|") == ["a", "b \\\\"], "an escaped backslash before the closing pipe leaves the pipe closing")
        #expect(MarkdownTableSource.isDelimiter("|:--|--:|:-:|"))
        #expect(!MarkdownTableSource.isDelimiter("---"), "a rule is not a table")
        #expect(!MarkdownTableSource.isRow("no pipes here"))
        #expect(!MarkdownTableSource.isRow("only \\| escaped"))
    }

    @Test func aTableIsFoundFromAnyOfItsRows() {
        let lines = MarkdownTableSource.lines(of: Self.markdown)
        let table = MarkdownTableSource.Table(header: 5, body: [7, 8])
        #expect(MarkdownTableSource.table(containing: 5, in: lines) == table)
        #expect(MarkdownTableSource.table(containing: 8, in: lines) == table)
        #expect(MarkdownTableSource.table(containing: 3, in: lines) == nil)
        #expect(MarkdownTableSource.table(containing: 10, in: lines) == nil)
        // A header whose delimiter row has another number of cells is no table.
        #expect(MarkdownTableSource.table(containing: 1, in: ["| a | b |", "|---|", "| 1 | 2 |"]) == nil)
        // Text right above the header is not the header; a body row of dashes is not a delimiter row; a line with no
        // pipe goes on with the body, as on GitHub, until a blank line.
        let tight = ["Results:", "| a | b |", "|---|---|", "| - | - |", "| 1 | 2 |", "no pipes", "", "after"]
        let expected = MarkdownTableSource.Table(header: 2, body: [4, 5, 6])
        #expect(MarkdownTableSource.table(containing: 5, in: tight) == expected)
        #expect(MarkdownTableSource.table(containing: 6, in: tight) == expected)
        #expect(MarkdownTableSource.table(containing: 1, in: tight) == nil)
        #expect(MarkdownTableSource.table(containing: 8, in: tight) == nil)
    }

    @Test func packetsReadMarkdownCellsFromTheirRows() throws {
        let cells = CellSelection(cells: [CellRef(lineOffset: 0, column: 1), CellRef(lineOffset: 1, column: 2)])
        let noted = anchor(Self.markdown, lines: 7...8, cells: cells)
        let excerpt = CellExcerpt.make(anchor: noted, cells: cells, content: Self.markdown, fileName: "trail.md")
        #expect(excerpt.description == "B7, C8")
        #expect(excerpt.lines == ["B7 (Distance): 1.2 km", "C8 (Surface): dirt | roots"])

        let column = CellSelection(columns: [0], headers: ["Segment"])
        let header = anchor(Self.markdown, lines: 5...5, cells: column)
        let columnExcerpt = CellExcerpt.make(anchor: header, cells: column, content: Self.markdown, fileName: "trail.md")
        #expect(columnExcerpt.description == "Column A \"Segment\"")
        #expect(columnExcerpt.lines == ["7: Lot to fence", "8: Fence to overlook"])
    }

    @Test func aColumnNoteFollowsItsTableAndItsName() throws {
        let column = CellSelection(columns: [1], headers: ["Distance"])
        let noted = anchor(Self.markdown, lines: 5...5, cells: column)

        // A paragraph added above moves the table down; a column added in front moves Distance right.
        let edited = Self.markdown
            .replacingOccurrences(of: "Segments so far.\n", with: "Segments so far.\n\nWalked in May.\n")
            .replacingOccurrences(of: "| Segment | Distance |", with: "| Day | Segment | Distance |")
            .replacingOccurrences(of: "|:--------|", with: "|---|:--------|")
            .replacingOccurrences(of: "| Lot to fence |", with: "| 1 | Lot to fence |")
            .replacingOccurrences(of: "| Fence to overlook |", with: "| 2 | Fence to overlook |")
        let result = try #require(moved(ReAnchorer.text(noted, in: edited, newHash: "h2", fileName: "trail.md")))
        #expect(result.anchor.start.line == 7 && result.anchor.end.line == 7, "on the header row, two lines down")
        #expect(result.anchor.cells?.columns == [2] && result.anchor.cells?.headers == ["Distance"])

        // Its own column renamed: the same place, for a look.
        let renamed = Self.markdown.replacingOccurrences(of: "| Distance |", with: "| Length |")
        let looked = try #require(moved(ReAnchorer.text(noted, in: renamed, newHash: "h3", fileName: "trail.md")))
        #expect(looked.anchor.cells?.columns == [1] && looked.review)

        #expect(ReAnchorer.text(noted, in: "# Trail\n\nNo table now.\n", newHash: "h4", fileName: "trail.md") == .orphaned)
    }

    @Test func cellNotesKeepTheirRowsWhenOneIsAddedAbove() throws {
        let cells = CellSelection(cells: [CellRef(lineOffset: 0, column: 2)])
        let noted = anchor(Self.markdown, lines: 8...8, cells: cells)
        let edited = Self.markdown.replacingOccurrences(of: "| Lot to fence | 1.2 km | gravel |\n", with: "| Car park | 0.1 km | tarmac |\n| Lot to fence | 1.2 km | gravel |\n")
        let result = try #require(moved(ReAnchorer.text(noted, in: edited, newHash: "h2", fileName: "trail.md")))
        #expect(result.anchor.start.line == 9 && result.anchor.cells == cells)
        let excerpt = CellExcerpt.make(anchor: result.anchor, cells: cells, content: edited, fileName: "trail.md")
        #expect(excerpt.lines == ["C9 (Surface): dirt | roots"])
    }
}
