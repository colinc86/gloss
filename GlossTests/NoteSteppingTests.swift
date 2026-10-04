import Core
import Testing
@testable import Gloss

/// Next and Previous Note (⌘', ⇧⌘'): reading order, from the caret or the note last reached, wrapping at the ends.
struct NoteSteppingTests {
    private let a = NoteID.new(), b = NoteID.new(), c = NoteID.new()
    private var ordered: [(id: NoteID, key: Double)] { [(a, 10), (b, 200), (c, 3000)] }

    @Test func fromTheCaretTheNextNoteIsTheFirstPastIt() {
        #expect(DocumentSession.step(from: 0, current: nil, in: ordered, forward: true) == a)
        #expect(DocumentSession.step(from: 150, current: nil, in: ordered, forward: true) == b)
        #expect(DocumentSession.step(from: 150, current: nil, in: ordered, forward: false) == a)
        #expect(DocumentSession.step(from: 200, current: nil, in: ordered, forward: false) == a, "a caret on a note's start goes before it")
    }

    @Test func fromTheNoteLastReachedItGoesOnAndWraps() {
        #expect(DocumentSession.step(from: nil, current: b, in: ordered, forward: true) == c)
        #expect(DocumentSession.step(from: nil, current: c, in: ordered, forward: true) == a)
        #expect(DocumentSession.step(from: nil, current: a, in: ordered, forward: false) == c)
        #expect(DocumentSession.step(from: 5000, current: nil, in: ordered, forward: true) == a, "past the last note, next wraps to the first")
    }

    @Test func withoutACaretItStartsAtAnEnd() {
        #expect(DocumentSession.step(from: nil, current: nil, in: ordered, forward: true) == a)
        #expect(DocumentSession.step(from: nil, current: nil, in: ordered, forward: false) == c)
        #expect(DocumentSession.step(from: 0, current: nil as NoteID?, in: [] as [(id: NoteID, key: Double)], forward: true) == nil)
    }
}
