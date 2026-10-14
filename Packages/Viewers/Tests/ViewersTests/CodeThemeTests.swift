import AppKit
import Core
import Foundation
import SwiftTreeSitter
import Testing
@testable import Viewers

struct CodeThemeTests {
    // MARK: Gloss

    /// Gloss is today's colors: every key it sets is SyntaxTheme's color, and every capture the grammars name colors
    /// the same through either.
    @Test func glossThemePreservesLegacyColorsAndFont() throws {
        let gloss = CodeTheme.gloss
        for key in CodeTheme.glossTokens.keys {
            #expect(gloss.color(forCapture: key) == SyntaxTheme.color(forCapture: key), "\(key)")
        }
        for name in ["delimiter", "text.reference", "keyword.conditional.ternary", "comment.documentation", "string.regexp",
                     "number.float", "variable.member", "function.macro", "constant.macro", "character.special",
                     "string.special.key", "tag", "attribute", "text.title", "markup.link.label", "diff.plus", "nonexistent"] {
            #expect(gloss.color(forCapture: name) == SyntaxTheme.color(forCapture: name), "\(name)")
        }
        // Every capture any bundled grammar's queries name colors exactly as before.
        var captures: Set<String> = []
        for language in GrammarCatalog.supportedLanguageNames() {
            let configuration = try #require(GrammarCatalog.configuration(forLanguage: language), "\(language)")
            for query in configuration.queries.values {
                for id in 0 ..< query.captureCount { query.captureName(for: id).map { captures.insert($0) } }
            }
        }
        #expect(captures.count > 60 && captures.contains("text.title") && captures.contains("keyword.import"), "\(captures.sorted())")
        for name in captures {
            #expect(gloss.color(forCapture: name) == SyntaxTheme.color(forCapture: name), "\(name)")
        }
        #expect(gloss.color(forCapture: "import") == nil, "no alias colors a name Gloss leaves plain")
        #expect(gloss.editor.cursor.nsColor == .textInsertionPointColor, "the accent caret, as before")
        #expect(gloss.appearance == .any && gloss.font == ThemeFont() && gloss.isBuiltIn)
        #expect(gloss.editor.background.nsColor == .textBackgroundColor && gloss.editor.selection.nsColor == .selectedTextBackgroundColor)
        #expect(gloss.font.resolved(defaultSize: 12.5) == NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular))
    }

    // MARK: Presets

    @Test func everyPresetLoadsWithItsDeclaredAppearanceAndPassesContrast() {
        let expected: [String: CodeTheme.Appearance] = [
            "solar-light": .light, "solar-dark": .dark, "balanced-light": .light, "balanced-dark": .dark,
            "earth-light": .light, "earth-dark": .dark, "frost-dark": .dark, "midnight-dark": .dark,
        ]
        let presets = Dictionary(uniqueKeysWithValues: CodeTheme.presets.map { ($0.id, $0) })
        #expect(Set(presets.keys) == Set(expected.keys))
        #expect(CodeTheme.builtIns.first?.id == "gloss")
        for (id, appearance) in expected {
            guard let theme = presets[id] else { continue }
            #expect(theme.appearance == appearance, "\(id)")
            #expect(theme.contrastIssues().isEmpty, "\(id): \(theme.contrastIssues())")
            #expect(theme.license?.contains("MIT") == true, "\(id)")
            #expect(theme.font == ThemeFont(), "\(id) keeps the user's font")
            for row in CodeTheme.editableTokens {
                #expect(theme.style(forCapture: row.key)?.color != nil, "\(id) colors \(row.key)")
            }
            #expect(theme.isBuiltIn)
        }
        #expect(presets["midnight-dark"]?.tokens["diff.plus"]?.color == ThemeColor("#50FA7B"))
        #expect(presets["solar-light"]?.style(forCapture: "markup.heading")?.bold == true)
    }

    // MARK: Lookup

    @Test func captureAliasAndUnknownFallback() {
        let theme = makeTheme(tokens: ["keyword": "#111111", "markup.heading": "#222222", "attribute": "#333333",
                                       "function": "#444444", "function.call": "#555555"])
        #expect(theme.style(forCapture: "function.call.weird")?.color == ThemeColor("#555555"), "exact beats parent")
        #expect(theme.style(forCapture: "function.method")?.color == ThemeColor("#444444"))
        #expect(theme.style(forCapture: "text.title")?.color == ThemeColor("#222222"))
        #expect(theme.style(forCapture: "conditional")?.color == ThemeColor("#111111"))
        #expect(theme.style(forCapture: "repeat")?.color == ThemeColor("#111111"))
        #expect(theme.style(forCapture: "label")?.color == ThemeColor("#333333"))
        #expect(theme.style(forCapture: "method")?.color == ThemeColor("#444444"))
        #expect(theme.style(forCapture: "string") == nil && theme.style(forCapture: "nonexistent") == nil)
    }

