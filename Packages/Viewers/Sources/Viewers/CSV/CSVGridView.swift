import AppKit
import Core
import SwiftUI

public struct CSVGridView: NSViewRepresentable {
    public let controller: CSVGridController

    public init(controller: CSVGridController) {
        self.controller = controller
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let table = CSVTableView()
        // Stripes come from `CSVTableView.drawBackground`, behind records only.
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = false
        table.allowsColumnSelection = false
        table.allowsColumnReordering = false
        table.selectionHighlightStyle = .none
        table.rowSizeStyle = .small
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.style = .plain
        // Source line of each record; clicking it selects rows.
        let numbers = NSTableColumn(identifier: Coordinator.lineColumn)
        numbers.title = "Line"
        numbers.width = 44
        numbers.minWidth = 32
        table.addTableColumn(numbers)
        let columns = max(1, controller.table.columnCount)
        for index in 0..<columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col\(index)"))
            let header = index < controller.table.header.count ? controller.table.header[index] : ""
            column.title = header.isEmpty ? CellSelection.columnName(index) : "\(CellSelection.columnName(index))  \(header)"
            // The letter quiet, the name strong; numeric columns align their header right like their values.
            let title = NSMutableAttributedString(string: CellSelection.columnName(index), attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.tertiaryLabelColor,
            ])
            if !header.isEmpty {
                title.append(NSAttributedString(string: "  " + header, attributes: [
                    .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: NSColor.labelColor,
                ]))
            }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = controller.numericColumns.contains(index) ? .right : .left
            paragraph.lineBreakMode = .byTruncatingTail
            title.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: title.length))
            column.headerCell.attributedStringValue = title
            column.headerToolTip = "Click to select column \(CellSelection.columnName(index)); ⌘-click to add columns"
            column.width = controller.columnWidths[index]
            column.minWidth = 40
            table.addTableColumn(column)
        }
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.coordinator = context.coordinator
        context.coordinator.table = table
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        controller.onHighlightsChange = { [weak coordinator = context.coordinator] in coordinator?.refreshAppearance() }
        controller.onSelectionChange = { [weak coordinator = context.coordinator] in coordinator?.refreshAppearance() }
        controller.onScroll = { [weak table] cell in
            table?.scrollRowToVisible(cell.row)
            table?.scrollColumnToVisible(cell.column + 1)
        }
        controller.rectProvider = { [weak coordinator = context.coordinator] selection in coordinator?.rect(for: selection) }
        controller.noteGeometry.viewport = { [weak table] in
            guard let table, table.window != nil else { return nil }
            return table.topLeftWindowRect(table.visibleRect)
        }
        controller.noteGeometry.visibleNoteRects = { [weak coordinator = context.coordinator] in coordinator?.visibleNoteRects() ?? [:] }
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak controller] _ in
            MainActor.assumeIsolated { controller?.noteGeometry.changed() }
        }
        return scroll
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.refreshAppearance()
    }

    public static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        if let observer = coordinator.scrollObserver { NotificationCenter.default.removeObserver(observer) }
        coordinator.scrollObserver = nil
    }

    @MainActor
    public final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let lineColumn = NSUserInterfaceItemIdentifier("line")
        let controller: CSVGridController
        weak var table: NSTableView?

        init(controller: CSVGridController) {
            self.controller = controller
        }

        var scrollObserver: (any NSObjectProtocol)?

        /// Each note's cells on screen: a row note as its rows, a cell or column note as its cells (the overlay joins
        /// touching ones into one outline).
        func visibleNoteRects() -> [NoteID: [CGRect]] {
            guard let table, table.window != nil else { return [:] }
            let visible = table.visibleRect
            let rows = table.rows(in: visible)
            let columns = table.columnIndexes(in: visible)
            var result: [NoteID: [CGRect]] = [:]
            func add(_ id: NoteID, _ rect: CGRect) {
                let clipped = rect.intersection(visible)
                guard !clipped.isNull, !clipped.isEmpty, let window = table.topLeftWindowRect(clipped) else { return }
                result[id, default: []].append(window)
            }
            for row in rows.location..<(rows.location + rows.length) {
                let rowNote = controller.rowHighlight(row)
                if let rowNote { add(rowNote.id, table.rect(ofRow: row)) }
                for tableColumn in columns {
                    guard let column = dataColumn(tableColumn), let highlight = controller.highlight(row: row, column: column),
                          highlight != rowNote else { continue }
                    add(highlight.id, table.frameOfCell(atColumn: tableColumn, row: row))
                }
            }
            return result
        }

        /// Data column for a table column index; nil for the line-number column.
        func dataColumn(_ tableColumn: Int) -> Int? {
            tableColumn >= 1 ? tableColumn - 1 : nil
        }

        func rowColor(_ row: Int) -> NSColor? {
            guard let highlight = controller.rowHighlight(row) else { return nil }
            // Softer than a text highlight: a whole row of colour drowns the values; the rail carries the colour.
            return Theme.color(for: highlight.color).withAlphaComponent(0.12 * Theme.strength(for: highlight.state))
        }

        /// Repaints row tints, cell tints, and the selection on the rows that are on screen.
        func refreshAppearance() {
            guard let table else { return }
            controller.noteGeometry.changed()
            table.enumerateAvailableRowViews { rowView, row in
                rowView.backgroundColor = rowColor(row) ?? .clear
                for column in 0..<table.numberOfColumns {
                    guard let cell = table.view(atColumn: column, row: row, makeIfNecessary: false) as? CSVCellView else { continue }
                    configure(cell, row: row, tableColumn: column)
                }
            }
        }

        private func configure(_ cell: CSVCellView, row: Int, tableColumn: Int) {
            guard let column = dataColumn(tableColumn) else {
                cell.isSelected = controller.isSelected(row: row, column: -1)   // true only for a row selection
                cell.tint = nil
                // A row note's colour as a bar beside its line number, like the editor's gutter.
                cell.rail = controller.rowHighlight(row).map { Theme.color(for: $0.color) }
                return
            }
            cell.rail = nil
            cell.isSelected = controller.isSelected(row: row, column: column)
            // Row notes tint the whole row view; cell and column notes tint just their cells.
            let highlight = controller.highlight(row: row, column: column)
            cell.tint = highlight.flatMap { controller.rowHighlight(row) == $0 ? nil : Theme.highlightBackground(for: $0.highlight) }
        }

        func rect(for selection: GridSelection) -> CGRect? {
            guard let table else { return nil }
            var union: CGRect?
            func add(_ rect: CGRect) { union = union.map { $0.union(rect) } ?? rect }
            switch selection {
            case .none:
                return nil
            case .rows(let rows):
                add(table.rect(ofRow: rows.lowerBound).union(table.rect(ofRow: rows.upperBound)))
            case .columns(let columns):
                // The visible part of the column, so the Add Note button sits beside what the user sees.
                for column in columns { add(table.rect(ofColumn: column + 1).intersection(table.visibleRect)) }
            case .cells(let cells):
                for cell in cells { add(table.frameOfCell(atColumn: cell.column + 1, row: cell.row)) }
            }
            guard let rect = union, !rect.isNull, !rect.isEmpty else { return nil }
            return table.topLeftWindowRect(rect)
        }

        public func numberOfRows(in tableView: NSTableView) -> Int {
            controller.table.rows.count
        }

        public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn else { return nil }
            let tableColumnIndex = tableView.column(withIdentifier: tableColumn.identifier)
            let identifier = NSUserInterfaceItemIdentifier("cell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? CSVCellView ?? CSVCellView(identifier: identifier)
            if let column = dataColumn(tableColumnIndex) {
                let fields = controller.table.rows[row].fields
                let numeric = controller.numericColumns.contains(column)
                cell.textField?.stringValue = column < fields.count ? fields[column] : ""
                cell.textField?.textColor = .labelColor
                cell.textField?.alignment = numeric ? .right : .natural
                cell.textField?.font = numeric ? .monospacedDigitSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12)
            } else {
                cell.textField?.stringValue = "\(controller.table.rows[row].firstLine)"
                cell.textField?.textColor = .tertiaryLabelColor
                cell.textField?.alignment = .right
                cell.textField?.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
            }
            configure(cell, row: row, tableColumn: tableColumnIndex)
            return cell
        }

        public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = NSTableRowView()
            view.backgroundColor = rowColor(row) ?? .clear
            return view
        }

        /// The table's own row selection is unused; the controller holds the grid selection.
        public func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet {
            []
        }

        public func tableView(_ tableView: NSTableView, mouseDownInHeaderOf tableColumn: NSTableColumn) {
            let index = tableView.column(withIdentifier: tableColumn.identifier)
            guard let column = dataColumn(index) else { return }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            controller.clickColumn(column, extend: flags.contains(.shift), toggle: flags.contains(.command))
            tableView.window?.makeFirstResponder(tableView)
        }
    }
}

