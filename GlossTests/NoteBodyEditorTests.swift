import AppKit
import Core
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
        // Its card is selected: selecting keeps the keyboard there; another card selected takes it to the list.
        let owner = NoteID.new()
        field.owner = owner
        #expect(NotesPanel.keepsKeyboard(field, selected: owner))
        #expect(!NotesPanel.keepsKeyboard(field, selected: NoteID.new()))
        #expect(!NotesPanel.keepsKeyboard(field, selected: nil))
        // A click is found in the field it landed on, and nowhere else.
        let inside = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
        let click = NSEvent.mouseEvent(with: .leftMouseUp, location: inside, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 0)
        #expect(NotesPanel.cardField(under: click) === field)
        let outside = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 2, y: 2), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                         context: nil, eventNumber: 0, clickCount: 1, pressure: 0)
        #expect(NotesPanel.cardField(under: outside) == nil)
        window.close()
    }

    private static func find(in view: NSView) -> NoteBodyEditor.SubmitTextView? {
        if let field = view as? NoteBodyEditor.SubmitTextView { return field }
        for subview in view.subviews { if let found = find(in: subview) { return found } }
        return nil
    }
}

/// The notes list draws no selection fill of its own (a selected card outlines itself), and still selects.
@MainActor
struct NotesListSelectionTests {
    @Observable final class Box { var selection: Set<Int> = [] }

    struct Rows: View {
        let box: Box
        var body: some View {
            @Bindable var box = box
            List(selection: $box.selection) {
                ForEach(0..<3, id: \.self) { row in
                    Text("Row \(row)").background(NoSystemSelectionHighlight()).tag(row)
                }
            }
            .listStyle(.inset)
        }
    }

    @Test func theListDrawsNoSelectionFillAndStillSelects() async throws {
        let box = Box()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: Rows(box: box))
        host.frame = window.contentView!.bounds
        window.contentView!.addSubview(host)
        var table: NSTableView?
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            table = Self.find(in: host)
            if let table, table.selectionHighlightStyle == .none { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let list = try #require(table)
        #expect(list.selectionHighlightStyle == .none)
        list.selectRowIndexes([1], byExtendingSelection: false)
        for _ in 0..<50 where box.selection != [1] { try await Task.sleep(for: .milliseconds(20)) }
        #expect(box.selection == [1], "the table's selection still reaches the binding")
        // Selected in a focused list, a row's text keeps its own colours: no white-on-accent style is asked for.
        let row = try #require(list.rowView(atRow: 1, makeIfNecessary: true))
        row.isEmphasized = true
        #expect(row.isSelected && row.interiorBackgroundStyle == .normal, "\(row.interiorBackgroundStyle.rawValue)")
        box.selection = [0, 2]
        for _ in 0..<50 where list.selectedRowIndexes != [0, 2] {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(list.selectedRowIndexes == [0, 2], "and the binding still selects rows")
        #expect(list.selectionHighlightStyle == .none, "an update doesn't bring the fill back")
    }

    private static func find(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews { if let found = find(in: subview) { return found } }
        return nil
    }
}
