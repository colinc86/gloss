import AppKit

/// A cell of one of the rendered page's tables.
struct TableCellPlace: Equatable {
    var table: Int
    var row: Int
    var column: Int
}

/// The handles that show beside the cell under the pointer: one on its column's top edge selects the column, one on
/// its row's left edge the row.
enum TableHandle: Equatable {
    case column(table: Int, column: Int)
    case row(table: Int, row: Int)
}

/// Selecting a rendered table's cells, rows and columns, as the CSV grid does. A drag that stays in one cell selects
/// its text; one that crosses into another cell selects the cells between. ⌘-click toggles a cell, ⇧-click extends
/// the block, and the handles beside the hovered cell pick its whole column or row (⌘ adds, ⇧ extends).
extension RenderedTextView {
    /// Each table's rows (their paragraphs), by table id.
    static func tableRows(in text: NSAttributedString) -> [Int: [NSRange]] {
        var rows: [Int: [NSRange]] = [:]
        text.enumerateAttribute(MarkdownRenderer.blockKey, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let chrome = (value as? MarkdownBlockDecoration)?.table else { return }
            rows[chrome.id, default: []].append(range)
        }
        return rows
    }

    /// The left edge of each column of a row and the right edge of its last, in container coordinates.
    static func columnEdges(_ row: CGRect, _ chrome: MarkdownBlockDecoration.TableChrome) -> [CGFloat] {
        [row.minX] + chrome.dividers + [row.maxX]
    }

    /// A row's frame cut to where its table shows (all of it unless it scrolls sideways).
    static func shown(_ rect: CGRect, _ chrome: MarkdownBlockDecoration.TableChrome) -> CGRect? {
        guard chrome.overflow > 0 else { return rect }
        let cut = rect.intersection(CGRect(x: chrome.visible.lowerBound, y: rect.minY, width: chrome.visible.upperBound - chrome.visible.lowerBound, height: rect.height))
        return cut.isNull || cut.width <= 0 ? nil : cut
    }

    /// Which row of its table a laid-out row is.
    func rowIndex(of fragment: NSTextLayoutFragment, table: Int) -> Int? {
        guard let contentManager = textLayoutManager?.textContentManager, let rows = tableRowRanges[table] else { return nil }
        let offset = contentManager.offset(from: contentManager.documentRange.location, to: fragment.rangeInElement.location)
        // The last row starting at or before the offset (rows are in order).
        var low = 0, high = rows.count
        while low < high {
            let middle = (low + high) / 2
            if rows[middle].location <= offset { low = middle + 1 } else { high = middle }
        }
        guard low > 0, rows[low - 1].location == offset || NSLocationInRange(offset, rows[low - 1]) else { return nil }
        return low - 1
    }

    /// A row of a table laid out (if it wasn't): its outline and chrome, in container coordinates.
    func rowLayout(table: Int, row: Int) -> (frame: CGRect, chrome: MarkdownBlockDecoration.TableChrome)? {
        guard let rows = tableRowRanges[table], row >= 0, row < rows.count, let layoutManager = textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let location = contentManager.location(contentManager.documentRange.location, offsetBy: rows[row].location) else { return nil }
        layoutManager.ensureLayout(for: NSTextRange(location: location))
        guard let fragment = layoutManager.textLayoutFragment(for: location) as? MarkdownLayoutFragment, let chrome = fragment.decoration.table,
              let frame = fragment.tableRowFrame else { return nil }
        return (frame, chrome)
    }

