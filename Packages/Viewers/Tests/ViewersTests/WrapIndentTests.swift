import AppKit
import SwiftUI
import Testing
@testable import Viewers

/// Wrapped lines continue at their own indentation plus one step, so a wrap never reads as a new line of code.
struct WrapIndentTests {
    @Test func indentFollowsLeadingWhitespacePlusOneStep() {
        let indent = { (line: String) in SourceTextView.wrapIndent(forLine: line, spaceWidth: 7, tabWidth: 28, limit: 1000) }
        #expect(indent("let x = 1") == 28)
        #expect(indent("    let x = 1") == 56)
        #expect(indent("\tlet x = 1") == 56)
        #expect(indent("  \tlet x = 1") == 56, "a tab runs to the next tab stop")
        #expect(indent("        ") == 0, "a blank line has nothing to wrap")
        #expect(indent("") == 0)
        #expect(SourceTextView.wrapIndent(forLine: String(repeating: " ", count: 80) + "x", spaceWidth: 7, tabWidth: 28, limit: 120) == 120)
    }

    @MainActor
    @Test func aWrappedLineContinuesUnderItsIndentation() throws {
        let long = "    /// " + Array(repeating: "words that run on", count: 12).joined(separator: " ")
        let controller = TextEditorController(text: "first\n" + long + "\nlast")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: TextEditorView(controller: controller))
        hosting.frame = NSRect(x: 0, y: 0, width: 460, height: 400)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        window.displayIfNeeded()

        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for subview in view.subviews { if let found = find(type, in: subview) { return found } }
            return nil
        }
        let textView = try #require(find(SourceTextView.self, in: hosting))
        let space = (" " as NSString).size(withAttributes: [.font: textView.font ?? Theme.editorFont]).width
        func rows(ofParagraph index: Int) -> [CGFloat] {
            var paragraph = 0
            var starts: [CGFloat] = []
            textView.textLayoutManager?.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
                if paragraph == index { starts = fragment.textLineFragments.map(\.typographicBounds.minX) }
                paragraph += 1
                return paragraph <= index
            }
            return starts
        }
        let starts = rows(ofParagraph: 1)
        try #require(starts.count > 1, "the long line should wrap")
        #expect(abs(starts[0]) < 1)
        // Four spaces of indentation plus one four-space step.
        #expect(abs(starts[1] - space * 8) < 1)

        // Typing at the start of the line moves its continuation along with it.
        textView.replaceUndoable(NSRange(location: 6, length: 0), with: "    ")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))   // indents follow once the edit is done
        let moved = rows(ofParagraph: 1)
        #expect(abs(moved[1] - space * 12) < 1)
    }
}

/// Settings › Editor reaches editors that are already open.
@MainActor
struct LiveEditorSettingsTests {
    @Test func anOpenEditorTakesANewFontAndWrappingAndKeepsItsText() throws {
        let long = "    " + Array(repeating: "words that run on", count: 12).joined(separator: " ")
        let controller = TextEditorController(text: "a {\n    b {\n        c\n    }\n}\n" + (1...60).map { "line \($0)" }.joined(separator: "\n") + "\n" + long)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: TextEditorView(controller: controller))
        hosting.frame = NSRect(x: 0, y: 0, width: 460, height: 300)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for subview in view.subviews { if let found = find(type, in: subview) { return found } }
            return nil
        }
        let textView = try #require(find(SourceTextView.self, in: hosting))
        let storage = try #require(textView.textStorage)
        let before = storage.string
        let longLine = (storage.string as NSString).range(of: long).location

        let bigger = NSFont.monospacedSystemFont(ofSize: 18, weight: .regular)
        textView.applyEditorSettings(font: bigger, wraps: false)
        #expect((storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 18)
        #expect(textView.textContainer?.widthTracksTextView == false)
        window.displayIfNeeded()
        func inked() -> Int {
            guard let backdrop = textView.subviews.first(where: { $0 is HighlightBackdropView }) else { return -1 }
            let rect = NSRect(x: 0, y: 0, width: 300, height: 300)
            guard let rep = backdrop.bitmapImageRepForCachingDisplay(in: rect) else { return -2 }
            backdrop.cacheDisplay(in: rect, to: rep)
            var count = 0
            for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.01 { count += 1 } }
            return count
        }
        #expect(inked() > 0, "guides still draw when lines run on")
        #expect(storage.attribute(.paragraphStyle, at: longLine, effectiveRange: nil) == nil, "no hanging indent when lines run on")

        textView.applyEditorSettings(font: bigger, wraps: true)
        window.displayIfNeeded()
        #expect(inked() > 0, "and after wrapping comes back")
        #expect(textView.textContainer?.widthTracksTextView == true)
        let style = storage.attribute(.paragraphStyle, at: longLine, effectiveRange: nil) as? NSParagraphStyle
        let space = (" " as NSString).size(withAttributes: [.font: bigger]).width
        #expect(abs((style?.headIndent ?? 0) - space * 8) < 0.5, "indents follow the new font's width")
        #expect(storage.string == before)
    }
}