/// The grid's table: clicks and drags select cells, records (line-number column), never the table's own rows.
final class CSVTableView: NSTableView {
    weak var coordinator: CSVGridView.Coordinator?

    /// Zebra stripes behind the records only: under a short file the pane stays a plain page, not an endless sheet.
    override func drawBackground(inClipRect clipRect: NSRect) {
        backgroundColor.setFill()
        clipRect.fill()
        let rows = rows(in: clipRect)
        guard rows.length > 0, let stripe = NSColor.alternatingContentBackgroundColors.dropFirst().first else { return }
        stripe.setFill()
        for row in rows.location..<(rows.location + rows.length) where row % 2 == 1 {
            rect(ofRow: row).intersection(clipRect).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let coordinator else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        let tableColumn = column(at: point)
        guard row >= 0, tableColumn >= 0 else {
            coordinator.controller.deselectAll()
            return
        }
        let controller = coordinator.controller
        let flags = event.modifierFlags
        guard let column = coordinator.dataColumn(tableColumn) else {
            controller.clickRow(row, extend: flags.contains(.shift))
            trackDrag(from: (row, tableColumn)) { target, _ in
                if let target { controller.clickRow(target.row, extend: true) }
            }
            return
        }
        let cell = GridCell(row: row, column: column)
        controller.click(cell, extend: flags.contains(.shift), toggle: flags.contains(.command))
        // A ⌘-drag adds a block to what is selected after the click (so a ⌘-click that removed this cell keeps it out).
        let base: Set<GridCell> = if flags.contains(.command), case .cells(let cells) = controller.selection { cells } else { [] }
        trackDrag(from: (row, tableColumn)) { target, dataColumn in
            guard let target, let dataColumn else { return }
            controller.drag(to: GridCell(row: target.row, column: dataColumn), adding: base)
        }
    }

    /// Follows the mouse until it is released, reporting the cell under it (clamped to the grid) once it leaves the
    /// cell where it went down. Periodic events keep autoscrolling while the pointer rests past an edge.
    private func trackDrag(from start: (Int, Int), _ moved: (_ target: (row: Int, column: Int)?, _ dataColumn: Int?) -> Void) {
        guard let window else { return }
        var last: (Int, Int)? = start
        var lastDrag: NSEvent?
        NSEvent.startPeriodicEvents(afterDelay: 0.1, withPeriod: 0.05)
        defer { NSEvent.stopPeriodicEvents() }
        while true {
            // A mouse-up can go missing (a very quick click, the app losing focus mid-drag); waiting for it forever
            // left the whole app deaf, quit included. Periodic events stop in some of those states too, so the wait
            // itself times out and the button's real state decides.
            let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic],
                                         until: Date(timeIntervalSinceNow: 0.1), inMode: .eventTracking, dequeue: true)
            // Only on a timeout: queued drags still count when the release has already happened in hardware.
            guard let event else {
                if NSEvent.pressedMouseButtons & 1 == 0 { break }
                continue
            }
            if event.type == .leftMouseUp { break }
            if event.type == .leftMouseDragged { lastDrag = event }
            guard let drag = lastDrag else { continue }
            autoscroll(with: drag)
            let point = convert(drag.locationInWindow, from: nil)
            let row = row(at: point) >= 0 ? row(at: point) : (point.y < 0 ? 0 : numberOfRows - 1)
            let column = column(at: point) >= 0 ? column(at: point) : (point.x < 0 ? 1 : numberOfColumns - 1)
            guard row >= 0, column >= 0, last.map({ $0 != (row, column) }) ?? true else { continue }
            last = (row, column)
            moved((row, column), coordinator?.dataColumn(column) ?? 0)
        }
    }

    /// Edit › Copy (⌘C): the selected rows, columns, or cells as tab-separated text.
    @objc func copy(_ sender: Any?) {
        guard let text = coordinator?.controller.copyText() else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        coordinator?.controller.copyCount += 1
    }

    /// Add Note on the cells, columns or rows selected, and Copy: the grid has no other menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let controller = coordinator?.controller, controller.hasSelection else { return nil }
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "").target = self
        AddNoteMenuItem.insert(into: menu, when: controller.addNote?.canAdd() ?? false, target: self, action: #selector(addNoteFromMenu(_:)))
        return menu
    }

    @objc func addNoteFromMenu(_ sender: Any?) { coordinator?.controller.addNote?.add() }

    /// Edit › Select All: the grid's own selection of every record (the table view's row selection is off).
    override func selectAll(_ sender: Any?) {
        coordinator?.controller.selectAll()
    }

    /// Edit › Find, Find Next and Find Previous: a table view takes no find actions itself.
    override func performTextFinderAction(_ sender: Any?) {
        if let action = FindMenuAction.action(of: sender) { coordinator?.controller.perform(action) }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return coordinator?.controller.hasSelection ?? false }
        if item.action == #selector(performTextFinderAction(_:)) { return FindMenuAction.action(of: item) != nil }
        if item.action == #selector(selectAll(_:)) { return !(coordinator?.controller.table.rows.isEmpty ?? true) }
        return super.validateUserInterfaceItem(item)
    }

    override func keyDown(with event: NSEvent) {
        guard let controller = coordinator?.controller else { return super.keyDown(with: event) }
        let extend = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 53: controller.deselectAll()                                        // escape
        case 123: controller.moveSelection(rowBy: 0, columnBy: -1, extend: extend) // left
        case 124: controller.moveSelection(rowBy: 0, columnBy: 1, extend: extend)  // right
        case 125: controller.moveSelection(rowBy: 1, columnBy: 0, extend: extend)  // down
        case 126: controller.moveSelection(rowBy: -1, columnBy: 0, extend: extend) // up
        default: return super.keyDown(with: event)
        }
        if let cursor = controller.cursorCell { scrollRowToVisible(cursor.row); scrollColumnToVisible(cursor.column + 1) }
    }
}

