import AppKit
import SwiftUI

extension SyntaxTheme {
    private struct SnippetKey: Hashable { let text: String; let language: String }
    @MainActor private static var snippetCaptures: [SnippetKey: [HighlightCapture]] = [:]

    /// Quotes keep their UI size and surface. Reuse semantic captures when a theme changes; only colors/traits vary.
    @MainActor public static func highlighted(_ text: String, language: String?, theme: CodeTheme? = nil,
                                             appearance: NSAppearance.Name? = nil, background: NSColor = .windowBackgroundColor) -> AttributedString? {
        guard let language, !text.isEmpty, text.utf16.count < 4_000 else { return nil }
        let key = SnippetKey(text: text,language: language)
        let captures: [HighlightCapture]
        if let cached = snippetCaptures[key] { captures = cached }
        else {
            guard let highlighter = Highlighter(languageName: language,text: text) else { return nil }
            captures = highlighter.captures
            if snippetCaptures.count >= 80 { snippetCaptures.removeAll(keepingCapacity: true) }
            snippetCaptures[key] = captures
        }
        let appearance = appearance ?? Theme.effectiveAppearance.name
        let palette = theme ?? ActiveCodeTheme.theme(for: NSAppearance(named: appearance) ?? Theme.effectiveAppearance)
        let coloured = NSMutableAttributedString(string: text)
        func displayColor(_ capture: String?) -> NSColor {
            NSColor(name: nil) { drawingAppearance in
                let palette = theme ?? ActiveCodeTheme.theme(for: drawingAppearance)
                let color = capture.flatMap { palette.color(forCapture: $0) } ?? palette.editor.foreground.nsColor
                return palette.id == "gloss" ? color : ThemeContrast.legible(color,on: background,in: drawingAppearance.name)
            }
        }
        if palette.id != "gloss" { coloured.addAttribute(.foregroundColor,value: displayColor(nil),range: NSRange(location: 0,length: coloured.length)) }
        for capture in captures {
            guard NSMaxRange(capture.range) <= coloured.length, palette.style(forCapture: capture.name) != nil else { continue }
            coloured.addAttribute(.foregroundColor,value: displayColor(capture.name),range: capture.range)
        }
        guard var result = try? AttributedString(coloured,including: \.appKit) else { return nil }
        for capture in captures {
            guard let style = palette.style(forCapture: capture.name), style.bold || style.italic,
                  let range = Range(capture.range,in: text),
                  let lower = AttributedString.Index(range.lowerBound,within: result), let upper = AttributedString.Index(range.upperBound,within: result) else { continue }
            var traits: InlinePresentationIntent = []
            if style.bold { traits.insert(.stronglyEmphasized) }
            if style.italic { traits.insert(.emphasized) }
            result[lower..<upper].inlinePresentationIntent = traits
        }
        return result
    }
}
