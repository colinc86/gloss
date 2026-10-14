import AppKit

public nonisolated struct CodeThemeImport: Sendable {
    /// Its id comes from its name; the store renames and re-ids it if either is taken.
    public var theme: CodeTheme
    public var report: ImportReport
}

public nonisolated struct ImportReport: Hashable, Sendable {
    public enum Format: String, Sendable { case gloss = "Gloss", xcode = "Xcode", textMate = "TextMate", vsCode = "VS Code" }

    public var format: Format
    /// Token keys the source set (diff colors filled in for a theme that has none aren't counted).
    public var mappedTokens: Int
    /// Rules or entries in the source.
    public var sourceRules: Int
    /// Scopes or keys no capture matched, sorted and unique.
    public var unmappedScopes: [String]
    /// Things deliberately not read, such as another file an `include` names.
    public var skipped: [String]

    public var summary: String {
        var sentence = "Imported a \(format.rawValue) theme: \(mappedTokens) token \(mappedTokens == 1 ? "style" : "styles") from \(sourceRules) \(sourceRules == 1 ? "rule" : "rules")"
        if !unmappedScopes.isEmpty {
            sentence += "; \(unmappedScopes.count) \(unmappedScopes.count == 1 ? "scope" : "scopes") had no match"
        }
        sentence += "."
        if !skipped.isEmpty { sentence += " Not read: " + skipped.joined(separator: "; ") + "." }
        return sentence
    }
}

