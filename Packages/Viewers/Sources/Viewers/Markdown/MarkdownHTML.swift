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

    /// Tags that start their own paragraph.
    static let blockTags: Set<String> = ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "details", "summary"]
    /// Tags drawn inside a paragraph. `picture` draws its `img`; `source` is ignored.
    static let inlineTags: Set<String> = ["b", "strong", "i", "em", "a", "img", "source", "code", "br", "picture"]
    /// Tags with no content and no end tag.
    static let voidTags: Set<String> = ["img", "source", "br"]

    /// Whether every tag in `tokens` is one rendered Markdown draws.
    static func isDrawable(_ tokens: [Token]) -> Bool {
        tokens.allSatisfy { token in
            switch token {
            case .start(let name, _, _), .end(let name, _): blockTags.contains(name) || inlineTags.contains(name)
            case .comment, .text: true
            case .other: false
            }
        }
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
