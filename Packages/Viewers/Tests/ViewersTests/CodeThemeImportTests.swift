import AppKit
import Foundation
import Testing
@testable import Viewers

/// Made-up fixture themes in each format Gloss imports.
struct CodeThemeImportTests {
    @Test func scopeMappingUsesLongestPrefix() {
        #expect(ScopeMapping.capture(forScope: "entity.name.function.swift") == "function")
        #expect(ScopeMapping.capture(forScope: "entity.name.whatever") == "type")
        #expect(ScopeMapping.capture(forScope: "keyword.control.import.js") == "keyword.import")
        #expect(ScopeMapping.capture(forScope: "keyword.operator.arithmetic") == "operator")
        #expect(ScopeMapping.capture(forScope: "entity.other.attribute-name.html") == "attribute")
        #expect(ScopeMapping.capture(forScope: "markup.inserted.diff") == "diff.plus")
        #expect(ScopeMapping.capture(forScope: "source") == nil && ScopeMapping.capture(forScope: "keywordish") == nil)
    }

    @Test func selectorsReduceToTheirScopes() {
        #expect(ScopeMapping.scopes(inSelector: "string, comment") == ["string", "comment"])
        #expect(ScopeMapping.scopes(inSelector: "meta.function entity.name.function") == ["entity.name.function"])
        #expect(ScopeMapping.scopes(inSelector: "entity.other.attribute-name - string") == ["entity.other.attribute-name"])
        #expect(ScopeMapping.scopes(inSelector: "- comment") == [])
        #expect(ScopeMapping.scopes(inSelector: "(string | comment)") == ["string", "comment"])
        #expect(ScopeMapping.scopes(inSelector: "source.python keyword") == ["source.python keyword"], "language-scoped: not global")
        #expect(ScopeMapping.capture(forScope: "source.python keyword") == nil)
    }

