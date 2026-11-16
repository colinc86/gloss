import Foundation

/// A GitHub-flavored Markdown table as written in the source: one row per line, cells between pipes. Notes on a
/// rendered table's cells and columns are anchored on these lines, and packets read the cells back from them.
public enum MarkdownTableSource {
    /// A table's lines, 1-based: its header row and its body rows (the delimiter row is neither).
    public struct Table: Equatable, Sendable {
        public var header: Int
        public var body: [Int]
        /// The rows in order, header first.
        public var rows: [Int] { [header] + body }
    }

    /// Whether `fileName` opens as Markdown, where cell notes are on table rows rather than CSV records.
    public static func isMarkdown(_ fileName: String) -> Bool {
        DocumentKindDetector.kind(forPath: fileName) == .markdown
    }

    /// The cells of one row as written, trimmed, without the outer pipes: `| a | b \| c |` is `a`, `b | c`.
    /// A table in a block quote keeps its `>` markers out of the first cell.
    public static func cells(_ line: some StringProtocol) -> [String] {
        var text = Substring(unquoted(line)).trimmingCharacters(in: .whitespaces)[...]
        if text.hasPrefix("|") { text = text.dropFirst() }
        // A closing pipe after an odd run of backslashes is escaped; after an even run it closes the row.
        if text.hasSuffix("|"), text.dropLast().reversed().prefix(while: { $0 == "\\" }).count % 2 == 0 { text = text.dropLast() }
        var result: [String] = []
        var cell = ""
        var escaped = false
        for character in text {
            if escaped {
                // `\|` is a pipe in its cell; any other escape stays as written.
                if character != "|" { cell.append("\\") }
                cell.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                result.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(character)
            }
        }
        if escaped { cell.append("\\") }
        result.append(cell.trimmingCharacters(in: .whitespaces))
        return result
    }

    /// A line that could be a table row: it has a pipe that isn't escaped.
    public static func isRow(_ line: some StringProtocol) -> Bool {
        let text = unquoted(line)
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        var escaped = false
        for character in text {
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true } else if character == "|" { return true }
        }
        return false
    }

    /// The row under the header: `|---|:--:|`.
    public static func isDelimiter(_ line: some StringProtocol) -> Bool {
        guard isRow(line) else { return false }
        let cells = cells(line)
        return !cells.isEmpty && cells.allSatisfy { cell in
            var body = Substring(cell)
            if body.hasPrefix(":") { body = body.dropFirst() }
            if body.hasSuffix(":") { body = body.dropLast() }
            return !body.isEmpty && body.allSatisfy { $0 == "-" }
        }
    }

    /// The table `line` (1-based) is a row of, in `lines`; nil when it isn't in one. As in GitHub's Markdown, a
    /// table's body runs on to a blank line or the start of another block, so a body line may have no pipe.
    public static func table(containing line: Int, in lines: [String]) -> Table? {
        guard line >= 1, line <= lines.count, continues(lines[line - 1]) else { return nil }
        // The run of lines the table could be in, then its header: the first row in the run with a delimiter row
        // under it (a later `| - |` body row is not one), at or above `line`.
        var start = line
        while start >= 2, continues(lines[start - 2]) { start -= 1 }
        var header: Int?
        for candidate in start...line where candidate < lines.count && isRow(lines[candidate - 1]) && isDelimiter(lines[candidate])
            && cells(lines[candidate - 1]).count == cells(lines[candidate]).count {
            header = candidate
            break
        }
        guard let header, line != header + 1 else { return nil }
        var body: [Int] = []
        var next = header + 2
        while next <= lines.count, continues(lines[next - 1]) {
            body.append(next)
            next += 1
        }
        guard line == header || body.contains(line) else { return nil }
        return Table(header: header, body: body)
    }

    /// A line that keeps a table going: a row, or text that doesn't start another block.
    static func continues(_ line: String) -> Bool {
        if isRow(line) { return true }
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return false }
        for opener in ["#", ">", "```", "~~~", "- ", "* ", "+ ", "<"] where text.hasPrefix(opener) { return false }
        if let dot = text.firstIndex(where: { $0 == "." || $0 == ")" }), dot != text.startIndex,
           text[..<dot].allSatisfy(\.isNumber), text[text.index(after: dot)...].first.map({ $0 == " " }) ?? true { return false }
        return true
    }

    /// `content`'s lines without terminators, as `Table` numbers them.
    public static func lines(of content: String) -> [String] {
        // Split as `LineIndex` (and so anchors) count lines, not on every character Swift calls a newline.
        let index = LineIndex(content)
        return (1...max(1, index.lineCount)).map { content.line($0, index: index) ?? "" }
    }

    /// The line without the `>` markers of the block quotes it is in.
    private static func unquoted(_ line: some StringProtocol) -> Substring {
        var text = Substring(line)
        while true {
            let trimmed = text.drop { $0 == " " || $0 == "\t" }
            guard trimmed.hasPrefix(">") else { return text }
            text = trimmed.dropFirst()
            if text.hasPrefix(" ") { text = text.dropFirst() }
        }
    }
}
