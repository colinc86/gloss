import Foundation

/// Line starts of a string in UTF-16 units, so `NSRange` and `TextPosition` convert both ways.
/// Line terminators follow `NSString`: `\n`, `\r`, `\r\n` (as one), U+0085, U+2028, U+2029.
public struct LineIndex: Sendable, Equatable {
    /// UTF-16 offset of every line start; `lineStarts[0] == 0`. A trailing terminator starts an empty last line.
    public let lineStarts: [Int]
    /// Length of each line's terminator in UTF-16 units (0 for the last line when the string has no trailing terminator).
    public let terminatorLengths: [Int]
    /// Total length in UTF-16 units.
    public let length: Int

    public init(_ string: String) {
        var starts = [0]
        var terminators: [Int] = []
        let utf16 = Array(string.utf16)
        var index = 0
        while index < utf16.count {
            let unit = utf16[index]
            switch unit {
            case 0x0D:
                if index + 1 < utf16.count, utf16[index + 1] == 0x0A {
                    index += 1
                    terminators.append(2)
                } else {
                    terminators.append(1)
                }
                starts.append(index + 1)
            case 0x0A, 0x85, 0x2028, 0x2029:
                terminators.append(1)
                starts.append(index + 1)
            default:
                break
            }
            index += 1
        }
        terminators.append(0)
        lineStarts = starts
        terminatorLengths = terminators
        length = utf16.count
    }

    public var lineCount: Int { lineStarts.count }

    /// 1-based line and column for a UTF-16 offset, clamped to the document.
    public func position(forUTF16Offset offset: Int) -> TextPosition {
        let clamped = max(0, min(offset, length))
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= clamped { low = mid } else { high = mid - 1 }
        }
        return TextPosition(line: low + 1, col: clamped - lineStarts[low] + 1)
    }

    /// UTF-16 offset of a position, clamped to the line's content (a column past the end lands on the terminator).
    public func utf16Offset(for position: TextPosition) -> Int {
        let line = max(1, min(position.line, lineCount))
        let content = contentRange(ofLine: line)
        return min(content.location + max(0, position.col - 1), content.location + content.length)
    }

    /// Range of a line's content without its terminator.
    public func contentRange(ofLine line: Int) -> NSRange {
        let clamped = max(1, min(line, lineCount))
        let start = lineStarts[clamped - 1]
        let end = clamped < lineCount ? lineStarts[clamped] - terminatorLengths[clamped - 1] : length
        return NSRange(location: start, length: end - start)
    }

    /// Range of a line including its terminator.
    public func range(ofLine line: Int) -> NSRange {
        let clamped = max(1, min(line, lineCount))
        let start = lineStarts[clamped - 1]
        let end = clamped < lineCount ? lineStarts[clamped] : length
        return NSRange(location: start, length: end - start)
    }

    public func range(for anchor: TextAnchor) -> NSRange {
        let start = utf16Offset(for: anchor.start)
        let end = max(start, utf16Offset(for: anchor.end))
        return NSRange(location: start, length: end - start)
    }

    public func positions(for range: NSRange) -> (start: TextPosition, end: TextPosition) {
        (position(forUTF16Offset: range.location), position(forUTF16Offset: range.location + range.length))
    }
}

extension String {
    /// Content of the 1-based `line` without its terminator, or nil past the end.
    public func line(_ line: Int, index: LineIndex) -> String? {
        guard line >= 1, line <= index.lineCount else { return nil }
        let range = index.contentRange(ofLine: line)
        return (self as NSString).substring(with: range)
    }
}
