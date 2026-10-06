import Foundation

/// Finds the pictures a Markdown document embeds, `![alt](src)` (or `![alt][ref]`), `<img src="src">` and a
/// `<picture>`'s `<source srcset="src">` alike, in document order. A source counts whether or not it is the one drawn
/// (it is under Reduce Motion when its `media` asks for that), so the numbering never depends on the setting. It is the one definition of "which embed of a picture is this": the renderer numbers the pictures
/// it draws by it and the re-anchorer follows notes by it, so the two agree by construction.
///
/// It reads the document as CommonMark blocks do, closely enough to skip what is never drawn as a picture: fenced
/// and indented code, code spans, HTML comments, and Markdown image syntax inside HTML blocks (which stays literal).
public enum EmbedScanner {
    public struct Embed: Equatable, Sendable {
        /// The picture as the document names it: a Markdown destination with escapes and entities decoded, an
        /// `<img>`'s `src` as written, or the first address in a `<source>`'s `srcset`.
        public var source: String
        /// The whole embed: `![alt](src)` from `!`, or the `<img …>` or `<source …>` tag.
        public var range: NSRange
    }

    public static func embeds(in content: String) -> [Embed] {
        var scanner = Scanner(content)
        return scanner.scan()
    }

    /// The first address in a `srcset` (`hero.png 1x, hero@2x.png 2x` names `hero.png`).
    public static func firstCandidate(inSrcset srcset: String) -> String {
        let trimmed = srcset.drop { $0.isWhitespace }
        return String(trimmed.prefix { !$0.isWhitespace && $0 != "," })
    }

    /// How many embeds of `source` start before `location`.
    public static func occurrence(of source: String, before location: Int, in embeds: [Embed]) -> Int {
        embeds.reduce(0) { $0 + ($1.source == source && $1.range.location < location ? 1 : 0) }
    }

    // MARK: Scanning

    private enum LineKind { case blank, text, code, html }

    private struct Scanner {
        let units: [UInt16]
        let index: LineIndex
        var embeds: [Embed] = []
        var references: [String: String] = [:]

        init(_ content: String) {
            units = Array(content.utf16)
            index = LineIndex(content)
        }

        mutating func scan() -> [Embed] {
            let kinds = classify()
            references = definitions(kinds)
            var line = 0
            while line < kinds.count {
                let kind = kinds[line]
                var last = line
                while last + 1 < kinds.count, kinds[last + 1] == kind { last += 1 }
                let start = index.contentRange(ofLine: line + 1).location
                let end = NSMaxRange(index.contentRange(ofLine: last + 1))
                switch kind {
                case .text: scanInline(start, end)
                case .html: scanHTML(start, end)
                case .blank, .code: break
                }
                line = last + 1
            }
            return embeds
        }

        // MARK: Blocks

        /// Each line's block: code (fenced or indented), an HTML block, text, or blank.
        func classify() -> [LineKind] {
            var kinds: [LineKind] = []
            var fence: (char: UInt16, length: Int)?
            var html: Int?  // the open HTML block's CommonMark type
            var previous = LineKind.blank
            var inList = false
            for line in 1...index.lineCount {
                let range = index.contentRange(ofLine: line)
                var i = afterQuotes(range)
                let end = NSMaxRange(range)
                var kind = LineKind.text
                defer {
                    kinds.append(kind)
                    previous = kind
                }
                let blank = (i..<end).allSatisfy { isSpace(units[$0]) }
                if let open = fence {
                    kind = .code
                    let j = skipSpaces(skipListMarkers(i, end), end)
                    if run(of: open.char, at: j, end) >= open.length, (j + run(of: open.char, at: j, end)..<end).allSatisfy({ isSpace(units[$0]) }) { fence = nil }
                    continue
                }
                if let type = html {
                    if type >= 6 {
                        if blank { html = nil; kind = .blank } else { kind = .html }
                    } else {
                        kind = .html
                        if htmlEnds(type, i, end) { html = nil }
                    }
                    continue
                }
                if blank { kind = .blank; continue }
                let indent = columns(i, end)
                if indent >= 4, !inList, previous == .blank || previous == .code {
                    kind = .code
                    continue
                }
                let core = skipListMarkers(i, end)
                if core != i { inList = true } else if indent == 0, previous == .blank { inList = false }
                i = skipSpaces(core, end)
                if i < end, units[i] == 96 || units[i] == 126 /* ` ~ */ {
                    let length = run(of: units[i], at: i, end)
                    if length >= 3, units[i] == 126 || !(i + length..<end).contains(where: { units[$0] == 96 }) {
                        fence = (units[i], length)
                        kind = .code
                        continue
                    }
                }
                if let type = htmlStart(i, end, interruptsParagraph: previous != .text) {
                    kind = .html
                    if type < 6, !htmlEnds(type, i, end, opening: true) { html = type } else if type >= 6 { html = type }
                }
            }
            return kinds
        }