/// A grid cell that paints its note tint and the selection behind its text.
final class CSVCellView: NSTableCellView {
    var tint: NSColor? {
        didSet { if tint != oldValue { needsDisplay = true } }
    }
    var isSelected = false {
        didSet { if isSelected != oldValue { needsDisplay = true } }
    }
    /// A note colour drawn as a bar at the leading edge (line-number cells).
    var rail: NSColor? {
        didSet { if rail != oldValue { needsDisplay = true } }
    }

    convenience init(identifier: NSUserInterfaceItemIdentifier) {
        self.init(frame: .zero)
        self.identifier = identifier
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        if let tint {
            tint.setFill()
            bounds.fill()
        }
        if let rail {
            rail.setFill()
            NSBezierPath(roundedRect: NSRect(x: 3, y: 3, width: 3, height: bounds.height - 6), xRadius: 1.5, yRadius: 1.5).fill()
        }
        if isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
            bounds.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
            let outline = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.stroke()
        }
        super.draw(dirtyRect)
    }
}

/// Grid with a status line.
public struct CSVGridPane: View {
    public let controller: CSVGridController

    public init(controller: CSVGridController) {
        self.controller = controller
    }

    static let idleHints = [
        ToolHint(symbol: "cursorarrow.click", "Click a cell", explained: "Click a cell to select it"),
        ToolHint(symbol: "rectangle.dashed", "Drag a block", explained: "Drag across cells to select a block"),
        ToolHint(keys: ["⌘"], "Click to add", explained: "Click to add cells to the selection"),
        ToolHint(symbol: "tablecells", "Header for a column", explained: "Click a column header to select the column"),
        ToolHint(symbol: "number", "Line for rows", explained: "Click a line number to select the row"),
    ]
    static let selectedHints = [
        ToolHint(keys: ["⌘", "C"], "Copy", explained: "Copy the selection as text"),
        ToolHint(keys: ["esc"], "Clear", explained: "Clear the selection"),
        ToolHint(keys: ["⇧", "↓"], "Extend", explained: "Extend the selection by a cell"),
        ToolHint(keys: ["⌘"], "Click to add", explained: "Click to add cells to the selection"),
    ]

    public var body: some View {
        VStack(spacing: 0) {
            ViewerToolbar {
                Label("\(controller.table.rows.count.counted("row")) · \(controller.table.columnCount.counted("column"))", systemImage: "tablecells")
                if controller.isTruncated { Text("showing the first \(CSVParser.maximumRows)") }
                if let summary = controller.selectionSummary {
                    Text(summary).foregroundStyle(.primary).transition(.opacity)
                }
            } trailing: {
                CopiedBadge(count: controller.copyCount)
                // Teach selecting until something is selected, then the keys that act on the selection.
                ZStack(alignment: .trailing) {
                    if controller.hasSelection {
                        ToolHints(Self.selectedHints).transition(.opacity)
                    } else {
                        ToolHints(Self.idleHints).transition(.opacity)
                    }
                }
            }
            .animation(Motion.smooth, value: controller.selectionSummary)
            .animation(Motion.smooth, value: controller.hasSelection)
            if controller.isFinding {
                FindBar(model: controller, prompt: "Find in table")
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            CSVGridView(controller: controller)
                .animation(Motion.smooth, value: controller.isFinding)
        }
    }
}
