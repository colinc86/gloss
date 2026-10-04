import Core
import Foundation

/// Where an editor's indent guides go: one faint vertical line per indentation level a line sits inside, as Nova, Zed,
/// and VS Code draw them. Pure, so the rules are testable without a view.
nonisolated struct IndentGuides: Equatable, Sendable {
    /// The indentation step, in columns, read from the file (2 for two-space files, 4 for most).
    let unit: Int
    /// For each line, how many guides it sits inside. Blank lines take the smaller of their neighbours, so a block's
    /// guides run through the gaps inside it instead of breaking.
    let levels: [Int]
    /// The UTF-16 offset where each line starts, for mapping layout fragments back to lines.
    let lineStarts: [Int]

    static let tabColumns = 4

    /// Where the window ends (the last line's end); offsets past it, or before the first line, are outside.
    let endOffset: Int

    /// The column a line's text starts at (tabs to the next stop), or nil when the line is blank.
    private static func leadingColumn(_ ns: NSString, _ range: NSRange) -> Int? {
        var column = 0
        var index = range.location
        let end = NSMaxRange(range)
        while index < end {
            let unit = ns.character(at: index)
            if unit == 0x20 { column += 1 }
            else if unit == 0x09 { column = (column / tabColumns + 1) * tabColumns }
            else if unit == 0x0A || unit == 0x0D { return nil }
            else { return column }
            index += 1
        }
        return nil
    }

    /// The whole text: the rules in one place, for tests and small files.
    init(text: String) {
        let ns = text as NSString
        let index = LineIndex(text)
        self.init(window: 1...index.lineCount, text: ns, lineIndex: index)
    }

    /// Only the given lines (1-based), read through the editor's own line index, so typing in a 45,000-line file
    /// never rescans it: the editor builds this around what is on screen.
    init(window lines: ClosedRange<Int>, text ns: NSString, lineIndex: LineIndex) {
        var starts: [Int] = []
        var columns: [Int?] = []
        for line in lines {
            let range = lineIndex.contentRange(ofLine: line)
            starts.append(range.location)
            columns.append(Self.leadingColumn(ns, range))
        }
        let positive = columns.compactMap { $0 }.filter { $0 > 0 }
        let unit = min(8, max(2, positive.min() ?? 4))
        var levels = columns.map { $0.map { $0 / unit } ?? -1 }
        // Fill blank lines from both sides.
        var previous = 0
        var fromAbove = levels
        for i in levels.indices {
            if levels[i] < 0 { fromAbove[i] = previous } else { previous = levels[i] }
        }
        var next = 0
        for i in levels.indices.reversed() {
            if levels[i] < 0 { levels[i] = min(fromAbove[i], next) } else { next = levels[i] }
        }
        self.unit = unit
        self.levels = levels
        self.lineStarts = starts
        self.endOffset = NSMaxRange(lineIndex.range(ofLine: lines.upperBound))
    }

    /// Whether an offset falls inside the lines this was built for.
    func covers(_ offset: Int) -> Bool {
        guard let first = lineStarts.first else { return false }
        return offset >= first && offset <= endOffset
    }

    /// The line holding a UTF-16 offset.
    func line(at offset: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The guide of the block around a line, drawn stronger: the innermost level the line sits inside, across the
    /// lines around it that stay at least that deep. Nil at the top level.
    func activeGuide(aroundLine line: Int) -> (level: Int, lines: ClosedRange<Int>)? {
        guard levels.indices.contains(line) else { return nil }
        // On a block's opening line (`func x() {`), the block is the one it opens.
        var depth = levels[line]
        if line + 1 < levels.count, levels[line + 1] > depth { depth = levels[line + 1] }
        guard depth > 0 else { return nil }
        var first = line, last = line
        while first > 0, levels[first - 1] >= depth { first -= 1 }
        while last + 1 < levels.count, levels[last + 1] >= depth { last += 1 }
        if levels[line] < depth { first = line + 1 }
        return (depth - 1, first...last)
    }
}
