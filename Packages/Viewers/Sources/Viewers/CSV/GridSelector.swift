import Foundation

/// How clicks, drags and arrow keys select in a grid of cells: the CSV grid and a rendered Markdown table select
/// the same way. A value; its owner publishes `selection`.
struct GridSelector: Equatable, Sendable {
    var selection: GridSelection = .none
    /// The cell a shift-click, drag, or shift-arrow extends from.
    var origin: GridCell?
    /// The row a shift-click on a row extends from.
    var rowOrigin: Int?
    /// The cell the arrow keys move from (the far corner of a shift-extended block).
    var cursor: GridCell?

    mutating func clear() {
        self = GridSelector()
    }

    /// A click on a cell: plain selects it, ⌘ toggles it, ⇧ selects the block from the last clicked cell.
    mutating func click(_ cell: GridCell, extend: Bool, toggle: Bool) {
        if extend, let origin {
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
        origin = cell
        cursor = cell
    }

    /// A drag from the cell where the mouse went down. With ⌘ the block is added to the cells already selected.
    mutating func drag(to cell: GridCell, adding base: Set<GridCell>) {
        guard let origin else { return }
        selection = .cells(base.union(Self.block(from: origin, to: cell)))
        cursor = cell
    }

    /// Arrow keys: move to the neighbouring cell, or with ⇧ grow the block from the origin. Nothing selected
    /// selects the first cell.
    mutating func move(rowBy rowDelta: Int, columnBy columnDelta: Int, extend: Bool, rows: Int, columns: Int) {
        guard rows > 0, columns > 0 else { return }
        if selection == .none {
            click(GridCell(row: 0, column: 0), extend: false, toggle: false)
            return
        }
        let from = cursor ?? origin ?? GridCell(row: 0, column: 0)
        let next = GridCell(row: min(max(0, from.row + rowDelta), rows - 1), column: min(max(0, from.column + columnDelta), columns - 1))
        click(next, extend: extend, toggle: false)
    }

    /// A click on a column's header or handle: plain selects the column, ⌘ toggles it, ⇧ selects the columns in
    /// between.
    mutating func clickColumn(_ column: Int, extend: Bool, toggle: Bool) {
        var columns: IndexSet = if case .columns(let current) = selection { current } else { [] }
        if extend, let last = columns.last ?? columns.first {
            columns.insert(integersIn: min(last, column)...max(last, column))
        } else if toggle {
            if columns.contains(column) { columns.remove(column) } else { columns.insert(column) }
        } else {
            columns = [column]
        }
        selection = columns.isEmpty ? .none : .columns(columns)
        origin = nil
        cursor = nil
    }

    /// A click on a row's number or handle: selects the row, ⇧ extends the run of rows.
    mutating func clickRow(_ row: Int, extend: Bool) {
        if extend, case .rows = selection, let rowOrigin {
            selection = .rows(min(rowOrigin, row)...max(rowOrigin, row))
        } else {
            selection = .rows(row...row)
            rowOrigin = row
        }
        origin = nil
        cursor = nil
    }

    /// ⌘ on a row's handle: adds the row's cells to what is selected, or takes them away when they all are.
    /// Rows that aren't next to each other are a set of cells, as a note covers one run of lines.
    mutating func toggleRow(_ row: Int, columns: Int) {
        guard columns > 0 else { return }
        var cells: Set<GridCell> = switch selection {
        case .none: []
        case .cells(let cells): cells
        case .rows(let rows): Set(rows.flatMap { row in (0..<columns).map { GridCell(row: row, column: $0) } })
        // Whole columns become cells only in rows the caller knows of; start again with the row.
        case .columns: []
        }
        let rowCells = (0..<columns).map { GridCell(row: row, column: $0) }
        if rowCells.allSatisfy(cells.contains) { cells.subtract(rowCells) } else { cells.formUnion(rowCells) }
        selection = cells.isEmpty ? .none : .cells(cells)
        origin = nil
        cursor = nil
        rowOrigin = row
    }

    /// Every row, as a drag down the row numbers would select them.
    mutating func selectAllRows(_ count: Int) {
        guard count > 0 else { return }
        selection = .rows(0...(count - 1))
        rowOrigin = 0
        origin = nil
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

    func contains(row: Int, column: Int) -> Bool {
        selection.contains(row: row, column: column)
    }
}

extension GridSelection {
    func contains(row: Int, column: Int) -> Bool {
        switch self {
        case .none: false
        case .rows(let rows): rows.contains(row)
        case .columns(let columns): columns.contains(column)
        case .cells(let cells): cells.contains(GridCell(row: row, column: column))
        }
    }
}
