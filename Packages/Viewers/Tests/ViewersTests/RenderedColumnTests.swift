import AppKit
import Core
import SwiftUI
import Testing
@testable import Viewers

/// Issue #20: resizing the window laid the rendered document out again on every step, blanking and re-wrapping it.
@MainActor
struct RenderedColumnTests {
    @Test func theColumnIsCentredAndAWiderWindowNeedsNoNewLayout() throws {
        var markdown = "# Title\n\nThe paragraph with a note on it.\n\n"
        for index in 1...20 { markdown += "Paragraph \(index), long enough to wrap over more than one line of the reading column when it is at its widest.\n\n" }
        let source = TextEditorController(text: markdown, languageName: "markdown")
        let noted = (markdown as NSString).range(of: "with a note")
        source.highlights = [TextHighlight(id: NoteID.new(), range: noted, color: .yellow, state: .draft)]
        let controller = MarkdownViewerController(source: source)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 500), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: MarkdownViewerView(controller: controller))
        hosting.frame = NSRect(x: 0, y: 0, width: 1300, height: 500)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for subview in view.subviews { if let found = find(type, in: subview) { return found } }
            return nil
        }
        let textView = try #require(find(RenderedTextView.self, in: hosting))
        let layoutManager = try #require(textView.textLayoutManager)
        #expect(textView.textContainer?.size.width == RenderedTextView.maximumColumnWidth)
        // Where AppKit itself puts the first character (its screen rect, brought back into the view), not a frame
        // worked out from the overridden origin.
        func firstCharacterX() -> CGFloat {
            let screen = textView.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
            guard let window = textView.window else { return -1 }
            return textView.convert(window.convertFromScreen(screen), from: nil).minX
        }
        #expect(abs(firstCharacterX() - (textView.bounds.width - RenderedTextView.maximumColumnWidth) / 2) < 2, "centred")
        let fragment = layoutManager.textLayoutFragment(for: layoutManager.documentRange.location)

        // A wider window moves the column; the text keeps the layout it had.
        window.setContentSize(NSSize(width: 1500, height: 500))
        hosting.frame = NSRect(x: 0, y: 0, width: 1500, height: 500)
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect(abs(firstCharacterX() - (textView.bounds.width - RenderedTextView.maximumColumnWidth) / 2) < 2, "still centred")
        #expect(layoutManager.textLayoutFragment(for: layoutManager.documentRange.location) === fragment, "not laid out again")

        // A pane narrower than the column narrows it.
        window.setContentSize(NSSize(width: 600, height: 500))
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect((textView.textContainer?.size.width ?? 0) < 600)
        #expect(abs(firstCharacterX() - RenderedTextView.minimumMargin) < 2)
        #expect(controller.pageWidth == textView.textContainer?.size.width, "the renderer hears the column's width, for tables")

        // A page that fills the window grows with it.
        let saved = Theme.renderedPageWidth
        defer { Theme.renderedPageWidth = saved }
        Theme.renderedPageWidth = nil
        window.setContentSize(NSSize(width: 1500, height: 500))
        hosting.frame = NSRect(x: 0, y: 0, width: 1500, height: 500)
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect(textView.textContainer?.size.width == textView.bounds.width - RenderedTextView.minimumMargin * 2)

        // A narrower page width takes effect at once.
        Theme.renderedPageWidth = 640
        #expect(textView.textContainer?.size.width == 640)
        #expect(abs(firstCharacterX() - (textView.bounds.width - 640) / 2) < 2)
    }
}