        /// The CommonMark HTML block type (1–7) a line starts, if any.
        func htmlStart(_ i: Int, _ end: Int, interruptsParagraph: Bool) -> Int? {
            guard i < end, units[i] == 60 else { return nil }
            if matches("<!--", at: i) { return 2 }
            if matches("<?", at: i) { return 3 }
            if matches("<![CDATA[", at: i) { return 5 }
            if i + 2 < end, units[i + 1] == 33, isLetter(units[i + 2]) { return 4 }
            let closing = i + 1 < end && units[i + 1] == 47
            var j = closing ? i + 2 : i + 1
            let nameStart = j
            while j < end, isLetter(units[j]) || (48...57).contains(units[j]) || units[j] == 45 { j += 1 }
            let name = lowercased(nameStart, j)
            guard !name.isEmpty else { return nil }
            let boundary = j == end || isSpace(units[j]) || units[j] == 62 || (units[j] == 47 && j + 1 < end && units[j + 1] == 62)
            if !closing, ["script", "pre", "style", "textarea"].contains(name), j == end || isSpace(units[j]) || units[j] == 62 { return 1 }
            if boundary, Self.blockNames.contains(name) { return 6 }
            // Type 7: a complete tag alone on its line, which cannot interrupt a paragraph.
            guard interruptsParagraph, let tagEnd = tagEnd(from: j, end) else { return nil }
            return (tagEnd..<end).allSatisfy { isSpace(units[$0]) } ? 7 : nil
        }

        func htmlEnds(_ type: Int, _ i: Int, _ end: Int, opening: Bool = false) -> Bool {
            let from = opening ? i + 2 : i
            switch type {
            case 1: return ["</script>", "</pre>", "</style>", "</textarea>"].contains { find($0, from: from, end) != nil }
            case 2: return find("-->", from: opening ? i + 4 : i, end) != nil
            case 3: return find("?>", from: from, end) != nil
            case 4: return find(">", from: from, end) != nil
            case 5: return find("]]>", from: from, end) != nil
            default: return false
            }
        }

        static let blockNames: Set<String> = [
            "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center", "col", "colgroup",
            "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "frame",
            "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr", "html", "iframe", "legend", "li", "link",
            "main", "menu", "menuitem", "nav", "noframes", "ol", "optgroup", "option", "p", "param", "search", "section",
            "summary", "table", "tbody", "td", "tfoot", "th", "thead", "title", "tr", "track", "ul",
        ]

        /// Link reference definitions (`[label]: destination`) on text lines, for `![alt][label]`.
        func definitions(_ kinds: [LineKind]) -> [String: String] {
            var found: [String: String] = [:]
            for (offset, kind) in kinds.enumerated() where kind == .text {
                let range = index.contentRange(ofLine: offset + 1)
                let end = NSMaxRange(range)
                var i = skipSpaces(afterQuotes(range), end)
                guard i < end, units[i] == 91 /* [ */, let close = closingBracket(i, end), close + 1 < end, units[close + 1] == 58 /* : */ else { continue }
                let label = Self.normalized(string(i + 1, close))
                i = skipSpaces(close + 2, end)
                guard let (destination, _) = destination(i, end), found[label] == nil else { continue }
                found[label] = destination
            }
            return found
        }

        // MARK: Inlines

        /// Text lines: code spans and comments are skipped; `![…](…)`, `![…][…]` and `<img>` are embeds.
        mutating func scanInline(_ start: Int, _ end: Int) {
            var i = start
            while i < end {
                switch units[i] {
                case 92 /* \ */:
                    i += 2
                case 96 /* ` */:
                    let length = run(of: 96, at: i, end)
                    var j = i + length
                    var closed: Int?
                    while j < end {
                        if units[j] == 96 {
                            let other = run(of: 96, at: j, end)
                            if other == length { closed = j + other; break }
                            j += other
                        } else {
                            j += 1
                        }
                    }
                    i = closed ?? i + length
                case 60 /* < */:
                    if matches("<!--", at: i), let close = find("-->", from: i + 4, end) {
                        i = close + 3
                    } else if let tag = image(i, end) {
                        i = tag
                    } else {
                        i += 1
                    }
                case 33 /* ! */ where i + 1 < end && units[i + 1] == 91:
                    i = markdownImage(i, end) ?? i + 1
                default:
                    i += 1
                }
            }
        }

