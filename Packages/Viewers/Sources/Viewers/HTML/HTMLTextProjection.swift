import Foundation

/// The text a browser keeps from an HTML document (every text node, as `documentElement.textContent` reports it),
/// with each UTF-16 unit mapped back to the source span it came from. Tags, comments, and doctypes produce no
/// text; entities decode to their characters; `<script>`, `<style>`, `<textarea>`, and `<title>` content is text.
///
/// The browser's parser can still differ from this scan (dropped leading whitespace, foster-parented table
/// text), so the rendered view aligns this text with the DOM's before mapping offsets (`alignment(withDOM:)`).
nonisolated public struct HTMLTextProjection: Sendable {
    /// The projected text.
    public let text: String
    /// Source UTF-16 offset where each projected unit starts.
    let starts: [Int]
    /// Source UTF-16 offset just after each projected unit (an entity's units all end after the `;`).
    let ends: [Int]

    public init(_ source: String) {
        let units = Array(source.utf16)
        var text: [UInt16] = []
        var starts: [Int] = []
        var ends: [Int] = []
        text.reserveCapacity(units.count / 2)

        func emit(_ string: String, from start: Int, to end: Int) {
            for unit in string.utf16 {
                text.append(unit)
                starts.append(start)
                ends.append(end)
            }
        }
        func lower(_ unit: UInt16) -> UInt16 { (65...90).contains(unit) ? unit + 32 : unit }
        func matches(_ word: String, at index: Int) -> Bool {
            let target = Array(word.utf16)
            guard index + target.count <= units.count else { return false }
            for offset in target.indices where lower(units[index + offset]) != target[offset] { return false }
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
        func isLetter(_ unit: UInt16) -> Bool { (65...90).contains(unit) || (97...122).contains(unit) }

        let rawText = ["script", "style"]
        let escapableRawText = ["textarea", "title"]
        var i = 0
        while i < units.count {
            let unit = units[i]
            if unit == 60 /* < */, i + 1 < units.count {
                let next = units[i + 1]
                if matches("<!--", at: i) {
                    // `<!-->` and `<!--->` are complete (empty) comments.
                    if matches("<!-->", at: i) { i += 5; continue }
                    if matches("<!--->", at: i) { i += 6; continue }
                    i = (find("-->", from: i + 4).map { $0 + 3 }) ?? units.count
                    continue
                }
                if next == 33 /* ! */ || next == 63 /* ? */ {
                    i = (find(">", from: i + 2).map { $0 + 1 }) ?? units.count
                    continue
                }
                if isLetter(next) || (next == 47 /* / */ && i + 2 < units.count && isLetter(units[i + 2])) {
                    // A tag: skip to its closing `>`, honouring quoted attribute values.
                    var j = i + 1
                    var quote: UInt16?
                    var afterEquals = false
                    while j < units.count {
                        let c = units[j]
                        if let open = quote {
                            if c == open { quote = nil }
                        } else if (c == 34 || c == 39) && afterEquals {
                            // Quotes open a value only right after `=` (spaces allowed); `title=it's` is unquoted.
                            quote = c
                        } else if c == 62 /* > */ {
                            break
                        }
                        if quote == nil, c == 61 /* = */ { afterEquals = true } else if !Self.isSpace(c) { afterEquals = false }
                        j += 1
                    }
                    let tagEnd = min(units.count, j + 1)
                    // Raw text elements: everything up to the matching end tag is one text run.
                    // A tag name ends at whitespace, `/`, or `>`: `<title-bar>` is a custom element, not `<title>`.
                    if next != 47, let name = (rawText + escapableRawText).first(where: { name in
                        let end = i + 1 + name.utf16.count
                        return matches("<" + name, at: i) && end < units.count && (Self.isSpace(units[end]) || units[end] == 47 || units[end] == 62)
                    }) {
                        let close = find("</" + name, from: tagEnd) ?? units.count
                        var k = tagEnd
                        while k < close {
                            if escapableRawText.contains(name), units[k] == 38, let entity = Self.entity(in: units, at: k) {
                                emit(entity.text, from: k, to: k + entity.length)
                                k += entity.length
                            } else if units[k] == 13, k + 1 < close, units[k + 1] == 10 {
                                emit("\n", from: k, to: k + 2)
                                k += 2
                            } else {
                                text.append(units[k] == 13 ? 10 : units[k])
                                starts.append(k)
                                ends.append(k + 1)
                                k += 1
                            }
                        }
                        i = close
                        continue
                    }
                    i = tagEnd
                    continue
                }
            }
            if unit == 38 /* & */, let entity = Self.entity(in: units, at: i) {
                emit(entity.text, from: i, to: i + entity.length)
                i += entity.length
                continue
            }
            if unit == 13 /* \r */ {
                // The parser normalizes CRLF and lone CR to LF.
                let length = i + 1 < units.count && units[i + 1] == 10 ? 2 : 1
                emit("\n", from: i, to: i + length)
                i += length
                continue
            }
            text.append(unit)
            starts.append(i)
            ends.append(i + 1)
            i += 1
        }
        self.text = String(decoding: text, as: UTF16.self)
        self.starts = starts
        self.ends = ends
    }

    public var length: Int { starts.count }

    nonisolated static func isSpace(_ unit: UInt16) -> Bool { unit == 32 || unit == 9 || unit == 10 || unit == 13 || unit == 12 }

    /// The source range a projected range came from.
    public func sourceRange(forProjected range: NSRange) -> NSRange? {
        guard range.length > 0, range.location >= 0, range.location + range.length <= starts.count else { return nil }
        let start = starts[range.location]
        let end = ends[range.location + range.length - 1]
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Projected ranges covering a source range (one run; text inside tags has no projection). A point (a note whose
    /// text was removed) stays a point: before the first projected character at or after it.
    public func projectedRange(forSource source: NSRange) -> NSRange? {
        if source.length == 0 {
            var low = 0, high = ends.count
            while low < high {
                let mid = (low + high) / 2
                if ends[mid] <= source.location { low = mid + 1 } else { high = mid }
            }
            return starts.isEmpty ? nil : NSRange(location: low, length: 0)
        }
        let sourceEnd = source.location + source.length
        // First unit ending after the source start, last unit starting before its end.
        var low = 0, high = ends.count
        while low < high {
            let mid = (low + high) / 2
            if ends[mid] <= source.location { low = mid + 1 } else { high = mid }
        }
        let first = low
        low = first
        high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] < max(sourceEnd, source.location + 1) { low = mid + 1 } else { high = mid }
        }
        let last = low - 1
        guard first < starts.count, last >= first else { return nil }
        return NSRange(location: first, length: last - first + 1)
    }

    // MARK: Entities

    nonisolated static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "copy": "©", "reg": "®",
        "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "bull": "•", "middot": "·", "deg": "°", "times": "×", "divide": "÷", "laquo": "«", "raquo": "»", "euro": "€",
        "pound": "£", "yen": "¥", "cent": "¢", "sect": "§", "para": "¶", "larr": "←", "rarr": "→", "uarr": "↑",
        "darr": "↓", "harr": "↔", "check": "✓", "zwj": "\u{200D}", "zwnj": "\u{200C}", "shy": "\u{00AD}",
        "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}", "sbquo": "‚", "bdquo": "„", "dagger": "†",
        "Dagger": "‡", "permil": "‰", "lsaquo": "‹", "rsaquo": "›", "prime": "′", "Prime": "″", "oline": "‾",
        "frasl": "⁄", "iexcl": "¡", "iquest": "¿", "curren": "¤", "brvbar": "¦", "uml": "¨", "ordf": "ª", "ordm": "º",
        "not": "¬", "macr": "¯", "plusmn": "±", "sup1": "¹", "sup2": "²", "sup3": "³", "acute": "´", "micro": "µ",
        "cedil": "¸", "frac14": "¼", "frac12": "½", "frac34": "¾", "minus": "−", "le": "≤", "ge": "≥", "ne": "≠",
        "asymp": "≈", "infin": "∞", "sum": "∑", "prod": "∏", "radic": "√", "part": "∂", "nabla": "∇", "isin": "∈",
        "forall": "∀", "exist": "∃", "empty": "∅", "and": "∧", "or": "∨", "cap": "∩", "cup": "∪", "int": "∫",
        "rArr": "⇒", "lArr": "⇐", "hArr": "⇔", "spades": "♠", "clubs": "♣", "hearts": "♥", "diams": "♦", "loz": "◊",
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ",
        "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "omicron": "ο", "pi": "π", "rho": "ρ",
        "sigma": "σ", "sigmaf": "ς", "tau": "τ", "upsilon": "υ", "phi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Alpha": "Α", "Beta": "Β", "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Pi": "Π", "Sigma": "Σ",
        "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω", "szlig": "ß", "OElig": "Œ", "oelig": "œ", "Scaron": "Š", "scaron": "š",
        "Yuml": "Ÿ", "fnof": "ƒ", "circ": "ˆ", "tilde": "˜",
    ]

    /// Latin-1 letters by name (`&eacute;`, `&Ntilde;`, …), built from their accents.
    nonisolated static let latinLetters: [String: String] = {
        var table: [String: String] = [:]
        let accents: [(String, String)] = [("grave", "\u{300}"), ("acute", "\u{301}"), ("circ", "\u{302}"), ("tilde", "\u{303}"), ("uml", "\u{308}"), ("ring", "\u{30A}"), ("cedil", "\u{327}")]
        for base in "aeiouyncAEIOUYNC" {
            for (name, mark) in accents {
                let composed = (String(base) + mark).precomposedStringWithCanonicalMapping
                if composed.unicodeScalars.count == 1 { table[String(base) + name] = composed }
            }
        }
        table["aelig"] = "æ"; table["AElig"] = "Æ"; table["oslash"] = "ø"; table["Oslash"] = "Ø"
        table["eth"] = "ð"; table["ETH"] = "Ð"; table["thorn"] = "þ"; table["THORN"] = "Þ"
        return table
    }()

    /// Entities browsers also accept without the `;` (the legacy set's most common members).
    nonisolated static let legacy = ["amp", "lt", "gt", "quot", "nbsp", "copy", "reg"]

    /// A character reference at `index` (`&amp;`, `&#38;`, `&#x26;`), or nil when the text there is not one.
    nonisolated static func entity(in units: [UInt16], at index: Int) -> (text: String, length: Int)? {
        var j = index + 1
        var name: [UInt16] = []
        while j < units.count, j - index <= 32, units[j] != 59 /* ; */ {
            let c = units[j]
            guard (48...57).contains(c) || (65...90).contains(c) || (97...122).contains(c) || c == 35 /* # */ else { break }
            name.append(c)
            j += 1
        }
        guard !name.isEmpty else { return nil }
        let body = String(decoding: name, as: UTF16.self)
        guard j < units.count, units[j] == 59 else {
            // `&amp b`, `&copy 2024`: a legacy entity without its semicolon.
            guard let prefix = legacy.first(where: { body.hasPrefix($0) }), let text = named[prefix] else { return nil }
            return (text, prefix.utf16.count + 1)
        }
        let length = j - index + 1
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value = digits.lowercased().hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits, radix: 10)
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return (String(Character(scalar)), length)
        }
        guard let text = named[body] ?? latinLetters[body] else { return nil }
        return (text, length)
    }

    // MARK: Aligning with the DOM

    /// Maps between DOM text offsets and projection offsets. The two texts are nearly always equal; where the
    /// browser dropped or kept whitespace this scan did not, the walk skips whitespace on either side.
    public struct Alignment: Sendable {
        /// Projection offset for each DOM offset (nil where the DOM has text the projection lacks).
        let domToProjection: [Int?]
        /// DOM offset for each projection offset.
        let projectionToDOM: [Int?]

        public func projected(_ dom: NSRange) -> NSRange? {
            guard dom.length > 0, dom.location >= 0, dom.location + dom.length <= domToProjection.count else { return nil }
            let mapped = (dom.location..<(dom.location + dom.length)).compactMap { domToProjection[$0] }
            guard let first = mapped.first, let last = mapped.last else { return nil }
            return NSRange(location: first, length: last - first + 1)
        }

        public func dom(_ projected: NSRange) -> NSRange? {
            if projected.length == 0 {
                // A point sits before the character at it, or after the one before it at the end of the text.
                let location = projected.location
                if location < projectionToDOM.count, location >= 0, let dom = projectionToDOM[location] { return NSRange(location: dom, length: 0) }
                if location > 0, location <= projectionToDOM.count, let dom = projectionToDOM[location - 1] { return NSRange(location: dom + 1, length: 0) }
                return nil
            }
            guard projected.length > 0, projected.location >= 0, projected.location + projected.length <= projectionToDOM.count else { return nil }
            let mapped = (projected.location..<(projected.location + projected.length)).compactMap { projectionToDOM[$0] }
            guard let first = mapped.first, let last = mapped.last else { return nil }
            return NSRange(location: first, length: last - first + 1)
        }
    }

    /// The smallest skip on each side (within `window`) after which `run` units agree again.
    nonisolated static func resync(_ a: [UInt16], _ i: Int, _ b: [UInt16], _ j: Int, window: Int = 32, run: Int = 4) -> (Int, Int)? {
        func agree(_ x: Int, _ y: Int) -> Bool {
            guard x + run <= a.count, y + run <= b.count else { return false }
            for k in 0..<run where a[x + k] != b[y + k] { return false }
            return true
        }
        for total in 1...(2 * window) {
            for skipA in max(0, total - window)...min(total, window) where agree(i + skipA, j + total - skipA) {
                return (skipA, total - skipA)
            }
        }
        return nil
    }

    public func alignment(withDOM dom: String) -> Alignment {
        let a = Array(dom.utf16)
        let b = Array(text.utf16)
        var domToProjection = [Int?](repeating: nil, count: a.count)
        var projectionToDOM = [Int?](repeating: nil, count: b.count)
        func isSpace(_ unit: UInt16) -> Bool { unit == 32 || unit == 9 || unit == 10 || unit == 13 || unit == 12 }
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                domToProjection[i] = j
                projectionToDOM[j] = i
                i += 1
                j += 1
            } else if isSpace(a[i]) {
                i += 1
            } else if isSpace(b[j]) {
                j += 1
            } else if let (skipA, skipB) = Self.resync(a, i, b, j) {
                // A real difference (an entity this scan does not know, text a script rewrote): jump to where the
                // texts agree again rather than pairing up unrelated characters.
                i += skipA
                j += skipB
            } else {
                i += 1
                j += 1
            }
        }
        return Alignment(domToProjection: domToProjection, projectionToDOM: projectionToDOM)
    }
}