    /// A cell's rect in view coordinates, cut to what shows of its table.
    func cellRect(_ place: TableCellPlace) -> CGRect? {
        guard let (frame, chrome) = rowLayout(table: place.table, row: place.row) else { return nil }
        let edges = Self.columnEdges(frame, chrome)
        guard place.column >= 0, place.column + 1 < edges.count else { return nil }
        let rect = CGRect(x: edges[place.column], y: frame.minY, width: edges[place.column + 1] - edges[place.column], height: frame.height)
        return Self.shown(rect, chrome)?.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    /// The cell of a selectable table under `point` (view coordinates).
    func tableCell(at point: NSPoint) -> TableCellPlace? {
        guard let controller, !controller.tables.isEmpty, let layoutManager = textLayoutManager else { return nil }
        let origin = textContainerOrigin
        let inContainer = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        guard inContainer.y >= 0, let fragment = layoutManager.textLayoutFragment(for: inContainer) as? MarkdownLayoutFragment,
              let chrome = fragment.decoration.table, controller.tables[chrome.id] != nil, let frame = fragment.tableRowFrame,
              let shown = Self.shown(frame, chrome), shown.contains(inContainer),
              let row = rowIndex(of: fragment, table: chrome.id) else { return nil }
        let edges = Self.columnEdges(frame, chrome)
        let column = max(0, (edges.dropFirst().firstIndex { inContainer.x < $0 } ?? edges.count - 1) - 1)
        return TableCellPlace(table: chrome.id, row: row, column: min(column, edges.count - 2))
    }

    /// The cell of `table` nearest `point`: the pointer's cell, or the edge cell beside or past the table while a
    /// drag goes outside it.
    func nearestCell(in table: Int, to point: NSPoint) -> TableCellPlace? {
        if let hit = tableCell(at: point), hit.table == table { return hit }
        guard let rows = tableRowRanges[table], !rows.isEmpty else { return nil }
        let origin = textContainerOrigin
        let inContainer = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        // The first row whose bottom is below the point, found by halving (rows are laid out top to bottom), so a
        // drag below a long table doesn't lay out every row on every move.
        var low = 0, high = rows.count - 1
        while low < high {
            let middle = (low + high) / 2
            if let (frame, _) = rowLayout(table: table, row: middle), inContainer.y >= frame.maxY { low = middle + 1 } else { high = middle }
        }
        let row = low
        guard let (frame, chrome) = rowLayout(table: table, row: row) else { return nil }
        let edges = Self.columnEdges(frame, chrome)
        let x = Self.shown(frame, chrome).map { min(max(inContainer.x, $0.minX), $0.maxX - 1) } ?? inContainer.x
        let column = (edges.dropFirst().firstIndex { x < $0 } ?? edges.count - 1) - 1
        return TableCellPlace(table: table, row: row, column: min(max(0, column), edges.count - 2))
    }

    // MARK: Handles

    static let handleLength: CGFloat = 22
    static let handleThickness: CGFloat = 8

    /// Where the hovered cell's handles are, in view coordinates: the column's on its table's top edge (or the top
    /// of what shows of it), the row's on the table's left edge.
    func handleRects() -> [(handle: TableHandle, rect: CGRect)] {
        guard let cell = hoveredCell, let (rowFrame, chrome) = rowLayout(table: cell.table, row: cell.row),
              let (headerFrame, _) = rowLayout(table: cell.table, row: 0) else { return [] }
        let origin = textContainerOrigin
        var result: [(TableHandle, CGRect)] = []
        let edges = Self.columnEdges(rowFrame, chrome)
        if cell.column + 1 < edges.count,
           let column = Self.shown(CGRect(x: edges[cell.column], y: rowFrame.minY, width: edges[cell.column + 1] - edges[cell.column], height: 1), chrome) {
            let visibleTop = visibleRect.minY - origin.y + Self.handleThickness
            let top = min(max(headerFrame.minY, visibleTop), rowFrame.minY)
            let rect = CGRect(x: column.midX - Self.handleLength / 2, y: top - Self.handleThickness / 2, width: Self.handleLength, height: Self.handleThickness)
            result.append((.column(table: cell.table, column: cell.column), rect.offsetBy(dx: origin.x, dy: origin.y)))
        }
        if let shown = Self.shown(rowFrame, chrome) {
            let length = min(Self.handleLength, max(10, rowFrame.height - 6))
            let rect = CGRect(x: shown.minX - Self.handleThickness / 2, y: rowFrame.midY - length / 2, width: Self.handleThickness, height: length)
            result.append((.row(table: cell.table, row: cell.row), rect.offsetBy(dx: origin.x, dy: origin.y)))
        }
        return result
    }

    /// The handle under `point` (view coordinates), with a little room around it.
    func tableHandle(at point: NSPoint) -> TableHandle? {
        handleRects().first { $0.rect.insetBy(dx: -5, dy: -5).contains(point) }?.handle
    }

    /// The pointer moved: the cell it is over shows its handles, which stay while the pointer goes onto them.
    func updateTableHover(at point: NSPoint) {
        let handle = tableHandle(at: point)
        if handle == nil { hoveredCell = tableCell(at: point) }
        if handle != hoveredHandle { hoveredHandle = handle }
    }

    /// A press on a handle: the column or row, with ⌘ added (or taken away) and with ⇧ extended.
    func pressHandle(_ handle: TableHandle, with event: NSEvent) {
        guard let controller else { return }
        window?.makeFirstResponder(self)
        collapseTextSelection()
        controller.imageSelection = nil
        let extend = event.modifierFlags.contains(.shift), toggle = event.modifierFlags.contains(.command)
        switch handle {
        case .column(let table, let column): controller.selectTableColumn(table: table, column: column, extend: extend, toggle: toggle)
        case .row(let table, let row): controller.selectTableRow(table: table, row: row, extend: extend, toggle: toggle)
        }
        refreshTableOverlay()
    }

    // MARK: Cells

    /// ⌘ or ⇧ pressed in a cell: toggles it or extends the block to it, and a drag goes on to select the block
    /// it sweeps. False when the press is for the text (no modifier, or ⇧ with no cells selected in that table).
    func pressCell(with event: NSEvent, at point: NSPoint) -> Bool {
        guard let controller, event.clickCount == 1, let cell = tableCell(at: point) else { return false }
        let toggle = event.modifierFlags.contains(.command)
        var extend = false
        if !toggle, event.modifierFlags.contains(.shift), let selected = controller.tableSelection, selected.table == cell.table,
           case .cells = selected.selection {
            extend = true
        }
        guard toggle || extend else { return false }
        window?.makeFirstResponder(self)
        collapseTextSelection()
        controller.imageSelection = nil
        var base: Set<GridCell> = []
        if toggle, let selected = controller.tableSelection, selected.table == cell.table, case .cells(let cells) = selected.selection { base = cells }
        controller.selectTableCell(table: cell.table, row: cell.row, column: cell.column, extend: extend, toggle: toggle)
        // With ⌘ a cell clicked off again leaves the rest; a drag from it adds its block to them.
        if toggle, base.contains(GridCell(row: cell.row, column: cell.column)) { base.remove(GridCell(row: cell.row, column: cell.column)) }
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            guard let over = nearestCell(in: cell.table, to: convert(next.locationInWindow, from: nil)) else { continue }
            if extend {
                controller.selectTableCell(table: over.table, row: over.row, column: over.column, extend: true, toggle: false)
            } else if over != cell {
                controller.dragTableCell(table: over.table, row: over.row, column: over.column, adding: base)
            }
            autoscroll(with: next)
            refreshTableOverlay()
        }
        refreshTableOverlay()
        return true
    }

