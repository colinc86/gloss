import AppKit
import Core
import Observation

/// One cell of the grid: a record index into `CSVTable.rows` and a 0-based data column.
public nonisolated struct GridCell: Hashable, Sendable, Comparable {
    public var row: Int
    public var column: Int

    public init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    public static func < (lhs: GridCell, rhs: GridCell) -> Bool {
        (lhs.row, lhs.column) < (rhs.row, rhs.column)
    }
}

/// What is selected in the grid. Rows stay contiguous (a note covers one run of source lines); cells may be any set.
public enum GridSelection: Equatable, Sendable {
    case none
    case rows(ClosedRange<Int>)
    case columns(IndexSet)
    case cells(Set<GridCell>)
}

/// A CSV document shown as a grid. Notes stay text anchors over the raw lines, so packets quote the source rows;
/// cell and column notes add a `CellSelection` to that anchor.
@Observable
public final class CSVGridController {
    public let text: String
    public let table: CSVTable
    public let lineIndex: LineIndex
    public private(set) var selection: GridSelection = .none {
        didSet { onSelectionChange() }
    }
    /// The cell a shift-click, drag, or shift-arrow extends from.
    @ObservationIgnored private(set) var selectionOrigin: GridCell?
    /// The record a row drag or shift-click in the line column extends from.
    @ObservationIgnored private var rowOrigin: Int?
    /// The cell the arrow keys move from (the far corner of a shift-extended block).
    @ObservationIgnored private var cursor: GridCell?
    /// Where the arrow keys are, for keeping it on screen.
    public var cursorCell: GridCell? { cursor }
    /// Lines (1-based) covered by text notes, with their colors, for row tinting.
    public var highlights: [TextHighlight] = [] {
        didSet { rebuildHighlightMaps() }
    }
    /// Cell and column notes by id; set before `highlights` so one rebuild covers both.
    @ObservationIgnored public var cellSelections: [NoteID: CellSelection] = [:]
    @ObservationIgnored public var onHighlightsChange: () -> Void = {}
    @ObservationIgnored public var onSelectionChange: () -> Void = {}
    /// Set by the view: on-screen rectangle of a selection, in top-left window coordinates.
    @ObservationIgnored public var rectProvider: (GridSelection) -> CGRect? = { _ in nil }
    /// Where this viewer's notes are on screen, for the notes panel's link and paths.
    @ObservationIgnored public let noteGeometry = NoteGeometry()

    @ObservationIgnored private var rowHighlights: [Int: TextHighlight] = [:]
    @ObservationIgnored private var columnHighlights: [Int: TextHighlight] = [:]
    @ObservationIgnored private var cellHighlights: [GridCell: TextHighlight] = [:]
    @ObservationIgnored private lazy var rowByFirstLine: [Int: Int] = {
        var result: [Int: Int] = [:]
        for (index, row) in table.rows.enumerated() { result[row.firstLine] = index }
        return result
    }()

    public init(text: String, fileName: String) {
        self.text = text
        lineIndex = LineIndex(text)
        table = CSVParser.parse(text, delimiter: CSVParser.delimiter(for: text, fileName: fileName))
    }

    public var isTruncated: Bool { table.isTruncated }

    /// A grid wider than this isn't a table anyone reads: one line of 2 million commas made 2 million columns
    /// measured and built on the main thread. Such files open as text instead.
    public static let maximumColumns = 1_000
    public var isTooWide: Bool { table.columnCount > Self.maximumColumns }

    /// Columns whose every non-empty field is a number; the grid right-aligns them so magnitudes line up.
    @ObservationIgnored public private(set) lazy var numericColumns: Set<Int> = {
        var result: Set<Int> = []
        for column in 0..<table.columnCount {
            var sawNumber = false
            var allNumeric = true
            for row in table.rows.prefix(2_000) where column < row.fields.count {
                let field = row.fields[column].trimmingCharacters(in: .whitespaces)
                if field.isEmpty { continue }
                if Double(field.replacingOccurrences(of: ",", with: "")) != nil { sawNumber = true } else { allNumeric = false; break }
            }
            if sawNumber && allNumeric { result.insert(column) }
        }
        return result
    }()

    /// Starting width per data column: the header or the widest of the first rows, whichever is wider, plus padding,
    /// held between 64 and 320 points so a one-digit column stays narrow and prose doesn't push the rest away.
    @ObservationIgnored public private(set) lazy var columnWidths: [CGFloat] = {
        let body = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let name = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        let letter = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        return (0..<max(1, table.columnCount)).map { column in
            let header = column < table.header.count ? table.header[column] : ""
            var widest = (CellSelection.columnName(column) as NSString).size(withAttributes: [.font: letter]).width
                + (header.isEmpty ? 0 : ("  " + header as NSString).size(withAttributes: [.font: name]).width)
            for row in table.rows.prefix(200) where column < row.fields.count {
                let field = row.fields[column]
                guard !field.isEmpty else { continue }
                widest = max(widest, (field.prefix(80) as NSString).size(withAttributes: [.font: body]).width)
            }
            return min(320, max(64, (widest + 24).rounded(.up)))
        }
    }()

