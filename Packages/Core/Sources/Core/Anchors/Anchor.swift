import Foundation

/// A 1-based line and column. `col` counts UTF-16 code units from the line start, matching `NSRange`.
public struct TextPosition: Codable, Hashable, Sendable, Comparable {
    public var line: Int
    public var col: Int

    public init(line: Int, col: Int) {
        self.line = line
        self.col = col
    }

    public static func < (lhs: TextPosition, rhs: TextPosition) -> Bool {
        (lhs.line, lhs.col) < (rhs.line, rhs.col)
    }
}

/// A selected range of a text, code, or markdown document (markdown anchors are always in source coordinates).
public struct TextAnchor: Codable, Hashable, Sendable {
    public var start: TextPosition
    public var end: TextPosition
    /// The exact selected text.
    public var text: String
    /// Up to three lines before the selection, joined by `\n`.
    public var before: String
    /// Up to three lines after the selection, joined by `\n`.
    public var after: String
    /// SHA-256 of the file when the anchor was made. Optional for rows written before this field existed.
    public var hash: String?
    /// Spreadsheet cells or columns the note is about. The text range still covers the records' source lines (the
    /// header line for whole columns), so re-anchoring and excerpts keep working; nil for ordinary text notes.
    public var cells: CellSelection?

    public init(start: TextPosition, end: TextPosition, text: String, before: String, after: String, hash: String? = nil, cells: CellSelection? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.before = before
        self.after = after
        self.hash = hash
        self.cells = cells
    }

    public var isSingleLine: Bool { start.line == end.line }

    /// The selected characters when the selection is part of one line: its first and last column, 1-based and in
    /// UTF-16 units as the editor counts them. Nil for a selection spanning lines, the whole line, or cells.
    /// `lineLength` is that line's length without its terminator.
    public func partialColumns(lineLength: Int) -> ClosedRange<Int>? {
        guard isSingleLine, cells == nil, end.col > start.col else { return nil }
        if start.col == 1, end.col - 1 >= lineLength { return nil }
        return start.col...(end.col - 1)
    }
}

/// A set of spreadsheet cells, or whole columns, inside a CSV text anchor.
public struct CellSelection: Codable, Hashable, Sendable {
    /// Whole columns, 0-based and sorted. When non-empty the anchor sits on the header line and `cells` is empty.
    public var columns: [Int]
    /// Individual cells, sorted by line then column.
    public var cells: [CellRef]
    /// Header names of `columns` when the note was made, in the same order; re-anchoring finds columns by name.
    public var headers: [String]?

    public init(columns: [Int] = [], cells: [CellRef] = [], headers: [String]? = nil) {
        let order = columns.indices.sorted { columns[$0] < columns[$1] }
        self.columns = order.map { columns[$0] }
        self.headers = headers.map { names in order.map { $0 < names.count ? names[$0] : "" } }
        self.cells = cells.sorted()
    }

    public var isColumns: Bool { !columns.isEmpty }

    /// `A`, `B`, … `Z`, `AA` for a 0-based column.
    public static func columnName(_ column: Int) -> String {
        var name = ""
        var value = column + 1
        while value > 0 {
            let remainder = (value - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + remainder))) + name
            value = (value - 1) / 26
        }
        return name
    }

    /// Spreadsheet references relative to an anchor starting at `startLine`: `B2`, `B2:C4` for a full rectangle,
    /// `B2, E4` otherwise. Row numbers are the record's first source line, which is the spreadsheet row whenever
    /// no field spans lines.
    public func references(startLine: Int) -> String {
        if isColumns { return columns.map(Self.columnName).joined(separator: ", ") }
        let lines = Set(cells.map(\.lineOffset))
        let columnSet = Set(cells.map(\.column))
        // A full block of consecutive lines and columns collapses to a range.
        if cells.count > 1, lines.count * columnSet.count == cells.count,
           let minColumn = columnSet.min(), let maxColumn = columnSet.max(), maxColumn - minColumn + 1 == columnSet.count,
           let minLine = lines.min(), let maxLine = lines.max(), maxLine - minLine + 1 == lines.count {
            return "\(Self.columnName(minColumn))\(startLine + minLine):\(Self.columnName(maxColumn))\(startLine + maxLine)"
        }
        return cells.map { "\(Self.columnName($0.column))\(startLine + $0.lineOffset)" }.joined(separator: ", ")
    }
}

