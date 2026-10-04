import Core
import Foundation
import Testing
@testable import Viewers

/// When hovering a highlight shows its note, and when the peek goes away.
struct NotePeekTests {
    private func controller() -> (TextEditorController, NoteID, NoteID) {
        let editor = TextEditorController(text: "alpha beta gamma delta\n")
        let first = NoteID.new(), second = NoteID.new()
        editor.highlights = [
            TextHighlight(id: first, range: NSRange(location: 0, length: 5), color: .yellow, state: .draft),
            TextHighlight(id: second, range: NSRange(location: 6, length: 4), color: .blue, state: .sent),
        ]
        return (editor, first, second)
    }

    /// Polls instead of sleeping a fixed time: the suite runs in parallel, so timers can run late.
    private func eventually(_ condition: @autoclosure () -> Bool, within seconds: Double = 20) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test func aRestOnAHighlightShowsItsNoteAndLeavingHidesIt() async throws {
        let (editor, first, second) = controller()
        editor.hover(at: 2)
        #expect(editor.peek == nil, "not straight away: skimming must not flash cards")
        #expect(await eventually(editor.peek?.id == first))
        editor.hover(at: 7)
        #expect(await eventually(editor.peek?.id == second, within: 20), "moving from one note to the next switches without the rest delay")
        editor.hover(at: nil)
        editor.isPeekHovered = true
        try await Task.sleep(for: .milliseconds(400))
        #expect(editor.peek?.id == second, "the pointer on the card keeps it")
        editor.isPeekHovered = false
        #expect(await eventually(editor.peek == nil))
        editor.hover(at: 15)
        try await Task.sleep(for: .milliseconds(600))
        #expect(editor.peek == nil, "plain text shows nothing")
    }
}
