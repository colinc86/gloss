import Foundation
import Testing
@testable import Core

/// Spreadsheet cell and column notes: references, packets, storage, and re-anchoring.
struct CellAnchorTests {
    static let csv = "segment,distance_km,climb_m,surface,notes\nLot to fence,1.2,40,gravel,easy start\nFence to overlook,2.8,310,dirt,\"steep, roots\"\nOverlook to view,0.9,25,rock,flat\n"

    private func anchor(lines: ClosedRange<Int>, cells: CellSelection) -> TextAnchor {
        let index = LineIndex(Self.csv)
        let start = index.contentRange(ofLine: lines.lowerBound).location
        let endRange = index.contentRange(ofLine: lines.upperBound)
        var anchor = ReAnchorer.make(from: NSRange(location: start, length: endRange.location + endRange.length - start), in: Self.csv, index: index, hash: "h")
        anchor.cells = cells
        return anchor
    }

    @Test func columnNamesFollowSpreadsheetLetters() {
        #expect(CellSelection.columnName(0) == "A")
        #expect(CellSelection.columnName(25) == "Z")
        #expect(CellSelection.columnName(26) == "AA")
        #expect(CellSelection.columnName(701) == "ZZ")
        #expect(CellSelection.columnName(702) == "AAA")
    }

    @Test func referencesCollapseOnlyFullBlocks() {
        let block = CellSelection(cells: [CellRef(lineOffset: 0, column: 1), CellRef(lineOffset: 0, column: 2), CellRef(lineOffset: 1, column: 1), CellRef(lineOffset: 1, column: 2)])
        #expect(block.references(startLine: 2) == "B2:C3")
        let gap = CellSelection(cells: [CellRef(lineOffset: 0, column: 1), CellRef(lineOffset: 2, column: 1)])
        #expect(gap.references(startLine: 2) == "B2, B4", "rows 2 and 4 are not a range")
        let scattered = CellSelection(cells: [CellRef(lineOffset: 2, column: 4), CellRef(lineOffset: 0, column: 0)])
        #expect(scattered.references(startLine: 2) == "A2, E4", "sorted by line then column")
        #expect(CellSelection(columns: [4, 1]).references(startLine: 1) == "B, E")
    }

    @Test func summariesNameCellsAndColumns() {
        #expect(Anchor.text(anchor(lines: 1...1, cells: CellSelection(columns: [4]))).summary == "Column E")
        #expect(Anchor.text(anchor(lines: 2...4, cells: CellSelection(cells: [CellRef(lineOffset: 0, column: 1), CellRef(lineOffset: 2, column: 4)]))).summary == "Cells B2, E4")
        #expect(Anchor.text(anchor(lines: 3...3, cells: CellSelection(cells: [CellRef(lineOffset: 0, column: 3)]))).summary == "Cell D3")
    }

    @Test func storageRoundTripsAndOldRowsStillDecode() throws {
        let withCells = Anchor.text(anchor(lines: 2...4, cells: CellSelection(cells: [CellRef(lineOffset: 0, column: 1)])))
        #expect(try Anchor(type: .text, json: try withCells.encodedJSON()) == withCells)
        let plain = Anchor.text(anchor(lines: 2...2, cells: CellSelection()))
        guard case .text(var bare) = plain else { return }
        bare.cells = nil
        let json = try Anchor.text(bare).encodedJSON()
        #expect(!json.contains("cells"), "notes without cells keep their old JSON")
        #expect(try Anchor(type: .text, json: json) == .text(bare))
    }

    @Test func columnPacketsListValuesByLine() {
        let column = anchor(lines: 1...1, cells: CellSelection(columns: [4]))
        let made = CellExcerpt.make(anchor: column, cells: column.cells!, content: Self.csv, fileName: "segments.csv")
        #expect(made.description == "Column E \"notes\"")
        #expect(made.lines == ["2: easy start", "3: steep, roots", "4: flat"])
        let packet = PacketBuilder.build([PacketNote(noteID: NoteID(rawValue: "n_1"), agentPath: "/p/segments.csv", source: .text, anchor: .text(column),
                                                     comment: "Fill these in", excerptLines: made.lines, cellDescription: made.description)])
        #expect(packet.text.contains("Column E \"notes\"\nExcerpt:\n> 2: easy start\n> 3: steep, roots\n> 4: flat\nUser comment: \"Fill these in\""))
        #expect(!packet.text.contains("Line 1"), "the column replaces the header line's range")
    }

