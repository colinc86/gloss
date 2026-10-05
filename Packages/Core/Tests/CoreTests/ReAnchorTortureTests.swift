import Foundation
import Testing
@testable import Core

/// Issue #6: many notes on one document, then the kind of rewrite an agent makes. Every note whose text survives
/// lands on that text; the ones whose text is gone are orphaned; none lands somewhere plausible but wrong.
struct ReAnchorTortureTests {
    /// A plan with repeated structure: every section has the same checklist lines, as real plans do.
    static func plan(sections: Int) -> String {
        (1...sections).map { n in
            """
            ## Step \(n): part \(n) of the rollout
            Owner for step \(n) is team \(n % 4).
            The rollout of part \(n) waits for the metrics review.
            - [ ] TODO
            - [ ] write the tests for part \(n)

            """
        }.joined(separator: "\n")
    }

    /// Anchors on `needle`'s `occurrence`-th appearance (0-based) in `text`.
    static func anchor(_ needle: String, occurrence: Int = 0, in text: String) -> TextAnchor {
        let ns = text as NSString
        var range = NSRange(location: 0, length: 0)
        var from = 0
        for _ in 0...occurrence {
            range = ns.range(of: needle, options: [.literal], range: NSRange(location: from, length: ns.length - from))
            from = range.location + range.length
        }
        precondition(range.location != NSNotFound, "\(needle) #\(occurrence) not found")
        return ReAnchorer.make(from: range, in: text, index: LineIndex(text), hash: "old")
    }

    static func place(_ result: ReAnchorResult) -> TextAnchor? {
        switch result {
        case .moved(.text(let anchor)), .movedNeedsReview(.text(let anchor)): anchor
        default: nil
        }
    }

    /// The text the anchor covers in `content`.
    static func covered(_ anchor: TextAnchor, in content: String) -> String {
        (content as NSString).substring(with: LineIndex(content).range(for: anchor))
    }