    /// Add Note in this viewer's context menu; set by the app.
    @ObservationIgnored public var addNote: AddNoteHook?

    // MARK: Find

    /// The find field over the grid is showing (Edit › Find; a table view has no find bar of its own).
    public var isFinding = false
    public var findText = ""
    public private(set) var findMissed = false
    /// The cell found last; the next search starts after it.
    @ObservationIgnored public private(set) var foundCell: GridCell?
    /// Set by the view: scroll a cell into sight (a match found, a note revealed).
    @ObservationIgnored public var onScroll: (GridCell) -> Void = { _ in }

    func perform(_ action: NSTextFinder.Action) {
        switch action {
        case .showFindInterface: isFinding = true
        case .nextMatch: Task { await find(backwards: false) }
        case .previousMatch: Task { await find(backwards: true) }
        case .hideFindInterface: endFind()
        default: break
        }
    }

    /// The next (or previous) cell holding `findText`, row by row, case aside, wrapping; it is selected, as a click
    /// would, so a note can be added to it straight away. The cells are searched off the main thread: a miss on a
    /// full sheet reads every one of them, about a second that used to freeze the app on each Return.
    public func find(backwards: Bool) async {
        let needle = findText
        let rows = table.rows
        let columns = max(1, table.columnCount)
        guard !needle.isEmpty, !rows.isEmpty else {
            findMissed = false
            return
        }
        let start = (foundCell ?? cursor).map { $0.row * columns + $0.column }
        let found = await Self.search(needle, in: rows, columns: columns, after: start, backwards: backwards)
        // Typed over, or the file reloaded, while it searched: that answer is for another question.
        guard needle == findText, rows == table.rows else { return }
        guard let cell = found else {
            findMissed = true
            return
        }
        findMissed = false
        foundCell = cell
        click(cell, extend: false, toggle: false)
        onScroll(cell)
    }

    @concurrent nonisolated private static func search(_ needle: String, in rows: [CSVRow], columns: Int, after start: Int?, backwards: Bool) async -> GridCell? {
        let total = rows.count * columns
        let origin = start ?? (backwards ? total : -1)
        for step in 1...total {
            if step % 65_536 == 0, Task.isCancelled { return nil }
            let index = ((origin + (backwards ? -step : step)) % total + total) % total
            let cell = GridCell(row: index / columns, column: index % columns)
            let fields = rows[cell.row].fields
            if cell.column < fields.count, fields[cell.column].range(of: needle, options: .caseInsensitive) != nil { return cell }
        }
        return nil
    }

    public func endFind() {
        isFinding = false
        findMissed = false
    }

    // MARK: Selecting

    public func deselectAll() {
        selection = .none
        selectionOrigin = nil
        rowOrigin = nil
        cursor = nil
    }

    /// A click on a data cell: plain selects it, ⌘ toggles it, ⇧ selects the block from the last clicked cell.
    public func click(_ cell: GridCell, extend: Bool, toggle: Bool) {
        if extend, let origin = selectionOrigin {
            selection = .cells(Self.block(from: origin, to: cell))
            cursor = cell
            return
        }
        if toggle, case .cells(var cells) = selection {
            if cells.contains(cell) { cells.remove(cell) } else { cells.insert(cell) }
            selection = cells.isEmpty ? .none : .cells(cells)
        } else {
            selection = .cells([cell])
        }
        selectionOrigin = cell
        cursor = cell
    }

    /// A drag from the cell where the mouse went down. With ⌘ the block is added to the cells already selected.
    public func drag(to cell: GridCell, adding base: Set<GridCell>) {
        guard let origin = selectionOrigin else { return }
        selection = .cells(base.union(Self.block(from: origin, to: cell)))
        cursor = cell
    }

    /// Arrow keys: move the selection to the neighbouring cell, or with ⇧ grow the block from the origin.
    public func moveSelection(rowBy rowDelta: Int, columnBy columnDelta: Int, extend: Bool) {
        let rows = table.rows.count
        let columns = max(1, table.columnCount)
        guard rows > 0 else { return }
        let from = cursor ?? selectionOrigin ?? GridCell(row: 0, column: 0)
        let next = GridCell(row: min(max(0, from.row + rowDelta), rows - 1), column: min(max(0, from.column + columnDelta), columns - 1))
        if selection == .none {
            click(GridCell(row: 0, column: 0), extend: false, toggle: false)
            return
        }
        click(next, extend: extend, toggle: false)
    }

