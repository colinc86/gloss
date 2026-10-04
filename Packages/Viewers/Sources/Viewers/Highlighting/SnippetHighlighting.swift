import AppKit
import SwiftUI

extension SyntaxTheme {
    /// A short piece of code coloured as the editor colours it, for quoting a selection back (the note composer).
    /// Nil when there is no grammar for the language, so callers fall back to plain text. Meant for a few lines:
    /// it parses the snippet on its own.
    public static func highlighted(_ text: String, language: String?) -> AttributedString? {
        guard let language, !text.isEmpty, text.utf16.count < 4_000,
              let highlighter = Highlighter(languageName: language, text: text) else { return nil }
        let coloured = NSMutableAttributedString(string: text)
        for capture in highlighter.captures(in: NSRange(location: 0, length: coloured.length)) {
            guard let color = color(forCapture: capture.name), NSMaxRange(capture.range) <= coloured.length else { continue }
            coloured.addAttribute(.foregroundColor, value: color, range: capture.range)
        }
        return try? AttributedString(coloured, including: \.appKit)
    }
}
