import AppKit
import SwiftUI
import Testing
@testable import Viewers

/// Typing leaves the caret after what was typed: wrap indents and highlighting restyle paragraphs during each edit,
/// and none of that may move the selection.
@MainActor
struct TypingCaretTests {
    @Test func typedCharactersStayTogether() throws {
        let controller = TextEditorController(text: "import Foundation\n\nlet x = 1\n")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: TextEditorView(controller: controller))
        hosting.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for subview in view.subviews { if let found = find(type, in: subview) { return found } }
            return nil
        }
        let textView = try #require(find(SourceTextView.self, in: hosting))
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("x", replacementRange: textView.selectedRange())
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        textView.insertText("y", replacementRange: textView.selectedRange())
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        textView.insertTab(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect(textView.string.hasPrefix("xy\timport Foundation\n\n"), "got: \(textView.string.debugDescription)")
        #expect(textView.selectedRange() == NSRange(location: 3, length: 0))
    }
}

@MainActor
struct WrapIndentResizeTests {
    @Test func narrowingTheEditorRecapsDeepIndents() throws {
        let deep = String(repeating: " ", count: 60) + Array(repeating: "words", count: 30).joined(separator: " ")
        let controller = TextEditorController(text: "top\n" + deep + "\n")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 300), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: TextEditorView(controller: controller))
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 300)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for subview in view.subviews { if let found = find(type, in: subview) { return found } }
            return nil
        }
        let textView = try #require(find(SourceTextView.self, in: hosting))
        window.setContentSize(NSSize(width: 360, height: 300))
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let width = try #require(textView.textContainer?.size.width)
        let style = textView.textStorage?.attribute(.paragraphStyle, at: 5, effectiveRange: nil) as? NSParagraphStyle
        #expect((style?.headIndent ?? .infinity) <= width * 0.4 + 0.5, "indent \(style?.headIndent ?? -1) for width \(width)")
    }
}
