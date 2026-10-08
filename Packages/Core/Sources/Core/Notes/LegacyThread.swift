import Foundation

/// A note body written before threads had their own table (before `v11-note-threads`): the comment, then each
/// exchange an answered question added as "Agent asked:" and "Answer:" lines. Split by exactly the rules the card
/// read it with, so a migrated thread shows the turns it showed before.
struct LegacyThread: Equatable {
    struct Turn: Equatable {
        let isAgent: Bool
        let text: String
    }

    static let askedLabel = "Agent asked:"
    static let answerLabel = "Answer:"

    /// What the user wrote before any exchange, trimmed.
    let comment: String
    /// Every turn, oldest first.
    let turns: [Turn]

    init(body: String) {
        var comment: [Substring] = []
        var turns: [(isAgent: Bool, lines: [Substring])] = []
        var previousBlank = false
        // Turns start only where the old `NoteStore.body(_:answering:with:)` wrote them: an exchange after a blank
        // line, and an answer right under the question. A line of the comment that happens to begin "Answer:" stays text.
        for line in body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let opensExchange = previousBlank
            let answersQuestion = turns.last?.isAgent == true
            previousBlank = line.allSatisfy(\.isWhitespace)
            if opensExchange, line.hasPrefix(Self.askedLabel) {
                turns.append((true, [line.dropFirst(Self.askedLabel.count)]))
            } else if opensExchange || answersQuestion, line.hasPrefix(Self.answerLabel) {
                turns.append((false, [line.dropFirst(Self.answerLabel.count)]))
            } else if turns.isEmpty {
                comment.append(line)
            } else {
                // A pasted answer can run over several lines; they belong to the turn above.
                turns[turns.count - 1].lines.append(line)
            }
        }
        self.comment = comment.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        self.turns = turns.map { Turn(isAgent: $0.isAgent, text: $0.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}