    /// The selection becomes the caret at its start, so text and cells are never selected at once.
    func collapseTextSelection() {
        let selected = selectedRange()
        if selected.length > 0 { setSelectedRange(NSRange(location: selected.location, length: 0)) }
    }

    /// Where the table selection is, in top-left window coordinates: the rect from its first to its last cell,
    /// cut to what is on screen when some of it is.
    func tableSelectionWindowRect(_ selected: MarkdownViewerController.TableSelection) -> CGRect? {
        guard let layout = controller?.tables[selected.table], layout.columns > 0, !layout.rowLines.isEmpty else { return nil }
        let rows: ClosedRange<Int>, columns: ClosedRange<Int>
        switch selected.selection {
        case .none:
            return nil
        case .rows(let range):
            (rows, columns) = (range, 0...(layout.columns - 1))
        case .columns(let set):
            guard let first = set.first, let last = set.last else { return nil }
            (rows, columns) = (0...(layout.rowLines.count - 1), first...last)
        case .cells(let cells):
            guard let top = cells.map(\.row).min(), let bottom = cells.map(\.row).max(),
                  let left = cells.map(\.column).min(), let right = cells.map(\.column).max() else { return nil }
            (rows, columns) = (top...bottom, left...right)
        }
        // The corners, or as near them as shows of a wide table.
        let corners = [TableCellPlace(table: selected.table, row: rows.lowerBound, column: columns.lowerBound),
                       TableCellPlace(table: selected.table, row: rows.upperBound, column: columns.upperBound),
                       TableCellPlace(table: selected.table, row: rows.lowerBound, column: columns.upperBound),
                       TableCellPlace(table: selected.table, row: rows.upperBound, column: columns.lowerBound)]
        guard let union = corners.compactMap(cellRect).reduce(nil, { (union: CGRect?, rect) in union.map { $0.union(rect) } ?? rect }) else { return nil }
        let onScreen = union.intersection(visibleRect)
        return topLeftWindowRect(onScreen.isNull || onScreen.isEmpty ? union : onScreen)
    }

    /// Scrolls the cell the arrow keys are on into sight, sideways in a wide table too.
    func revealTableCursor() {
        guard let controller, let selected = controller.tableSelection, let cursor = controller.tableCursor,
              let rows = tableRowRanges[selected.table], cursor.row < rows.count else { return }
        let piece = controller.cellTexts(selected.table).flatMap { texts in
            cursor.row < texts.count && cursor.column < texts[cursor.row].count ? texts[cursor.row][cursor.column].ranges.first : nil
        }
        scrollRangeToVisible(piece ?? NSRange(location: rows[cursor.row].location, length: 0))
        refreshTableOverlay()
    }

