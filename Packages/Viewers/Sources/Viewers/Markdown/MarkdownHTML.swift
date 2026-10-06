import Foundation

/// The HTML rendered Markdown draws: the small set READMEs use (centered pictures and headings, bold, links,
/// collapsible details). Anything else stays source, so a table or script is never half drawn.
nonisolated enum MarkdownHTML {
    enum Token: Equatable {
        /// Attribute names are lowercased; values are as written, entities and all.
        case start(name: String, attributes: [String: String], range: NSRange)
        case end(name: String, range: NSRange)
        case comment(range: NSRange)
        case text(range: NSRange)
        /// A doctype, processing instruction or CDATA section: never drawn.
        case other(range: NSRange)
    }

    /// Tags that start their own paragraph (or row, cell or list item). GitHub's allowlist, where TextKit can draw it.
    static let blockTags: Set<String> = [
        "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "details", "summary", "blockquote", "ul", "ol", "li", "pre", "hr",
        "table", "thead", "tbody", "tfoot", "tr", "th", "td", "dl", "dt", "dd",
    ]
    /// Tags drawn inside a paragraph. `picture` draws its `img`; `source` is ignored; `span` changes nothing.
    static let inlineTags: Set<String> = [
        "b", "strong", "i", "em", "a", "img", "source", "code", "br", "picture", "kbd", "sup", "sub", "s", "del", "strike",
        "ins", "u", "span",
    ]
    /// Tags with no content and no end tag.
    static let voidTags: Set<String> = ["img", "source", "br", "hr"]
    /// A table's own structure, below `table`.
    static let tableParts: Set<String> = ["thead", "tbody", "tfoot", "tr", "th", "td"]

    /// Whether rendered Markdown can draw `tokens` (from `html`): every tag is one it knows, and the structure is one
    /// it lays out. A table's cells hold inline content only (no paragraphs, lists or tables of their own), a list
    /// item sits in a list, nothing but cells sits directly in a table, and a `<pre>` holds no blocks. End tags a
    /// browser would imply (`<td>` after `<td>`, `<li>` after `<li>`) are implied here too.
    static func isDrawable(_ tokens: [Token], in html: String) -> Bool {
        let units = Array(html.utf16)
        var open: [String] = []
        func last(_ names: Set<String>) -> Int { open.lastIndex { names.contains($0) } ?? -1 }
        func end(_ names: Set<String>, within containers: Set<String>) {
            let boundary = last(containers)
            if let index = open.indices.first(where: { $0 > boundary && names.contains(open[$0]) }) { open.removeSubrange(index...) }
        }
        for token in tokens {
            switch token {
            case .other:
                return false
            case .comment:
                continue
            case .text(let range):
                let blank = (range.location..<(range.location + range.length)).allSatisfy { HTMLTextProjection.isSpace(units[$0]) }
                if !blank, let top = open.last, top == "table" || (tableParts.contains(top) && top != "td" && top != "th") { return false }
            case .end(let name, _):
                if let index = open.lastIndex(of: name) { open.removeSubrange(index...) }
            case .start(let name, _, _):
                guard blockTags.contains(name) || inlineTags.contains(name) else { return false }
                let table = last(["table"])
                let cell = last(["td", "th"])
                let inCell = table >= 0 && cell > table
                switch name {
                case "td", "th":
                    guard table >= 0 else { return false }
                    end(["td", "th"], within: ["table", "tr"])
                case "tr":
                    guard table >= 0 else { return false }
                    end(["tr", "td", "th"], within: ["table", "thead", "tbody", "tfoot"])
                case "thead", "tbody", "tfoot":
                    guard table >= 0 else { return false }
                    end(tableParts, within: ["table"])
                case "li":
                    // In a table a list item is either in a cell (a block there) or loose in the table.
                    guard last(["ul", "ol"]) >= 0, table < 0, !open.contains("pre") else { return false }
                    end(["li"], within: ["ul", "ol"])
                case "dt", "dd":
                    guard table < 0, !open.contains("pre") else { return false }
                    end(["dt", "dd"], within: ["dl"])
                default:
                    if table >= 0, !inCell { return false }
                    if blockTags.contains(name), inCell || open.contains("pre") { return false }
                }
                if !voidTags.contains(name) { open.append(name) }
            }
        }
        return true
    }

    /// Tags, comments and text runs, with their UTF-16 ranges in `html`.
    static func tokens(_ html: String) -> [Token] {
        let units = Array(html.utf16)
        var tokens: [Token] = []
        var textStart: Int?
        func isLetter(_ unit: UInt16) -> Bool { (65...90).contains(unit) || (97...122).contains(unit) }
        func lower(_ unit: UInt16) -> UInt16 { (65...90).contains(unit) ? unit + 32 : unit }
        func matches(_ word: String, at index: Int) -> Bool {
            let target = Array(word.utf16)
            guard index + target.count <= units.count else { return false }
            for offset in target.indices where units[index + offset] != target[offset] { return false }
            return true
        }
        func find(_ needle: String, from index: Int) -> Int? {
            var i = index
            while i < units.count {
                if matches(needle, at: i) { return i }
                i += 1
            }
            return nil
        }
        func flushText(_ end: Int) {
            if let start = textStart, end > start { tokens.append(.text(range: NSRange(location: start, length: end - start))) }
            textStart = nil
        }
        var i = 0
        while i < units.count {
            guard units[i] == 60 /* < */, i + 1 < units.count else {
                if textStart == nil { textStart = i }
                i += 1
                continue
            }
            let next = units[i + 1]
            if matches("<!--", at: i) {
                flushText(i)
                let end = (find("-->", from: i + 4).map { $0 + 3 }) ?? units.count
                tokens.append(.comment(range: NSRange(location: i, length: end - i)))
                i = end
                continue
            }
            if next == 33 /* ! */ || next == 63 /* ? */ {
                flushText(i)
                let end = (find(">", from: i + 2).map { $0 + 1 }) ?? units.count
                tokens.append(.other(range: NSRange(location: i, length: end - i)))
                i = end
                continue
            }
            let closing = next == 47 /* / */
            let nameStart = closing ? i + 2 : i + 1
            guard nameStart < units.count, isLetter(units[nameStart]) else {
                if textStart == nil { textStart = i }
                i += 1
                continue
            }
            flushText(i)
            var j = nameStart
            while j < units.count, !HTMLTextProjection.isSpace(units[j]), units[j] != 47, units[j] != 62 { j += 1 }
            let name = String(decoding: units[nameStart..<j].map(lower), as: UTF16.self)
            var attributes: [String: String] = [:]
            // Attributes up to the closing `>`: `name`, `name=value`, `name="value"`, `name='value'`.
            while j < units.count, units[j] != 62 /* > */ {
                if HTMLTextProjection.isSpace(units[j]) || units[j] == 47 { j += 1; continue }
                let attributeStart = j
                while j < units.count, !HTMLTextProjection.isSpace(units[j]), units[j] != 47, units[j] != 62, units[j] != 61 { j += 1 }
                let attribute = String(decoding: units[attributeStart..<j].map(lower), as: UTF16.self)
                while j < units.count, HTMLTextProjection.isSpace(units[j]) { j += 1 }
                var value = ""
                if j < units.count, units[j] == 61 /* = */ {
                    j += 1
                    while j < units.count, HTMLTextProjection.isSpace(units[j]) { j += 1 }
                    if j < units.count, units[j] == 34 || units[j] == 39 {
                        let quote = units[j]
                        let valueStart = j + 1
                        j = valueStart
                        while j < units.count, units[j] != quote { j += 1 }
                        value = String(decoding: units[valueStart..<j], as: UTF16.self)
                        if j < units.count { j += 1 }
                    } else {
                        let valueStart = j
                        while j < units.count, !HTMLTextProjection.isSpace(units[j]), units[j] != 62 { j += 1 }
                        value = String(decoding: units[valueStart..<j], as: UTF16.self)
                    }
                }
                if !attribute.isEmpty, attributes[attribute] == nil { attributes[attribute] = value }
            }
            let end = min(units.count, j + 1)
            let range = NSRange(location: i, length: end - i)
            tokens.append(closing ? .end(name: name, range: range) : .start(name: name, attributes: attributes, range: range))
            i = end
        }
        flushText(units.count)
        return tokens
    }

    /// Whether a `<source>`'s `media` holds here: none at all, `all` or `screen`, or the reduced-motion query that
    /// matches the setting. Anything else (a color scheme, a width) is not followed, so the `<img>` stands.
    static func mediaMatches(_ media: String?, reduceMotion: Bool) -> Bool {
        let query = (media ?? "").lowercased().filter { !$0.isWhitespace }
        switch query {
        case "", "all", "screen": return true
        case "(prefers-reduced-motion:reduce)": return reduceMotion
        case "(prefers-reduced-motion:no-preference)": return !reduceMotion
        default: return false
        }
    }

    /// An attribute value with its character references decoded (`&amp;` in a link).
    static func decoded(_ value: String) -> String {
        guard value.contains("&") else { return value }
        let units = Array(value.utf16)
        var result = ""
        var i = 0
        while i < units.count {
            if units[i] == 38, let entity = HTMLTextProjection.entity(in: units, at: i) {
                result += entity.text
                i += entity.length
            } else {
                var j = i + 1
                while j < units.count, units[j] != 38 { j += 1 }
                result += String(decoding: units[i..<j], as: UTF16.self)
                i = j
            }
        }
        return result
    }

    /// The largest `width` or `height` taken as written.
    static let maximumPixels = 10_000.0

    /// A `width` or `height` in pixels (`128`, `128px`); nil for percentages and anything else.
    static func pixels(_ value: String?) -> CGFloat? {
        guard var value = value?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        if value.hasSuffix("px") { value.removeLast(2) }
        guard let number = Double(value), number.isFinite, number > 0 else { return nil }
        return CGFloat(min(number, maximumPixels))
    }
}