    @Test func cellPacketsNameEachCell() {
        let cells = anchor(lines: 2...4, cells: CellSelection(cells: [CellRef(lineOffset: 0, column: 1), CellRef(lineOffset: 2, column: 4)]))
        let made = CellExcerpt.make(anchor: cells, cells: cells.cells!, content: Self.csv, fileName: "segments.csv")
        #expect(made.description == "B2, E4")
        #expect(made.lines == ["B2 (distance_km): 1.2", "E4 (notes): flat"])
        let note = PacketNote(noteID: NoteID(rawValue: "n_2"), agentPath: "/p/segments.csv", source: .text, anchor: .text(cells),
                              comment: "Check", excerptLines: made.lines, cellDescription: made.description)
        #expect(PacketBuilder.build([note]).text.contains("Lines 2-4\nCells: B2, E4\nExcerpt:\n> B2 (distance_km): 1.2\n> E4 (notes): flat"))
        #expect(PacketBuilder.summaryLine(note).contains("/p/segments.csv:cells B2,E4 "))
    }

    @Test func aHeaderWithALineBreakStaysOnItsCellsLine() {
        let csv = "segment,\"distance\nkm\"\nLot to fence,1.2\n"
        let index = LineIndex(csv)
        let row = index.contentRange(ofLine: 3)
        var cells = ReAnchorer.make(from: row, in: csv, index: index, hash: "h")
        cells.cells = CellSelection(cells: [CellRef(lineOffset: 0, column: 1)])
        let made = CellExcerpt.make(anchor: cells, cells: cells.cells!, content: csv, fileName: "x.csv")
        #expect(made.lines == ["B3 (distance\\nkm): 1.2"], "the header's line break is spelled, as a value's is")
        let column = CellExcerpt.make(anchor: cells, cells: CellSelection(columns: [1]), content: csv, fileName: "x.csv")
        #expect(column.description == "Column B \"distance\\nkm\"")
    }

    @Test func reanchoringKeepsTheCells() {
        let cells = CellSelection(cells: [CellRef(lineOffset: 1, column: 4)])
        let original = anchor(lines: 2...3, cells: cells)
        let edited = "segment,distance_km,climb_m,surface,notes\nNew first leg,0.1,1,road,added\n" + Self.csv.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
        guard case .moved(.text(let moved)) = ReAnchorer.text(original, in: edited, newHash: "h2") else {
            Issue.record("expected a move")
            return
        }
        #expect(moved.start.line == 3, "two rows shifted down by the inserted row")
        #expect(moved.cells == cells)
    }

    private static let rows = "id,value\nr1,1\nr2,2\nr3,3\nr4,4\nr5,5\n"

    private func rowsAnchor(lines: ClosedRange<Int>, cells: [CellRef]) -> TextAnchor {
        let index = LineIndex(Self.rows)
        let start = index.contentRange(ofLine: lines.lowerBound).location
        let end = index.contentRange(ofLine: lines.upperBound)
        var anchor = ReAnchorer.make(from: NSRange(location: start, length: end.location + end.length - start), in: Self.rows, index: index, hash: "h")
        anchor.cells = CellSelection(cells: cells)
        return anchor
    }

    private func moved(_ result: ReAnchorResult) -> (anchor: TextAnchor, review: Bool)? {
        switch result {
        case .moved(.text(let anchor)): (anchor, false)
        case .movedNeedsReview(.text(let anchor)): (anchor, true)
        default: nil
        }
    }

    @Test func aRowInsertedInsideTheSpanKeepsCellsOnTheirRecords() throws {
        // Cells on r2 (offset 0) and r4 (offset 2), anchored over lines 3-5.
        let anchor = rowsAnchor(lines: 3...5, cells: [CellRef(lineOffset: 0, column: 1), CellRef(lineOffset: 2, column: 1)])
        let edited = "id,value\nr1,1\nr2,2\nnew,9\nr3,3\nr4,4\nr5,5\n"
        let result = try #require(moved(ReAnchorer.text(anchor, in: edited, newHash: "h2")))
        let made = CellExcerpt.make(anchor: result.anchor, cells: result.anchor.cells!, content: edited, fileName: "x.csv")
        #expect(made.lines == ["B3 (value): 2", "B6 (value): 4"], "still r2 and r4, not the inserted row")
    }

