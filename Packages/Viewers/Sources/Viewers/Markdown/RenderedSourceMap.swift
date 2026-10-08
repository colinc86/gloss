import Foundation

/// One run of rendered text that came from a span of source.
public struct SourceSpan: Equatable, Sendable {
    public var rendered: NSRange
    public var source: NSRange
    /// Rendered characters equal source characters one to one, so offsets inside the run map directly.
    public var exact: Bool

    public init(rendered: NSRange, source: NSRange, exact: Bool) {
        self.rendered = rendered
        self.source = source
        self.exact = exact
    }
}

/// Bidirectional mapping between rendered markdown and its source, in UTF-16 units.
public struct RenderedSourceMap: Sendable {
    /// Sorted by rendered location, non-overlapping.
    public let spans: [SourceSpan]
    /// Block-level spans (paragraphs, headings, items) for coarse fallbacks, sorted by rendered location.
    public let blocks: [SourceSpan]

    public init(spans: [SourceSpan], blocks: [SourceSpan]) {
        self.spans = spans.sorted { $0.rendered.location < $1.rendered.location }
        self.blocks = blocks.sorted { $0.rendered.location < $1.rendered.location }
    }

    public struct Mapping: Equatable, Sendable {
        public var source: NSRange
        /// True when every rendered character in the selection mapped exactly to source characters.
        public var exact: Bool
    }

    /// Source range for a rendered selection. Exact inside exact runs; otherwise the union of the runs' sources,
    /// widened to the enclosing block when the selection touches generated text only.
    public func sourceRange(forRendered rendered: NSRange) -> Mapping? {
        let renderedEnd = rendered.location + rendered.length
        var touched = spans.filter { span in
            let spanEnd = span.rendered.location + span.rendered.length
            return rendered.length == 0 ? (span.rendered.location <= rendered.location && rendered.location < spanEnd)
                                        : (span.rendered.location < renderedEnd && rendered.location < spanEnd)
        }
        if rendered.length == 0, touched.isEmpty {
            // A caret at the very end of a run belongs to that run, not to the next one.
            touched = spans.filter { $0.rendered.location + $0.rendered.length == rendered.location }.suffix(1).map { $0 }
        }
        if touched.isEmpty {
            guard let block = blocks.first(where: { NSIntersectionRange($0.rendered, rendered).length > 0 || ($0.rendered.location <= rendered.location && rendered.location <= $0.rendered.location + $0.rendered.length) }) else { return nil }
            return Mapping(source: block.source, exact: false)
        }
        // Exact only inside one exact run: generated text (bullets, separators) between runs has no source.
        var exact = touched.count == 1 && touched[0].exact
            && touched[0].rendered.location <= rendered.location && renderedEnd <= touched[0].rendered.location + touched[0].rendered.length
        var start = Int.max
        var end = 0
        for span in touched {
            if span.exact {
                let from = max(rendered.location, span.rendered.location) - span.rendered.location + span.source.location
                let to = min(renderedEnd, span.rendered.location + span.rendered.length) - span.rendered.location + span.source.location
                start = min(start, from)
                end = max(end, to)
            } else {
                exact = false
                start = min(start, span.source.location)
                end = max(end, span.source.location + span.source.length)
            }
        }
        guard start <= end else { return nil }
        return Mapping(source: NSRange(location: start, length: end - start), exact: exact)
    }

    /// Rendered ranges that show a source range (several when the source spans runs). A point (a note whose text
    /// was removed) maps to one rendered point: exact inside an exact run, else the start of the run it falls in, or
    /// the end of the run it follows; never a whole run or block.
    public func renderedRanges(forSource source: NSRange) -> [NSRange] {
        if source.length == 0 { return renderedPoint(forSource: source.location).map { [NSRange(location: $0, length: 0)] } ?? [] }
        let sourceEnd = source.location + source.length
        var ranges: [NSRange] = []
        for span in spans {
            let spanEnd = span.source.location + span.source.length
            let overlaps = source.length == 0
                ? (span.source.location <= source.location && source.location < spanEnd)
                : (span.source.location < sourceEnd && source.location < spanEnd)
            guard overlaps else { continue }
            if span.exact {
                let from = max(source.location, span.source.location) - span.source.location + span.rendered.location
                let to = min(sourceEnd, spanEnd) - span.source.location + span.rendered.location
                if to > from { ranges.append(NSRange(location: from, length: to - from)) }
            } else {
                ranges.append(span.rendered)
            }
        }
        return ranges
    }

    private func renderedPoint(forSource location: Int) -> Int? {
        if let span = spans.first(where: { $0.source.location <= location && location < $0.source.location + $0.source.length }) {
            return span.exact ? span.rendered.location + location - span.source.location : span.rendered.location
        }
        // Between runs (where removed text was): the end of the run it follows, else the start of the next.
        if let before = spans.last(where: { $0.source.location + $0.source.length == location }) {
            return before.rendered.location + before.rendered.length
        }
        return spans.first { $0.source.location >= location }?.rendered.location
            ?? spans.last.map { $0.rendered.location + $0.rendered.length }
    }
}
