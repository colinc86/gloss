import Core
import Testing
@testable import Viewers

/// How note bars share the gutter.
struct GutterLaneTests {
    @Test func overlappingNotesSitSideBySideAndFreedLanesAreReused() {
        let a = NoteID.new(), b = NoteID.new(), c = NoteID.new(), d = NoteID.new()
        let lanes = LineNumberGutterView.lanes(for: [
            (a, 14, 19),   // the whole enum
            (b, 15, 15),   // a line inside it
            (c, 4, 4),     // earlier, alone
            (d, 21, 21),   // after the enum ends
        ])
        #expect(lanes[c] == 0 && lanes[a] == 0, "non-overlapping notes share the first lane")
        #expect(lanes[b] == 1, "a note inside another moves over a lane")
        #expect(lanes[d] == 0, "a lane frees up once its note ends")
    }

    @Test func moreThanThreeOverlapsShareTheLastLane() {
        let ids = (0..<5).map { _ in NoteID.new() }
        let lanes = LineNumberGutterView.lanes(for: ids.map { ($0, 1, 10) })
        #expect(Set(ids.map { lanes[$0]! }) == [0, 1, 2])
    }
}