    /// A click on a column header: plain selects the column, ⌘ toggles it, ⇧ selects the columns in between.
    public func clickColumn(_ column: Int, extend: Bool, toggle: Bool) {
        var columns: IndexSet = if case .columns(let current) = selection { current } else { [] }
        if extend, let last = columns.last ?? columns.first {
            columns.insert(integersIn: min(last, column)...max(last, column))
        } else if toggle {
            if columns.contains(column) { columns.remove(column) } else { columns.insert(column) }
        } else {
            columns = [column]
        }
        selection = columns.isEmpty ? .none : .columns(columns)
        selectionOrigin = nil
        cursor = nil
    }

    /// A click in the line-number column: selects the record, ⇧ extends the run of records.
    public func clickRow(_ row: Int, extend: Bool) {
        if extend, case .rows = selection, let origin = rowOrigin {
            selection = .rows(min(origin, row)...max(origin, row))
        } else {
            selection = .rows(row...row)
            rowOrigin = row
        }
        selectionOrigin = nil
        cursor = nil
    }

    /// Edit › Select All (⌘A): every record, as a drag down the line numbers would select them.
    public func selectAll() {
        guard !table.rows.isEmpty else { return }
        selection = .rows(0...(table.rows.count - 1))
        rowOrigin = 0
        selectionOrigin = nil
        cursor = nil
    }

    static func block(from origin: GridCell, to cell: GridCell) -> Set<GridCell> {
        var result: Set<GridCell> = []
        for row in min(origin.row, cell.row)...max(origin.row, cell.row) {
            for column in min(origin.column, cell.column)...max(origin.column, cell.column) {
                result.insert(GridCell(row: row, column: column))
            }
        }
        return result
    }

    public func isSelected(row: Int, column: Int) -> Bool {
        switch selection {
        case .none: false
        case .rows(let rows): rows.contains(row)
        case .columns(let columns): columns.contains(column)
        case .cells(let cells): cells.contains(GridCell(row: row, column: column))
        }
    }

    // MARK: Notes

    /// The selection as a note anchor: the records' source lines (the header line for columns), with the cells.
    public func selectionAnchor() -> TextAnchor? {
        let hash = Data(text.utf8).sha256Hex
        switch selection {
        case .none:
            return nil
        case .rows(let rows):
            guard let range = lineRange(rows: rows.lowerBound, rows.upperBound) else { return nil }
            return ReAnchorer.make(from: range, in: text, index: lineIndex, hash: hash)
        case .columns(let columns):
            guard !columns.isEmpty else { return nil }
            // The header record, which may span lines when a quoted name holds a newline.
            let headerLines = CSVParser.parse(String(text.prefix(65_536)), delimiter: table.delimiter, hasHeader: false).rows.first?.lastLine ?? 1
            let start = lineIndex.contentRange(ofLine: 1).location
            let end = lineIndex.contentRange(ofLine: headerLines)
            var anchor = ReAnchorer.make(from: NSRange(location: start, length: end.location + end.length - start), in: text, index: lineIndex, hash: hash)
            anchor.cells = CellSelection(columns: Array(columns), headers: columns.map { $0 < table.header.count ? table.header[$0] : "" })
            return anchor
        case .cells(let cells):
            guard let first = cells.map(\.row).min(), let last = cells.map(\.row).max(),
                  let range = lineRange(rows: first, last) else { return nil }
            var anchor = ReAnchorer.make(from: range, in: text, index: lineIndex, hash: hash)
            let startLine = table.rows[first].firstLine
            anchor.cells = CellSelection(cells: cells.map { CellRef(lineOffset: table.rows[$0.row].firstLine - startLine, column: $0.column) })
            return anchor
        }
    }

    private func lineRange(rows first: Int, _ last: Int) -> NSRange? {
        guard first >= 0, last < table.rows.count, first <= last else { return nil }
        let start = lineIndex.contentRange(ofLine: table.rows[first].firstLine).location
        let endRange = lineIndex.contentRange(ofLine: table.rows[last].lastLine)
        return NSRange(location: start, length: endRange.location + endRange.length - start)
    }

    public var hasSelection: Bool { selection != .none }
    /// Bumped on each copy, for the toolbar's brief "Copied".
    public internal(set) var copyCount = 0

