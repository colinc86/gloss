import Core
import Foundation

/// A note read as a conversation: the comment the user wrote, then its messages as turns (the user's follow-ups,
/// the agent's replies and questions). The card shows the latest turn and keeps the rest behind a button.
nonisolated struct NoteThread: Equatable {
    enum Speaker: Equatable { case agent, user }

    struct Turn: Equatable {
        let speaker: Speaker
        let text: String
        /// An agent's question.
        var asks = false
        /// A follow-up the user hasn't sent yet.
        var unsent = false
        /// The agent's name as its client gave it; nil for the user, or an agent that gave none.
        var agent: String? = nil
    }

    /// What the user wrote first.
    let comment: String
    /// Every turn, oldest first. Moves are not turns.
    let turns: [Turn]

    init(comment: String, messages: [NoteMessage]) {
        self.comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        turns = messages.compactMap { message in
            let text = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
            switch (message.kind, message.author) {
            case (.moved, _), (_, .app):
                return nil
            case (_, .user):
                return Turn(speaker: .user, text: text, unsent: !message.isSent)
            case (let kind, .agent(let name)):
                guard !text.isEmpty else { return nil }
                return Turn(speaker: .agent, text: text, asks: kind == .question, agent: name == MessageAuthor.unnamedAgent ? nil : name)
            }
        }
    }

    /// The turn a card always shows: the newest.
    var latest: Turn? { turns.last }

    /// Turns the collapsed card leaves out.
    var earlier: [Turn] { Array(turns.dropLast()) }
}