/// One cell: its record's first source line relative to the anchor's start line, and its 0-based column.
public struct CellRef: Codable, Hashable, Sendable, Comparable {
    public var lineOffset: Int
    public var column: Int

    public init(lineOffset: Int, column: Int) {
        self.lineOffset = lineOffset
        self.column = column
    }

    public static func < (lhs: CellRef, rhs: CellRef) -> Bool {
        (lhs.lineOffset, lhs.column) < (rhs.lineOffset, rhs.column)
    }
}

/// A rectangle in the original image's pixel space, origin top-left.
public struct ImageAnchor: Codable, Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var w: Int
    public var h: Int
    public var imageW: Int
    public var imageH: Int
    public var hash: String?

    public init(x: Int, y: Int, w: Int, h: Int, imageW: Int, imageH: Int, hash: String? = nil) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.imageW = imageW
        self.imageH = imageH
        self.hash = hash
    }
}

/// Bounds in PDF page points (crop box space, origin bottom-left as PDFKit reports it).
public struct PDFBounds: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

public struct PDFAnchor: Codable, Hashable, Sendable {
    /// 0-based page index. Printed 1-based in packets.
    public var page: Int
    /// Nil when the anchor is a whole-page text selection without a drawn region.
    public var bounds: PDFBounds?
    /// Selected text, when any.
    public var text: String?
    public var pageCount: Int

    public init(page: Int, bounds: PDFBounds?, text: String?, pageCount: Int) {
        self.page = page
        self.bounds = bounds
        self.text = text
        self.pageCount = pageCount
    }
}

/// A rectangle in CSS pixels, in page (document) coordinates with the origin at the page's top-left.
public struct ElementRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    var center: (x: Double, y: Double) { (x + w / 2, y + h / 2) }
}

/// A DOM element on a web page, found again by selector first and by its text second.
public struct ElementAnchor: Codable, Hashable, Sendable {
    public static let textLimit = 500
    public static let htmlLimit = 2048

    /// `#id`, `[data-testid="…"]`, or a `tag:nth-of-type(n)` path from the nearest uniquely identified ancestor.
    /// Never class names, which change with every stylesheet.
    public var selector: String
    /// Lowercase tag name.
    public var tag: String
    /// Whitespace-collapsed `textContent`, at most `textLimit` characters.
    public var text: String
    /// `outerHTML`, at most `htmlLimit` characters.
    public var html: String
    public var rect: ElementRect
    /// Source line of the element's first text node, for pages backed by a file the app can open.
    public var line: Int?
    /// SHA-256 of the file, or of the page's serialised DOM, when the anchor was made.
    public var hash: String?

    public init(selector: String, tag: String, text: String, html: String, rect: ElementRect, line: Int? = nil, hash: String? = nil) {
        self.selector = selector
        self.tag = tag.lowercased()
        self.text = Self.collapse(text, limit: Self.textLimit)
        self.html = Self.truncate(html, limit: Self.htmlLimit)
        self.rect = rect
        self.line = line
        self.hash = hash
    }

    /// The last compound of the selector: `button:nth-of-type(2)` of `#toolbar > button:nth-of-type(2)`.
    public var lastCompound: String {
        selector.components(separatedBy: " > ").last?.trimmingCharacters(in: .whitespaces) ?? selector
    }

    static func collapse(_ text: String, limit: Int) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return truncate(collapsed, limit: limit)
    }

    static func truncate(_ text: String, limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
}