    // MARK: Drawing

    /// Draws the table selection and handles again when there are any, or were last time (to take them away). The
    /// overlay is made when first needed.
    func refreshTableOverlay() {
        let wanted = controller?.tableSelection != nil || hoveredCell != nil
        if tableOverlay == nil {
            guard wanted else { return }
            let overlay = TableSelectionOverlayView(frame: bounds)
            overlay.autoresizingMask = [.width, .height]
            overlay.textView = self
            addSubview(overlay, positioned: .above, relativeTo: nil)
            tableOverlay = overlay
        }
        guard let overlay = tableOverlay, wanted || overlay.showing else { return }
        overlay.showing = wanted
        overlay.needsDisplay = true
    }

    /// The table selection over the cells on screen: a tint in each selected cell and the accent around the
    /// selection's outer edges; then the hovered cell's handles.
    func drawTableSelection(in dirtyRect: CGRect) {
        guard let controller, let layoutManager = textLayoutManager else { return }
        let origin = textContainerOrigin
        let accent = window?.isKeyWindow == false ? NSColor.secondaryLabelColor : NSColor.controlAccentColor
        if let selected = controller.tableSelection, let viewport = layoutManager.textViewportLayoutController.viewportRange {
            layoutManager.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
                guard fragment.rangeInElement.location.compare(viewport.endLocation) == .orderedAscending else { return false }
                guard let fragment = fragment as? MarkdownLayoutFragment, let chrome = fragment.decoration.table, chrome.id == selected.table,
                      let frame = fragment.tableRowFrame, let row = rowIndex(of: fragment, table: chrome.id),
                      let shown = Self.shown(frame, chrome) else { return true }
                let edges = Self.columnEdges(frame, chrome)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: shown.offsetBy(dx: origin.x, dy: origin.y)).addClip()
                for column in 0..<(edges.count - 1) where selected.selection.contains(row: row, column: column) {
                    let cell = CGRect(x: edges[column], y: frame.minY, width: edges[column + 1] - edges[column], height: frame.height)
                        .offsetBy(dx: origin.x, dy: origin.y)
                    guard cell.intersects(dirtyRect) else { continue }
                    accent.withAlphaComponent(0.16).setFill()
                    cell.fill()
                    accent.setFill()
                    let line: CGFloat = 2
                    if !selected.selection.contains(row: row - 1, column: column) { CGRect(x: cell.minX, y: cell.minY, width: cell.width, height: line).fill() }
                    if !selected.selection.contains(row: row + 1, column: column) { CGRect(x: cell.minX, y: cell.maxY - line, width: cell.width, height: line).fill() }
                    if !selected.selection.contains(row: row, column: column - 1) { CGRect(x: cell.minX, y: cell.minY, width: line, height: cell.height).fill() }
                    if !selected.selection.contains(row: row, column: column + 1) { CGRect(x: cell.maxX - line, y: cell.minY, width: line, height: cell.height).fill() }
                }
                NSGraphicsContext.restoreGraphicsState()
                return true
            }
        }
        for (handle, rect) in handleRects() {
            let selected: Bool = switch (handle, controller.tableSelection?.selection) {
            case (.column(let table, let column), .columns(let columns)?): controller.tableSelection?.table == table && columns.contains(column)
            case (.row(let table, let row), .rows(let rows)?): controller.tableSelection?.table == table && rows.contains(row)
            default: false
            }
            let hot = selected || hoveredHandle == handle
            let path = NSBezierPath(roundedRect: rect, xRadius: Self.handleThickness / 2, yRadius: Self.handleThickness / 2)
            (hot ? NSColor.controlAccentColor : NSColor.controlBackgroundColor).setFill()
            path.fill()
            (hot ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
            path.lineWidth = 1
            path.stroke()
            // Three dots along it, as a grip.
            (hot ? NSColor.white : NSColor.secondaryLabelColor).setFill()
            let vertical = rect.height > rect.width
            for step in -1...1 {
                let center = vertical ? CGPoint(x: rect.midX, y: rect.midY + CGFloat(step) * 4) : CGPoint(x: rect.midX + CGFloat(step) * 4, y: rect.midY)
                NSBezierPath(ovalIn: CGRect(x: center.x - 1, y: center.y - 1, width: 2, height: 2)).fill()
            }
        }
    }
}

/// Draws a table selection and the hovered cell's handles over the rendered text; clicks go through to the text.
final class TableSelectionOverlayView: NSView {
    weak var textView: RenderedTextView?
    /// Whether it last drew a selection or handles.
    var showing = false

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        textView?.drawTableSelection(in: dirtyRect)
    }
}
