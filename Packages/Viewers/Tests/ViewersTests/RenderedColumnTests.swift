import AppKit
import Core
import SwiftUI
import Testing
@testable import Viewers

/// Issue #20: resizing the window laid the rendered document out again on every step, blanking and re-wrapping it.
/// Serialized: they change the page width setting.
@MainActor @Suite(.serialized)
struct RenderedColumnTests {
    @Test func theColumnIsCentredAndAWiderWindowNeedsNoNewLayout() async throws {
        var markdown = "# Title\n\nThe paragraph with a note on it.\n\n"
        for index in 1...20 { markdown += "Paragraph \(index), long enough to wrap over more than one line of the reading column when it is at its widest.\n\n" }
        // A table too wide for the column sets the column in, leaving it room to scroll.
        markdown += "| \((1...8).map { "h\($0)" }.joined(separator: " | ")) |\n|\(String(repeating: " - |", count: 8))\n"
        markdown += "| \(Array(repeating: "Supercalifragilistic", count: 8).joined(separator: " | ")) |\n"
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
        try await Task.sleep(for: .milliseconds(300))
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for subview in view.subviews { if let found = find(type, in: subview) { return found } }
            return nil
        }
        let textView = try #require(find(RenderedTextView.self, in: hosting))
        let layoutManager = try #require(textView.textLayoutManager)
        let laid = try #require(controller.laidOutColumn)
        #expect(laid.width == Theme.renderedPageWidth && laid.inset > 0, "the page is as wide as the setting")
        #expect(textView.textContainer?.size.width == laid.width + laid.inset * 2, "room either side of the column")
        // Where AppKit itself puts the first character (its screen rect, brought back into the view), not a frame
        // worked out from the overridden origin.
        func firstCharacterX() -> CGFloat {
            let screen = textView.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
            guard let window = textView.window else { return -1 }
            return textView.convert(window.convertFromScreen(screen), from: nil).minX
        }
        // The column is centred, its room out of sight.
        #expect(abs(firstCharacterX() - (textView.bounds.width - laid.width) / 2) < 2, "centred")
        /// Waits, up to a few seconds, for the page to be rendered again for its new width.
        func settle(_ done: () -> Bool) async throws {
            for _ in 0..<30 where !done() {
                try await Task.sleep(for: .milliseconds(100))
                hosting.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
        }
        let fragment = layoutManager.textLayoutFragment(for: layoutManager.documentRange.location)
        let version = controller.renderedVersion

        // A wider window moves the column; the text keeps the layout it had.
        window.setContentSize(NSSize(width: 1500, height: 500))
        hosting.frame = NSRect(x: 0, y: 0, width: 1500, height: 500)
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect(abs(firstCharacterX() - (textView.bounds.width - laid.width) / 2) < 2, "still centred")
        #expect(controller.renderedVersion == version, "not rendered again")
        #expect(layoutManager.textLayoutFragment(for: layoutManager.documentRange.location) === fragment, "not laid out again")

        // A pane narrower than the column narrows it, once the page is laid out again for it: until then it keeps the
        // width its text was set in for, centred, rather than squeezing the text.
        window.setContentSize(NSSize(width: 600, height: 500))
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await settle { abs(firstCharacterX() - RenderedTextView.minimumMargin) < 2 }
        let narrowed = try #require(controller.laidOutColumn)
        #expect(narrowed.width < 600 && controller.columnWidth == narrowed.width, "the renderer hears the column's width, for tables")
        #expect(abs(firstCharacterX() - RenderedTextView.minimumMargin) < 2, "rendered again for the narrower column")

        // A page that fills the window grows with it.
        let saved = Theme.renderedPageWidth
        defer { Theme.renderedPageWidth = saved }
        Theme.renderedPageWidth = nil
        window.setContentSize(NSSize(width: 1500, height: 500))
        hosting.frame = NSRect(x: 0, y: 0, width: 1500, height: 500)
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await settle { controller.laidOutColumn?.width == textView.bounds.width - RenderedTextView.minimumMargin * 2 }
        #expect(controller.laidOutColumn?.width == textView.bounds.width - RenderedTextView.minimumMargin * 2)

        // A narrower page width takes effect without waiting for a pause.
        Theme.renderedPageWidth = 640
        try await settle { controller.laidOutColumn?.width == 640 }
        #expect(controller.laidOutColumn?.width == 640)
        #expect(abs(firstCharacterX() - (textView.bounds.width - 640) / 2) < 2)
    }

