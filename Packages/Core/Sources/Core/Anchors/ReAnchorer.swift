import Foundation

public enum ReAnchorResult: Sendable, Equatable {
    /// The file is byte-identical to when the anchor was made.
    case unchanged
    /// The anchor was found again; store the new anchor.
    case moved(Anchor)
    /// A plausible new position was found; store it but flag the note for a glance.
    case movedNeedsReview(Anchor)
    /// Nothing matched; the note becomes orphaned.
    case orphaned
}

/// Text source for PDF re-anchoring, so Core needs no PDFKit. Viewers adapts `PDFDocument`.
public protocol PDFTextSource {
    var pageCount: Int { get }
    func text(ofPage page: Int) -> String?
    /// Every occurrence of `text`, with page index and bounds in page points.
    func find(_ text: String) -> [(page: Int, bounds: PDFBounds)]
}

public enum ReAnchorer {
    public static let contextLines = 3
    public static let acceptScore = 0.6
    public static let reviewScore = 0.4
    /// When both context lines bracket the span, half the lines surviving is enough to accept.
    public static let bracketedAcceptScore = 0.5

    // MARK: Text

    public static func text(_ anchor: TextAnchor, in newContent: String, newHash: String) -> ReAnchorResult {
        if let hash = anchor.hash, hash == newHash { return .unchanged }

        let normalized = normalizeNewlines(newContent)
        let index = LineIndex(normalized)
        let selected = normalizeNewlines(anchor.text)

        // 1. Exact match on the selected text, nearest the old position.
        if !selected.isEmpty, let range = nearestOccurrence(of: selected, in: normalized, index: index, toLine: anchor.start.line) {
            let rebuilt = make(from: range, in: normalized, index: index, hash: newHash)
            return .moved(.text(rebuilt))
        }

        // 2. Fuzzy match on the context lines.
        return fuzzyText(anchor, selected: selected, normalized: normalized, index: index, newHash: newHash)
    }

    /// The last non-blank line of `before` (first of `after`) is the probe; blank lines between the probe and the
    /// span are added back when placing the candidate.
    static func fuzzyText(_ anchor: TextAnchor, selected: String, normalized: String, index: LineIndex, newHash: String) -> ReAnchorResult {
        let oldLines = selected.isEmpty ? [] : selected.components(separatedBy: "\n")
        let beforeLines = anchor.before.isEmpty ? [] : anchor.before.components(separatedBy: "\n")
        let afterLines = anchor.after.isEmpty ? [] : anchor.after.components(separatedBy: "\n")
        let beforeProbe = beforeLines.lastIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let afterProbe = afterLines.firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let beforeGap = beforeProbe.map { beforeLines.count - 1 - $0 } ?? 0   // blank lines between probe and span
        let afterGap = afterProbe ?? 0
        let lines = (1...max(1, index.lineCount)).map { normalized.line($0, index: index) ?? "" }
        let limit = max(200, Int(Double(index.lineCount) * 0.2))
        let foundBefore = beforeProbe.flatMap { nearestLine(equalTo: beforeLines[$0], in: lines, toLine: anchor.start.line - 1 - beforeGap, limit: limit) }
        let foundAfter = afterProbe.flatMap { nearestLine(equalTo: afterLines[$0], in: lines, toLine: anchor.end.line + 1 + afterGap, limit: limit) }

        var candidate: ClosedRange<Int>?   // 1-based lines
        var bracketed = false              // both context lines found: the location is reliable even if the text changed a lot
        let maxSpan = 3 * max(oldLines.count, 1) + contextLines
        switch (foundBefore, foundAfter) {
        case let (before?, after?) where after - afterGap > before + beforeGap + 1:
            let start = before + beforeGap + 1
            let end = after - afterGap - 1
            if end - start + 1 <= maxSpan {
                candidate = start...end
                bracketed = true
            } else {
                candidate = nil
            }
        case let (before?, _):
            let start = before + beforeGap + 1
            let end = min(lines.count, start + max(1, oldLines.count) - 1)
            if start <= end { candidate = start...end }
        case let (_, after?):
            let end = after - afterGap - 1
            let start = max(1, end - max(1, oldLines.count) + 1)
            if start <= end { candidate = start...end }
        default:
            candidate = nil
        }
        guard let span = candidate else { return .orphaned }

        let newLines = Array(lines[(span.lowerBound - 1)...(span.upperBound - 1)])
        let score = oldLines.isEmpty ? 1.0 : similarity(oldLines, newLines)
        guard bracketed || score >= reviewScore else { return .orphaned }
        let start = TextPosition(line: span.lowerBound, col: 1)
        let end = TextPosition(line: span.upperBound, col: (newLines.last?.utf16.count ?? 0) + 1)
        let rebuilt = TextAnchor(
            start: start, end: end, text: newLines.joined(separator: "\n"),
            before: context(lines, before: span.lowerBound), after: context(lines, after: span.upperBound), hash: newHash
        )
        let accept = bracketed ? bracketedAcceptScore : acceptScore
        return score >= accept ? .moved(.text(rebuilt)) : .movedNeedsReview(.text(rebuilt))
    }

    /// Builds a text anchor for a selection range of `content`, including context lines and hash.
    public static func make(from range: NSRange, in content: String, index: LineIndex, hash: String?) -> TextAnchor {
        var range = range
        var (start, end) = index.positions(for: range)
        // A whole-line selection ends at column 1 of the next line; anchor it at the end of the selected line instead,
        // so the packet's line range, the excerpt, and the context all describe the same lines.
        if range.length > 0, end.col == 1, end.line > start.line {
            let previous = index.contentRange(ofLine: end.line - 1)
            let newEnd = previous.location + previous.length
            range = NSRange(location: range.location, length: max(0, newEnd - range.location))
            end = index.position(forUTF16Offset: newEnd)
        }
        let lines = (1...max(1, index.lineCount)).map { content.line($0, index: index) ?? "" }
        return TextAnchor(
            start: start, end: end, text: (content as NSString).substring(with: range),
            before: context(lines, before: start.line), after: context(lines, after: end.line), hash: hash
        )
    }

