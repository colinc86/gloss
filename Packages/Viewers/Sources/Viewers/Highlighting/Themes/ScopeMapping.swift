import Foundation

/// How TextMate scopes (TextMate and VS Code themes) and Xcode's syntax keys land on Gloss's capture names.
///
/// A scope takes the capture of the longest entry that is a whole-component prefix of it:
/// `entity.name.function.swift` matches `entity.name.function` (→ `function`), not `entity.name` (→ `type`).
/// When several rules land on one capture, the most general scope wins (fewest components), and on a tie the
/// later rule, as in TextMate.
public nonisolated enum ScopeMapping {
    public static let table: [(scope: String, capture: String)] = [
        ("comment", "comment"),
        ("comment.block.documentation", "comment.documentation"),
        ("string", "string"),
        ("string.regexp", "string.regexp"),
        ("string.quoted.single.char", "character"),
        ("constant.character.escape", "escape"),
        ("constant.character", "character"),
        ("constant.numeric", "number"),
        ("constant.numeric.float", "number.float"),
        ("constant.language", "constant.builtin"),
        ("constant.language.boolean", "boolean"),
        ("constant.other", "constant"),
        ("constant", "constant"),
        ("variable", "variable"),
        ("variable.parameter", "variable.parameter"),
        ("variable.language", "variable.builtin"),
        ("variable.other.member", "property"),
        ("variable.other.property", "property"),
        ("variable.other.object.property", "property"),
        ("variable.other.constant", "constant"),
        ("variable.other.enummember", "constant"),
        ("support.variable.property", "property"),
        ("meta.property-name", "property"),
        ("support.type.property-name", "property"),
        ("keyword", "keyword"),
        ("keyword.control", "keyword"),
        ("keyword.control.import", "keyword.import"),
        ("keyword.control.directive", "keyword.directive"),
        ("keyword.control.conditional", "keyword.conditional"),
        ("keyword.control.loop", "keyword.repeat"),
        ("keyword.control.flow.return", "keyword.return"),
        ("keyword.operator", "operator"),
        ("keyword.operator.new", "keyword.operator"),
        ("keyword.operator.expression", "keyword.operator"),
        ("keyword.other.unit", "number"),
        ("storage", "keyword"),
        ("storage.type", "keyword"),
        ("storage.modifier", "keyword.modifier"),
        ("storage.type.function", "keyword.function"),
        ("entity.name.type", "type"),
        ("entity.name.class", "type"),
        ("entity.name.struct", "type"),
        ("entity.name.enum", "type"),
        ("entity.name.interface", "type"),
        ("entity.name.namespace", "namespace"),
        ("entity.name.module", "namespace"),
        ("entity.name.function", "function"),
        ("entity.name.function.macro", "function.macro"),
        ("entity.name.label", "label"),
        ("entity.name.tag", "tag"),
        ("entity.name.section", "markup.heading"),
        ("entity.name", "type"),
        ("entity.other.inherited-class", "type"),
        ("entity.other.attribute-name", "attribute"),
        ("meta.attribute", "attribute"),
        ("meta.decorator", "attribute"),
        ("meta.function-call", "function.call"),
        ("support.function", "function.builtin"),
        ("support.function.builtin", "function.builtin"),
        ("support.type", "type.builtin"),
        ("support.class", "type"),
        ("support.constant", "constant.builtin"),
        ("support.variable", "variable.builtin"),
        ("punctuation", "punctuation"),
        ("punctuation.separator", "punctuation.delimiter"),
        ("punctuation.terminator", "punctuation.delimiter"),
        ("punctuation.accessor", "punctuation.delimiter"),
        ("punctuation.bracket", "punctuation.bracket"),
        ("punctuation.section", "punctuation.bracket"),
        ("punctuation.definition.tag", "tag"),
        ("punctuation.definition.string", "string"),
        ("punctuation.definition.comment", "comment"),
        ("punctuation.special", "punctuation.special"),
        ("markup.heading", "markup.heading"),
        ("markup.italic", "markup.italic"),
        ("markup.bold", "markup.bold"),
        ("markup.underline.link", "markup.link.url"),
        ("markup.link", "markup.link"),
        ("string.other.link", "markup.link.label"),
        ("markup.inline.raw", "markup.raw"),
        ("markup.raw", "markup.raw"),
        ("markup.fenced_code", "markup.raw"),
        ("markup.quote", "markup.quote"),
        ("markup.list", "markup.list"),
        ("punctuation.definition.list", "markup.list"),
        ("markup.strikethrough", "markup.strikethrough"),
        ("markup.inserted", "diff.plus"),
        ("markup.deleted", "diff.minus"),
        ("markup.changed", "diff.hunk"),
        ("meta.diff.range", "diff.hunk"),
        ("meta.diff.header", "diff.header"),
        ("meta.diff.index", "diff.header"),
        ("invalid", "error"),
    ]

    private static let lookup: [String: String] = Dictionary(table.map { ($0.scope, $0.capture) }, uniquingKeysWith: { first, _ in first })

    /// The capture a single scope maps to, or nil.
    public static func capture(forScope scope: String) -> String? {
        var components = scope.split(separator: ".").map(String.init)
        while !components.isEmpty {
            if let capture = lookup[components.joined(separator: ".")] { return capture }
            components.removeLast()
        }
        return nil
    }

    /// The scopes a TextMate selector names: comma- or `|`-separated alternatives, each reduced to its last descendant
    /// part, with exclusions (`- comment`) and parentheses dropped. A descendant selector scoped to one language
    /// (`source.python keyword`) comes back whole, so it maps to nothing rather than restyling every language.
    public static func scopes(inSelector selector: String) -> [String] {
        selector.split(whereSeparator: { $0 == "," || $0 == "|" }).compactMap { alternative in
            var included = alternative.trimmingCharacters(in: .whitespacesAndNewlines)
            // An exclusion is " - scope" (hyphens inside a scope, as in `attribute-name`, are part of it).
            guard !included.hasPrefix("-") else { return nil }
            if let exclusion = included.range(of: " -") { included = String(included[..<exclusion.lowerBound]) }
            let parts = included.replacingOccurrences(of: "(", with: " ").replacingOccurrences(of: ")", with: " ")
                .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            if parts.count > 1, let first = parts.first, first.hasPrefix("source.") || first.hasPrefix("text.") {
                return parts.joined(separator: " ")
            }
            return parts.last.map(String.init)
        }
    }

    /// Xcode's syntax keys (`xcode.syntax.…`, the part after the prefix), in priority order: when several keys land
    /// on one capture, the earliest listed wins, whatever order the file has them in. (`plain` is the foreground.)
    public static let xcode: [(key: String, capture: String)] = [
        ("comment", "comment"),
        ("comment.doc", "comment.documentation"),
        ("comment.doc.keyword", "comment.documentation"),
        ("string", "string"),
        ("character", "character"),
        ("number", "number"),
        ("keyword", "keyword"),
        ("preprocessor", "keyword.directive"),
        ("url", "markup.link.url"),
        ("attribute", "attribute"),
        ("mark", "label"),
        ("regex", "string.regexp"),
        ("identifier.type", "type"),
        ("identifier.class", "type"),
        ("declaration.type", "type"),
        ("identifier.type.system", "type.builtin"),
        ("identifier.class.system", "type.builtin"),
        ("identifier.function", "function"),
        ("declaration.other", "function"),
        ("identifier.function.system", "function.builtin"),
        ("identifier.constant", "constant"),
        ("identifier.constant.system", "constant.builtin"),
        ("identifier.variable", "property"),
        ("identifier.variable.system", "variable.builtin"),
        ("identifier.macro", "function.macro"),
        ("identifier.macro.system", "function.macro"),
        ("markup.code", "markup.raw"),
    ]
}