    @Test func editingAKeyCanClearItsMoreSpecificKeys() {
        var theme = makeTheme(tokens: ["keyword": "#111111", "keyword.function": "#222222", "keywords": "#333333"])
        theme.setStyle(TokenStyle(color: ThemeColor("#999999")), forKey: "keyword", clearingDescendants: true)
        #expect(theme.tokens["keyword.function"] == nil && theme.tokens["keywords"] != nil)
        #expect(theme.style(forCapture: "keyword.function")?.color == ThemeColor("#999999"))

        // In a copy of Gloss, the older names that alias into a row change with it.
        var copy = CodeTheme.gloss
        copy.setStyle(TokenStyle(color: ThemeColor("#FF8800")), forKey: "markup.heading", clearingDescendants: true)
        copy.setStyle(TokenStyle(color: ThemeColor("#00AA00")), forKey: "keyword", clearingDescendants: true)
        #expect(copy.style(forCapture: "text.title")?.color == ThemeColor("#FF8800"))
        #expect(copy.style(forCapture: "conditional")?.color == ThemeColor("#00AA00"))
        #expect(copy.style(forCapture: "include")?.color == ThemeColor("#00AA00"))
        #expect(copy.style(forCapture: "string")?.color?.isSystem == true, "other rows untouched")
    }

    /// A row never clears another row or what that row owns.
    @Test func editingARowLeavesOtherRowsAlone() {
        var copy = CodeTheme.gloss
        copy.setStyle(TokenStyle(color: ThemeColor("#101010")), forKey: "punctuation", clearingDescendants: true)
        copy.setStyle(TokenStyle(color: ThemeColor("#202020")), forKey: "variable", clearingDescendants: true)
        copy.setStyle(TokenStyle(color: ThemeColor("#303030")), forKey: "markup.link", clearingDescendants: true)
        copy.setStyle(TokenStyle(color: ThemeColor("#404040")), forKey: "constant", clearingDescendants: true)
        #expect(copy.tokens["punctuation.special"]?.color == ThemeColor.system("systemPink"), "Special Punctuation is its own row")
        #expect(copy.tokens["punctuation.bracket"] == nil && copy.tokens["delimiter"] == nil)
        #expect(copy.style(forCapture: "delimiter")?.color == ThemeColor("#101010"))
        #expect(copy.tokens["variable.builtin"]?.color == ThemeColor.system("systemIndigo"), "Built-in Variable is its own row")
        #expect(copy.tokens["variable.parameter"] == nil && copy.tokens["parameter"] == nil)
        #expect(copy.tokens["markup.link.label"] != nil && copy.tokens["text.reference"] != nil, "Link Label and its alias stay")
        #expect(copy.tokens["markup.link.url"] == nil && copy.tokens["text.uri"] == nil)
        #expect(copy.tokens["boolean"] == nil && copy.style(forCapture: "boolean")?.color == ThemeColor("#404040"))
        #expect(CodeTheme.owningRow(of: "none") == nil)
    }

    // MARK: Colors and decoding

    @Test func colorsParseAndPrint() {
        #expect(ThemeColor("#abc")?.description == "#AABBCC")
        #expect(ThemeColor("#11223380")?.description == "#11223380")
        #expect(ThemeColor("#112233FF")?.description == "#112233")
        #expect(ThemeColor(red: .nan, green: .infinity, blue: 0.5).description == "#000080", "never traps on NaN")
        #expect(ThemeFont(size: .nan, lineSpacing: .infinity) == ThemeFont())
        #expect(ThemeColor("system:systemPurple")?.nsColor == .systemPurple)
        for bad in ["112233", "#12345", "#GG0000", "#ＦＦＦ", "system:notAColor", "red", ""] {
            #expect(ThemeColor(bad) == nil, "\(bad)")
        }
        let half = ThemeColor("#00000080")!.resolved(in: .aqua)
        #expect(abs(half.alpha - 128.0 / 255) < 0.001)
    }