    @Test func aTextMateThemeImports() throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>name</key><string>Acme Dusk</string>
          <key>settings</key><array>
            <dict><key>settings</key><dict>
              <key>background</key><string>#1B1D23</string><key>foreground</key><string>#E0E0E0</string>
              <key>selection</key><string>#3A3F4B</string><key>lineHighlight</key><string>#22252C</string>
              <key>caret</key><string>#FFCC00</string><key>gutterForeground</key><string>#6B7080</string>
            </dict></dict>
            <dict><key>scope</key><string>keyword.control.import</string><key>settings</key><dict><key>foreground</key><string>#AA0000</string></dict></dict>
            <dict><key>scope</key><string>keyword</string><key>settings</key><dict><key>foreground</key><string>#C792EA</string><key>fontStyle</key><string>bold</string></dict></dict>
            <dict><key>scope</key><string>storage.type</string><key>settings</key><dict><key>foreground</key><string>#00AA00</string></dict></dict>
            <dict><key>scope</key><string>string, punctuation.definition.string</string><key>settings</key><dict><key>foreground</key><string>#A5D6A7</string></dict></dict>
            <dict><key>scope</key><string>comment</string><key>settings</key><dict><key>foreground</key><string>#7A7F8C</string><key>fontStyle</key><string>italic underline</string></dict></dict>
            <dict><key>scope</key><string>meta.acme.thing</string><key>settings</key><dict><key>foreground</key><string>#123456</string></dict></dict>
          </array>
        </dict></plist>
        """
        let result = try CodeThemeImporter.parse(Data(plist.utf8), fileName: "Acme Dusk.tmTheme")
        let theme = result.theme
        #expect(result.report.format == .textMate && theme.name == "Acme Dusk" && theme.id == "acme-dusk")
        #expect(theme.appearance == .dark)
        #expect(theme.editor.background == ThemeColor("#1B1D23") && theme.editor.cursor == ThemeColor("#FFCC00"))
        #expect(theme.editor.lineNumbers == ThemeColor("#6B7080") && theme.editor.currentLine == ThemeColor("#22252C"))
        #expect(theme.tokens["keyword"] == TokenStyle(color: ThemeColor("#C792EA"), bold: true), "most general rule wins")
        #expect(theme.tokens["keyword.import"]?.color == ThemeColor("#AA0000"))
        #expect(theme.tokens["string"]?.color == ThemeColor("#A5D6A7"))
        #expect(theme.tokens["comment"] == TokenStyle(color: ThemeColor("#7A7F8C"), italic: true))
        #expect(result.report.unmappedScopes == ["meta.acme.thing"])
        #expect(result.report.sourceRules == 6 && result.report.mappedTokens == 4)
        #expect(theme.tokens["diff.plus"] != nil && theme.tokens["diff.minus"] != nil, "diff colors filled in")
        #expect(ThemeContrast.ratio(theme.tokens["diff.minus"]!.color!.nsColor, theme.editor.background.nsColor, in: .darkAqua) >= 3 - 0.01)
        #expect(result.report.summary.contains("4 token styles from 6 rules"))
    }

    @Test func aVSCodeThemeWithCommentsImportsAndNeverFollowsIncludes() throws {
        let json = """
        // Acme Light, a made-up theme
        {
          "name": "Acme Light",
          "type": "light",
          "include": "./acme-base.json",
          /* editor colors */
          "colors": {
            "editor.background": "#FAFAF8",
            "editor.foreground": "#24292E",
            "editor.selectionBackground": "#0366D625",
            "editorLineNumber.foreground": "#1B1F2380", // quiet
            "editorCursor.foreground": "#044289",
          },
          "tokenColors": [
            { "scope": ["keyword", "storage"], "settings": { "foreground": "#D73A49" } },
            { "scope": "string", "settings": { "foreground": "#032F62", "fontStyle": "" } },
            { "scope": "entity.name.function", "settings": { "foreground": "#6F42C1", "fontStyle": "bold italic" } },
            { "name": "url // not a comment", "scope": "markup.underline.link", "settings": { "foreground": "#0000EE" } },
            { "settings": { "foreground": "#000000" } },
          ],
          "semanticTokenColors": { "variable": "#FF0000" },
        }
        """
        let result = try CodeThemeImporter.parse(Data(json.utf8), fileName: "acme-light-color-theme.json")
        let theme = result.theme
        #expect(result.report.format == .vsCode && theme.name == "Acme Light" && theme.appearance == .light)
        #expect(theme.editor.selection == ThemeColor("#0366D625") && theme.editor.cursor == ThemeColor("#044289"))
        #expect(theme.tokens["keyword"]?.color == ThemeColor("#D73A49"))
        #expect(theme.tokens["function"] == TokenStyle(color: ThemeColor("#6F42C1"), bold: true, italic: true))
        #expect(theme.tokens["markup.link.url"]?.color == ThemeColor("#0000EE"))
        #expect(result.report.skipped.contains { $0.hasPrefix("include: ./acme-base.json") })
        #expect(result.report.skipped.contains("semanticTokenColors"))

        let external = ##"{ "name": "Pointer", "colors": { "editor.background": "#000000" }, "tokenColors": "./tokens.tmTheme" }"##
        let pointer = try CodeThemeImporter.parse(Data(external.utf8), fileName: "pointer.json")
        #expect(pointer.report.skipped == ["tokenColors: ./tokens.tmTheme (other files are never read)"])
        #expect(pointer.report.mappedTokens == 0 && pointer.theme.appearance == .dark)
    }

    @Test func anXcodeThemeImports() throws {
        let plist: [String: Any] = [
            "DVTSourceTextBackground": "0.1 0.11 0.13 1",
            "DVTSourceTextSelectionColor": "0.25 0.3 0.4 1",
            "DVTSourceTextInsertionPointColor": "1 1 1 1",
            "DVTLineSpacing": "1.2",
            "DVTMarkupTextPrimaryHeadingColor": "0.9 0.6 0.2 1",
            "DVTSourceTextSyntaxColors": [
                "xcode.syntax.plain": "0.9 0.9 0.9 1",
                "xcode.syntax.keyword": "0.99 0.37 0.64 1",
                "xcode.syntax.string": "0.99 0.42 0.36 1",
                "xcode.syntax.identifier.function": "0.4 0.8 0.9 1",
                "xcode.syntax.markup.aside.kind": "0.5 0.5 0.5 1",
            ],
            "DVTSourceTextSyntaxFonts": [
                "xcode.syntax.plain": "Menlo-Regular - 13.0",
                "xcode.syntax.keyword": "Menlo-Bold - 13.0",
            ],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let result = try CodeThemeImporter.parse(data, fileName: "Acme Midnight.xccolortheme")
        let theme = result.theme
        #expect(result.report.format == .xcode && theme.name == "Acme Midnight" && theme.appearance == .dark)
        #expect(theme.editor.foreground == ThemeColor(red: 0.9, green: 0.9, blue: 0.9))
        #expect(theme.tokens["keyword"]?.bold == true && theme.tokens["string"]?.bold == false)
        #expect(theme.tokens["function"]?.color == ThemeColor(red: 0.4, green: 0.8, blue: 0.9))
        #expect(theme.tokens["markup.heading"] != nil)
        #expect(theme.font == ThemeFont(family: "Menlo-Regular", size: 13, lineSpacing: 1.2))
        #expect(result.report.unmappedScopes == ["xcode.syntax.markup.aside.kind"])
    }

    /// TextMate merges per property: a trailing rule that only italicizes keeps the earlier color.
    @Test func aFontStyleOnlyRuleKeepsTheColor() throws {
        let json = ##"""
        { "name": "Acme Slant", "type": "dark", "colors": { "editor.background": "#101010", "editor.foreground": "#E0E0E0" },
          "tokenColors": [
            { "scope": "comment", "settings": { "foreground": "#808890" } },
            { "scope": "keyword", "settings": { "foreground": "#FF7090", "fontStyle": "bold" } },
            { "scope": ["comment", "keyword"], "settings": { "fontStyle": "italic" } },
            { "scope": "source.python keyword", "settings": { "foreground": "#00FF00" } }
          ] }
        """##
        let result = try CodeThemeImporter.parse(Data(json.utf8), fileName: "slant.json")
        #expect(result.theme.tokens["comment"] == TokenStyle(color: ThemeColor("#808890"), italic: true))
        #expect(result.theme.tokens["keyword"] == TokenStyle(color: ThemeColor("#FF7090"), italic: true))
        #expect(result.report.unmappedScopes == ["source.python keyword"])
    }

    @Test func aNaNInAnXcodeThemeNeverCrashes() throws {
        let plist: [String: Any] = [
            "DVTSourceTextBackground": "nan 0 0 1",
            "DVTLineSpacing": "nan",
            "DVTSourceTextSyntaxColors": ["xcode.syntax.plain": "1 1 1 1", "xcode.syntax.keyword": "nan nan nan 1"],
            "DVTSourceTextSyntaxFonts": ["xcode.syntax.plain": "Menlo - nan"],
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let result = try CodeThemeImporter.parse(data, fileName: "Bad.xccolortheme")
        #expect(result.theme.font.size == nil && result.theme.font.lineSpacing == nil)
        #expect(result.report.unmappedScopes.isEmpty && result.report.skipped == ["xcode.syntax.keyword: unreadable color"])
        #expect(try CodeTheme.decode(result.theme.encoded()) == result.theme)
    }

    /// Several Xcode keys landing on one capture resolve by ScopeMapping.xcode's fixed priority, never by dictionary
    /// order; doc-comment markup colors only fill what the syntax keys left unset.
    @Test func xcodeImportIsDeterministic() throws {
        var syntax: [String: Any] = ["xcode.syntax.plain": "0 0 0 1"]
        let competing = ["identifier.class", "identifier.type", "declaration.type", "identifier.function", "declaration.other",
                         "comment.doc.keyword", "comment.doc", "markup.code", "identifier.macro.system", "identifier.macro"]
        for (index, key) in competing.enumerated() { syntax["xcode.syntax." + key] = "0.\(index) 0 0 1" }
        func shade(_ key: String) -> ThemeColor { ThemeColor(red: Double("0.\(competing.firstIndex(of: key)!)")!, green: 0, blue: 0) }
        let plist: [String: Any] = ["DVTSourceTextBackground": "1 1 1 1", "DVTSourceTextSyntaxColors": syntax,
                                    "DVTMarkupTextInlineCodeColor": "0 0 1 1"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        for _ in 0 ..< 5 {
            let tokens = try CodeThemeImporter.parse(data, fileName: "Order.xccolortheme").theme.tokens
            #expect(tokens["type"]?.color == shade("identifier.type"))
            #expect(tokens["function"]?.color == shade("identifier.function"))
            #expect(tokens["comment.documentation"]?.color == shade("comment.doc"))
            #expect(tokens["function.macro"]?.color == shade("identifier.macro"))
            #expect(tokens["markup.raw"]?.color == shade("markup.code"), "syntax keys win over markup")
        }
    }

    @Test func importRejectsOversizedOrInvalidInput() throws {
        let big = Data(count: CodeTheme.maximumFileSize + 1)
        #expect(throws: CodeThemeError.tooLarge(bytes: big.count)) { try CodeThemeImporter.parse(big, fileName: "a.json") }
        #expect(throws: CodeThemeError.unknownFormat) { try CodeThemeImporter.parse(Data(#"{ "hello": 1 }"#.utf8), fileName: "a.json") }
        #expect(throws: CodeThemeError.unknownFormat) { try CodeThemeImporter.parse(Data("plain text".utf8), fileName: "a.txt") }
        #expect(throws: CodeThemeError.malformed("it isn’t valid JSON.")) { try CodeThemeImporter.parse(Data("{".utf8), fileName: "a.json") }
        let array = try PropertyListSerialization.data(fromPropertyList: ["x"], format: .xml, options: 0)
        #expect(throws: CodeThemeError.malformed("it isn’t a dictionary.")) { try CodeThemeImporter.parse(array, fileName: "a.tmTheme") }
    }

    @Test func aGlossExportImportsAsItself() throws {
        let theme = try #require(CodeTheme.presets.first)
        let result = try CodeThemeImporter.parse(theme.encoded(), fileName: "whatever.json")
        #expect(result.report.format == .gloss && result.theme == theme)
        let commented = Data(("// exported\n" + String(decoding: theme.encoded(), as: UTF8.self)).utf8)
        #expect(try CodeThemeImporter.parse(commented, fileName: "c.json").theme == theme, "a Gloss theme with comments")
    }

    @Test func jsoncCommentsAndTrailingCommasGoButStringsStay() throws {
        let text = #"{ "a": "x // y /* z */ ,]", /* c */ "b": [1, 2,], // d"# + "\n}"
        let object = try JSONSerialization.jsonObject(with: CodeThemeImporter.strippingJSONComments(Data(text.utf8))) as? [String: Any]
        #expect(object?["a"] as? String == "x // y /* z */ ,]")
        #expect(object?["b"] as? [Int] == [1, 2])
    }
}

@MainActor struct CodeThemeStoreTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "gloss-themes-\(UUID().uuidString)", directoryHint: .isDirectory)

    @Test func savedThemesReloadAndBuiltInsCannotBeEditedOrDeleted() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CodeThemeStore(folder: folder, watches: false)
        #expect(store.themes == CodeTheme.builtIns && store.problems.isEmpty)
        #expect(throws: CodeThemeError.readOnly("Gloss")) { try store.save(.gloss) }
        #expect(throws: CodeThemeError.readOnly("Gloss")) { try store.delete(id: "gloss") }

        let copy = try store.duplicate(.gloss)
        #expect(copy.name == "Gloss Copy" && copy.id == "gloss-copy" && !copy.isBuiltIn)
        let second = try store.duplicate(.gloss)
        #expect(second.name == "Gloss Copy 2" && second.id == "gloss-copy-2")
        #expect(store.themes.suffix(2).map(\.id) == ["gloss-copy", "gloss-copy-2"])
        #expect(CodeThemeStore(folder: folder, watches: false).theme(id: "gloss-copy") == copy, "survives a fresh store")
        #expect(copy.editor.background.isSystem, "a copy of Gloss keeps its dynamic colors")

        #expect(throws: CodeThemeError.invalidIdentifier("../gloss-copy")) { try store.delete(id: "../gloss-copy") }
        let trashed = try #require(try store.delete(id: "gloss-copy"))
        defer { try? FileManager.default.removeItem(at: trashed) }
        #expect(store.theme(id: "gloss-copy") == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "gloss-copy.json").path))
        #expect(try CodeTheme.decode(Data(contentsOf: trashed)) == copy, "the file is in the Trash, intact")
        #expect(try store.delete(id: "gloss-copy") == nil, "nothing left to delete")
    }

    @Test func missingThemeFallsBackPerAppearance() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{ broken".utf8).write(to: folder.appending(path: "broken.json"))
        var mismatched = try #require(CodeTheme.presets.first)
        mismatched.id = "other-name"
        try mismatched.encoded().write(to: folder.appending(path: "renamed.json"))
        var builtInID = try #require(CodeTheme.presets.first)
        builtInID.name = "Impostor"
        try builtInID.encoded().write(to: folder.appending(path: "\(builtInID.id).json"))
        try Data("x".utf8).write(to: folder.appending(path: "notes.txt"))

        let store = CodeThemeStore(folder: folder, watches: false)
        #expect(store.problems.map(\.fileName) == ["\(builtInID.id).json", "broken.json", "renamed.json"])
        #expect(store.themes == CodeTheme.builtIns)
        let broken = store.resolve(id: "broken")
        #expect(broken.theme == .gloss && broken.problem?.contains("can’t be read") == true)
        let missing = store.resolve(id: "gone")
        #expect(missing.theme == .gloss && missing.problem?.contains("missing") == true)
        #expect(store.resolve(id: nil).problem == nil && store.resolve(id: "frost-dark").theme.id == "frost-dark")
    }

    @Test func importNeverOverwritesExistingThemeIdentity() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CodeThemeStore(folder: folder, watches: false)
        let source = FileManager.default.temporaryDirectory.appending(path: "gloss-theme-source-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: source) }

        // A Gloss export of a built-in imports as a new user theme, never replacing the built-in.
        let preset = try #require(CodeTheme.presets.first)
        try preset.encoded().write(to: source)
        let first = try store.importTheme(from: source)
        #expect(first.theme.id != preset.id && first.theme.name == "\(preset.name) 2" && !first.theme.isBuiltIn)
        let second = try store.importTheme(from: source)
        #expect(second.theme.id != first.theme.id && second.theme.name == "\(preset.name) 3")
        #expect(store.theme(id: preset.id) == preset)

        let exported = folder.appending(path: "exported.out")
        try store.export(first.theme, to: exported)
        #expect(try CodeTheme.decode(Data(contentsOf: exported)) == first.theme)
    }

    @Test func externalChangesShowUp() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CodeThemeStore(folder: folder)
        var theme = try #require(CodeTheme.presets.first)
        theme.id = "dropped-in"
        theme.name = "Dropped In"
        try theme.encoded().write(to: folder.appending(path: "dropped-in.json"), options: .atomic)
        for _ in 0 ..< 50 where store.theme(id: "dropped-in") == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(store.theme(id: "dropped-in") == theme)

        // Saved in place, not renamed into the folder.
        theme.name = "Dropped In, Edited"
        let handle = try FileHandle(forWritingTo: folder.appending(path: "dropped-in.json"))
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: theme.encoded())
        try handle.close()
        for _ in 0 ..< 50 where store.theme(id: "dropped-in")?.name != theme.name {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(store.theme(id: "dropped-in")?.name == theme.name)

        try FileManager.default.removeItem(at: folder.appending(path: "dropped-in.json"))
        for _ in 0 ..< 50 where store.theme(id: "dropped-in") != nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(store.theme(id: "dropped-in") == nil)

        // The folder removed and made again: the watch follows the path.
        try FileManager.default.removeItem(at: folder)
        try await Task.sleep(for: .milliseconds(300))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try theme.encoded().write(to: folder.appending(path: "dropped-in.json"))
        for _ in 0 ..< 50 where store.theme(id: "dropped-in") == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(store.theme(id: "dropped-in")?.name == theme.name)
    }
}
