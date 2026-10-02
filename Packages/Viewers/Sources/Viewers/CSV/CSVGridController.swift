import Core
import Foundation
import Observation

/// A CSV document shown as a grid. Notes stay text anchors over the raw lines, so packets quote the source rows.
@Observable
public final class CSVGridController {
    public let text: String
    public let table: CSVTable
    public let lineIndex: LineIndex
    public var selectedRows: IndexSet = []
    /// Lines (1-based) covered by text notes, with their colors, for row tinting.
    public var highlights: [TextHighlight] = [] {
        didSet { onHighlightsChange() }
    }
    @ObservationIgnored public var onHighlightsChange: () -> Void = {}
    @ObservationIgnored public var rectProvider: (IndexSet) -> CGRect? = { _ in nil }

    public init(text: String, fileName: String) {
        self.text = text
        lineIndex = LineIndex(text)
        table = CSVParser.parse(text, delimiter: CSVParser.delimiter(for: text, fileName: fileName))
    }

    public var isTruncated: Bool { table.rows.count >= CSVParser.maximumRows }

    /// The UTF-16 range of the selected records' source lines.
    public var selectionRange: NSRange? {
        guard let first = selectedRows.min(), let last = selectedRows.max(),
              first < table.rows.count, last < table.rows.count else { return nil }
        let start = lineIndex.contentRange(ofLine: table.rows[first].firstLine).location
        let endRange = lineIndex.contentRange(ofLine: table.rows[last].lastLine)
        return NSRange(location: start, length: endRange.location + endRange.length - start)
    }

    public var selectionSummary: String? {
        guard let first = selectedRows.min(), let last = selectedRows.max() else { return nil }
        return first == last ? "Row \(first + 1)" : "Rows \(first + 1)-\(last + 1)"
    }

    /// Row indexes whose source lines intersect a highlight.
    public func highlightedRows() -> [Int: TextHighlight] {
        var result: [Int: TextHighlight] = [:]
        for highlight in highlights {
            let (start, end) = lineIndex.positions(for: highlight.range)
            for (index, row) in table.rows.enumerated() where row.lastLine >= start.line && row.firstLine <= end.line {
                result[index] = highlight
            }
        }
        return result
    }
}