        /// HTML blocks: only `<img>` tags outside comments.
        mutating func scanHTML(_ start: Int, _ end: Int) {
            var i = start
            while i < end {
                if units[i] == 60, matches("<!--", at: i) {
                    i = find("-->", from: i + 4, end).map { $0 + 3 } ?? end
                } else if units[i] == 60, let tag = image(i, end) {
                    i = tag
                } else {
                    i += 1
                }
            }
        }

        /// An `<img …>` or `<source …>` tag at `i`: records it and returns the offset after it.
        mutating func image(_ i: Int, _ end: Int) -> Int? {
            let tag = matches("<img", at: i, caseInsensitive: true) ? 4 : matches("<source", at: i, caseInsensitive: true) ? 7 : 0
            guard tag > 0, i + tag < end, isSpace(units[i + tag]) || units[i + tag] == 47 || units[i + tag] == 62 else { return nil }
            let attributeName = tag == 4 ? "src" : "srcset"
            var j = i + tag
            var source: String?
            while j < end, units[j] != 62 {
                if isSpace(units[j]) || units[j] == 47 { j += 1; continue }
                let nameStart = j
                while j < end, !isSpace(units[j]), units[j] != 47, units[j] != 62, units[j] != 61 { j += 1 }
                let name = lowercased(nameStart, j)
                j = skipWhitespace(j, end)
                guard j < end, units[j] == 61 else { continue }
                j = skipWhitespace(j + 1, end)
                var value = ""
                if j < end, units[j] == 34 || units[j] == 39 {
                    let quote = units[j]
                    let valueStart = j + 1
                    j = valueStart
                    while j < end, units[j] != quote { j += 1 }
                    guard j < end else { return nil }
                    value = string(valueStart, j)
                    j += 1
                } else {
                    let valueStart = j
                    while j < end, !isSpace(units[j]), units[j] != 62 { j += 1 }
                    value = string(valueStart, j)
                }
                if name == attributeName, source == nil { source = attributeName == "src" ? value : EmbedScanner.firstCandidate(inSrcset: value) }
            }
            guard j < end else { return nil }
            if let source { embeds.append(Embed(source: source, range: NSRange(location: i, length: j + 1 - i))) }
            return j + 1
        }

        /// `![alt](destination "title")`, `![alt][label]`, `![alt][]` or `![alt]` at `i`: records it when it is one
        /// and returns the offset after it.
        mutating func markdownImage(_ i: Int, _ end: Int) -> Int? {
            guard let close = closingBracket(i + 1, end) else { return nil }
            let after = close + 1
            if after < end, units[after] == 40 /* ( */ {
                guard let (source, next) = destination(skipWhitespace(after + 1, end), end) else { return nil }
                var j = skipWhitespace(next, end)
                if j < end, let closer = [34: 34, 39: 39, 40: 41][units[j]] {
                    j += 1
                    while j < end, units[j] != UInt16(closer) { j += units[j] == 92 ? 2 : 1 }
                    j = skipWhitespace(j + 1, end)
                }
                guard j < end, units[j] == 41 else { return nil }
                embeds.append(Embed(source: source, range: NSRange(location: i, length: j + 1 - i)))
                return j + 1
            }
            var label = string(i + 2, close)
            var next = after
            if after < end, units[after] == 91, let labelClose = closingBracket(after, end) {
                let written = string(after + 1, labelClose)
                if !written.isEmpty { label = written }
                next = labelClose + 1
            }
            guard let source = references[Self.normalized(label)] else { return nil }
            embeds.append(Embed(source: source, range: NSRange(location: i, length: next - i)))
            return next
        }

        /// A link destination at `i` (`<…>` or bare with balanced parentheses), decoded, and the offset after it.
        func destination(_ i: Int, _ end: Int) -> (String, Int)? {
            guard i < end else { return nil }
            if units[i] == 60 {
                var j = i + 1
                while j < end, units[j] != 62, units[j] != 10 { j += units[j] == 92 ? 2 : 1 }
                guard j < end, units[j] == 62 else { return nil }
                return (Self.decoded(string(i + 1, j)), j + 1)
            }
            var j = i
            var depth = 0
            while j < end, !isSpace(units[j]) {
                if units[j] == 92 { j += 2; continue }
                if units[j] == 40 { depth += 1 }
                if units[j] == 41 { if depth == 0 { break }; depth -= 1 }
                j += 1
            }
            j = min(j, end)
            return (Self.decoded(string(i, j)), j)
        }

        /// The `]` closing the `[` at `i`, with nesting and escapes, not past a blank line.
        func closingBracket(_ i: Int, _ end: Int) -> Int? {
            var depth = 0
            var j = i
            while j < end {
                switch units[j] {
                case 92: j += 1
                case 91: depth += 1
                case 93:
                    depth -= 1
                    if depth == 0 { return j }
                case 10 where j + 1 < end && units[j + 1] == 10: return nil
                default: break
                }
                j += 1
            }
            return nil
        }

