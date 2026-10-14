import AppKit

public nonisolated enum CodeThemeError: Error, Equatable, Sendable, LocalizedError {
    /// Over `CodeTheme.maximumFileSize`.
    case tooLarge(bytes: Int)
    /// Not JSON or a property list, or a required key is missing; says where.
    case malformed(String)
    case unsupportedVersion(Int)
    case invalidIdentifier(String)
    case invalidColor(key: String, value: String)
    /// An import that isn't a theme in any format Gloss reads.
    case unknownFormat
    /// A save or delete aimed at a built-in theme.
    case readOnly(String)

    public var errorDescription: String? {
        switch self {
        case let .tooLarge(bytes): "The theme file is too large (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)); the limit is 2 MB)."
        case let .malformed(detail): "The theme file can’t be read: \(detail)"
        case let .unsupportedVersion(version): "The theme was made by a newer Gloss (format \(version))."
        case let .invalidIdentifier(id): "“\(id)” isn’t a valid theme identifier."
        case let .invalidColor(key, value): "“\(value)” isn’t a color (\(key))."
        case .unknownFormat: "This isn’t a theme Gloss can import. It reads Gloss, Xcode (.xccolortheme), TextMate (.tmTheme) and VS Code (.json) themes."
        case let .readOnly(name): "“\(name)” is built in. Duplicate it to make changes."
        }
    }
}

nonisolated extension CodeTheme: Codable {
    public static let maximumFileSize = 2 * 1024 * 1024

    private enum CodingKeys: String, CodingKey {
        case formatVersion, id, name, appearance, editor, tokens, font, license
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? Self.formatVersion
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        editor = try container.decode(EditorColors.self, forKey: .editor)
        appearance = try container.decodeIfPresent(Appearance.self, forKey: .appearance)
            ?? (ThemeContrast.isDark(editor.background) ? .dark : .light)
        tokens = try container.decodeIfPresent([String: TokenStyle].self, forKey: .tokens) ?? [:]
        font = try container.decodeIfPresent(ThemeFont.self, forKey: .font) ?? ThemeFont()
        license = try container.decodeIfPresent(String.self, forKey: .license)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(appearance, forKey: .appearance)
        try container.encode(editor, forKey: .editor)
        try container.encode(tokens, forKey: .tokens)
        if font != ThemeFont() { try container.encode(font, forKey: .font) }
        try container.encodeIfPresent(license, forKey: .license)
    }

    /// A Gloss theme file. Unknown keys are ignored; missing editor colors are derived from the background and
    /// foreground.
    public static func decode(_ data: Data) throws(CodeThemeError) -> CodeTheme {
        guard data.count <= maximumFileSize else { throw .tooLarge(bytes: data.count) }
        // The version first, so a newer file whose shape changed says so instead of "can't be read".
        struct Version: Decodable { var formatVersion: Int? }
        if let version = (try? JSONDecoder().decode(Version.self, from: data))?.formatVersion, version > formatVersion {
            throw .unsupportedVersion(version)
        }
        let theme: CodeTheme
        do {
            theme = try JSONDecoder().decode(CodeTheme.self, from: data)
        } catch let DecodingError.dataCorrupted(context) where context.debugDescription.hasPrefix("not a color: ") {
            throw .invalidColor(key: context.codingPath.map(\.stringValue).joined(separator: "."),
                                value: String(context.debugDescription.dropFirst("not a color: ".count)))
        } catch let error as DecodingError {
            throw .malformed(Self.describe(error))
        } catch {
            throw .malformed(error.localizedDescription)
        }
        guard theme.formatVersion <= formatVersion else { throw .unsupportedVersion(theme.formatVersion) }
        guard isValidIdentifier(theme.id) else { throw .invalidIdentifier(theme.id) }
        guard !theme.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw .malformed("the theme has no name") }
        return theme
    }

    /// The bytes Gloss writes: sorted keys, pretty-printed, so an exported theme diffs cleanly.
    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Every value is a string, number or bool; encoding can't fail.
        return (try? encoder.encode(self)) ?? Data()
    }

    public static func isValidIdentifier(_ id: String) -> Bool {
        (1 ... 64).contains(id.unicodeScalars.count) && !id.hasPrefix("-")
            && id.unicodeScalars.allSatisfy { ("a" ... "z").contains($0) || ("0" ... "9").contains($0) || $0 == "-" }
    }

    /// An id for a theme name: lowercase ASCII words joined by hyphens ("Harbor Night" → "harbor-night"), with "-2",
    /// "-3"… added when it's taken.
    public static func identifier(forName name: String, avoiding taken: Set<String>) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil).lowercased()
        var words: [String] = []
        var word = ""
        for character in folded {
            if character.isASCII, character.isLetter || character.isNumber {
                word.append(character)
            } else if !word.isEmpty {
                words.append(word)
                word = ""
            }
        }
        if !word.isEmpty { words.append(word) }
        var base = String(words.joined(separator: "-").prefix(56))
        while base.hasSuffix("-") { base.removeLast() }
        if base.isEmpty { base = "theme" }
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base)-\(number)") { number += 1 }
        return "\(base)-\(number)"
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            return path.isEmpty ? "" : " (at \(path))"
        }
        switch error {
        case let .keyNotFound(key, context): return "“\(key.stringValue)” is missing\(path(context))."
        case let .typeMismatch(_, context), let .valueNotFound(_, context): return "unexpected value\(path(context))."
        case let .dataCorrupted(context): return context.underlyingError == nil ? "\(context.debugDescription)\(path(context))." : "it isn’t valid JSON."
        @unknown default: return "it isn’t a Gloss theme."
        }
    }
}