    static func normalizeNewlines(_ string: String) -> String {
        string.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    static func nearestOccurrence(of needle: String, in haystack: String, index: LineIndex, toLine line: Int) -> NSRange? {
        let ns = haystack as NSString
        var occurrences: [NSRange] = []
        var searchRange = NSRange(location: 0, length: ns.length)
        while searchRange.location < ns.length {
            let found = ns.range(of: needle, options: [.literal], range: searchRange)
            guard found.location != NSNotFound else { break }
            occurrences.append(found)
            let next = found.location + max(1, found.length)
            searchRange = NSRange(location: next, length: ns.length - next)
        }
        guard !occurrences.isEmpty else { return nil }
        let withDistance = occurrences.map { ($0, abs(index.position(forUTF16Offset: $0.location).line - line)) }
        let best = withDistance.min { $0.1 < $1.1 }!
        let limit = max(200, Int(Double(index.lineCount) * 0.2))
        return occurrences.count == 1 || best.1 <= limit ? best.0 : nil
    }

    static func nearestLine(equalTo target: String, in lines: [String], toLine line: Int, limit: Int) -> Int? {
        func search(_ matches: (String) -> Bool) -> Int? {
            var best: (line: Int, distance: Int)?
            for (offset, candidate) in lines.enumerated() where matches(candidate) {
                let number = offset + 1
                let distance = abs(number - line)
                if best == nil || distance < best!.distance { best = (number, distance) }
            }
            guard let best, best.distance <= limit else { return nil }
            return best.line
        }
        if let exact = search({ $0 == target }) { return exact }
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return search { $0.trimmingCharacters(in: .whitespaces) == trimmed }
    }

    /// LCS over trimmed lines divided by the longer length.
    static func similarity(_ oldLines: [String], _ newLines: [String]) -> Double {
        let x = oldLines.map { $0.trimmingCharacters(in: .whitespaces) }
        let y = newLines.map { $0.trimmingCharacters(in: .whitespaces) }
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var table = Array(repeating: Array(repeating: 0, count: y.count + 1), count: x.count + 1)
        for i in 1...x.count {
            for j in 1...y.count {
                table[i][j] = x[i - 1] == y[j - 1] ? table[i - 1][j - 1] + 1 : max(table[i - 1][j], table[i][j - 1])
            }
        }
        return Double(table[x.count][y.count]) / Double(max(x.count, y.count))
    }

    static func context(_ lines: [String], before line: Int) -> String {
        let end = line - 1
        guard end >= 1 else { return "" }
        let start = max(1, end - contextLines + 1)
        return lines[(start - 1)...(end - 1)].joined(separator: "\n")
    }

    static func context(_ lines: [String], after line: Int) -> String {
        let start = line + 1
        guard start <= lines.count else { return "" }
        let end = min(lines.count, start + contextLines - 1)
        return lines[(start - 1)...(end - 1)].joined(separator: "\n")
    }

    // MARK: Image

    public static func image(_ anchor: ImageAnchor, newWidth: Int, newHeight: Int, newHash: String) -> ReAnchorResult {
        if let hash = anchor.hash, hash == newHash { return .unchanged }
        if newWidth == anchor.imageW && newHeight == anchor.imageH {
            var updated = anchor
            updated.hash = newHash
            return .movedNeedsReview(.image(updated))
        }
        guard anchor.imageW > 0, anchor.imageH > 0, newWidth > 0, newHeight > 0 else { return .orphaned }
        let sx = Double(newWidth) / Double(anchor.imageW)
        let sy = Double(newHeight) / Double(anchor.imageH)
        let x = min(max(0, Int((Double(anchor.x) * sx).rounded())), newWidth - 1)
        let y = min(max(0, Int((Double(anchor.y) * sy).rounded())), newHeight - 1)
        let w = max(1, min(Int((Double(anchor.w) * sx).rounded()), newWidth - x))
        let h = max(1, min(Int((Double(anchor.h) * sy).rounded()), newHeight - y))
        return .movedNeedsReview(.image(ImageAnchor(x: x, y: y, w: w, h: h, imageW: newWidth, imageH: newHeight, hash: newHash)))
    }

    // MARK: PDF

    public static func pdf(_ anchor: PDFAnchor, in source: some PDFTextSource) -> ReAnchorResult {
        let pageCount = source.pageCount
        if anchor.page < pageCount {
            let pageText = source.text(ofPage: anchor.page) ?? ""
            let textPresent = anchor.text.map { $0.isEmpty || pageText.contains($0) } ?? true
            if textPresent {
                if pageCount == anchor.pageCount { return .unchanged }
                var updated = anchor
                updated.pageCount = pageCount
                return .movedNeedsReview(.pdf(updated))
            }
        }
        guard let text = anchor.text, !text.isEmpty else { return .orphaned }
        let hits = source.find(text).sorted { abs($0.page - anchor.page) < abs($1.page - anchor.page) }
        guard let hit = hits.first else { return .orphaned }
        let moved = PDFAnchor(page: hit.page, bounds: anchor.bounds == nil ? nil : hit.bounds, text: text, pageCount: pageCount)
        return hits.count == 1 ? .moved(.pdf(moved)) : .movedNeedsReview(.pdf(moved))
    }
}
