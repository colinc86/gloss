import AppKit
import Core
import SwiftUI
import Testing
@testable import Viewers

struct TextEditorRenderTests {
    func render(languageName: String?) throws -> (distinctColors: Int, textView: SourceTextView) {
        let source = "import Foundation\n\nfunc greet() -> String {\n    return \"hi\" // note\n}\n"
        let controller = TextEditorController(text: source, languageName: languageName)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let hosting = NSHostingView(rootView: TextEditorView(controller: controller))
        hosting.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        window.contentView = hosting
        window.layoutIfNeeded()
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for subview in view.subviews { if let found = find(type, in: subview) { return found } }
            return nil
        }
        let textView = try #require(find(SourceTextView.self, in: hosting))
        let rep = try #require(textView.bitmapImageRepForCachingDisplay(in: textView.bounds))
        textView.cacheDisplay(in: textView.bounds, to: rep)
        var colors: Set<String> = []
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: min(rep.pixelsWide, 300), by: 2) {
                if let color = rep.colorAt(x: x, y: y) { colors.insert(String(format: "%.1f,%.1f,%.1f", color.redComponent, color.greenComponent, color.blueComponent)) }
            }
        }
        return (colors.count, textView)
    }

    @Test func plainTextDrawsSomething() throws {
        let (distinct, _) = try render(languageName: nil)
        #expect(distinct > 3, "text should produce more than a flat background")
    }

    @Test func highlightedTextDrawsSomething() throws {
        let (distinct, _) = try render(languageName: "swift")
        #expect(distinct > 3, "highlighted text should produce more than a flat background")
    }

    /// Typing must not strip syntax colours from the other lines (seen in the app after `/*` and after a Backspace).
    @Test @MainActor func typingKeepsSyntaxColours() throws {
        let source = (1...40).map { "func f\($0)() -> Int { let value = \($0); return value } // note \($0)" }.joined(separator: "\n") + "\n"
        let controller = TextEditorController(text: source, languageName: "swift")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: TextEditorView(controller: controller))
        hosting.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        window.contentView = hosting
        window.layoutIfNeeded()
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for subview in view.subviews { if let found = find(type, in: subview) { return found } }
            return nil
        }
        let textView = try #require(find(SourceTextView.self, in: hosting))
        func colouredPixels() throws -> Int {
            textView.layoutSubtreeIfNeeded()
            let rep = try #require(textView.bitmapImageRepForCachingDisplay(in: textView.visibleRect))
            textView.cacheDisplay(in: textView.visibleRect, to: rep)
            var count = 0
            for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
                for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if max(c.redComponent, c.greenComponent, c.blueComponent) - min(c.redComponent, c.greenComponent, c.blueComponent) > 0.25 { count += 1 }
                }
            }
            return count
        }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
        settle()
        let before = try colouredPixels()
        #expect(before > 200, "keywords and numbers are coloured: \(before)")
        let line5End = controller.lineIndex.contentRange(ofLine: 5)
        textView.setSelectedRange(NSRange(location: line5End.location + line5End.length, length: 0))
        textView.insertText("/", replacementRange: textView.selectedRange())
        textView.insertText("*", replacementRange: textView.selectedRange())
        settle()
        let afterComment = try colouredPixels()
        #expect(afterComment > before / 3, "lines above the edit keep their colours: \(afterComment) of \(before)")
        textView.deleteBackward(nil)
        textView.deleteBackward(nil)
        settle()
        let restored = try colouredPixels()
        #expect(restored > before * 8 / 10, "after undoing the edit by hand every line is coloured again: \(restored) of \(before)")

        // Lines coloured before the edits and off screen during them are re-coloured as they scroll in.
        textView.scrollToEndOfDocument(nil)
        settle()
        let end = try colouredPixels()
        textView.scrollToBeginningOfDocument(nil)
        settle()
        let top = try colouredPixels()
        #expect(end > before / 2 && top > before * 8 / 10, "scrolled lines are coloured: end \(end), top \(top), before \(before)")
    }

    /// A jump requested while the document is still opening (the view not yet in a window) is applied once the
    /// view is attached: the line is on screen and the editor has the keyboard.
    @Test @MainActor func aJumpBeforeTheViewIsInAWindowStillLandsAndFocuses() throws {
        let source = (1...200).map { "let value\($0) = \($0)" }.joined(separator: "\n") + "\n"
        let controller = TextEditorController(text: source, languageName: "swift")
        let target = controller.lineIndex.contentRange(ofLine: 150)
        controller.scroll(to: target)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: TextEditorView(controller: controller))
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        window.contentView = hosting
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for subview in view.subviews { if let found = find(type, in: subview) { return found } }
            return nil
        }
        let textView = try #require(find(SourceTextView.self, in: hosting))
        #expect(window.firstResponder === textView, "the editor takes the keyboard")
        #expect(textView.selectedRange() == target)
        let lineTop = controller.lineIndex.position(forUTF16Offset: textView.characterIndexForInsertion(at: NSPoint(x: 10, y: textView.visibleRect.minY + 5))).line
        #expect(lineTop > 100 && lineTop <= 150, "line 150 is on screen, top line \(lineTop)")
    }

    /// A jump to an off-screen line puts that line in the middle of the view, within a couple of lines, for
    /// lines far from anything laid out yet (where TextKit only has estimated heights).
    @Test @MainActor func jumpsCentreTheTargetLine() throws {
        let source = (1...3000).map { $0 % 7 == 0 ? "// a longer comment line \($0) that wraps \(String(repeating: "x", count: 150))" : "let value\($0) = \($0)" }.joined(separator: "\n") + "\n"
        let controller = TextEditorController(text: source, languageName: "swift")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: TextEditorView(controller: controller))
        hosting.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        window.contentView = hosting
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for subview in view.subviews { if let found = find(type, in: subview) { return found } }
            return nil
        }
        let textView = try #require(find(SourceTextView.self, in: hosting))
        var misses: [String] = []
        for line in [1500, 2900, 40, 2200] {
            controller.scroll(to: controller.lineIndex.contentRange(ofLine: line))
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let visible = textView.visibleRect
            let middle = controller.lineIndex.position(forUTF16Offset: textView.characterIndexForInsertion(at: NSPoint(x: 10, y: visible.midY))).line
            let top = controller.lineIndex.position(forUTF16Offset: textView.characterIndexForInsertion(at: NSPoint(x: 10, y: visible.minY + 2))).line
            let bottom = controller.lineIndex.position(forUTF16Offset: textView.characterIndexForInsertion(at: NSPoint(x: 10, y: visible.maxY - 2))).line
            #expect(top <= line && line <= bottom, "line \(line) is on screen (\(top)...\(bottom))")
            if line > 60, abs(middle - line) > 2 { misses.append("\(line)→\(middle)") }
        }
        #expect(misses.isEmpty, "off-centre jumps: \(misses)")
    }

    /// An added row is tinted across the whole width, past the text; an untouched row is not.
    @Test func changedLinesTintTheWholeRow() throws {
        let controller = TextEditorController(text: "one\ntwo\nthree\nfour\n", languageName: nil)
        controller.isEditable = false
        controller.lineChanges = LineChanges(added: [2...2], deletions: [4])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        let hosting = NSHostingView(rootView: TextEditorView(controller: controller))
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        window.contentView = hosting
        window.layoutIfNeeded()
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for subview in view.subviews { if let found = find(type, in: subview) { return found } }
            return nil
        }
        let textView = try #require(find(SourceTextView.self, in: hosting))
        let rep = try #require(textView.bitmapImageRepForCachingDisplay(in: textView.bounds))
        textView.cacheDisplay(in: textView.bounds, to: rep)
        // Scan a column far to the right of the text: tinted rows are greener than the page, plain rows are the page.
        let column = rep.pixelsWide - 20
        var tinted = 0, plain = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            guard let color = rep.colorAt(x: column, y: y)?.usingColorSpace(.sRGB) else { continue }
            if color.greenComponent > color.redComponent + 0.01 { tinted += 1 } else { plain += 1 }
        }
        #expect(tinted > 0, "the added row carries the green tint far from the text")
        #expect(plain > tinted, "only the added row is tinted")
    }

    /// Add Note heads the context menu while text is selected, beside the floating button and ⌘↩.
    @Test func theContextMenuOffersAddNoteOnASelection() throws {
        let controller = TextEditorController(text: "one\ntwo\nthree\n", languageName: nil)
        var added = 0
        controller.onAddNote = { added += 1 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: TextEditorView(controller: controller))
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        window.contentView = hosting
        window.layoutIfNeeded()
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for subview in view.subviews { if let found = find(type, in: subview) { return found } }
            return nil
        }
        let textView = try #require(find(SourceTextView.self, in: hosting))
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: 20, y: 180), modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        textView.setSelectedRange(NSRange(location: 4, length: 3))
        let menu = try #require(textView.menu(for: event))
        #expect(menu.items.first?.title == "Add Note")
        textView.addNoteFromMenu(nil)
        #expect(added == 1)
        // A right-click with nothing selected selects the word under the pointer, as text views do: Add Note is on it.
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        let onWord = textView.menu(for: event)
        #expect(textView.selectedRange() == NSRange(location: 0, length: 3) && onWord?.items.first?.title == "Add Note")
        // The same menu comes back each time: with nothing selected the item put there before comes out.
        let menu2 = NSMenu()
        AddNoteMenuItem.insert(into: menu2, selection: NSRange(location: 0, length: 3), target: textView, action: #selector(SourceTextView.addNoteFromMenu(_:)))
        menu2.addItem(withTitle: "Copy", action: nil, keyEquivalent: "")
        AddNoteMenuItem.insert(into: menu2, selection: NSRange(location: 0, length: 0), target: textView, action: #selector(SourceTextView.addNoteFromMenu(_:)))
        #expect(menu2.items.map(\.title) == ["Copy"])
        textView.onAddNote = nil
        textView.setSelectedRange(NSRange(location: 4, length: 3))
        #expect(textView.menu(for: event)?.items.contains { $0.title == "Add Note" } == false, "where notes can't be added, it isn't offered")
    }
}
