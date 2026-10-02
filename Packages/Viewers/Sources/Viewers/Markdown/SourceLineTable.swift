import Core
import Foundation
import Markdown

/// Converts swift-markdown's 1-based line and UTF-8 byte columns into UTF-16 offsets.
public struct SourceLineTable {
    public let index: LineIndex
    private let utf16Units: [UInt16]

    public init(_ source: String) {
        index = LineIndex(source)
        utf16Units = Array(source.utf16)
    }

    /// UTF-16 offset for a source location; clamps columns past the end of the line.
    public func utf16Offset(_ location: SourceLocation) -> Int {
        let line = max(1, min(location.line, index.lineCount))
        let content = index.contentRange(ofLine: line)
        var bytes = 0
        let target = max(0, location.column - 1)
        var offset = content.location
        let end = content.location + content.length
        while offset < end, bytes < target {
            let unit = utf16Units[offset]
            if unit >= 0xD800, unit <= 0xDBFF {
                bytes += 4
                offset += 2
            } else if unit < 0x80 {
                bytes += 1
                offset += 1
            } else if unit < 0x800 {
                bytes += 2
                offset += 1
            } else {
                bytes += 3
                offset += 1
            }
        }
        return min(offset, end)
    }

    public func nsRange(_ range: SourceRange) -> NSRange {
        let start = utf16Offset(range.lowerBound)
        let end = max(start, utf16Offset(range.upperBound))
        return NSRange(location: start, length: end - start)
    }
}