nonisolated extension TokenStyle: Codable {
    private enum CodingKeys: String, CodingKey { case color, bold, italic }

    /// `"#AF00DB"` or `{ "color": "#AF00DB", "bold": true }`.
    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let string = try? single.decode(String.self) {
            guard let color = ThemeColor(string) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a color: \(string)"))
            }
            self.init(color: color)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(color: try container.decodeIfPresent(ThemeColor.self, forKey: .color),
                  bold: try container.decodeIfPresent(Bool.self, forKey: .bold) ?? false,
                  italic: try container.decodeIfPresent(Bool.self, forKey: .italic) ?? false)
    }

    public func encode(to encoder: any Encoder) throws {
        if let color, !bold, !italic {
            var single = encoder.singleValueContainer()
            try single.encode(color)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(color, forKey: .color)
        if bold { try container.encode(true, forKey: .bold) }
        if italic { try container.encode(true, forKey: .italic) }
    }
}

nonisolated extension EditorColors: Codable {
    private enum CodingKeys: String, CodingKey {
        case background, foreground, selection, currentLine, lineNumbers, currentLineNumber, gutterBackground, invisibles, cursor,
             codeBlockBackground
    }

    /// Only `background` and `foreground` are required; the rest are derived from them when missing.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func optional(_ key: CodingKeys) throws -> ThemeColor? { try container.decodeIfPresent(ThemeColor.self, forKey: key) }
        self = .derived(background: try container.decode(ThemeColor.self, forKey: .background),
                        foreground: try container.decode(ThemeColor.self, forKey: .foreground),
                        selection: try optional(.selection), currentLine: try optional(.currentLine),
                        lineNumbers: try optional(.lineNumbers), currentLineNumber: try optional(.currentLineNumber),
                        gutterBackground: try optional(.gutterBackground), invisibles: try optional(.invisibles),
                        cursor: try optional(.cursor), codeBlockBackground: try optional(.codeBlockBackground))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(background, forKey: .background)
        try container.encode(foreground, forKey: .foreground)
        try container.encode(selection, forKey: .selection)
        try container.encode(currentLine, forKey: .currentLine)
        try container.encode(lineNumbers, forKey: .lineNumbers)
        try container.encode(currentLineNumber, forKey: .currentLineNumber)
        try container.encode(gutterBackground, forKey: .gutterBackground)
        try container.encode(invisibles, forKey: .invisibles)
        try container.encode(cursor, forKey: .cursor)
        try container.encode(codeBlockBackground, forKey: .codeBlockBackground)
    }
}

nonisolated extension ThemeFont: Codable {
    private enum CodingKeys: String, CodingKey { case family, size, lineSpacing }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(family: try container.decodeIfPresent(String.self, forKey: .family),
                  size: try container.decodeIfPresent(Double.self, forKey: .size),
                  lineSpacing: try container.decodeIfPresent(Double.self, forKey: .lineSpacing))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(family, forKey: .family)
        try container.encodeIfPresent(size, forKey: .size)
        try container.encodeIfPresent(lineSpacing, forKey: .lineSpacing)
    }
}
