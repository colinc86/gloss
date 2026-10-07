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

/// An element the page's bridge found while looking for an anchor again.
public struct ElementCandidate: Sendable, Equatable {
    public var selector: String
    public var tag: String
    public var text: String
    public var html: String
    public var rect: ElementRect
    /// The page-text offset where the element starts (its first text, or the text that follows it).
    public var textOffset: Int?
    /// The source line that offset maps to, on a served file; filled in by whoever can map it.
    public var line: Int?
    /// A picture's own size in pixels; nil for any other element.
    public var imageW: Int?
    public var imageH: Int?

    public init(selector: String, tag: String, text: String, html: String, rect: ElementRect, textOffset: Int? = nil, line: Int? = nil,
                imageW: Int? = nil, imageH: Int? = nil) {
        self.selector = selector
        self.tag = tag
        self.text = text
        self.html = html
        self.rect = rect
        self.textOffset = textOffset
        self.line = line
        self.imageW = imageW
        self.imageH = imageH
    }
}

/// What the page reported for one element anchor: the element at its selector, if any, and every element of the
/// same tag with the same collapsed text. The bridge only gathers facts; `ReAnchorer.element` decides.
public struct ElementResolution: Sendable, Equatable {
    public var bySelector: ElementCandidate?
    public var byText: [ElementCandidate]

    public init(bySelector: ElementCandidate? = nil, byText: [ElementCandidate] = []) {
        self.bySelector = bySelector
        self.byText = byText
    }
}

public enum ReAnchorer {
    public static let contextLines = 3
    public static let acceptScore = 0.6
    public static let reviewScore = 0.4
    /// When both context lines bracket the span, half the lines surviving is enough to accept.
    public static let bracketedAcceptScore = 0.5

    // MARK: Text

    public static func text(_ anchor: TextAnchor, in newContent: String, newHash: String) -> ReAnchorResult {
        guard let cells = anchor.cells else { return lineText(anchor, in: newContent, newHash: newHash) }
        if let hash = anchor.hash, hash == newHash { return .unchanged }
        if cells.isColumns { return columns(anchor, cells: cells, in: newContent, newHash: newHash) }
        // Cells point at records by line offset; follow each record line from the old span into the new one.
        let result = lineText(anchor, in: newContent, newHash: newHash)
        let moved: TextAnchor
        var review: Bool
        switch result {
        case .moved(.text(let text)): (moved, review) = (text, false)
        case .movedNeedsReview(.text(let text)): (moved, review) = (text, true)
        default: return result
        }
        let oldLines = normalizeNewlines(anchor.text).components(separatedBy: "\n")
        let newLines = moved.text.components(separatedBy: "\n")
        guard let map = lineMap(oldLines, newLines) else {
            // Too large to align: keep the offsets but ask for a look.
            var kept = moved
            kept.cells = cells
            return .movedNeedsReview(.text(kept))
        }
        var remapped: [CellRef] = []
        for cell in cells.cells {
            guard let line = map.lines[cell.lineOffset] else {
                review = true
                continue
            }
            if map.changed.contains(cell.lineOffset) { review = true }
            remapped.append(CellRef(lineOffset: line, column: cell.column))
        }
        guard !remapped.isEmpty else { return .orphaned }
        // The span may now start before the first remaining cell; keep offsets relative to the new start.
        var rebuilt = moved
        rebuilt.cells = CellSelection(cells: remapped)
        return review ? .movedNeedsReview(.text(rebuilt)) : .moved(.text(rebuilt))
    }