    /// A page of text fills the page: the page width setting's, or the window's.
    @Test func textFillsThePage() async throws {
        let markdown = "# Title\n\nA paragraph long enough to wrap over more than one line of the reading column, which it would not do on a wide page.\n"
        let controller = MarkdownViewerController(source: TextEditorController(text: markdown, languageName: "markdown"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 500), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: MarkdownViewerView(controller: controller))
        hosting.frame = NSRect(x: 0, y: 0, width: 1500, height: 500)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for subview in view.subviews { if let found = find(type, in: subview) { return found } }
            return nil
        }
        let textView = try #require(find(RenderedTextView.self, in: hosting))
        #expect(textView.textContainer?.size.width == Theme.renderedPageWidth)
        #expect(controller.laidOutColumn == nil, "no room set aside without a wide table")
        let saved = Theme.renderedPageWidth
        defer { Theme.renderedPageWidth = saved }
        Theme.renderedPageWidth = nil
        #expect(textView.textContainer?.size.width == textView.bounds.width - RenderedTextView.minimumMargin * 2, "filling the window")
        Theme.renderedPageWidth = saved
        window.setContentSize(NSSize(width: 400, height: 500))
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 500)
        hosting.layoutSubtreeIfNeeded()
        #expect(textView.textContainer?.size.width == textView.bounds.width - RenderedTextView.minimumMargin * 2, "a view narrower than the page narrows it")
    }

    /// A table wider than the column scrolls sideways within it: what shows is what can be clicked and noted.
    @Test func aWideTableScrollsSidewaysWithinTheColumn() async throws {
        let word = "Supercalifragilistic"
        let cells = (1...8).map { "\(word)\($0)" }
        let markdown = "Intro.\n\n| \((1...8).map { "h\($0)" }.joined(separator: " | ")) |\n|\(String(repeating: " - |", count: 8))\n| \(cells.joined(separator: " | ")) |\n\nAfter.\n"
        let controller = MarkdownViewerController(source: TextEditorController(text: markdown, languageName: "markdown"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 500), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: MarkdownViewerView(controller: controller))
        hosting.frame = NSRect(x: 0, y: 0, width: 1300, height: 500)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for subview in view.subviews { if let found = find(type, in: subview) { return found } }
            return nil
        }
        let textView = try #require(find(RenderedTextView.self, in: hosting))
        let text = textView.string as NSString
        let laid = try #require(controller.laidOutColumn)
        let columnRight = textView.textContainerOrigin.x + laid.inset + laid.width
        func frame(of needle: String) throws -> CGRect { try #require(textView.frame(ofCharacterAt: text.range(of: needle).location)) }
        let last = try frame(of: cells[7])
        #expect(last.minX > columnRight, "the last cell starts past the column")
        let layoutManager = try #require(textView.textLayoutManager as? MarkdownTextLayoutManager)
        let origin = textView.textContainerOrigin
        #expect(layoutManager.shown(last.offsetBy(dx: -origin.x, dy: -origin.y)) == nil, "and nothing of it shows, so no selection or note highlight is drawn there")
        let table = try #require(textView.wideTable(at: NSPoint(x: try frame(of: cells[0]).midX, y: last.midY)))

        textView.scrollTable(table, to: 10_000)
        window.displayIfNeeded()
        let scrolled = try frame(of: cells[7])
        #expect(scrolled.maxX <= columnRight + 1 && scrolled.maxX > columnRight - 200, "scrolled to its end, the last cell shows: \(scrolled)")
        #expect(textView.tableOffsets[table] == controller.rendered.attribute(MarkdownRenderer.blockKey, at: text.range(of: cells[0]).location, effectiveRange: nil)
            .flatMap { ($0 as? MarkdownBlockDecoration)?.table?.overflow }, "no further than it runs past the column")
        let clicked = textView.characterIndexForInsertion(at: NSPoint(x: scrolled.minX + 2, y: scrolled.midY))
        #expect(NSLocationInRange(clicked, text.range(of: cells[7])) || clicked == text.range(of: cells[7]).location, "a click lands on the cell that shows there")

        // Finding the first cell again scrolls back to it.
        textView.scrollRangeToVisible(text.range(of: cells[0]))
        #expect(textView.tableOffsets[table] == 0)

        // Rendering again (as an edit does) keeps the table where it was scrolled.
        textView.scrollTable(table, to: 50)
        controller.rebuildNow()
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        #expect(textView.tableOffsets[table] == 50)
    }
}