    @Test func aThemeFileDecodesWithShorthandDerivedColorsAndUnknownKeys() throws {
        let json = """
        { "id": "harbor-night", "name": "Harbor Night", "futureKey": [1, 2],
          "editor": { "background": "#1E1F24", "foreground": "#D6D7DC", "sparkle": "#FFFFFF" },
          "tokens": { "string": "#A5D6A7", "comment": { "color": "#7A7F8C", "italic": true } },
          "font": { "family": "Menlo", "size": 13, "lineSpacing": 9 } }
        """
        let theme = try CodeTheme.decode(Data(json.utf8))
        #expect(theme.appearance == .dark, "derived from the background")
        #expect(theme.formatVersion == 1)
        #expect(theme.tokens["comment"] == TokenStyle(color: ThemeColor("#7A7F8C"), italic: true))
        #expect(theme.editor.gutterBackground == theme.editor.background && theme.editor.cursor == theme.editor.foreground)
        #expect(theme.editor.selection != theme.editor.background)
        #expect(theme.font.lineSpacing == 2, "clamped")
        // Derived colors are written out, and the round trip is exact.
        let again = try CodeTheme.decode(theme.encoded())
        #expect(again == theme)
        let text = String(decoding: theme.encoded(), as: UTF8.self)
        #expect(text.contains("\"selection\"") && text.contains("\"string\" : \"#A5D6A7\""))
        #expect(text.range(of: "\"appearance\"")!.lowerBound < text.range(of: "\"editor\"")!.lowerBound, "sorted keys")
    }

    @Test func brokenThemeFilesSayWhy() {
        func error(_ json: String) -> CodeThemeError? {
            do { _ = try CodeTheme.decode(Data(json.utf8)); return nil } catch { return error }
        }
        let editor = ##""editor": { "background": "#FFFFFF", "foreground": "#000000" }"##
        #expect(error(##"{ "id": "a", "name": "A", "editor": { "background": "#FFFFFF", "foreground": "black" } }"##)
            == .invalidColor(key: "editor.foreground", value: "black"))
        #expect(error(##"{ "id": "a", "name": "A", \##(editor), "tokens": { "keyword": "#12" } }"##)
            == .invalidColor(key: "tokens.keyword", value: "#12"))
        #expect(error(##"{ "formatVersion": 2, "id": "a", "name": "A", \##(editor) }"##) == .unsupportedVersion(2))
        #expect(error(##"{ "formatVersion": 3, "palette": [] }"##) == .unsupportedVersion(3), "the version is read first")
        #expect(error(##"{ "id": "../evil", "name": "A", \##(editor) }"##) == .invalidIdentifier("../evil"))
        #expect(error(##"{ "id": "a", "name": "  ", \##(editor) }"##) == .malformed("the theme has no name"))
        if case .malformed = error(##"{ "id": "a", "name": "A" }"##) {} else { Issue.record("missing editor") }
        if case .malformed = error("not json") {} else { Issue.record("not JSON") }
        let big = Data(count: CodeTheme.maximumFileSize + 1)
        #expect(throws: CodeThemeError.tooLarge(bytes: big.count)) { try CodeTheme.decode(big) }
    }

    @Test func identifiersComeFromNames() {
        #expect(CodeTheme.identifier(forName: "Harbor Night", avoiding: []) == "harbor-night")
        #expect(CodeTheme.identifier(forName: "Café  Crème!", avoiding: []) == "cafe-creme")
        #expect(CodeTheme.identifier(forName: "Harbor Night", avoiding: ["harbor-night", "harbor-night-2"]) == "harbor-night-3")
        #expect(CodeTheme.identifier(forName: "★", avoiding: []) == "theme")
        #expect(CodeTheme.isValidIdentifier("a-1") && !CodeTheme.isValidIdentifier("-a") && !CodeTheme.isValidIdentifier("A"))
        #expect(!CodeTheme.isValidIdentifier("b\u{301}") && !CodeTheme.isValidIdentifier("a/b"))
    }

    // MARK: Contrast

    @Test func contrastRatiosFollowWCAG() {
        #expect(abs(ThemeContrast.ratio(.black, .white, in: .aqua) - 21) < 0.01)
        #expect(abs(ThemeContrast.ratio(.white, .white, in: .aqua) - 1) < 0.001)
        let gray = NSColor(srgbRed: 0.6, green: 0.6, blue: 0.6, alpha: 1)
        let legible = ThemeContrast.legible(gray, on: .white, minimum: 4.5, in: .aqua)
        #expect(ThemeContrast.ratio(legible, .white, in: .aqua) >= 4.5)
        #expect(ThemeContrast.legible(NSColor.black, on: .white, in: .aqua) == NSColor.black, "already legible: unchanged")
        let onDark = ThemeContrast.legible(NSColor(srgbRed: 0.1, green: 0.1, blue: 0.4, alpha: 1), on: .black, in: .darkAqua)
        #expect(ThemeContrast.ratio(onDark, .black, in: .darkAqua) >= 3)
    }

    /// Low contrast is reported (never refused), for tokens below 3:1 and the foreground below 4.5:1.
    @Test func contrastWarningsNameTheKeyAndRatio() {
        let theme = makeTheme(background: "#FFFFFF", foreground: "#999999", tokens: ["keyword": "#000000", "comment": "#EEEEEE"])
        let issues = theme.contrastIssues()
        #expect(issues.map(\.key) == ["foreground", "comment"])
        #expect(issues.allSatisfy { $0.appearance == .aqua && $0.ratio < $0.minimum })
    }

    @Test func noteColorsRemainLegibleAgainstCustomBackground() {
        let light = makeTheme(background: "#FFFDF5", foreground: "#222222", tokens: [:])
        let dark = makeTheme(background: "#0A0A0A", foreground: "#EEEEEE", tokens: [:])
        for theme in [light, dark] {
            let appearance: NSAppearance.Name = theme.appearance == .dark ? .darkAqua : .aqua
            for color in NoteColor.allCases {
                let adapted = theme.noteColor(color)
                #expect(ThemeContrast.ratio(adapted, theme.editor.background.nsColor, in: appearance) >= 3 - 0.01, "\(theme.id) \(color)")
            }
        }
        #expect(CodeTheme.gloss.noteColor(.yellow) == NSColor.systemYellow, "Gloss keeps its system colors")
    }

    @Test func aSelectionTheColorOfANoteFillClashes() {
        let background = "#FFFFFF"
        var clashing = makeTheme(background: background, foreground: "#000000", tokens: [:])
        // The yellow draft fill over white, as an opaque selection.
        let yellow = ThemeColor.components(of: clashing.noteColor(.yellow), in: .aqua)
        let fill = ThemeColor(red: 1 + (yellow.red - 1) * 0.28, green: 1 + (yellow.green - 1) * 0.28, blue: 1 + (yellow.blue - 1) * 0.28)
        clashing.editor.selection = fill
        #expect(clashing.selectionClashes().contains(.yellow))
        let distinct = makeTheme(background: background, foreground: "#000000", selection: "#B4D5FE", tokens: [:])
        #expect(!distinct.selectionClashes().contains(.yellow))
    }

    // MARK: Helpers

    func makeTheme(id: String = "fixture", background: String = "#FFFFFF", foreground: String = "#000000",
                   selection: String? = nil, tokens: [String: String]) -> CodeTheme {
        CodeTheme(id: id, name: "Fixture", appearance: ThemeContrast.isDark(ThemeColor(background)!) ? .dark : .light,
                  editor: .derived(background: ThemeColor(background)!, foreground: ThemeColor(foreground)!,
                                   selection: selection.flatMap(ThemeColor.init)),
                  tokens: tokens.mapValues { TokenStyle(color: ThemeColor($0)) })
    }
}

