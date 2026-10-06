import Core
import Foundation

/// A note's body read as a conversation: the comment the user wrote, then each exchange an answered question added
/// (`NoteStore.body(_:answering:with:)` writes them as "Agent asked:" and "Answer:" lines), then the agent's pending
/// turn if it resolved the note with a message. The card shows the latest turn and keeps the rest behind a button.
nonisolated struct NoteThread: Equatable {
    enum Speaker: Equatable { case agent, user }

    struct Turn: Equatable {
        let speaker: Speaker
        let text: String
    }

    /// What the user wrote before any exchange.
    let comment: String
    /// Every turn, oldest first; the agent's resolve message, when there is one, is last.
    let turns: [Turn]

    init(body: String, resolveMessage: String? = nil) {
        var comment: [Substring] = []
        var turns: [(speaker: Speaker, lines: [Substring])] = []
        var previousBlank = false
        // Turns start only where `NoteStore.body(_:answering:with:)` writes them: an exchange after a blank line,
        // and an answer right under the question. A line of the comment that happens to begin "Answer:" stays text.
        for line in body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let opensExchange = previousBlank
            let answersQuestion = turns.last?.speaker == .agent
            previousBlank = line.allSatisfy(\.isWhitespace)
            if opensExchange, line.hasPrefix(NoteStore.askedLabel) {
                turns.append((.agent, [line.dropFirst(NoteStore.askedLabel.count)]))
            } else if opensExchange || answersQuestion, line.hasPrefix(NoteStore.answerLabel) {
                turns.append((.user, [line.dropFirst(NoteStore.answerLabel.count)]))
            } else if turns.isEmpty {
                comment.append(line)
            } else {
                // A pasted answer can run over several lines; they belong to the turn above.
                turns[turns.count - 1].lines.append(line)
            }
        }
        self.comment = comment.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        var parsed = turns.map { Turn(speaker: $0.speaker, text: $0.lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let message = resolveMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            parsed.append(Turn(speaker: .agent, text: message))
        }
        self.turns = parsed
    }

    /// The turn a card always shows: the agent's resolve message if it left one, else the user's last answer.
    /// An agent's question already answered is never the latest; its answer is.
    var latest: Turn? { turns.last }

    /// Turns the collapsed card leaves out.
    var earlier: [Turn] { Array(turns.dropLast()) }
}
