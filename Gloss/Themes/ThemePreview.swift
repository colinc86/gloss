import AppKit
import SwiftUI
import Viewers
import Core

nonisolated enum ThemePreviewMode: String, CaseIterable, Identifiable {
    case code = "Code", markdown = "Markdown", diff = "Diff"
    var id: String { rawValue }
    var source: String {
        switch self {
        case .code: "// A sample, not a document\nstruct Example {\n    let count: Int = 42\n    func greeting() -> String {\n        return \"Hello\"\n    }\n}\n"
        case .markdown: "# Heading\nOrdinary prose with *emphasis* and a [link](https://example.com).\n\n```swift\nlet count = 42 // Sample\nprint(\"Hello\")\n```\n"
        case .diff: "diff --git a/example.swift b/example.swift\n--- a/example.swift\n+++ b/example.swift\n@@ -1,2 +1,2 @@\n-let count = 2\n+let count = 42\n // unchanged\n"
        }
    }
    var language: String { self == .code ? "swift" : (self == .markdown ? "markdown" : "diff") }
}

struct ThemePreview: View {
    let theme: CodeTheme
    let slot: ThemeSlot
    var mode: ThemePreviewMode = .code
    var defaultSize: CGFloat = 12.5
    var body: some View {
        VStack(alignment: .leading,spacing: DS.Space.xs) {
            ThemeSampleCanvas(theme: theme,slot: slot,mode: mode,defaultSize: defaultSize)
                .frame(minHeight: 140)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.s))
            HStack(spacing: DS.Space.s) {
                ForEach(NoteColor.allCases,id: \.self) { note in
                    Circle().fill(Color(nsColor: Theme.color(for: note))).frame(width: 8,height: 8)
                        .accessibilityLabel("\(note.rawValue) note")
                }
                Text("Notes · Selection · + Added · − Removed").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// A read-only sample has no document, undo manager, or global theme switch. Each appearance preview is independent.
private struct ThemeSampleCanvas: NSViewRepresentable {
    let theme: CodeTheme
    let slot: ThemeSlot
    let mode: ThemePreviewMode
    let defaultSize: CGFloat
    func makeNSView(context: Context) -> SampleView { SampleView(frame: .zero) }
    func updateNSView(_ view: SampleView,context: Context) {
        view.appearance = NSAppearance(named: slot.appearance)
        view.theme = theme; view.mode = mode; view.defaultSize = defaultSize
        view.setAccessibilityLabel("\(slot.rawValue.capitalized) theme preview, \(theme.name). Sample \(mode.rawValue). Selection, six note colors, added and removed lines.")
        view.needsDisplay = true
    }
    final class SampleView: NSView {
        var theme = CodeTheme.gloss
        var mode = ThemePreviewMode.code
        var defaultSize: CGFloat = 12.5
        private var grammar: String?
        private var captures: [HighlightCapture] = []
        override var isFlipped: Bool { true }
        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(true); setAccessibilityRole(.staticText)
        }
        required init?(coder: NSCoder) { nil }
        override func draw(_ dirtyRect: NSRect) {
            let appearance = effectiveAppearance.name
            theme.editor.background.nsColor.setFill(); bounds.fill()
            theme.editor.gutterBackground.nsColor.setFill(); NSRect(x: 0,y: 0,width: 30,height: bounds.height).fill()
            let code = mode.source
            if grammar != mode.language {
                grammar = mode.language; captures = Highlighter(languageName: mode.language,text: code)?.captures ?? []
            }
            let font = theme.font.resolved(defaultSize: defaultSize)
            let text = NSMutableAttributedString(string: code,attributes: [.font: font,.foregroundColor: theme.editor.foreground.nsColor])
            if mode == .markdown {
                NSColor.textBackgroundColor.setFill(); bounds.fill()
                let rendered = NSMutableAttributedString(attributedString: MarkdownRenderer.render(code,codeTheme: theme,codeAppearance: appearance).text)
                let full = NSRange(location: 0,length: rendered.length)
                rendered.enumerateAttribute(MarkdownRenderer.blockKey,in: full) { value, range, _ in
                    if let decoration = value as? MarkdownBlockDecoration, decoration.kind == .codeBlock {
                        rendered.addAttribute(.backgroundColor,value: theme.editor.codeBlockBackground.nsColor,range: range)
                    }
                }
                if let range = rendered.string.range(of: "count") {
                    let selection = Theme.selectedColors(theme: theme,in: appearance)
                    rendered.addAttributes([.backgroundColor: selection.background,.foregroundColor: selection.foreground],range: NSRange(range,in: rendered.string))
                }
                rendered.draw(with: NSRect(x: 38,y: 8,width: max(0,bounds.width-46),height: bounds.height-16),options: [.usesLineFragmentOrigin,.usesFontLeading])
                for index in 0..<6 { theme.noteColor(NoteColor.allCases[index]).setFill(); NSRect(x: 8,y: 10+CGFloat(index)*18,width: 3,height: 15).fill() }
                return
            }
            for capture in captures {
                guard let style = theme.style(forCapture: capture.name), NSMaxRange(capture.range) <= text.length else { continue }
                if let color = style.color { text.addAttribute(.foregroundColor,value: color.nsColor,range: capture.range) }
                text.addAttribute(.font,value: style.font(from: font),range: capture.range)
            }
            let selection = Theme.selectedColors(theme: theme,in: appearance)
            if let range = code.range(of: mode == .diff ? "42" : "count") {
                text.addAttributes([.backgroundColor: selection.background,.foregroundColor: selection.foreground],range: NSRange(range,in: code))
            }
            let lineHeight = max(14,NSLayoutManager().defaultLineHeight(for: font) * CGFloat(theme.font.lineSpacing ?? 1))
            theme.editor.currentLine.nsColor.setFill(); NSRect(x: 0,y: 8+lineHeight*2,width: bounds.width,height: lineHeight).fill()
            for index in 0..<6 {
                let color = theme.noteColor(NoteColor.allCases[index])
                color.setFill(); NSRect(x: 33+CGFloat(index)*3,y: 9+CGFloat(index)*lineHeight,width: 2,height: lineHeight-2).fill()
            }
            let paragraph = NSMutableParagraphStyle(); paragraph.lineHeightMultiple = CGFloat(theme.font.lineSpacing ?? 1)
            text.addAttribute(.paragraphStyle,value: paragraph,range: NSRange(location: 0,length: text.length))
            text.draw(with: NSRect(x: 40,y: 8,width: max(0,bounds.width-48),height: bounds.height-16),options: [.usesLineFragmentOrigin,.usesFontLeading])
            for line in 0..<8 where CGFloat(line)*lineHeight < bounds.height {
                NSAttributedString(string: String(line+1),attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 9,weight: .regular),.foregroundColor: theme.editor.lineNumbers.nsColor])
                    .draw(at: NSPoint(x: 12,y: 8+CGFloat(line)*lineHeight))
            }
        }
    }
}