    /// Old line index → new line index for lines that survived, by longest common subsequence. Lines left
    /// unmatched between two matches are paired by position when both gaps have the same length (an edited row),
    /// and reported in `changed`. Nil when the spans are too large to align.
    static func lineMap(_ old: [String], _ new: [String]) -> (lines: [Int: Int], changed: Set<Int>)? {
        if old == new { return (Dictionary(uniqueKeysWithValues: old.indices.map { ($0, $0) }), []) }
        guard old.count * new.count <= alignmentLimit else { return nil }
        var table = Array(repeating: Array(repeating: 0, count: new.count + 1), count: old.count + 1)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                table[i][j] = old[i] == new[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < old.count, j < new.count {
            if old[i] == new[j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        var lines: [Int: Int] = [:]
        var changed: Set<Int> = []
        var previous = (-1, -1)
        for pair in pairs + [(old.count, new.count)] {
            let oldGap = pair.0 - previous.0 - 1
            if oldGap > 0, oldGap == pair.1 - previous.1 - 1 {
                for offset in 1...oldGap {
                    lines[previous.0 + offset] = previous.1 + offset
                    changed.insert(previous.0 + offset)
                }
            }
            if pair.0 < old.count { lines[pair.0] = pair.1 }
            previous = pair
        }
        return (lines, changed)
    }

    /// Old × new line pairs compared when aligning spans; beyond it the comparison is skipped (about 32 MB).
    static let alignmentLimit = 4_000_000

    /// Whole-column notes follow the header record and find each column by its name.
    static func columns(_ anchor: TextAnchor, cells: CellSelection, in newContent: String, newHash: String) -> ReAnchorResult {
        let normalized = normalizeNewlines(newContent)
        let index = LineIndex(normalized)
        // The header is the first record; a prefix is enough to parse it.
        let prefix = String(normalized.prefix(65_536))
        guard let header = CSVParser.parse(prefix, delimiter: CSVParser.delimiter(for: prefix, fileName: ""), hasHeader: false).rows.first else { return .orphaned }
        let names = cells.headers ?? []
        var columns: [Int] = []
        var keptNames: [String] = []
        var review = false
        for (position, column) in cells.columns.enumerated() {
            let name = position < names.count ? names[position] : nil
            if let name, column < header.fields.count, header.fields[column] == name {
                columns.append(column)
            } else if let name, let found = header.fields.indices.first(where: { header.fields[$0] == name && !columns.contains($0) }) {
                columns.append(found)
                // A duplicate name could be either column.
                if header.fields.filter({ $0 == name }).count > 1 { review = true }
            } else if column < header.fields.count {
                // Renamed (or no stored name): keep the position, but have the user confirm it.
                columns.append(column)
                review = true
            } else {
                review = true
                continue
            }
            keptNames.append(header.fields[columns.last!])
        }
        guard !columns.isEmpty else { return .orphaned }
        let start = index.contentRange(ofLine: 1).location
        let endRange = index.contentRange(ofLine: header.lastLine)
        var rebuilt = make(from: NSRange(location: start, length: endRange.location + endRange.length - start), in: normalized, index: index, hash: newHash)
        rebuilt.cells = CellSelection(columns: columns, headers: keptNames)
        return review ? .movedNeedsReview(.text(rebuilt)) : .moved(.text(rebuilt))
    }

    static func lineText(_ anchor: TextAnchor, in newContent: String, newHash: String) -> ReAnchorResult {
        if let hash = anchor.hash, hash == newHash { return .unchanged }

        let normalized = normalizeNewlines(newContent)
        let index = LineIndex(normalized)
        let selected = normalizeNewlines(anchor.text)

        // 1. Exact match on the selected text; among several, the one whose surrounding lines match best.
        if !selected.isEmpty, let match = bestOccurrence(of: selected, anchor: anchor, in: normalized, index: index) {
            let rebuilt = make(from: match.range, in: normalized, index: index, hash: newHash)
            return match.ambiguous ? .movedNeedsReview(.text(rebuilt)) : .moved(.text(rebuilt))
        }

        // 2. Fuzzy match on the context lines.
        return fuzzyText(anchor, selected: selected, normalized: normalized, index: index, newHash: newHash)
    }

    /// Below this many characters a phrase is too common to look for inside a rewritten line.
    static let distinctiveLength = 12

    /// Every exact occurrence of the selected text, scored by how well the lines around it match the anchor's
    /// context (the agent inserting lines above moves the text, not its neighbours), with the distance from the
    /// old line breaking ties. With several occurrences the move is silent only when the best one's neighbours are
    /// clearly the note's (two thirds of the context lines) and clearly beat the next; otherwise it is `ambiguous`:
    /// the note still moves, but asks for a glance.
    /// Nil when no occurrence is near enough and none is recognisable by its context.
    static func bestOccurrence(of needle: String, anchor: TextAnchor, in haystack: String, index: LineIndex) -> (range: NSRange, ambiguous: Bool)? {
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
        if occurrences.count == 1 { return (occurrences[0], false) }

        let lines = (1...max(1, index.lineCount)).map { haystack.line($0, index: index) ?? "" }
        let before = anchor.before.isEmpty ? [] : anchor.before.components(separatedBy: "\n")
        let after = anchor.after.isEmpty ? [] : anchor.after.components(separatedBy: "\n")
        let limit = max(200, Int(Double(index.lineCount) * 0.2))
        struct Candidate { var range: NSRange; var context: Double; var distance: Int; var column: Int }
        let candidates = occurrences.map { range -> Candidate in
            let start = index.position(forUTF16Offset: range.location)
            let end = index.position(forUTF16Offset: range.location + range.length)
            var scores: [Double] = []
            if !before.isEmpty { scores.append(similarity(before, context(lines, before: start.line).components(separatedBy: "\n"))) }
            if !after.isEmpty { scores.append(similarity(after, context(lines, after: end.line).components(separatedBy: "\n"))) }
            let context = scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count)
            return Candidate(range: range, context: context, distance: abs(start.line - anchor.start.line), column: abs(start.col - anchor.start.col))
        }
        // Context first; a small pull towards the old place, so equal contexts (repeated blocks) keep their order.
        func score(_ candidate: Candidate) -> Double {
            candidate.context - 0.05 * min(Double(candidate.distance) / Double(limit), 1)
        }
        let ranked = candidates.sorted { lhs, rhs in
            let l = score(lhs), r = score(rhs)
            if l != r { return l > r }
            if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
            return lhs.column < rhs.column
        }
        let best = ranked[0], runnerUp = ranked[1]
        // Far from where it was and not recognisable by its neighbours: leave it to the context search instead.
        if best.context < 0.34, best.distance > limit { return nil }
        let recognised = best.context >= 0.67 && score(best) - score(runnerUp) >= 0.15
        let untouched = best.distance == 0 && best.context >= 1
        return (best.range, !(recognised || untouched))
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
        // A selection inside a line (a phrase, not whole lines): keep it a phrase when its start and end can still
        // be found in the span, rather than widening the note to the whole lines.
        if let narrowed = narrowed(selected, toSpan: span, in: normalized, index: index) {
            let rebuilt = make(from: narrowed, in: normalized, index: index, hash: newHash)
            return .movedNeedsReview(.text(rebuilt))
        }
        let start = TextPosition(line: span.lowerBound, col: 1)
        let end = TextPosition(line: span.upperBound, col: (newLines.last?.utf16.count ?? 0) + 1)
        let rebuilt = TextAnchor(
            start: start, end: end, text: newLines.joined(separator: "\n"),
            before: context(lines, before: span.lowerBound), after: context(lines, after: span.upperBound), hash: newHash
        )
        let accept = bracketed ? bracketedAcceptScore : acceptScore
        return score >= accept ? .moved(.text(rebuilt)) : .movedNeedsReview(.text(rebuilt))
    }

    /// The part of the span that begins with the selection's first words and ends with its last, when the selection
    /// was shorter than its lines. Nil for whole-line selections, or when either end is gone.
    static func narrowed(_ selected: String, toSpan span: ClosedRange<Int>, in content: String, index: LineIndex) -> NSRange? {
        let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= distinctiveLength else { return nil }
        let first = index.contentRange(ofLine: span.lowerBound)
        let last = index.contentRange(ofLine: span.upperBound)
        let spanRange = NSRange(location: first.location, length: last.location + last.length - first.location)
        let ns = content as NSString
        let spanText = ns.substring(with: spanRange)
        // Only worth it when the selection did not cover its lines.
        guard trimmed != spanText.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let length = min(16, trimmed.count / 3)
        let head = String(trimmed.prefix(length)), tail = String(trimmed.suffix(length))
        let headRange = ns.range(of: head, options: [.literal], range: spanRange)
        guard headRange.location != NSNotFound else { return nil }
        let afterHead = NSRange(location: headRange.location, length: spanRange.location + spanRange.length - headRange.location)
        let tailRange = ns.range(of: tail, options: [.literal, .backwards], range: afterHead)
        guard tailRange.location != NSNotFound, tailRange.location + tailRange.length > headRange.location + headRange.length else { return nil }
        let range = NSRange(location: headRange.location, length: tailRange.location + tailRange.length - headRange.location)
        // A phrase that grew past twice its length is no longer the same phrase.
        guard range.length <= (selected as NSString).length * 2 else { return nil }
        return range
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
        guard x.count * y.count <= alignmentLimit else {
            // Too large for a table: count shared lines instead (an upper bound on the common subsequence).
            var counts: [String: Int] = [:]
            for line in x { counts[line, default: 0] += 1 }
            var shared = 0
            for line in y where (counts[line] ?? 0) > 0 {
                counts[line]! -= 1
                shared += 1
            }
            return Double(shared) / Double(max(x.count, y.count))
        }
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

    // MARK: Embedded image

    /// A picture embedded in a document follows the text that embeds it; the note is orphaned when that text is gone
    /// or now embeds another picture. The region stays in the picture's own pixels.
    public static func embeddedImage(_ anchor: EmbeddedImageAnchor, in newContent: String, newHash: String) -> ReAnchorResult {
        let result = text(anchor.embed, in: newContent, newHash: newHash)
        func moved(_ embed: TextAnchor) -> EmbeddedImageAnchor? {
            guard embed.text.contains(anchor.source) else { return nil }
            var next = anchor
            next.embed = embed
            // The rendered view finds the picture by which embed of it this is: embeds added or removed above change that.
            next.occurrence = embedOccurrence(of: anchor.source, before: LineIndex(newContent).range(for: embed).location, in: newContent)
            return next
        }
        switch result {
        case .unchanged: return .unchanged
        case .moved(.text(let embed)): return moved(embed).map { .moved(.embeddedImage($0)) } ?? .orphaned
        case .movedNeedsReview(.text(let embed)): return moved(embed).map { .movedNeedsReview(.embeddedImage($0)) } ?? .orphaned
        default: return .orphaned
        }
    }

    /// How many embeds of `source` start before `location`, Markdown (`![alt](source…)`) and HTML (`<img src="source">`)
    /// alike: the embed at `location` is that occurrence of the picture, as the renderer counts them (both read
    /// `EmbedScanner`).
    public static func embedOccurrence(of source: String, before location: Int, in content: String) -> Int {
        EmbedScanner.occurrence(of: source, before: location, in: EmbedScanner.embeds(in: content))
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

    // MARK: Element

    /// Selector first, text second: a selector hit with the same tag keeps the note (flagged when the text changed);
    /// otherwise the one element with the same text takes over, several pick the nearest, none orphans the note.
    /// A note on part of a picture whose own size changed keeps the same part, scaled, and is flagged; on an element
    /// that is no longer a picture it loses its region and is flagged.
    public static func element(_ anchor: ElementAnchor, resolution: ElementResolution, newHash: String, line: Int? = nil) -> ReAnchorResult {
        if let hash = anchor.hash, hash == newHash { return .unchanged }
        func regionChanged(_ candidate: ElementCandidate) -> Bool {
            guard let region = anchor.region else { return false }
            return candidate.imageW != region.imageW || candidate.imageH != region.imageH
        }
        func updated(_ candidate: ElementCandidate) -> ElementAnchor {
            var next = anchor
            if let region = anchor.region, regionChanged(candidate) {
                if let w = candidate.imageW, let h = candidate.imageH, region.imageW > 0, region.imageH > 0 {
                    let sx = Double(w) / Double(region.imageW), sy = Double(h) / Double(region.imageH)
                    next.region = ImageAnchor(x: Int((Double(region.x) * sx).rounded()), y: Int((Double(region.y) * sy).rounded()),
                                              w: Int((Double(region.w) * sx).rounded()), h: Int((Double(region.h) * sy).rounded()),
                                              imageW: w, imageH: h, hash: region.hash)
                } else {
                    next.region = nil
                }
            }
            next.selector = candidate.selector
            next.tag = candidate.tag
            next.text = ElementAnchor.collapse(candidate.text, limit: ElementAnchor.textLimit)
            next.html = ElementAnchor.truncate(candidate.html, limit: ElementAnchor.htmlLimit)
            next.rect = candidate.rect
            next.line = line ?? candidate.line ?? anchor.line
            next.hash = newHash
            return next
        }
        if let hit = resolution.bySelector, hit.tag.lowercased() == anchor.tag {
            let sameText = ElementAnchor.collapse(hit.text, limit: ElementAnchor.textLimit) == anchor.text
            return sameText && !regionChanged(hit) ? .moved(.element(updated(hit))) : .movedNeedsReview(.element(updated(hit)))
        }
        let hits = resolution.byText.filter { $0.tag.lowercased() == anchor.tag }
        guard !hits.isEmpty else { return .orphaned }
        let origin = anchor.rect.center
        let nearest = hits.min { lhs, rhs in
            let l = lhs.rect.center, r = rhs.rect.center
            return (l.x - origin.x) * (l.x - origin.x) + (l.y - origin.y) * (l.y - origin.y)
                < (r.x - origin.x) * (r.x - origin.x) + (r.y - origin.y) * (r.y - origin.y)
        }!
        return .movedNeedsReview(.element(updated(nearest)))
    }
}
