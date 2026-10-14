import AppKit

/// A syntax theme: the colors code is drawn with (tokens and the editor around them) and its font. One theme is one
/// palette; a preset with light and dark variants is two themes. Stored as JSON (see `CodeTheme+Decoding.swift`).
public nonisolated struct CodeTheme: Hashable, Identifiable, Sendable {
    public static let formatVersion = 1

    public var formatVersion: Int
    /// `[a-z0-9-]{1,64}`, and the file name: `<id>.json`.
    public var id: String
    public var name: String
    public var appearance: Appearance
    public var editor: EditorColors
    /// Keyed by tree-sitter capture name; a dotted name falls back to its prefix.
    public var tokens: [String: TokenStyle]
    public var font: ThemeFont
    /// Where a preset's palette comes from and its license; an import keeps the source file's name.
    public var license: String?

    public nonisolated enum Appearance: String, Codable, Sendable, CaseIterable {
        case light, dark, any
    }

    public init(id: String, name: String, appearance: Appearance, editor: EditorColors, tokens: [String: TokenStyle],
                font: ThemeFont = ThemeFont(), license: String? = nil) {
        formatVersion = Self.formatVersion
        self.id = id
        self.name = name
        self.appearance = appearance
        self.editor = editor
        self.tokens = tokens
        self.font = font
        self.license = license
    }

    /// A capture's style: its own key, else the longest dotted prefix that has one (`function.call` → `function`).
    /// Nil when nothing matches, so the text keeps `editor.foreground`.
    /// Older grammars' names (`text.title`, `conditional`) are tried under their current ones when nothing matches
    /// them directly, so a theme that sets only `markup.heading` or `keyword` still colors them.
    public func style(forCapture name: String) -> TokenStyle? {
        if let style = longestPrefixStyle(name) { return style }
        return Self.alias(of: name).flatMap(longestPrefixStyle)
    }

    private func longestPrefixStyle(_ name: String) -> TokenStyle? {
        if let exact = tokens[name] { return exact }
        var end = name.endIndex
        while let dot = name[..<end].lastIndex(of: ".") {
            end = dot
            if let style = tokens[String(name[..<dot])] { return style }
        }
        return nil
    }

    /// Capture names some bundled grammars use, under the names the theme editor lists. Never one that Gloss leaves
    /// plain (CSS's `import` stays uncolored, as it always was): a test checks Gloss against every bundled capture.
    static let captureAliases: [String: String] = [
        "text.title": "markup.heading", "text.emphasis": "markup.italic", "text.strong": "markup.bold",
        "text.literal": "markup.raw", "text.uri": "markup.link.url", "text.reference": "markup.link.label",
        "text.quote": "markup.quote", "conditional": "keyword.conditional", "repeat": "keyword.repeat",
        "include": "keyword.import", "boolean": "constant.builtin.boolean",
        "float": "number.float", "field": "property", "method": "function.method", "parameter": "variable.parameter",
        "constructor": "type.constructor", "character": "string.character", "delimiter": "punctuation.delimiter",
        "label": "attribute.label",
    ]

    public func color(forCapture name: String) -> NSColor? {
        style(forCapture: name)?.color?.nsColor
    }

    /// Sets a key's style. With `clearingDescendants`, the keys this row owns are removed so the change shows
    /// everywhere it applies, which is what an edit in the theme editor means: more specific keys (`keyword.function`
    /// under `keyword`) and older names that alias into it (`text.title` under `markup.heading`).
    ///
    /// A key belongs to the most specific editor row that covers it, so a row never clears another row or what that
    /// row owns: editing Punctuation leaves Special Punctuation (`punctuation.special`) alone, Variable leaves
    /// Built-in Variable, and Link leaves Link Label.
    public mutating func setStyle(_ style: TokenStyle?, forKey key: String, clearingDescendants: Bool = false) {
        if clearingDescendants {
            for existing in tokens.keys where existing != key && Self.owningRow(of: existing) == key {
                tokens[existing] = nil
            }
        }
        tokens[key] = style
    }

    /// The editor row (`editableTokens` key) a token key belongs to: the longest row that is the key or a dotted
    /// prefix of it, else of its alias. Nil when no row covers it.
    static func owningRow(of key: String) -> String? {
        func row(_ name: String) -> String? {
            editableRowKeys.filter { name == $0 || name.hasPrefix($0 + ".") }.max { $0.count < $1.count }
        }
        if let own = row(key) { return own }
        return alias(of: key).flatMap(row)
    }

    static func alias(of name: String) -> String? {
        let first = name.split(separator: ".", maxSplits: 1).first.map(String.init) ?? name
        return captureAliases[name] ?? captureAliases[first].map { $0 + name.dropFirst(first.count) }
    }

    static let editableRowKeys: Set<String> = Set(editableTokens.map(\.key))

    public var isBuiltIn: Bool { Self.builtInIDs.contains(id) }

    /// The appearances this theme is drawn in: one for a light or dark theme, both for one that adapts.
    public var appearanceNames: [NSAppearance.Name] {
        switch appearance {
        case .light: [.aqua]
        case .dark: [.darkAqua]
        case .any: [.aqua, .darkAqua]
        }
    }
}