    @Test func twentyFiveNotesSurviveAnAgentRewrite() {
        let original = Self.plan(sections: 6)
        // Notes on distinctive phrases, on whole lines, and on the repeated checklist lines of several sections.
        var anchors: [(label: String, anchor: TextAnchor, expected: String?)] = []
        for n in 1...6 {
            anchors.append(("owner \(n)", Self.anchor("team \(n % 4)", occurrence: n <= 4 ? 0 : 1, in: original), nil))
            anchors.append(("rollout \(n)", Self.anchor("The rollout of part \(n) waits for the metrics review.", in: original), "The rollout of part \(n) waits for the metrics review."))
            anchors.append(("tests \(n)", Self.anchor("write the tests for part \(n)", in: original), "write the tests for part \(n)"))
            anchors.append(("todo \(n)", Self.anchor("- [ ] TODO", occurrence: n - 1, in: original), "- [ ] TODO"))
        }
        anchors.append(("heading 3", Self.anchor("## Step 3: part 3 of the rollout", in: original), "## Step 3: part 3 of the rollout"))
        #expect(anchors.count == 25)

        // The agent adds a long preamble, deletes step 2, rewrites step 4's rollout sentence and moves step 6
        // above step 5.
        var sections = original.components(separatedBy: "\n## ").enumerated().map { $0.offset == 0 ? $0.element : "## " + $0.element }
        sections[3] = sections[3].replacingOccurrences(of: "The rollout of part 4 waits for the metrics review.", with: "Part 4 ships behind a flag; no metrics review.")
        sections.swapAt(4, 5)
        sections.remove(at: 1)
        let preamble = (1...50).map { "Context line \($0) the agent added." }.joined(separator: "\n") + "\n\n"
        let edited = preamble + sections.joined(separator: "\n")

        for (label, anchor, expected) in anchors {
            let result = ReAnchorer.text(anchor, in: edited, newHash: "new")
            let partTwo = label.hasSuffix(" 2") && !label.hasPrefix("owner")
            if partTwo || label == "rollout 4" {
                // Its text is gone (step 2 deleted; step 4's sentence rewritten): orphaned, or at most a flagged guess.
                if case .moved = result { Issue.record("\(label) silently moved: \(result)") }
                continue
            }
            guard let moved = Self.place(result) else { Issue.record("\(label) lost: \(result)"); continue }
            if let expected { #expect(Self.covered(moved, in: edited) == expected, "\(label)") }
            // Every surviving note must sit in its own section, not a neighbour's look-alike line.
            let sectionNumber = label.split(separator: " ").last.map(String.init) ?? ""
            let headingLine = (edited as NSString).range(of: "## Step \(sectionNumber):")
            if !label.hasPrefix("owner"), !label.hasPrefix("heading"), headingLine.location != NSNotFound {
                let headingRow = LineIndex(edited).position(forUTF16Offset: headingLine.location).line
                #expect(moved.start.line > headingRow && moved.start.line <= headingRow + 5, "\(label) at line \(moved.start.line), section heading at \(headingRow)")
            }
        }
    }

    /// Identical checklist lines in different sections each keep their own note after lines are inserted above.
    @Test func duplicateLinesKeepTheirOwnNotes() {
        let original = Self.plan(sections: 4)
        let notes = (0..<4).map { Self.anchor("- [ ] TODO", occurrence: $0, in: original) }
        let edited = (1...50).map { "inserted \($0)" }.joined(separator: "\n") + "\n" + original
        for (number, note) in notes.enumerated() {
            guard let moved = Self.place(ReAnchorer.text(note, in: edited, newHash: "new")) else { Issue.record("todo \(number) lost"); continue }
            #expect(moved.start.line == note.start.line + 50, "todo \(number + 1)")
        }
    }

    /// When an agent duplicates a section, the original keeps the note and the copy is not mistaken for it.
    @Test func aDuplicatedSectionDoesNotStealTheNote() {
        let original = Self.plan(sections: 3)
        let note = Self.anchor("write the tests for part 2", in: original)
        let sections = original.components(separatedBy: "\n## ")
        let copy = "## " + sections[1].replacingOccurrences(of: "Owner for step 2 is team 2.", with: "Owner for step 2b is unknown.")
        let edited = copy + "\n" + original
        guard let moved = Self.place(ReAnchorer.text(note, in: edited, newHash: "new")) else { Issue.record("lost"); return }
        let copyLines = copy.components(separatedBy: "\n").count
        #expect(moved.start.line == note.start.line + copyLines, "the original, below the copy")
    }

    /// A short text with several equally good places moves, but asks for a glance instead of guessing silently.
    @Test func anAmbiguousShortAnchorIsFlagged() {
        let original = "intro\nTODO\nmiddle\nTODO\nend\n"
        let note = ReAnchorer.make(from: (original as NSString).range(of: "TODO"), in: original, index: LineIndex(original), hash: "old")
        // Its neighbours change everywhere, and a third TODO arrives.
        let edited = "preface\nTODO\nnew middle\nTODO\nmore\nTODO\nfin\n"
        let result = ReAnchorer.text(note, in: edited, newHash: "new")
        guard case .movedNeedsReview = result else { Issue.record("expected a flagged move, got \(result)"); return }
    }

    /// A phrase inside a line whose line changed around it stays the phrase, not the whole line.
    @Test func aPhraseKeepsItsColumnsThroughAFuzzyMatch() {
        let original = "# Notes\nfirst context line\nWe should cache the forecast results for ten minutes at most.\nlast context line\n"
        let phrase = "cache the forecast results for ten minutes"
        let note = ReAnchorer.make(from: (original as NSString).range(of: phrase), in: original, index: LineIndex(original), hash: "old")
        // The agent rewords the phrase's middle; its start and end words survive, as do the context lines.
        let edited = "# Notes\nfirst context line\nWe should probably cache the forecast results (all of them) for ten minutes at most.\nlast context line\n"
        guard let moved = Self.place(ReAnchorer.text(note, in: edited, newHash: "new")) else { Issue.record("lost"); return }
        let covered = Self.covered(moved, in: edited)
        #expect(covered.hasPrefix("cache the") && covered.hasSuffix("ten minutes"), "\(covered)")
        #expect(moved.start.col > 1, "still a phrase, not the whole line")
    }
}
