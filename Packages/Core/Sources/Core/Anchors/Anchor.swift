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

    public init(start: TextPosition, end: TextPosition, text: String, before: String, after: String, hash: String? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.before = before
        self.after = after
        self.hash = hash
    }

    public var isSingleLine: Bool { start.line == end.line }
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

public enum AnchorType: String, Codable, Sendable, CaseIterable {
    case text
    case image
    case pdf
    case file
}

/// A typed description of the part of a document a note refers to. Stored as `anchor_type` + `anchor_json`.
public enum Anchor: Hashable, Sendable {
    case text(TextAnchor)
    case image(ImageAnchor)
    case pdf(PDFAnchor)
    case wholeFile

    public var type: AnchorType {
        switch self {
        case .text: .text
        case .image: .image
        case .pdf: .pdf
        case .wholeFile: .file
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
        }
    }

    /// Sort key so notes in one document list in reading order.
    public var sortKey: SortKey {
        switch self {
        case .text(let anchor): SortKey(primary: anchor.start.line, secondary: anchor.start.col)
        case .image(let anchor): SortKey(primary: anchor.y, secondary: anchor.x)
        case .pdf(let anchor): SortKey(primary: anchor.page, secondary: Int(-(anchor.bounds?.y ?? 0)))
        case .wholeFile: SortKey(primary: Int.max, secondary: 0)
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
            anchor.isSingleLine ? "Line \(anchor.start.line)" : "Lines \(anchor.start.line)-\(anchor.end.line)"
        case .image(let anchor):
            "Region \(anchor.x),\(anchor.y) \(anchor.w)x\(anchor.h)"
        case .pdf(let anchor):
            anchor.bounds == nil ? "Page \(anchor.page + 1)" : "Page \(anchor.page + 1) region"
        case .wholeFile:
            "Whole file"
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
