import Core
import Testing
@testable import Viewers

/// Issue #12: open work leads, everything else steps back the same way on every surface, and a note in focus can
/// always be found.
struct NoteStateLadderTests {
    @Test func draftsFillAndSentNotesStepBackToUnderlines() {
        #expect(Theme.mark(for: .draft, focused: false) == .fill)
        #expect(Theme.mark(for: .sent, focused: false) == .underline)
        #expect(Theme.mark(for: .resolved, focused: false) == .dottedUnderline)
        #expect(Theme.mark(for: .orphaned, focused: false) == .dashedUnderline)
        #expect(Theme.mark(for: .sent, focused: true) == .fill, "in focus, any note fills")
        #expect(Theme.mark(for: .resolved, focused: true) == .fill)
        #expect(Theme.mark(for: .orphaned, focused: true) == .dashedUnderline, "an orphan's text isn't there to fill")
    }

    @Test func oneLadderEverywhere() {
        let ladder = [NoteState.draft, .sent, .resolved].map(Theme.strength(for:))
        #expect(ladder == ladder.sorted(by: >) && ladder.first == 1, "each step quieter")
    }
}
