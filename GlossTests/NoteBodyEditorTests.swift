import AppKit
import SwiftUI
import Testing
@testable import Gloss

/// The follow-up field is the composer's own editor inside a notes-list row. Hosted in a window, it takes the
/// keyboard, keeps typing in its binding, and the panel leaves the keyboard with it.
@MainActor
struct NoteBodyEditorTests {
    @Observable final class Box { var text = "" }

    @Test func aFieldInAListRowTakesTheKeyboardAndKeepsWhatIsTyped() async throws {
        let box = Box()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: List {
            NoteBodyEditor(text: Binding(get: { box.text }, set: { box.text = $0 }), onSubmit: {}, focusesOnAppear: false)
                .frame(minHeight: 28, maxHeight: 120)
        })
        window.isReleasedWhenClosed = false
        host.frame = window.contentView!.bounds
        window.contentView!.addSubview(host)
        var textView: NoteBodyEditor.SubmitTextView?
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            textView = Self.find(in: host)
            if let textView, textView.frame.width > 40 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let field = try #require(textView)
        #expect(field.frame.width > 40, "the text view spans its row, not a zero-width strip")
        #expect(window.firstResponder !== field, "a field that waits to be asked doesn't take the keyboard on appear")
        #expect(window.makeFirstResponder(field))
        #expect(NotesPanel.isTypingInCard(window.firstResponder), "the list leaves the keyboard with a card's field")
        field.insertText("Only severe ones", replacementRange: field.selectedRange())
        #expect(box.text == "Only severe ones")
        #expect(!NotesPanel.isTypingInCard(host))
        window.close()
    }

    private static func find(in view: NSView) -> NoteBodyEditor.SubmitTextView? {
        if let field = view as? NoteBodyEditor.SubmitTextView { return field }
        for subview in view.subviews { if let found = find(in: subview) { return found } }
        return nil
    }
}
