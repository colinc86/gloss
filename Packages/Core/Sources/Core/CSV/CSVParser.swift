import Foundation

/// One record with the 1-based source lines it spans (quoted fields may contain newlines).
public struct CSVRow: Equatable, Sendable {
    public var fields: [String]
    public var firstLine: Int
    public var lastLine: Int

    public init(fields: [String], firstLine: Int, lastLine: Int) {
        self.fields = fields
        self.firstLine = firstLine
        self.lastLine = lastLine
    }
}

public struct CSVTable: Equatable, Sendable {
    public var header: [String]
    public var rows: [CSVRow]
    public var delimiter: Character

    public init(header: [String], rows: [CSVRow], delimiter: Character) {
        self.header = header
        self.rows = rows
        self.delimiter = delimiter
    }

    public var columnCount: Int { max(header.count, rows.map(\.fields.count).max() ?? 0) }
}

/// RFC 4180 parser: quoted fields, doubled quotes, embedded newlines, CR, LF, and CRLF.
public enum CSVParser {
    public static let maximumRows = 100_000

    /// Picks tab for `.tsv`, else the most frequent of `,` `;` `\t` on the first line.
    public static func delimiter(for text: String, fileName: String) -> Character {
        if fileName.lowercased().hasSuffix(".tsv") { return "\t" }
        let firstLine = text.prefix { !$0.isNewline }
        let counts: [(Character, Int)] = [",", ";", "\t"].map { delimiter in (delimiter, firstLine.filter { $0 == delimiter }.count) }
        return counts.max { $0.1 < $1.1 }.flatMap { $0.1 > 0 ? $0.0 : nil } ?? ","
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    /// Parses every record, with the first record as the header when `hasHeader` is true.
    public static func parse(_ text: String, delimiter: Character, hasHeader: Bool = true) -> CSVTable {
        var records: [CSVRow] = []
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        var line = 1
        var recordStart = 1
        var recordHasContent = false
        var iterator = text.makeIterator()
        var pending: Character?

        func endField() {
            fields.append(field)
            field = ""
        }
        func endRecord(lastLine: Int) {
            endField()
            if fields.count == 1 && fields[0].isEmpty && !recordHasContent {
                fields = []
            } else {
                records.append(CSVRow(fields: fields, firstLine: recordStart, lastLine: lastLine))
                fields = []
            }
            recordHasContent = false
        }

        while true {
            let character: Character
            if let next = pending {
                character = next
                pending = nil
            } else if let next = iterator.next() {
                character = next
            } else {
                break
            }
            if records.count >= maximumRows { break }
            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            pending = next
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    if character.isNewline { line += 1 }
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"":
                inQuotes = true
                recordHasContent = true
            case delimiter:
                endField()
                recordHasContent = true
            case _ where character.isNewline:
                endRecord(lastLine: line)
                line += 1
                recordStart = line
            default:
                field.append(character)
                recordHasContent = true
            }
        }
        if !field.isEmpty || !fields.isEmpty || recordHasContent { endRecord(lastLine: line) }

        if hasHeader, let first = records.first {
            return CSVTable(header: first.fields, rows: Array(records.dropFirst()), delimiter: delimiter)
        }
        return CSVTable(header: [], rows: records, delimiter: delimiter)
    }
}