public nonisolated struct TokenStyle: Hashable, Sendable {
    public var color: ThemeColor?
    public var bold: Bool
    public var italic: Bool

    public init(color: ThemeColor?, bold: Bool = false, italic: Bool = false) {
        self.color = color
        self.bold = bold
        self.italic = italic
    }

    /// The editor font with this style's weight and slant.
    public func font(from base: NSFont) -> NSFont {
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        guard !traits.isEmpty else { return base }
        let descriptor = base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }
}

public nonisolated struct EditorColors: Hashable, Sendable {
    /// The editor and the Markdown source view.
    public var background: ThemeColor
    /// Plain text.
    public var foreground: ThemeColor
    public var selection: ThemeColor
    /// The current line's band.
    public var currentLine: ThemeColor
    public var lineNumbers: ThemeColor
    public var currentLineNumber: ThemeColor
    public var gutterBackground: ThemeColor
    /// Indent guides.
    public var invisibles: ThemeColor
    public var cursor: ThemeColor
    /// Fenced code blocks in rendered Markdown.
    public var codeBlockBackground: ThemeColor

    public init(background: ThemeColor, foreground: ThemeColor, selection: ThemeColor, currentLine: ThemeColor,
                lineNumbers: ThemeColor, currentLineNumber: ThemeColor, gutterBackground: ThemeColor, invisibles: ThemeColor,
                cursor: ThemeColor, codeBlockBackground: ThemeColor) {
        self.background = background
        self.foreground = foreground
        self.selection = selection
        self.currentLine = currentLine
        self.lineNumbers = lineNumbers
        self.currentLineNumber = currentLineNumber
        self.gutterBackground = gutterBackground
        self.invisibles = invisibles
        self.cursor = cursor
        self.codeBlockBackground = codeBlockBackground
    }

    /// Every color from the two that matter, the rest mixed from the foreground over the background. Any of them
    /// can be given; the ones left nil are derived.
    public static func derived(background: ThemeColor, foreground: ThemeColor, selection: ThemeColor? = nil,
                               currentLine: ThemeColor? = nil, lineNumbers: ThemeColor? = nil,
                               currentLineNumber: ThemeColor? = nil, gutterBackground: ThemeColor? = nil,
                               invisibles: ThemeColor? = nil, cursor: ThemeColor? = nil,
                               codeBlockBackground: ThemeColor? = nil) -> EditorColors {
        let appearance: NSAppearance.Name = ThemeContrast.isDark(background) ? .darkAqua : .aqua
        func mix(_ amount: Double) -> ThemeColor { foreground.mixed(over: background, amount: amount, in: appearance) }
        return EditorColors(background: background, foreground: foreground, selection: selection ?? mix(0.25),
                            currentLine: currentLine ?? mix(0.05), lineNumbers: lineNumbers ?? mix(0.45),
                            currentLineNumber: currentLineNumber ?? foreground, gutterBackground: gutterBackground ?? background,
                            invisibles: invisibles ?? mix(0.15), cursor: cursor ?? foreground,
                            codeBlockBackground: codeBlockBackground ?? mix(0.06))
    }
}

