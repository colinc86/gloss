import Foundation

/// Why a note couldn't be moved where an agent said. Plain words, since the agent reads them through MCP.
public enum RelocationError: Error, Equatable, Sendable {
    /// The text isn't in the file within `lines` (the lines given, then `AnchorRelocator.searchRadius` either side).
    case notFound(text: String, lines: ClosedRange<Int>)
    /// Notes on images, PDFs, pictures and whole files have no text to follow.
    case notMovable(AnchorType)
    /// The location is for another kind of note: a selector for text, or lines for a page element.
    case wrongKind(AnchorType)
    case lineOutOfRange(line: Int, lineCount: Int)
    case emptyText
    case invalidSelector
}

extension RelocationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound(let text, let lines):
            let quoted = text.count > 80 ? String(text.prefix(79)) + "…" : text
            return "The text \"\(quoted)\" isn't in the file between lines \(lines.lowerBound) and \(lines.upperBound); give the exact new text and its lines."
        case .notMovable(let type):
            return "This note is on \(type == .file ? "the whole file" : "an image or PDF region"); it can't be moved."
        case .wrongKind(.element):
            return "This note is on a page element; give its new `selector`."
        case .wrongKind:
            return "This note is on text; give `line`, `end_line` and `text`, or `removed` and `line`."
        case .lineOutOfRange(let line, let lineCount):
            return "Line \(line) is outside the file, which has \(lineCount.counted("line"))."
        case .emptyText:
            return "`text` is empty; to say the note's text was removed, pass `removed: true` and `line`."
        case .invalidSelector:
            return "`selector` must be one CSS selector on one line."
        }
    }
}

/// Where an agent says a note now is, in the terms it can give.
public enum RelocationTarget: Sendable, Equatable {
    /// The lines the change is on and its exact new text.
    case text(line: Int, endLine: Int, text: String)
    /// The note's text was removed; `line` is where it was: where what followed it now starts.
    case removed(line: Int)
    /// A page element's new selector.
    case element(selector: String)
}

/// Builds a note's new anchor from an agent's description of where its change is, against the document's current
/// text. Columns, context and hash always come from the text, never from the agent. Pure: the caller reads the text
/// and stores the result (`NoteStore.applyRelocation`, or with the agent's reply in one write).
public enum AnchorRelocator {
    /// How far from the given lines the text is looked for.
    public static let searchRadius = 50

    /// The note's new place for `target`. `content` and `hash` are the document's current text and its SHA-256;
    /// an element target needs neither.
    public static func relocate(_ anchor: Anchor, to target: RelocationTarget, content: String, hash: String?) throws -> NoteRelocation {
        switch (anchor, target) {
        case (.text, .text(let line, let endLine, let text)):
            return NoteRelocation(anchor: .text(try self.text(in: content, hash: hash, line: line, endLine: endLine, text: text)), removed: false)
        case (.text, .removed(let line)):
            return NoteRelocation(anchor: .text(try removed(in: content, hash: hash, line: line)), removed: true)
        case (.element(let old), .element(let selector)):
            return NoteRelocation(anchor: .element(try element(selector: selector, from: old)), removed: false)
        case (.text, .element):
            throw RelocationError.wrongKind(.text)
        case (.element, _):
            throw RelocationError.wrongKind(.element)
        case (.image, _), (.pdf, _), (.wholeFile, _), (.embeddedImage, _):
            throw RelocationError.notMovable(anchor.type)
        }
    }

    /// `text` exactly as it is in `content`: within lines `line`...`endLine` first, then the occurrence nearest to
    /// `line` within `searchRadius` lines. Trailing newlines of `text` are ignored, and CRLF matches LF.
    public static func text(in content: String, hash: String?, line: Int, endLine: Int, text: String) throws -> TextAnchor {
        let normalized = ReAnchorer.normalizeNewlines(content)
        var needle = ReAnchorer.normalizeNewlines(text)
        while needle.hasSuffix("\n") { needle.removeLast() }
        guard !needle.isEmpty else { throw RelocationError.emptyText }
        let index = LineIndex(normalized)
        guard line >= 1, line <= index.lineCount else { throw RelocationError.lineOutOfRange(line: line, lineCount: index.lineCount) }
        let last = min(max(line, endLine), index.lineCount)
        let ns = normalized as NSString
        func span(_ first: Int, _ last: Int) -> NSRange {
            let start = index.range(ofLine: first).location
            let end = index.contentRange(ofLine: last)
            return NSRange(location: start, length: end.location + end.length - start)
        }
        let given = ns.range(of: needle, options: [.literal], range: span(line, last))
        if given.location != NSNotFound {
            return ReAnchorer.make(from: given, in: normalized, index: index, hash: hash)
        }
        let window = max(1, line - searchRadius)...min(index.lineCount, last + searchRadius)
        var best: (range: NSRange, distance: Int)?
        var searchRange = span(window.lowerBound, window.upperBound)
        let windowEnd = searchRange.location + searchRange.length
        while searchRange.length > 0 {
            let found = ns.range(of: needle, options: [.literal], range: searchRange)
            guard found.location != NSNotFound else { break }
            let distance = abs(index.position(forUTF16Offset: found.location).line - line)
            if best == nil || distance < best!.distance { best = (found, distance) }
            let next = found.location + max(1, found.length)
            searchRange = NSRange(location: next, length: max(0, windowEnd - next))
        }
        guard let best else { throw RelocationError.notFound(text: needle, lines: window) }
        return ReAnchorer.make(from: best.range, in: normalized, index: index, hash: hash)
    }

    /// A point where the note's text was removed, at the start of `line`: what now sits where the text was (the
    /// first line with something on it, if `line` is blank). Past the last line, the end of the file.
    public static func removed(in content: String, hash: String?, line: Int) throws -> TextAnchor {
        let normalized = ReAnchorer.normalizeNewlines(content)
        let index = LineIndex(normalized)
        guard line >= 1, line <= index.lineCount + 1 else { throw RelocationError.lineOutOfRange(line: line, lineCount: index.lineCount) }
        let lines = (1...max(1, index.lineCount)).map { normalized.line($0, index: index) ?? "" }
        let point: TextPosition
        if line > lines.count {
            point = TextPosition(line: lines.count, col: lines[lines.count - 1].utf16.count + 1)
        } else {
            let filled = (line...min(lines.count, line + searchRadius)).first { !lines[$0 - 1].trimmingCharacters(in: .whitespaces).isEmpty }
            point = TextPosition(line: filled ?? line, col: 1)
        }
        return ReAnchorer.make(from: NSRange(location: index.utf16Offset(for: point), length: 0), in: normalized, index: index, hash: hash)
    }

    /// An element note on a page, under the selector the agent gave. The page bridge checks the selector the next
    /// time the page resolves its notes; until then the element's other facts are the old ones, and the hash is
    /// cleared so that check happens.
    public static func element(selector: String, from old: ElementAnchor) throws -> ElementAnchor {
        let selector = selector.trimmingCharacters(in: .whitespaces)
        guard !selector.isEmpty, !selector.contains(where: \.isNewline) else { throw RelocationError.invalidSelector }
        var moved = old
        moved.selector = selector
        moved.hash = nil
        return moved
    }
}