    @Test func aDeletedRowDropsItsCellAndAsksForReview() throws {
        let anchor = rowsAnchor(lines: 3...5, cells: [CellRef(lineOffset: 0, column: 1), CellRef(lineOffset: 2, column: 1)])
        let edited = "id,value\nr1,1\nr2,2\nr3,3\nr5,5\n"
        let result = try #require(moved(ReAnchorer.text(anchor, in: edited, newHash: "h2")))
        #expect(result.review)
        let made = CellExcerpt.make(anchor: result.anchor, cells: result.anchor.cells!, content: edited, fileName: "x.csv")
        #expect(made.lines == ["B3 (value): 2"], "r4 is gone, so its cell is dropped rather than moved onto r5")
    }

    @Test func anEditedValueKeepsItsCellForReview() throws {
        let anchor = rowsAnchor(lines: 3...5, cells: [CellRef(lineOffset: 1, column: 1)])
        let edited = "id,value\nr1,1\nr2,2\nr3,33\nr4,4\nr5,5\n"
        let result = try #require(moved(ReAnchorer.text(anchor, in: edited, newHash: "h2")))
        #expect(result.review)
        let made = CellExcerpt.make(anchor: result.anchor, cells: result.anchor.cells!, content: edited, fileName: "x.csv")
        #expect(made.lines == ["B4 (value): 33"])
    }

    private func columnAnchor(_ csv: String, columns: [Int], headers: [String]?) -> TextAnchor {
        let index = LineIndex(csv)
        var anchor = ReAnchorer.make(from: index.contentRange(ofLine: 1), in: csv, index: index, hash: "h")
        anchor.cells = CellSelection(columns: columns, headers: headers)
        return anchor
    }

    @Test func columnNotesFollowTheirColumnByName() throws {
        let csv = "h,a,b,c\n1,2,3,4\n"
        let anchor = columnAnchor(csv, columns: [2], headers: ["b"])
        let prepended = try #require(moved(ReAnchorer.text(anchor, in: "x,h,a,b,c\n0,1,2,3,4\n", newHash: "h2")))
        #expect(prepended.anchor.cells?.columns == [3] && !prepended.review, "a column added in front moves the note with b")
        let renamedOther = try #require(moved(ReAnchorer.text(anchor, in: "h,A,b,c\n1,2,3,4\n", newHash: "h3")))
        #expect(renamedOther.anchor.cells?.columns == [2] && !renamedOther.review, "renaming another column does not orphan it")
        let renamedOwn = try #require(moved(ReAnchorer.text(anchor, in: "h,a,B,c\n1,2,3,4\n", newHash: "h4")))
        #expect(renamedOwn.anchor.cells?.columns == [2] && renamedOwn.review, "its own rename keeps the position for review")
        #expect(ReAnchorer.text(anchor, in: "h\n1\n", newHash: "h5") == .orphaned, "the column is gone")
    }

    /// A `.tsv` header with a comma in a name is split on tabs, as the grid splits it, when the column is found again.
    @Test func aTSVColumnIsFoundByItsTabs() throws {
        let tsv = "Last, First, Middle, Suffix\tNotes\nDoe, J, Q, Jr\tok\n"
        let anchor = columnAnchor(tsv, columns: [1], headers: ["Notes"])
        let edited = "Id\tLast, First, Middle, Suffix\tNotes\n1\tDoe, J, Q, Jr\tok\n"
        let result = try #require(moved(ReAnchorer.text(anchor, in: edited, newHash: "h2", fileName: "people.tsv")))
        #expect(result.anchor.cells?.columns == [2] && !result.review)
        let guessed = moved(ReAnchorer.text(anchor, in: edited, newHash: "h2"))
        #expect(guessed == nil || guessed?.anchor.cells?.columns != [2] || guessed?.review == true, "without the name, commas outnumber tabs")
    }

    @Test func hugeSpansDoNotBuildAnAlignmentTable() {
        let old = (0..<3000).map { "line \($0)" }
        let new = (0..<3000).map { "other \($0)" }
        #expect(ReAnchorer.lineMap(old, new) == nil)
        #expect(ReAnchorer.similarity(old, new) == 0)
    }
}