public nonisolated struct ThemeFont: Hashable, Sendable {
    /// A PostScript or family name; nil is the system monospaced font.
    public var family: String?
    /// Points; nil is Settings › Editor's size.
    public var size: Double?
    /// A line-height multiple, 1…2; nil is 1.
    public var lineSpacing: Double?

    public static let lineSpacingRange: ClosedRange<Double> = 1 ... 2
    public static let sizeRange: ClosedRange<Double> = 6 ... 72

    public init(family: String? = nil, size: Double? = nil, lineSpacing: Double? = nil) {
        self.family = family
        self.size = size.flatMap { $0.isFinite ? min(max($0, Self.sizeRange.lowerBound), Self.sizeRange.upperBound) : nil }
        self.lineSpacing = lineSpacing.flatMap {
            $0.isFinite ? min(max($0, Self.lineSpacingRange.lowerBound), Self.lineSpacingRange.upperBound) : nil
        }
    }

    /// The font to draw code with: the family at the theme's size (else `defaultSize`), or the system monospaced font
    /// when the family isn't installed.
    public func resolved(defaultSize: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let size = size.map { CGFloat($0) } ?? defaultSize
        if let named = namedFont(size: size) {
            guard weight != .regular else { return named }
            let descriptor = named.fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight]])
            return NSFont(descriptor: descriptor, size: size) ?? named
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// False when `family` names a font this Mac doesn't have.
    public var isAvailable: Bool { family == nil || namedFont(size: 12) != nil }

    private func namedFont(size: CGFloat) -> NSFont? {
        guard let family, !family.isEmpty else { return nil }
        if let font = NSFont(name: family, size: size) { return font }
        return NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
    }
}

// MARK: - Built-ins