        // MARK: Helpers

        /// Past a line's block-quote markers (`> `, `>>`).
        func afterQuotes(_ range: NSRange) -> Int {
            let end = NSMaxRange(range)
            var i = range.location
            while true {
                let j = skipSpaces(i, end)
                guard j < end, units[j] == 62, j - i <= 3 else { return i }
                i = j + 1
                if i < end, units[i] == 32 { i += 1 }
            }
        }

        /// Past any list markers (`- `, `1. `, `- 1) `) and the spaces before them.
        func skipListMarkers(_ i: Int, _ end: Int) -> Int {
            var i = i
            while true {
                let j = skipSpaces(i, end)
                var k = j
                if k < end, units[k] == 45 || units[k] == 42 || units[k] == 43 {
                    k += 1
                } else {
                    while k < end, (48...57).contains(units[k]), k - j < 9 { k += 1 }
                    guard k > j, k < end, units[k] == 46 || units[k] == 41 else { return i }
                    k += 1
                }
                guard k == end || units[k] == 32 || units[k] == 9 else { return i }
                i = k
            }
        }

        func columns(_ i: Int, _ end: Int) -> Int {
            var count = 0
            var j = i
            while j < end, units[j] == 32 || units[j] == 9 {
                count += units[j] == 9 ? 4 - count % 4 : 1
                j += 1
            }
            return count
        }

        func skipSpaces(_ i: Int, _ end: Int) -> Int {
            var j = i
            while j < end, units[j] == 32 || units[j] == 9 { j += 1 }
            return j
        }

        func skipWhitespace(_ i: Int, _ end: Int) -> Int {
            var j = i
            while j < end, isSpace(units[j]) { j += 1 }
            return j
        }

        func run(of unit: UInt16, at i: Int, _ end: Int) -> Int {
            var j = i
            while j < end, units[j] == unit { j += 1 }
            return j - i
        }

        func tagEnd(from i: Int, _ end: Int) -> Int? {
            var j = i
            var quote: UInt16?
            while j < end {
                if let open = quote {
                    if units[j] == open { quote = nil }
                } else if units[j] == 34 || units[j] == 39 {
                    quote = units[j]
                } else if units[j] == 62 {
                    return j + 1
                }
                j += 1
            }
            return nil
        }

        func matches(_ word: String, at i: Int, caseInsensitive: Bool = false) -> Bool {
            let target = Array(word.utf16)
            guard i + target.count <= units.count else { return false }
            for (offset, unit) in target.enumerated() {
                let actual = units[i + offset]
                if actual != unit, !(caseInsensitive && (65...90).contains(actual) && actual + 32 == unit) { return false }
            }
            return true
        }

        func find(_ needle: String, from i: Int, _ end: Int) -> Int? {
            var j = i
            while j < end {
                if matches(needle, at: j, caseInsensitive: true) { return j }
                j += 1
            }
            return nil
        }

        func isSpace(_ unit: UInt16) -> Bool { unit == 32 || unit == 9 || unit == 10 || unit == 13 || unit == 12 }
        func isLetter(_ unit: UInt16) -> Bool { (65...90).contains(unit) || (97...122).contains(unit) }
        func string(_ start: Int, _ end: Int) -> String { String(decoding: units[start..<max(start, end)], as: UTF16.self) }
        func lowercased(_ start: Int, _ end: Int) -> String { string(start, end).lowercased() }

        static func normalized(_ label: String) -> String {
            label.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }

        /// Backslash escapes and the common character references, as CommonMark decodes a destination.
        static func decoded(_ text: String) -> String {
            guard text.contains("\\") || text.contains("&") else { return text }
            var result = ""
            var rest = Substring(text)
            while let first = rest.first {
                if first == "\\", let next = rest.dropFirst().first, next.isASCII, next.isPunctuation || next.isSymbol {
                    result.append(next)
                    rest = rest.dropFirst(2)
                } else if first == "&", let semicolon = rest.prefix(12).firstIndex(of: ";") {
                    let body = rest[rest.index(after: rest.startIndex)..<semicolon]
                    let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}"]
                    var decoded = named[String(body)]
                    if decoded == nil, body.hasPrefix("#") {
                        let digits = body.dropFirst()
                        let value = digits.lowercased().hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                        decoded = value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                    }
                    if let decoded {
                        result += decoded
                        rest = rest[rest.index(after: semicolon)...]
                    } else {
                        result.append(first)
                        rest = rest.dropFirst()
                    }
                } else {
                    result.append(first)
                    rest = rest.dropFirst()
                }
            }
            return result
        }
    }
}
