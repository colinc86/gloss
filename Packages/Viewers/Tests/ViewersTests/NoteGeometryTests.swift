import AppKit
import Core
import SwiftUI
import Testing
@testable import Viewers

/// The link and paths read where notes are on screen: only notes in view, one rect per line, inside the viewport.
struct NoteGeometryTests {
    @Test func reportsOnlyVisibleNotesLineByLineAndFollowsScrolling() throws {
        let lines = (1...200).map { "line \($0) with some words on it" }
        let text = lines.joined(separator: "\n")
        let controller = TextEditorController(text: text)
        func range(line: Int, through last: Int? = nil) -> NSRange {
            let start = lines[..<(line - 1)].reduce(0) { $0 + $1.utf16.count + 1 }
            let end = lines[..<(last ?? line)].reduce(0) { $0 + $1.utf16.count + 1 } - 1
            return NSRange(location: start, length: end - start)
        }
        let single = NoteID.new(), multi = NoteID.new(), far = NoteID.new()
        controller.highlights = [
            TextHighlight(id: single, range: range(line: 2), color: .yellow, state: .draft),
            TextHighlight(id: multi, range: range(line: 4, through: 6), color: .blue, state: .draft),
            TextHighlight(id: far, range: range(line: 195), color: .pink, state: .draft),
        ]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: TextEditorView(controller: controller))
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let geometry = controller.noteGeometry
        let viewport = try #require(geometry.viewport())
        var rects = geometry.visibleNoteRects()
        #expect(rects[single]?.count == 1)
        #expect(rects[multi]?.count == 3)
        #expect(rects[far] == nil)
        for rect in rects.values.flatMap({ $0 }) {
            #expect(viewport.insetBy(dx: -0.5, dy: -0.5).contains(rect))
        }
        // Lines stack downwards in the top-left space SwiftUI draws in.
        let multiRects = try #require(rects[multi])
        #expect(multiRects.map(\.minY) == multiRects.map(\.minY).sorted())
        #expect(try #require(rects[single]?.first).minY < multiRects[0].minY)

        var changes = 0
        geometry.onChange = { changes += 1 }
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for subview in view.subviews { if let found = find(type, in: subview) { return found } }
            return nil
        }
        let textView = try #require(find(SourceTextView.self, in: hosting))
        textView.scrollRangeToVisible(range(line: 195))
        window.displayIfNeeded()
        #expect(changes > 0)
        rects = geometry.visibleNoteRects()
        #expect(rects[far]?.count == 1)
        #expect(rects[single] == nil)
    }

    /// A note whose text was removed is a caret where it was: one rect, 2 pt wide and a line tall, so its path
    /// reaches it; the backdrop draws the same rect.
    @Test func aRemovalPointIsItsCaret() throws {
        #expect(NoteGeometry.caretBar(at: CGRect(x: 10, y: 20, width: 0, height: 15)) == CGRect(x: 9, y: 20, width: 2, height: 15))
        let text = "first line\nsecond line\nthird line"
        let controller = TextEditorController(text: text)
        let point = NoteID.new(), span = NoteID.new()
        controller.highlights = [
            TextHighlight(id: point, range: NSRange(location: 17, length: 0), color: .orange, state: .sent),
            TextHighlight(id: span, range: NSRange(location: 11, length: 6), color: .blue, state: .draft),
        ]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: TextEditorView(controller: controller))
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        window.displayIfNeeded()

        let rects = controller.noteGeometry.visibleNoteRects()
        let caret = try #require(rects[point]?.first)
        #expect(rects[point]?.count == 1)
        #expect(caret.width == NoteGeometry.caretWidth)
        #expect(caret.height > 8, "as tall as its line")
        // "second" spans 11..<17: the caret sits at its end, on the same line.
        let word = try #require(rects[span]?.first)
        #expect(abs(caret.midX - word.maxX) < 1.5)
        #expect(abs(caret.midY - word.midY) < 2)
        #expect(controller.rect(for: NSRange(location: 17, length: 0)).map { abs($0.midX - caret.midX) < 0.5 } == true, "the peek points at the caret")
    }
}
