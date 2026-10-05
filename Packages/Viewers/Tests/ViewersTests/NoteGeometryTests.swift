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
}