struct ActiveCodeThemeTests {
    /// The pair resolves per appearance, posts once per real change, and hands out one dynamic color per capture.
    /// One test, since the pair is global.
    @Test func appearanceSelectsIndependentThemes() throws {
        let night = try #require(CodeTheme.presets.first { $0.id == "midnight-dark" })
        defer { ActiveCodeTheme.set(light: .gloss, dark: .gloss) }
        final class Count: @unchecked Sendable { var value = 0 }
        let posts = Count()
        let observer = NotificationCenter.default.addObserver(forName: ActiveCodeTheme.didChange, object: nil, queue: nil) { _ in posts.value += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        ActiveCodeTheme.set(light: .gloss, dark: night)
        ActiveCodeTheme.dark = night
        #expect(posts.value == 1, "setting the same theme again doesn't post")

        let keyword = try #require(ActiveCodeTheme.color(forCapture: "keyword"))
        #expect(ActiveCodeTheme.color(forCapture: "keyword") === keyword)
        let dark = ThemeColor.components(of: keyword, in: .darkAqua)
        #expect(ThemeColor(red: dark.red, green: dark.green, blue: dark.blue) == ThemeColor("#FF79C6"))
        let light = ThemeColor.components(of: keyword, in: .aqua)
        let purple = ThemeColor.components(of: .systemPurple, in: .aqua)
        #expect(abs(light.red - purple.red) < 0.01 && abs(light.blue - purple.blue) < 0.01)
        let background = ThemeColor.components(of: ActiveCodeTheme.editorColor(\.background), in: .darkAqua)
        #expect(ThemeColor(red: background.red, green: background.green, blue: background.blue) == ThemeColor("#282A36"))
        #expect(ActiveCodeTheme.theme(for: NSAppearance(named: .darkAqua)!).id == "midnight-dark")
        #expect(ActiveCodeTheme.theme(for: NSAppearance(named: .aqua)!).id == "gloss")
        #expect(ActiveCodeTheme.color(forCapture: "nonexistent") == nil)
    }
}
