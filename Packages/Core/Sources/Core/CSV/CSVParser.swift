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
    /// The file has more rows than `CSVParser.maximumRows`; only the first are here.
    public var isTruncated: Bool

    public init(header: [String], rows: [CSVRow], delimiter: Character, isTruncated: Bool = false) {
        self.header = header
        self.rows = rows
        self.delimiter = delimiter
        self.isTruncated = isTruncated
    }

    public var columnCount: Int { max(header.count, rows.map(\.fields.count).max() ?? 0) }
}

/// RFC 4180 parser: quoted fields, doubled quotes, embedded newlines, CR, LF, and CRLF.
public enum CSVParser {
    /// Data rows kept; the header, when there is one, is not counted.
    public static let maximumRows = 100_000

    /// Picks tab for `.tsv`, else the most frequent of `,` `;` `\t` on the first line, outside quoted fields (a
    /// header `"Last, First";Age` is split by semicolons).
    public static func delimiter(for text: String, fileName: String) -> Character {
        if fileName.lowercased().hasSuffix(".tsv") { return "\t" }
        if let declared = declaredDelimiter(in: text) { return declared }
        let firstLine = text.prefix { !$0.isNewline }
        var unquoted: [Character] = []
        var inQuotes = false
        for character in firstLine {
            if character == "\"" { inQuotes.toggle() } else if !inQuotes { unquoted.append(character) }
        }
        let counts: [(Character, Int)] = [",", ";", "\t"].map { delimiter in (delimiter, unquoted.filter { $0 == delimiter }.count) }
        return counts.max { $0.1 < $1.1 }.flatMap { $0.1 > 0 ? $0.0 : nil } ?? ","
    }

    /// The delimiter a first line of `sep=;` names, as Excel writes and reads it (common where `;` separates fields);
    /// that line is not part of the table.
    public static func declaredDelimiter(in text: String) -> Character? {
        let first = text.prefix { !$0.isNewline }
        guard first.count == 5, first.lowercased().hasPrefix("sep="), let delimiter = first.last else { return nil }
        return delimiter
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
        // Nothing of the current field read yet: only there does a quote open a quoted field.
        var fieldIsFresh = true
        var iterator = text.makeIterator()
        var pending: Character?
        let limit = maximumRows + (hasHeader ? 1 : 0)
        var truncated = false

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
            if records.count >= limit {
                if character.isNewline { continue }   // blank lines after the last row are not more rows
                truncated = true
                break
            }
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
            case "\"" where fieldIsFresh:
                inQuotes = true
                recordHasContent = true
                fieldIsFresh = false
            case delimiter:
                endField()
                recordHasContent = true
                fieldIsFresh = true
            case _ where character.isNewline:
                endRecord(lastLine: line)
                line += 1
                recordStart = line
                fieldIsFresh = true
            default:
                // A quote inside an unquoted field (`5'10"`) is text, as in RFC 4180 and Excel.
                field.append(character)
                recordHasContent = true
                fieldIsFresh = false
            }
        }
        if !field.isEmpty || !fields.isEmpty || recordHasContent { endRecord(lastLine: line) }
        // Excel's `sep=;` line says how to read the file; the header is the line after it.
        if declaredDelimiter(in: text) != nil, records.first?.firstLine == 1 { records.removeFirst() }

        if hasHeader, let first = records.first {
            return CSVTable(header: first.fields, rows: Array(records.dropFirst()), delimiter: delimiter, isTruncated: truncated)
        }
        return CSVTable(header: [], rows: records, delimiter: delimiter, isTruncated: truncated)
    }
}
