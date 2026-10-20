import AppKit
import Core
import SwiftUI
import Testing
@testable import Viewers

@Suite(.serialized)
struct ThemeApplicationTests {
    func palette() -> CodeTheme {
        var theme = CodeTheme.gloss
        theme.id = "fixture-palette"; theme.name = "Example Palette"; theme.appearance = .any
        theme.editor = .derived(background: ThemeColor("#FAFAFA")!,foreground: ThemeColor("#202020")!)
        theme.font = ThemeFont(family: "Menlo",size: 16.5,lineSpacing: 1.4)
        theme.setStyle(TokenStyle(color: ThemeColor("#9B2200"),bold: true),forKey: "keyword",clearingDescendants: true)
        theme.setStyle(TokenStyle(color: ThemeColor("#245500")),forKey: "diff.plus")
        theme.setStyle(TokenStyle(color: ThemeColor("#992211")),forKey: "diff.minus")
        return theme
    }
    func components(_ color: NSColor?,appearance: NSAppearance.Name = .aqua) -> String? {
        guard let color else { return nil }
        let c = ThemeColor(color).resolved(in: appearance)
        return String(format: "%.3f,%.3f,%.3f",c.red,c.green,c.blue)
    }
    func find<T: NSView>(_ type: T.Type,in view: NSView) -> T? {
        if let found = view as? T { return found }
        for child in view.subviews { if let found = find(type,in: child) { return found } }
        return nil
    }
    @Test func glossThemePreservesLegacyColorsAndFont() {
        let prior = ActiveCodeTheme.snapshot(), size = Theme.fontSize
        defer { ActiveCodeTheme.set(light: prior.light,dark: prior.dark); Theme.fontSize = size }
        ActiveCodeTheme.set(light: .gloss,dark: .gloss); Theme.fontSize = 12.5
        let editor = SourceTextView.make()
        #expect(editor.font?.pointSize == 12.5)
        #expect(components(editor.selectedTextAttributes[.foregroundColor] as? NSColor) == components(.selectedTextColor))
        #expect(components(editor.backgroundColor) == components(.textBackgroundColor))
        // Code in a page is 0.9× its text, which is the base font size unless given.
        let output = MarkdownRenderer.render("Body\n\n```swift\nfunc example() {}\n```\n", readingSize: 14)
        let source = output.text.string as NSString
        let index = source.range(of: "func").location
        #expect((output.text.attribute(.font,at: index,effectiveRange: nil) as? NSFont)?.pointSize == 13)
        let base = MarkdownRenderer.render("Body\n\n```swift\nfunc example() {}\n```\n")
        #expect(abs(((base.text.attribute(.font,at: index,effectiveRange: nil) as? NSFont)?.pointSize ?? 0) - 11) < 0.01)
        #expect((base.text.attribute(.font,at: 0,effectiveRange: nil) as? NSFont)?.pointSize == 12.5, "the page's text is the base size")
        let decoration = output.text.attribute(MarkdownRenderer.blockKey,at: index,effectiveRange: nil) as? MarkdownBlockDecoration
        #expect(decoration?.codeForeground == nil)
        for row in CodeTheme.editableTokens {
            #expect(components(ActiveCodeTheme.color(forCapture: row.key)) == components(SyntaxTheme.color(forCapture: row.key)))
        }
    }
    @Test func glossNoteColorsOnEditorGutterMinimapPDFAndFencesMatchTheOriginalSystemColors() {
        let prior = ActiveCodeTheme.snapshot(); defer { ActiveCodeTheme.set(light: prior.light,dark: prior.dark) }
        ActiveCodeTheme.set(light: .gloss,dark: .gloss)
        let originals: [NoteColor: NSColor] = [.yellow: .systemYellow,.green: .systemGreen,.blue: .systemBlue,.pink: .systemPink,.purple: .systemPurple,.orange: .systemOrange]
        for appearance in [NSAppearance.Name.aqua,.darkAqua] {
            for color in NoteColor.allCases {
                // Editor, gutter, source minimap and fences share codeColor; PDF/prose/card selections use color.
                #expect(components(Theme.codeColor(for: color),appearance: appearance) == components(originals[color],appearance: appearance))
                #expect(Theme.color(for: color) == originals[color])
            }
        }
    }
    @Test func renderedMarkdownClassifiesCodeNotesWithoutTreatingProseAsCode() {
        let result = MarkdownRenderer.render("Prose\n\n```swift\nlet count = 1\n```\n")
        let text = result.text.string as NSString
        #expect(!MarkdownRenderer.isCode(at: text.range(of: "Prose").location,in: result.text))
        #expect(MarkdownRenderer.isCode(at: text.range(of: "let count").location,in: result.text))
        #expect(!MarkdownRenderer.isCode(at: result.text.length,in: result.text))
    }
    @Test func markdownThemeChangesCoalesceIntoOneRebuild() {
        let prior = ActiveCodeTheme.snapshot(); defer { ActiveCodeTheme.set(light: prior.light,dark: prior.dark) }
        ActiveCodeTheme.set(light: .gloss,dark: .gloss)
        let controller = MarkdownViewerController(source: TextEditorController(text: "```swift\nlet value = 1\n```",languageName: "markdown"))
        let version = controller.renderedVersion
        var theme = palette()
        ActiveCodeTheme.set(light: theme,dark: theme)
        theme.font.size = 17
        ActiveCodeTheme.set(light: theme,dark: theme)
        theme.editor.foreground = ThemeColor("#303030")!
        ActiveCodeTheme.set(light: theme,dark: theme)
        #expect(controller.renderedVersion == version)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(controller.renderedVersion == version+1)
        let code = (controller.rendered.string as NSString).range(of: "let value").location
        #expect((controller.rendered.attribute(.font,at: code,effectiveRange: nil) as? NSFont)?.pointSize == 17)
    }
    @Test func systemCaretIsNativeAndReturningFromACustomCaretClearsTheOverride() {
        let prior = ActiveCodeTheme.snapshot(); defer { ActiveCodeTheme.set(light: prior.light,dark: prior.dark) }
        ActiveCodeTheme.set(light: .gloss,dark: .gloss)
        let editor = SourceTextView.make()
        let native = NSTextView(usingTextLayoutManager: true)
        #expect(components(editor.insertionPointColor) == components(native.insertionPointColor))
        var theme = palette(); theme.editor.cursor = ThemeColor("#882233")!
        ActiveCodeTheme.set(light: theme,dark: theme); editor.applyEditorSettings()
        #expect(components(editor.insertionPointColor) == components(theme.editor.cursor.nsColor))
        ActiveCodeTheme.set(light: .gloss,dark: .gloss); editor.applyEditorSettings()
        #expect(components(editor.insertionPointColor) == components(native.insertionPointColor))
        // A system theme does not override a caret owned by AppKit or another view customizer.
        editor.insertionPointColor = .systemYellow; editor.applyEditorSettings()
        #expect(editor.insertionPointColor == .systemYellow)
    }
    @Test func markdownBodyFontSurvivesCodeThemeChange() throws {
        let theme = palette()
        let result = MarkdownRenderer.render("Ordinary prose\n\n```swift\nlet count = 42\n```\n",codeTheme: theme)
        let text = result.text.string as NSString
        let body = text.range(of: "Ordinary").location, code = text.range(of: "let").location
        let bodyFont = try #require(result.text.attribute(.font,at: body,effectiveRange: nil) as? NSFont)
        let codeFont = try #require(result.text.attribute(.font,at: code,effectiveRange: nil) as? NSFont)
        #expect(bodyFont == MarkdownRenderer.bodyFont && codeFont.pointSize == 16.5)
        #expect(codeFont.fontDescriptor.symbolicTraits.contains(.bold))
        #expect((result.text.attribute(.paragraphStyle,at: code,effectiveRange: nil) as? NSParagraphStyle)?.lineHeightMultiple == 1.4)
        let decoration = try #require(result.text.attribute(MarkdownRenderer.blockKey,at: code,effectiveRange: nil) as? MarkdownBlockDecoration)
        #expect(components(decoration.codeBackground) == components(theme.editor.codeBlockBackground.nsColor))
    }
    @Test func snippetFontRemainsUISizedAndItsColorsFitTheSystemSurface() throws {
        let prior = ActiveCodeTheme.snapshot(); defer { ActiveCodeTheme.set(light: prior.light,dark: prior.dark) }
        var theme = palette(); theme.font.size = 20
        theme.editor.background = ThemeColor("#101010")!
        theme.tokens["string"] = TokenStyle(color: ThemeColor("#FFFFEE"))
        ActiveCodeTheme.set(light: theme,dark: theme)
        let snippet = try #require(SyntaxTheme.highlighted("let greeting = \"hi\"",language: "swift",appearance: .aqua,background: .white))
        #expect(snippet.runs.allSatisfy { $0.appKit.font == nil })
        #expect(snippet.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        for run in snippet.runs {
            if let color = run.appKit.foregroundColor { #expect(ThemeContrast.ratio(color,.white,in: .aqua) >= 2.999) }
        }
    }
    @Test func diffUsesThemeTokensAndExistingQuietWashes() {
        let prior = ActiveCodeTheme.snapshot(); defer { ActiveCodeTheme.set(light: prior.light,dark: prior.dark) }
        let theme = palette(); ActiveCodeTheme.set(light: theme,dark: theme)
        let result = MarkdownRenderer.render("```diff\n-old\n+new\n```\n")
        let text = result.text.string as NSString
        let plus = result.text.attribute(.foregroundColor,at: text.range(of: "+new").location,effectiveRange: nil) as? NSColor
        #expect(components(plus) == components(theme.color(forCapture: "diff.plus")))
        #expect(components(Theme.changeBar) == components(theme.color(forCapture: "diff.plus")))
        #expect(Theme.changeBar.alphaComponent == 0.85 && Theme.changeDeletedMarker.alphaComponent == 0.9)
    }
    @Test func noteColorsRemainLegibleAgainstCustomBackground() {
        let prior = ActiveCodeTheme.snapshot(); defer { ActiveCodeTheme.set(light: prior.light,dark: prior.dark) }
        for background in ["#FFFFFF","#101010","#907030"] {
            var theme = palette(); theme.editor.background = ThemeColor(background)!
            ActiveCodeTheme.set(light: theme,dark: theme)
            for color in NoteColor.allCases {
                #expect(ThemeContrast.ratio(Theme.codeColor(for: color),theme.editor.background.nsColor,in: .aqua) >= 2.999)
            }
        }
    }
    @Test func codeThemesDoNotRecolorSystemNotesOnPDFProseOrCards() {
        let prior = ActiveCodeTheme.snapshot(); defer { ActiveCodeTheme.set(light: prior.light,dark: prior.dark) }
        var theme = palette(); theme.editor.background = ThemeColor("#907030")!
        ActiveCodeTheme.set(light: theme,dark: theme)
        for appearance in [NSAppearance.Name.aqua,.darkAqua] {
            for color in NoteColor.allCases {
                #expect(components(Theme.color(for: color),appearance: appearance) == components(CodeTheme.gloss.noteColor(color),appearance: appearance))
            }
        }
    }
    @Test func selectionStaysDistinctFromClashingNoteFills() {
        var theme = palette(); theme.editor.background = ThemeColor("#FFFFFF")!
        let color = theme.noteColor(.green)
        let value = ThemeColor(color).resolved(in: .aqua)
        theme.editor.selection = ThemeColor(red: 1+(value.red-1)*0.28,green: 1+(value.green-1)*0.28,blue: 1+(value.blue-1)*0.28)
        #expect(!theme.selectionClashes().isEmpty)
        let displayed = Theme.selectedColors(theme: theme,in: .aqua)
        #expect(ThemeContrast.ratio(displayed.background,theme.editor.background.nsColor,in: .aqua) >= 1.799)
        #expect(ThemeContrast.ratio(displayed.foreground,displayed.background,in: .aqua) >= 4.499)
        #expect(Theme.mark(for: .sent,focused: false) == .underline && Theme.mark(for: .resolved,focused: false) == .dottedUnderline)
    }
    @Test func aPendingParagraphUpdateCannotConsumeANewDocumentsFontState() throws {
        let prior = ActiveCodeTheme.snapshot(); defer { ActiveCodeTheme.set(light: prior.light,dark: prior.dark) }
        ActiveCodeTheme.set(light: .gloss,dark: .gloss)
        let controller = TextEditorController(text: "let first = 1\nlet second = 2\n",languageName: "swift")
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 500,height: 300),styleMask: [.titled],backing: .buffered,defer: false)
        window.appearance = NSAppearance(named: .aqua)
        let hosting = NSHostingView(rootView: TextEditorView(controller: controller)); window.contentView = hosting
        window.layoutIfNeeded()
        let editor = try #require(find(SourceTextView.self,in: hosting))
        editor.insertText("3",replacementRange: NSRange(location: 12,length: 1))
        let theme = palette(); ActiveCodeTheme.set(light: theme,dark: theme)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let second = (editor.string as NSString).range(of: "let second").location
        let firstFont = editor.textStorage?.attribute(.font,at: 0,effectiveRange: nil) as? NSFont
        let secondFont = editor.textStorage?.attribute(.font,at: second,effectiveRange: nil) as? NSFont
        #expect(firstFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(secondFont?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(firstFont?.pointSize == 16.5 && secondFont?.pointSize == 16.5)
        var colorsOnly = theme; colorsOnly.editor.foreground = ThemeColor("#404040")!
        let version = controller.contentVersion
        ActiveCodeTheme.set(light: colorsOnly,dark: colorsOnly)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        #expect(controller.contentVersion == version && editor.appliedEditorFont == theme.font.resolved(defaultSize: Theme.fontSize))
        #expect(editor.textStorage?.attribute(.font,at: second,effectiveRange: nil) as? NSFont == secondFont)
        editor.insertText("let third = 3\n",replacementRange: NSRange(location: editor.string.utf16.count,length: 0))
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let third = (editor.string as NSString).range(of: "let third").location
        let thirdFont = editor.textStorage?.attribute(.font,at: third,effectiveRange: nil) as? NSFont
        #expect(thirdFont?.fontDescriptor.symbolicTraits.contains(.bold) == true && thirdFont?.pointSize == 16.5)
    }
    @Test func everyCodeSurfaceUsesActiveThemeWithoutChangingTextUndoOrSelection() throws {
        let prior = ActiveCodeTheme.snapshot(); defer { ActiveCodeTheme.set(light: prior.light,dark: prior.dark) }
        ActiveCodeTheme.set(light: .gloss,dark: .gloss)
        let text = "let count = 42\n// comment\n"
        let controller = TextEditorController(text: text,languageName: "swift")
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 500,height: 300),styleMask: [.titled],backing: .buffered,defer: false)
        window.appearance = NSAppearance(named: .aqua)
        let hosting = NSHostingView(rootView: TextEditorView(controller: controller)); window.contentView = hosting
        window.layoutIfNeeded()
        let editor = try #require(find(SourceTextView.self,in: hosting))
        editor.setSelectedRange(NSRange(location: 4,length: 5))
        editor.insertText("value",replacementRange: editor.selectedRange())
        editor.setSelectedRange(NSRange(location: 4,length: 5))
        let before = editor.string, version = controller.contentVersion
        let theme = palette(); ActiveCodeTheme.set(light: theme,dark: theme)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect(editor.string == before && controller.contentVersion == version)
        #expect(editor.selectedRange() == NSRange(location: 4,length: 5) && editor.undoManager?.canUndo == true)
        #expect(editor.font?.pointSize == 16.5)
        #expect(components(editor.backgroundColor) == components(theme.editor.background.nsColor))
        let font = editor.textStorage?.attribute(.font,at: 0,effectiveRange: nil) as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        let snippet = try #require(SyntaxTheme.highlighted(editor.string,language: "swift"))
        #expect(snippet.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        let markdown = MarkdownRenderer.render("```swift\nlet value = 42\n```\n")
        #expect((markdown.text.attribute(.font,at: 0,effectiveRange: nil) as? NSFont)?.pointSize == 16.5)
    }
}