public enum AnchorType: String, Codable, Sendable, CaseIterable {
    case text
    case image
    case pdf
    case file
    case element
}

/// A typed description of the part of a document a note refers to. Stored as `anchor_type` + `anchor_json`.
public enum Anchor: Hashable, Sendable {
    case text(TextAnchor)
    case image(ImageAnchor)
    case pdf(PDFAnchor)
    case wholeFile
    case element(ElementAnchor)

    public var type: AnchorType {
        switch self {
        case .text: .text
        case .image: .image
        case .pdf: .pdf
        case .wholeFile: .file
        case .element: .element
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// The `anchor_json` column value. Keys are sorted so rows are diffable.
    public func encodedJSON() throws -> String {
        let data: Data
        switch self {
        case .text(let anchor): data = try Self.encoder.encode(anchor)
        case .image(let anchor): data = try Self.encoder.encode(anchor)
        case .pdf(let anchor): data = try Self.encoder.encode(anchor)
        case .wholeFile: data = Data("{}".utf8)
        case .element(let anchor): data = try Self.encoder.encode(anchor)
        }
        return String(decoding: data, as: UTF8.self)
    }

    public init(type: AnchorType, json: String) throws {
        let decoder = JSONDecoder()
        let data = Data(json.utf8)
        switch type {
        case .text: self = .text(try decoder.decode(TextAnchor.self, from: data))
        case .image: self = .image(try decoder.decode(ImageAnchor.self, from: data))
        case .pdf: self = .pdf(try decoder.decode(PDFAnchor.self, from: data))
        case .file: self = .wholeFile
        case .element: self = .element(try decoder.decode(ElementAnchor.self, from: data))
        }
    }

    /// Sort key so notes in one document list in reading order.
    public var sortKey: SortKey {
        switch self {
        case .text(let anchor): SortKey(primary: anchor.start.line, secondary: anchor.start.col)
        case .image(let anchor): SortKey(primary: anchor.y, secondary: anchor.x)
        case .pdf(let anchor): SortKey(primary: anchor.page, secondary: Int(-(anchor.bounds?.y ?? 0)))
        case .wholeFile: SortKey(primary: Int.max, secondary: 0)
        case .element(let anchor): SortKey(primary: Int(anchor.rect.y.rounded()), secondary: Int(anchor.rect.x.rounded()))
        }
    }

    public struct SortKey: Hashable, Comparable, Sendable {
        public var primary: Int
        public var secondary: Int

        public static func < (lhs: SortKey, rhs: SortKey) -> Bool {
            (lhs.primary, lhs.secondary) < (rhs.primary, rhs.secondary)
        }
    }

    /// Short human-readable description for cards and summaries: `Lines 40-52`, `Region 1204,312 640x220`, `Page 3`.
    public var summary: String {
        switch self {
        case .text(let anchor):
            if let cells = anchor.cells {
                cells.isColumns
                    ? (cells.columns.count == 1 ? "Column " : "Columns ") + cells.references(startLine: anchor.start.line)
                    : (cells.cells.count == 1 ? "Cell " : "Cells ") + cells.references(startLine: anchor.start.line)
            } else {
                anchor.isSingleLine ? "Line \(anchor.start.line)" : "Lines \(anchor.start.line)-\(anchor.end.line)"
            }
        case .image(let anchor):
            "Region \(anchor.x),\(anchor.y) \(anchor.w)x\(anchor.h)"
        case .pdf(let anchor):
            anchor.bounds == nil ? "Page \(anchor.page + 1)" : "Page \(anchor.page + 1) region"
        case .wholeFile:
            "Whole file"
        case .element(let anchor):
            "Element \(anchor.lastCompound)"
        }
    }
}

extension Anchor: Codable {
    private enum CodingKeys: String, CodingKey { case type, json }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(AnchorType.self, forKey: .type)
        let json = try container.decode(String.self, forKey: .json)
        try self.init(type: type, json: json)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(try encodedJSON(), forKey: .json)
    }
}
