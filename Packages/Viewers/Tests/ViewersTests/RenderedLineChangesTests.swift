import AppKit
import Core
import SwiftUI
import Testing
@testable import Viewers

/// Show Changes Since on a Markdown file read rendered: the paragraphs showing changed source lines are tinted.
@MainActor
struct RenderedLineChangesTests {
    static let markdown = "# Title\n\nFirst paragraph.\n\nSecond paragraph,\nits second source line.\n\nThird paragraph.\n"

    @Test func aRenderedSpanKnowsItsSourceLines() throws {
        let controller = MarkdownViewerController(source: TextEditorController(text: Self.markdown, languageName: "markdown"))
        let rendered = controller.rendered.string as NSString
        let second = rendered.range(of: "Second paragraph")
        #expect(controller.sourceLines(forRendered: NSRange(location: second.location, length: 30)) == 5...6, "a paragraph over two source lines")
        #expect(controller.sourceLines(forRendered: rendered.range(of: "Third")) == 8...8)
        #expect(controller.sourceLines(forRendered: rendered.range(of: "Title")) == 1...1)
    }

    @Test func aChangedParagraphIsTintedAndTheOthersAreNot() async throws {
        let source = TextEditorController(text: Self.markdown, languageName: "markdown")
        source.lineChanges = LineChanges(added: [6...6])
        let controller = MarkdownViewerController(source: source)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        let hosting = NSHostingView(rootView: MarkdownViewerView(controller: controller))
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
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
        let rep = try #require(textView.bitmapImageRepForCachingDisplay(in: textView.bounds))
        textView.cacheDisplay(in: textView.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / textView.bounds.width
        func tinted(_ text: String) throws -> Bool {
            let range = (controller.rendered.string as NSString).range(of: text)
            let screen = textView.firstRect(forCharacterRange: range, actualRange: nil)
            let rect = textView.convert(try #require(textView.window).convertFromScreen(screen), from: nil)
            // A column right of the text, on the paragraph's first line: the tint spans the whole width.
            let x = Int((textView.bounds.width - 12) * scale), y = Int(rect.midY * scale)
            let color = try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            return color.greenComponent > color.redComponent + 0.01
        }
        #expect(try tinted("Second paragraph"), "line 6 changed, and the paragraph shows lines 5 and 6")
        #expect(try !tinted("First paragraph"))
        #expect(try !tinted("Third paragraph"))

        // The minimap marks the change in its left lane, as the editor's does.
        let minimap = try #require(find(RenderedMinimapView.self, in: hosting))
        func laneMarks() throws -> Int {
            let map = try #require(minimap.bitmapImageRepForCachingDisplay(in: minimap.bounds))
            minimap.cacheDisplay(in: minimap.bounds, to: map)
            let x = Int(2.5 * CGFloat(map.pixelsWide) / minimap.bounds.width)
            return (0..<map.pixelsHigh).filter { y in
                guard let color = map.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                return color.greenComponent > color.redComponent + 0.15
            }.count
        }
        // The first draw asks for the page, built on the next turn: a suspension, which a run loop nested in this
        // main-actor test is not (it never runs the minimap's task).
        minimap.display()
        try await Task.sleep(for: .milliseconds(200))
        #expect(try laneMarks() > 0)
        source.lineChanges = nil
        #expect(try laneMarks() == 0)
    }
}
