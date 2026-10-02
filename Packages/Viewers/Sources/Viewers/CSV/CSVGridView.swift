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
        let table = NSTableView()
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnSelection = false
        table.rowSizeStyle = .small
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.style = .plain
        let columns = max(1, controller.table.columnCount)
        for index in 0..<columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("col\(index)"))
            column.title = index < controller.table.header.count ? controller.table.header[index] : "Column \(index + 1)"
            column.width = 140
            column.minWidth = 40
            table.addTableColumn(column)
        }
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        context.coordinator.table = table
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        controller.rectProvider = { [weak table, weak scroll] rows in
            guard let table, let scroll, let first = rows.min(), let last = rows.max() else { return nil }
            let rect = table.rect(ofRow: first).union(table.rect(ofRow: last))
            return table.convert(rect, to: scroll)
        }
        return scroll
    }

    public func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.table?.reloadData(forRowIndexes: IndexSet(0..<controller.table.rows.count), columnIndexes: IndexSet(0..<max(1, controller.table.columnCount)))
        context.coordinator.table?.enumerateAvailableRowViews { rowView, row in
            rowView.backgroundColor = context.coordinator.rowColor(row) ?? .clear
        }
    }

    @MainActor
    public final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let controller: CSVGridController
        weak var table: NSTableView?

        init(controller: CSVGridController) {
            self.controller = controller
        }

        func rowColor(_ row: Int) -> NSColor? {
            guard let highlight = controller.highlightedRows()[row] else { return nil }
            return Theme.highlightBackground(for: highlight.highlight)
        }

        public func numberOfRows(in tableView: NSTableView) -> Int {
            controller.table.rows.count
        }

        public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let index = Int(tableColumn.identifier.rawValue.dropFirst(3)) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("cell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? {
                let view = NSTableCellView()
                view.identifier = identifier
                let field = NSTextField(labelWithString: "")
                field.lineBreakMode = .byTruncatingTail
                field.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
                field.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(field)
                view.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
                    field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
                    field.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                ])
                return view
            }()
            let fields = controller.table.rows[row].fields
            cell.textField?.stringValue = index < fields.count ? fields[index] : ""
            return cell
        }

        public func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = NSTableRowView()
            view.backgroundColor = rowColor(row) ?? .clear
            return view
        }

        public func tableViewSelectionDidChange(_ notification: Notification) {
            controller.selectedRows = table?.selectedRowIndexes ?? []
        }
    }
}

/// Grid with a status line.
public struct CSVGridPane: View {
    public let controller: CSVGridController

    public init(controller: CSVGridController) {
        self.controller = controller
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("\(controller.table.rows.count) rows, \(controller.table.columnCount) columns")
                if controller.isTruncated { Text("showing the first \(CSVParser.maximumRows)") }
                if let summary = controller.selectionSummary { Text(summary) }
                Spacer()
                Text("Select rows, then ⌘⇧N to note them").foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            CSVGridView(controller: controller)
        }
    }
}