    /// The selection as tab-separated text, the form spreadsheets paste into cells: whole records for rows, the
    /// header and values for columns, and for scattered cells the block that holds them with the gaps left empty.
    public func copyText() -> String? {
        // A tab or newline inside a value (or a header) would split it into the next cell or row.
        func flat(_ value: String) -> String { String(value.map { $0.isNewline || $0 == "\t" ? " " : $0 }) }
        func field(_ row: Int, _ column: Int) -> String {
            let fields = table.rows[row].fields
            return column < fields.count ? flat(fields[column]) : ""
        }
        switch selection {
        case .none:
            return nil
        case .rows(let rows):
            return rows.map { row in (0..<table.columnCount).map { field(row, $0) }.joined(separator: "\t") }.joined(separator: "\n")
        case .columns(let columns):
            let header = columns.map { $0 < table.header.count ? flat(table.header[$0]) : "" }.joined(separator: "\t")
            let body = table.rows.indices.map { row in columns.map { field(row, $0) }.joined(separator: "\t") }
            return ([header] + body).joined(separator: "\n")
        case .cells(let cells):
            guard let top = cells.map(\.row).min(), let bottom = cells.map(\.row).max(),
                  let left = cells.map(\.column).min(), let right = cells.map(\.column).max() else { return nil }
            return (top...bottom).map { row in
                (left...right).map { column in cells.contains(GridCell(row: row, column: column)) ? field(row, column) : "" }.joined(separator: "\t")
            }.joined(separator: "\n")
        }
    }

    public var selectionSummary: String? {
        switch selection {
        case .none:
            return nil
        case .rows(let rows):
            let first = table.rows[rows.lowerBound].firstLine
            let last = table.rows[rows.upperBound].lastLine
            return first == last ? "Line \(first)" : "Lines \(first)-\(last)"
        case .columns(let columns):
            let names = columns.map { column in
                let header = column < table.header.count ? table.header[column] : ""
                return header.isEmpty ? CellSelection.columnName(column) : "\(CellSelection.columnName(column)) (\(header))"
            }
            return (columns.count == 1 ? "Column " : "Columns ") + names.joined(separator: ", ")
        case .cells(let cells):
            if cells.count == 1, let cell = cells.first {
                return "Cell \(CellSelection.columnName(cell.column))\(table.rows[cell.row].firstLine)"
            }
            return "\(cells.count) cells"
        }
    }

    // MARK: Highlights

    /// The note tint for a cell: a cell or column note on it, else a row note on its record.
    public func highlight(row: Int, column: Int) -> TextHighlight? {
        cellHighlights[GridCell(row: row, column: column)] ?? columnHighlights[column] ?? rowHighlights[row]
    }

    /// Record indexes covered by row notes (notes without cells), for whole-row tinting.
    public func rowHighlight(_ row: Int) -> TextHighlight? { rowHighlights[row] }

    /// Where a note sits in the grid: its cells, its columns, or its records; nil when it isn't drawn.
    public func place(of id: NoteID) -> GridSelection? {
        let cells = Set(cellHighlights.filter { $0.value.id == id }.keys)
        if !cells.isEmpty { return .cells(cells) }
        let columns = IndexSet(columnHighlights.filter { $0.value.id == id }.keys)
        if !columns.isEmpty { return .columns(columns) }
        let rows = rowHighlights.filter { $0.value.id == id }.keys
        guard let first = rows.min(), let last = rows.max() else { return nil }
        return .rows(first...last)
    }

    /// The first cell of a note's place, row then column: where reading reaches it.
    public func firstCell(of id: NoteID) -> GridCell? {
        switch place(of: id) {
        case .cells(let cells)?: cells.min { ($0.row, $0.column) < ($1.row, $1.column) }
        case .columns(let columns)?: columns.first.map { GridCell(row: 0, column: $0) }
        case .rows(let rows)?: GridCell(row: rows.lowerBound, column: 0)
        case .none?, nil: nil
        }
    }

    /// Scrolls a note's first cell into sight (its card was clicked, or Next Note reached it).
    public func show(_ id: NoteID) {
        if let cell = firstCell(of: id) { onScroll(cell) }
    }

    private func rebuildHighlightMaps() {
        rowHighlights = [:]
        columnHighlights = [:]
        cellHighlights = [:]
        for highlight in highlights {
            let (start, end) = lineIndex.positions(for: highlight.range)
            if let cells = cellSelections[highlight.id] {
                if cells.isColumns {
                    for column in cells.columns { columnHighlights[column] = highlight }
                } else {
                    for cell in cells.cells {
                        guard let row = rowByFirstLine[start.line + cell.lineOffset] else { continue }
                        cellHighlights[GridCell(row: row, column: cell.column)] = highlight
                    }
                }
                continue
            }
            for (index, row) in table.rows.enumerated() where row.lastLine >= start.line && row.firstLine <= end.line {
                rowHighlights[index] = highlight
            }
        }
        onHighlightsChange()
    }
}

extension CSVGridController: FindBarModel {}