nonisolated extension CodeTheme {
    /// Today's colors: system colors, the system background, the current font. The default in both pickers, and
    /// what a missing or broken theme falls back to.
    public static let gloss: CodeTheme = {
        func system(_ name: String) -> ThemeColor { .system(name) }
        let editor = EditorColors(background: system("textBackgroundColor"), foreground: system("textColor"),
                                  selection: system("selectedTextBackgroundColor"), currentLine: system("glossCurrentLine"),
                                  lineNumbers: system("tertiaryLabelColor"), currentLineNumber: system("labelColor"),
                                  gutterBackground: system("windowBackgroundColor"), invisibles: system("glossGuide"),
                                  cursor: system("textInsertionPointColor"), codeBlockBackground: system("quaternarySystemFill"))
        let tokens = glossTokens.mapValues { TokenStyle(color: system($0)) }
        return CodeTheme(id: "gloss", name: "Gloss", appearance: .any, editor: editor, tokens: tokens,
                         license: "Gloss's own colors (macOS system colors).")
    }()

    /// The same table as `SyntaxTheme`, by system color name (a test keeps the two equal).
    static let glossTokens: [String: String] = [
        "keyword": "systemPurple", "keyword.function": "systemPurple", "keyword.return": "systemPurple",
        "keyword.operator": "systemPurple", "include": "systemPurple", "conditional": "systemPurple", "repeat": "systemPurple",
        "diff.plus": "systemGreen", "diff.minus": "systemRed", "diff.hunk": "systemPurple", "diff.header": "secondaryLabelColor",
        "string": "systemRed", "string.special": "systemRed", "character": "systemRed", "escape": "systemOrange",
        "comment": "systemGray",
        "type": "systemTeal", "type.builtin": "systemTeal", "constructor": "systemTeal",
        "function": "systemBlue", "function.call": "systemBlue", "function.method": "systemBlue",
        "function.builtin": "systemBlue", "method": "systemBlue",
        "variable": "labelColor", "variable.builtin": "systemIndigo", "variable.parameter": "labelColor", "parameter": "labelColor",
        "property": "systemIndigo", "field": "systemIndigo",
        "number": "systemOrange", "float": "systemOrange", "boolean": "systemOrange", "constant": "systemOrange",
        "constant.builtin": "systemOrange",
        "operator": "secondaryLabelColor", "punctuation": "secondaryLabelColor", "punctuation.bracket": "secondaryLabelColor",
        "punctuation.delimiter": "secondaryLabelColor", "delimiter": "secondaryLabelColor", "punctuation.special": "systemPink",
        "attribute": "systemBrown", "label": "systemBrown", "namespace": "systemTeal", "tag": "systemBlue",
        "text.title": "systemBlue", "markup.heading": "systemBlue", "text.emphasis": "systemPink", "markup.italic": "systemPink",
        "text.strong": "systemPink", "markup.bold": "systemPink", "text.literal": "systemRed", "markup.raw": "systemRed",
        "text.uri": "systemBlue", "markup.link": "systemBlue", "markup.link.url": "systemBlue", "markup.link.label": "systemTeal",
        "text.reference": "systemTeal", "markup.list": "secondaryLabelColor", "markup.quote": "systemGray",
        "text.quote": "systemGray", "markup.strikethrough": "secondaryLabelColor", "none": "labelColor",
    ]

    /// Gloss first, then the bundled presets by name. A preset that fails to decode is left out (a test makes sure
    /// none does).
    public static var builtIns: [CodeTheme] { [gloss] + presets }

    static let presets: [CodeTheme] = {
        guard let folder = Bundle.module.url(forResource: "Presets", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? CodeTheme.decode($0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()

    static let builtInIDs: Set<String> = Set(builtIns.map(\.id))

    // MARK: Editable tokens

    public nonisolated struct EditableToken: Hashable, Sendable, Identifiable {
        public enum Group: String, Sendable, CaseIterable { case code = "Code", markup = "Markup", diff = "Diff" }
        public let key: String
        public let label: String
        public let group: Group
        public var id: String { key }
    }

    /// The theme editor's rows, in order.
    public static let editableTokens: [EditableToken] = {
        let code: [(String, String)] = [
            ("keyword", "Keyword"), ("string", "String"), ("escape", "Escape"), ("comment", "Comment"), ("type", "Type"),
            ("function", "Function"), ("variable", "Variable"), ("variable.builtin", "Built-in Variable"),
            ("property", "Property"), ("number", "Number"), ("constant", "Constant"), ("operator", "Operator"),
            ("punctuation", "Punctuation"), ("punctuation.special", "Special Punctuation"), ("tag", "Tag"),
            ("attribute", "Attribute"), ("namespace", "Namespace"),
        ]
        let markup: [(String, String)] = [
            ("markup.heading", "Heading"), ("markup.italic", "Emphasis"), ("markup.bold", "Strong"), ("markup.link", "Link"),
            ("markup.link.label", "Link Label"), ("markup.raw", "Raw Text"), ("markup.list", "List"), ("markup.quote", "Quote"),
            ("markup.strikethrough", "Strikethrough"),
        ]
        let diff: [(String, String)] = [
            ("diff.plus", "Added"), ("diff.minus", "Removed"), ("diff.hunk", "Hunk"), ("diff.header", "Diff Header"),
        ]
        return code.map { EditableToken(key: $0.0, label: $0.1, group: .code) }
            + markup.map { EditableToken(key: $0.0, label: $0.1, group: .markup) }
            + diff.map { EditableToken(key: $0.0, label: $0.1, group: .diff) }
    }()
}
