import AppKit

/// Maps tree-sitter capture names to colors. A dotted name falls back to its prefix (`function.call` → `function`).
public nonisolated enum SyntaxTheme {
    nonisolated private static let colors: [String: NSColor] = [
        "keyword": .systemPurple,
        "keyword.function": .systemPurple,
        "keyword.return": .systemPurple,
        "keyword.operator": .systemPurple,
        "include": .systemPurple,
        "conditional": .systemPurple,
        "repeat": .systemPurple,
        "string": .systemRed,
        "string.special": .systemRed,
        "character": .systemRed,
        "escape": .systemOrange,
        "comment": .systemGray,
        "type": .systemTeal,
        "type.builtin": .systemTeal,
        "constructor": .systemTeal,
        "function": .systemBlue,
        "function.call": .systemBlue,
        "function.method": .systemBlue,
        "function.builtin": .systemBlue,
        "method": .systemBlue,
        "variable": .labelColor,
        "variable.builtin": .systemIndigo,
        "variable.parameter": .labelColor,
        "parameter": .labelColor,
        "property": .systemIndigo,
        "field": .systemIndigo,
        "number": .systemOrange,
        "float": .systemOrange,
        "boolean": .systemOrange,
        "constant": .systemOrange,
        "constant.builtin": .systemOrange,
        "operator": .secondaryLabelColor,
        "punctuation": .secondaryLabelColor,
        "punctuation.bracket": .secondaryLabelColor,
        "punctuation.delimiter": .secondaryLabelColor,
        "punctuation.special": .systemPink,
        "attribute": .systemBrown,
        "label": .systemBrown,
        "namespace": .systemTeal,
        "tag": .systemBlue,
        "text.title": .systemBlue,
        "markup.heading": .systemBlue,
        "text.emphasis": .systemPink,
        "markup.italic": .systemPink,
        "text.strong": .systemPink,
        "markup.bold": .systemPink,
        "text.literal": .systemRed,
        "markup.raw": .systemRed,
        "text.uri": .systemBlue,
        "markup.link": .systemBlue,
        "markup.link.url": .systemBlue,
        "markup.link.label": .systemTeal,
        "text.reference": .systemTeal,
        "markup.list": .secondaryLabelColor,
        "markup.quote": .systemGray,
        "text.quote": .systemGray,
        "markup.strikethrough": .secondaryLabelColor,
        "none": .labelColor,
    ]

    public nonisolated static func color(forCapture name: String) -> NSColor? {
        if let exact = colors[name] { return exact }
        var components = name.split(separator: ".")
        while components.count > 1 {
            components.removeLast()
            if let color = colors[components.joined(separator: ".")] { return color }
        }
        return nil
    }
}
