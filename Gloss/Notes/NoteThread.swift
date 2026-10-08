import Core
import Foundation

/// A note read as a conversation: the comment the user wrote, then its messages in order. Turns are the user's
/// follow-ups and the agent's replies and questions; moves are quiet lines between them. The card shows the latest
/// turn and keeps the rest behind a button.
nonisolated struct NoteThread: Equatable {
    enum Speaker: Equatable { case agent, user }

    struct Turn: Equatable {
        /// The message; nil only for turns made up in tests and previews.
        var id: MessageID? = nil
        let speaker: Speaker
        let text: String
        /// An agent's question.
        var asks = false
        /// A follow-up the user hasn't sent yet.
        var unsent = false
        /// The agent's name as its client gave it; nil for the user, or an agent that gave none.
        var agent: String? = nil
    }

    /// The note's place changed: an agent said where its change is, Gloss found the text removed, or the user put
    /// it back.
    struct Move: Equatable {
        enum Mover: Equatable {
            /// An agent, by its client's name; nil when it gave none.
            case agent(String?)
            /// Gloss, finding the text removed.
            case app
            /// Restore Original.
            case user
        }

        let id: MessageID
        let by: Mover
        let removed: Bool
        /// The first line of the text the note was on before the move, for the struck-through disclosure.
        let oldExcerpt: String?
    }

    enum Entry: Equatable, Identifiable {
        case turn(Turn)
        case move(Move)

        /// The message's id; a turn made up without one (tests, previews) takes its text.
        var id: String {
            switch self {
            case .turn(let turn): turn.id?.rawValue ?? "turn:\(turn.text)"
            case .move(let move): move.id.rawValue
            }
        }
    }

    /// What the user wrote first.
    let comment: String
    /// Every turn and move, oldest first.
    let entries: [Entry]

    init(comment: String, messages: [NoteMessage]) {
        self.comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        entries = messages.compactMap { message in
            let text = message.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.kind == .moved {
                guard let move = message.move else { return nil }
                let by: Move.Mover = switch message.author {
                case .app: .app
                case .user: .user
                case .agent(let name): .agent(name == MessageAuthor.unnamedAgent ? nil : name)
                }
                return .move(Move(id: message.id, by: by, removed: move.removed, oldExcerpt: NoteCard.excerpt(of: move.from)))
            }
            switch message.author {
            case .app:
                return nil
            case .user:
                return .turn(Turn(id: message.id, speaker: .user, text: text, unsent: !message.isSent))
            case .agent(let name):
                guard !text.isEmpty else { return nil }
                return .turn(Turn(id: message.id, speaker: .agent, text: text, asks: message.kind == .question,
                                  agent: name == MessageAuthor.unnamedAgent ? nil : name))
            }
        }
    }

    /// Every turn, oldest first. Moves are not turns.
    var turns: [Turn] {
        entries.compactMap { if case .turn(let turn) = $0 { turn } else { nil } }
    }

    /// The turn a card always shows: the newest.
    var latest: Turn? { turns.last }

    /// Turns the collapsed card leaves out.
    var earlier: [Turn] { Array(turns.dropLast()) }

    /// The newest move, for the collapsed card while the note is still away from where it was made.
    var latestMove: Move? {
        entries.last { if case .move = $0 { true } else { false } }.flatMap { if case .move(let move) = $0 { move } else { nil } }
    }

    /// Follow-ups the user hasn't sent, oldest first.
    var unsent: [Turn] { turns.filter(\.unsent) }
}

nonisolated extension NoteThread.Move {
    /// The quiet line a move reads as: "Edited by Claude Code", "Removed by Codex", "Edited" or "Removed" (Gloss
    /// found the text rewritten or gone, so no one is named), "Restored original".
    var title: String {
        switch by {
        case .app: removed ? "Removed" : "Edited"
        case .user: "Restored original"
        case .agent(let name):
            "\(removed ? "Removed" : "Edited") by \(AgentMessageBubble.displayName(name ?? "the agent"))"
        }
    }
}

extension Core.Anchor {
    /// A point where an agent or an edit removed the note's text: a text anchor with nothing between its ends.
    nonisolated var isRemovalPoint: Bool {
        guard case .text(let text) = self, text.cells == nil else { return false }
        return text.start == text.end && text.text.isEmpty
    }
}