/// Reads Xcode (`.xccolortheme`), TextMate (`.tmTheme`) and VS Code (`.json`) themes, and Gloss's own, into a
/// `CodeTheme`. Only `PropertyListSerialization` and `JSONSerialization` read the bytes; nothing runs, and no other
/// file is opened.
public nonisolated enum CodeThemeImporter {
    public static func parse(_ data: Data, fileName: String) throws(CodeThemeError) -> CodeThemeImport {
        guard data.count <= CodeTheme.maximumFileSize else { throw .tooLarge(bytes: data.count) }
        let stem = ((fileName as NSString).deletingPathExtension as NSString).lastPathComponent
        switch (fileName as NSString).pathExtension.lowercased() {
        case "xccolortheme":
            return try xcode(plistDictionary(data), stem: stem)
        case "tmtheme":
            return try textMate(plistDictionary(data), stem: stem)
        case "json", "jsonc":
            return try json(data, stem: stem)
        default:
            if let plist = try? plistDictionary(data) {
                if plist["DVTSourceTextSyntaxColors"] != nil { return try xcode(plist, stem: stem) }
                if plist["settings"] is [Any] { return try textMate(plist, stem: stem) }
            }
            if let result = try? json(data, stem: stem) { return result }
            throw .unknownFormat
        }
    }

    // MARK: Gloss and VS Code (JSON)

    private static func json(_ data: Data, stem: String) throws(CodeThemeError) -> CodeThemeImport {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: strippingJSONComments(data))
        } catch {
            throw .malformed("it isn’t valid JSON.")
        }
        guard let root = object as? [String: Any] else { throw .unknownFormat }
        if root["formatVersion"] != nil || (root["editor"] != nil && root["tokens"] != nil) {
            let theme = try CodeTheme.decode(strippingJSONComments(data))
            return CodeThemeImport(theme: theme, report: ImportReport(format: .gloss, mappedTokens: theme.tokens.count,
                                                                      sourceRules: theme.tokens.count, unmappedScopes: [], skipped: []))
        }
        guard root["tokenColors"] != nil || root["colors"] != nil else { throw .unknownFormat }
        return vsCode(root, stem: stem)
    }

    private static func vsCode(_ root: [String: Any], stem: String) -> CodeThemeImport {
        var skipped: [String] = []
        if let include = root["include"] as? String { skipped.append("include: \(include) (other files are never read)") }
        if root["semanticTokenColors"] != nil { skipped.append("semanticTokenColors") }
        let type = (root["type"] as? String)?.lowercased()
        let declaredDark: Bool? = switch type {
        case "dark", "hc", "hc-black", "hc-dark": true
        case "light", "hc-light": false
        default: nil
        }
        let colors = root["colors"] as? [String: Any] ?? [:]
        func color(_ key: String) -> ThemeColor? { (colors[key] as? String).flatMap(ThemeColor.init) }
        let background = color("editor.background") ?? ThemeColor(declaredDark == false ? "#FFFFFF" : "#1E1E1E")!
        let foreground = color("editor.foreground") ?? ThemeColor(declaredDark == false ? "#000000" : "#D4D4D4")!

        var rules: [Rule] = []
        switch root["tokenColors"] {
        case let path as String:
            skipped.append("tokenColors: \(path) (other files are never read)")
        case let entries as [Any]:
            for entry in entries {
                guard let entry = entry as? [String: Any], let settings = entry["settings"] as? [String: Any] else { continue }
                let selectors: [String] = switch entry["scope"] {
                case let scope as String: [scope]
                case let scopes as [Any]: scopes.compactMap { $0 as? String }
                default: []
                }
                rules.append(Rule(selectors: selectors, settings: settings))
            }
        default:
            break
        }
        let editor = EditorColors.derived(background: background, foreground: foreground,
                                          selection: color("editor.selectionBackground"),
                                          currentLine: color("editor.lineHighlightBackground"),
                                          lineNumbers: color("editorLineNumber.foreground"),
                                          currentLineNumber: color("editorLineNumber.activeForeground"),
                                          gutterBackground: color("editorGutter.background"),
                                          invisibles: color("editorIndentGuide.background1") ?? color("editorIndentGuide.background")
                                              ?? color("editorWhitespace.foreground"),
                                          cursor: color("editorCursor.foreground"))
        let name = (root["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? stem
        let appearance: CodeTheme.Appearance = (declaredDark ?? ThemeContrast.isDark(background)) ? .dark : .light
        return finish(name: name, appearance: appearance, editor: editor, rules: rules, font: ThemeFont(), format: .vsCode,
                      license: "Imported from \(stem).json", skipped: skipped)
    }

    // MARK: TextMate

    private static func textMate(_ root: [String: Any], stem: String) throws(CodeThemeError) -> CodeThemeImport {
        guard let entries = root["settings"] as? [Any] else { throw .malformed("it has no “settings” list.") }
        var global: [String: Any] = [:]
        var rules: [Rule] = []
        for entry in entries {
            guard let entry = entry as? [String: Any], let settings = entry["settings"] as? [String: Any] else { continue }
            if let scope = entry["scope"] as? String {
                rules.append(Rule(selectors: [scope], settings: settings))
            } else if global.isEmpty {
                global = settings
            }
        }
        func color(_ key: String) -> ThemeColor? { (global[key] as? String).flatMap(ThemeColor.init) }
        let background = color("background") ?? ThemeColor("#FFFFFF")!
        let foreground = color("foreground") ?? (ThemeContrast.isDark(background) ? ThemeColor("#FFFFFF")! : ThemeColor("#000000")!)
        let editor = EditorColors.derived(background: background, foreground: foreground, selection: color("selection"),
                                          currentLine: color("lineHighlight"), lineNumbers: color("gutterForeground"),
                                          gutterBackground: color("gutter"), invisibles: color("invisibles"), cursor: color("caret"))
        let name = (root["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? stem
        return finish(name: name, appearance: ThemeContrast.isDark(background) ? .dark : .light, editor: editor, rules: rules,
                      font: ThemeFont(), format: .textMate, license: "Imported from \(stem).tmTheme", skipped: [])
    }

    // MARK: Xcode

    private static func xcode(_ root: [String: Any], stem: String) throws(CodeThemeError) -> CodeThemeImport {
        guard let syntax = root["DVTSourceTextSyntaxColors"] as? [String: Any] else {
            throw .malformed("it has no “DVTSourceTextSyntaxColors”.")
        }
        let fonts = root["DVTSourceTextSyntaxFonts"] as? [String: Any] ?? [:]
        func color(_ value: Any?) -> ThemeColor? {
            guard let string = value as? String else { return nil }
            let numbers = string.split(separator: " ").compactMap { Double($0) }.filter(\.isFinite)
            guard numbers.count == 3 || numbers.count == 4 else { return nil }
            return ThemeColor(red: numbers[0], green: numbers[1], blue: numbers[2], alpha: numbers.count == 4 ? numbers[3] : 1)
        }
        let prefix = "xcode.syntax."
        let background = color(root["DVTSourceTextBackground"]) ?? ThemeColor("#FFFFFF")!
        let foreground = color(syntax[prefix + "plain"]) ?? (ThemeContrast.isDark(background) ? ThemeColor("#FFFFFF")! : ThemeColor("#000000")!)
        let editor = EditorColors.derived(background: background, foreground: foreground,
                                          selection: color(root["DVTSourceTextSelectionColor"]),
                                          currentLine: color(root["DVTSourceTextCurrentLineHighlightColor"]),
                                          invisibles: color(root["DVTSourceTextInvisiblesColor"]),
                                          cursor: color(root["DVTSourceTextInsertionPointColor"]),
                                          codeBlockBackground: color(root["DVTMarkupTextBackgroundColor"]))

        // In ScopeMapping.xcode's priority order, so the result never depends on the dictionary's order.
        var tokens: [String: TokenStyle] = [:]
        var used: Set<String> = [prefix + "plain"]
        var unreadable: [String] = []
        for (short, capture) in ScopeMapping.xcode {
            let key = prefix + short
            guard let value = syntax[key] else { continue }
            used.insert(key)
            guard let tokenColor = color(value) else { unreadable.append("\(key): unreadable color"); continue }
            guard tokens[capture] == nil else { continue }
            let face = (fonts[key] as? String)?.lowercased() ?? ""
            tokens[capture] = TokenStyle(color: tokenColor, bold: face.contains("bold") || face.contains("heavy"),
                                         italic: face.contains("italic") || face.contains("oblique"))
        }
        let unmapped = syntax.keys.filter { !used.contains($0) }
        var sourceRules = syntax.count
        // Doc-comment markup colors fill only what the syntax keys left unset.
        let markup: [(String, String)] = [
            ("DVTMarkupTextPrimaryHeadingColor", "markup.heading"), ("DVTMarkupTextLinkColor", "markup.link"),
            ("DVTMarkupTextInlineCodeColor", "markup.raw"), ("DVTMarkupTextEmphasisColor", "markup.italic"),
            ("DVTMarkupTextStrongColor", "markup.bold"),
        ]
        for (key, capture) in markup {
            guard let markupColor = color(root[key]) else { continue }
            sourceRules += 1
            guard tokens[capture] == nil else { continue }
            tokens[capture] = TokenStyle(color: markupColor, bold: capture == "markup.bold", italic: capture == "markup.italic")
        }

        var font = ThemeFont()
        if let plain = fonts[prefix + "plain"] as? String, let separator = plain.range(of: " - ", options: .backwards) {
            let family = String(plain[..<separator.lowerBound])
            font = ThemeFont(family: family.isEmpty || family.hasPrefix("SFMono") ? nil : family,
                             size: Double(plain[separator.upperBound...].trimmingCharacters(in: .whitespaces)),
                             lineSpacing: (root["DVTLineSpacing"] as? String).flatMap(Double.init) ?? root["DVTLineSpacing"] as? Double)
        }
        let mapped = tokens.count
        addMissingDiffColors(to: &tokens, editor: editor)
        let theme = CodeTheme(id: CodeTheme.identifier(forName: stem, avoiding: []), name: stem,
                              appearance: ThemeContrast.isDark(background) ? .dark : .light, editor: editor, tokens: tokens,
                              font: font, license: "Imported from \(stem).xccolortheme")
        return CodeThemeImport(theme: theme, report: ImportReport(format: .xcode, mappedTokens: mapped, sourceRules: sourceRules,
                                                                  unmappedScopes: unmapped.sorted(), skipped: unreadable))
    }

    // MARK: Rules → tokens

    private struct Rule {
        var selectors: [String]
        var settings: [String: Any]

        var color: ThemeColor? { (settings["foreground"] as? String).flatMap(ThemeColor.init) }

        /// Nil when the rule doesn't mention a font style; an empty `fontStyle` sets plain.
        var fontStyle: (bold: Bool, italic: Bool)? {
            guard let words = (settings["fontStyle"] as? String)?.lowercased().split(separator: " ") else { return nil }
            return (words.contains("bold"), words.contains("italic"))
        }
    }

    /// Each capture takes its color and its font style separately, each from the most general rule that sets it
    /// (fewest scope components), the later rule on a tie, so a trailing rule that only italicizes keeps the color.
    private static func finish(name: String, appearance: CodeTheme.Appearance, editor: EditorColors, rules: [Rule],
                               font: ThemeFont, format: ImportReport.Format, license: String, skipped: [String]) -> CodeThemeImport {
        var colors: [String: (components: Int, color: ThemeColor)] = [:]
        var fontStyles: [String: (components: Int, bold: Bool, italic: Bool)] = [:]
        var unmapped: Set<String> = []
        for rule in rules {
            let color = rule.color
            let fontStyle = rule.fontStyle
            guard color != nil || fontStyle != nil else { continue }
            for selector in rule.selectors {
                for scope in ScopeMapping.scopes(inSelector: selector) {
                    guard let capture = ScopeMapping.capture(forScope: scope) else { unmapped.insert(scope); continue }
                    let components = scope.split(separator: ".").count
                    if let color, colors[capture].map({ $0.components >= components }) ?? true {
                        colors[capture] = (components, color)
                    }
                    if let fontStyle, fontStyles[capture].map({ $0.components >= components }) ?? true {
                        fontStyles[capture] = (components, fontStyle.bold, fontStyle.italic)
                    }
                }
            }
        }
        var tokens: [String: TokenStyle] = [:]
        for capture in Set(colors.keys).union(fontStyles.keys) {
            let style = TokenStyle(color: colors[capture]?.color, bold: fontStyles[capture]?.bold ?? false,
                                   italic: fontStyles[capture]?.italic ?? false)
            if style.color != nil || style.bold || style.italic { tokens[capture] = style }
        }
        let mapped = tokens.count
        addMissingDiffColors(to: &tokens, editor: editor)
        let theme = CodeTheme(id: CodeTheme.identifier(forName: name, avoiding: []), name: name, appearance: appearance,
                              editor: editor, tokens: tokens, font: font, license: license)
        return CodeThemeImport(theme: theme, report: ImportReport(format: format, mappedTokens: mapped, sourceRules: rules.count,
                                                                  unmappedScopes: unmapped.sorted(), skipped: skipped))
    }

    /// Diff lines stay readable in a theme that never colored them: green, red and purple made legible on its background.
    private static func addMissingDiffColors(to tokens: inout [String: TokenStyle], editor: EditorColors) {
        let appearance: NSAppearance.Name = ThemeContrast.isDark(editor.background) ? .darkAqua : .aqua
        let background = editor.background.nsColor
        let defaults: [(String, NSColor)] = [
            ("diff.plus", NSColor(srgbRed: 0.25, green: 0.73, blue: 0.31, alpha: 1)),
            ("diff.minus", NSColor(srgbRed: 0.97, green: 0.32, blue: 0.29, alpha: 1)),
            ("diff.hunk", NSColor(srgbRed: 0.64, green: 0.44, blue: 0.97, alpha: 1)),
        ]
        for (key, color) in defaults where tokens[key] == nil {
            let legible = ThemeContrast.legible(color, on: background, in: appearance)
            tokens[key] = TokenStyle(color: ThemeColor(ThemeColor.components(of: legible, in: appearance)))
        }
        if tokens["diff.header"] == nil { tokens["diff.header"] = TokenStyle(color: editor.lineNumbers) }
    }

    // MARK: Reading

    private static func plistDictionary(_ data: Data) throws(CodeThemeError) -> [String: Any] {
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw .malformed("it isn’t a property list.")
        }
        guard let dictionary = object as? [String: Any] else { throw .malformed("it isn’t a dictionary.") }
        return dictionary
    }

    /// JSONC to JSON: `//` and `/* */` comments and trailing commas removed, strings left alone.
    static func strippingJSONComments(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        var inString = false
        /// Where a comma waits to see if a closing bracket follows (only whitespace and comments between).
        var pendingComma: Int?
        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                output.append(byte)
                if byte == UInt8(ascii: "\\"), index + 1 < bytes.count {
                    output.append(bytes[index + 1])
                    index += 2
                    continue
                }
                if byte == UInt8(ascii: "\"") { inString = false }
                index += 1
                continue
            }
            if byte == UInt8(ascii: "/"), index + 1 < bytes.count {
                if bytes[index + 1] == UInt8(ascii: "/") {
                    while index < bytes.count, bytes[index] != UInt8(ascii: "\n") { index += 1 }
                    continue
                }
                if bytes[index + 1] == UInt8(ascii: "*") {
                    index += 2
                    while index + 1 < bytes.count, !(bytes[index] == UInt8(ascii: "*") && bytes[index + 1] == UInt8(ascii: "/")) { index += 1 }
                    index = min(index + 2, bytes.count)
                    continue
                }
            }
            switch byte {
            case UInt8(ascii: "\""):
                pendingComma = nil
                inString = true
            case UInt8(ascii: ","):
                pendingComma = output.count
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                if let comma = pendingComma { output[comma] = UInt8(ascii: " ") }
                pendingComma = nil
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"):
                break
            default:
                pendingComma = nil
            }
            output.append(byte)
            index += 1
        }
        return Data(output)
    }
}

nonisolated private extension ThemeColor {
    init(_ components: (red: Double, green: Double, blue: Double, alpha: Double)) {
        self.init(red: components.red, green: components.green, blue: components.blue, alpha: components.alpha)
    }
}
