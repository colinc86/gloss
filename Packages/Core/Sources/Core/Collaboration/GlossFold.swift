import Foundation

/// A published note with the state its events fold to. The same files give the same state on every Mac, whatever
/// order they arrived in.
public struct GlossNoteState: Hashable, Sendable {
    public enum Status: String, Hashable, Sendable {
        /// Published to the review and waiting with the owner; no agent has it.
        case posted
        /// The owner delivered it to an agent.
        case sent
        case resolved
    }

    public struct Resolution: Hashable, Sendable {
        /// A `ResolveOutcome` raw value.
        public var outcome: String
        public var message: String?
        public var by: AuthorID
        public var via: GlossVia?
        public var at: Date
    }

    public var note: GlossNote
    /// The note's anchor after its last move.
    public var anchor: Anchor
    /// The last move found the text removed.
    public var removed = false
    public var status: Status = .posted
    /// When the owner first delivered it to an agent. Only notes with one are agent-visible (MCP).
    public var sentAt: Date?
    /// The last send asked for the result to be reviewed.
    public var reviewRequested = false
    public var resolution: Resolution?
    /// When the owner accepted the result.
    public var acceptedAt: Date?
    /// In Recently Deleted.
    public var trashed = false
    public var deletedBy: AuthorID?
    /// Its thread after the comment, in creation order.
    public var thread: [GlossMessage] = []
    /// Events the fold refused because their author had no right to them (a participant's accept, a stranger's
    /// delete), kept so the app can say why nothing happened.
    public var refused: [EventID] = []

    public var id: NoteID { note.id }

    /// Only notes the owner delivered are visible to agents.
    public var isAgentVisible: Bool { sentAt != nil }

    public var awaitsReview: Bool { status == .resolved && reviewRequested && acceptedAt == nil }

    /// An agent asked something and nobody has answered: the last turn is an agent's question, or the note itself
    /// is an agent's question (`ask_user`) with no turns yet. Only owners' records name an agent (see `read()`).
    public var waitingOnUser: Bool {
        guard status != .resolved, !trashed else { return false }
        if let last = thread.last { return last.messageKind == .question && last.via != nil }
        return note.via != nil
    }
}

/// Folds each note's events, in identifier (creation) order, into its state, applying who may do what:
/// - `sent` and `accepted` count only from an owner; `accepted` counts only on a resolved note.
/// - `resolved` and `reopened` count from anyone; resolving again or sending again clears an acceptance. Only an
///   owner's resolve names an agent (`via`): agents work on the owner's Mac.
/// - `deleted`, `restored` and `moved` count from the note's author or the owner.
/// Unknown event types are skipped, so a newer Gloss's events don't break the fold.
public enum GlossFold {
    public static func fold(_ snapshot: GlossSnapshot) -> [GlossNoteState] {
        let messages = Dictionary(grouping: snapshot.messages, by: \.note)
        let events = Dictionary(grouping: snapshot.events, by: \.note)
        return snapshot.notes.map { note in
            fold(note, messages: messages[note.id] ?? [], events: events[note.id] ?? [], info: snapshot.info)
        }
    }

    public static func fold(_ note: GlossNote, messages: [GlossMessage], events: [GlossEvent], info: GlossInfo) -> GlossNoteState {
        var state = GlossNoteState(note: note, anchor: note.anchor)
        state.thread = messages.filter { $0.note == note.id }.sorted { $0.id.rawValue < $1.id.rawValue }
        for event in events.filter({ $0.note == note.id }).sorted(by: { $0.id.rawValue < $1.id.rawValue }) {
            guard let type = event.eventType else { continue }
            let byOwner = info.isOwner(event.author)
            let byAuthorOrOwner = byOwner || event.author == note.author
            switch type {
            case .sent:
                guard byOwner else { state.refused.append(event.id); continue }
                state.status = .sent
                state.sentAt = state.sentAt ?? event.at
                state.reviewRequested = event.data?["review"]?.boolValue ?? false
                state.resolution = nil
                state.acceptedAt = nil
            case .resolved:
                state.status = .resolved
                state.resolution = GlossNoteState.Resolution(
                    outcome: event.data?["outcome"]?.stringValue ?? ResolveOutcome.done.rawValue,
                    message: event.data?["message"]?.stringValue, by: event.author, via: byOwner ? event.via : nil, at: event.at)
                state.acceptedAt = nil
            case .accepted:
                guard byOwner, state.status == .resolved else { state.refused.append(event.id); continue }
                state.acceptedAt = event.at
            case .reopened:
                state.status = state.sentAt == nil ? .posted : .sent
                state.resolution = nil
                state.acceptedAt = nil
            case .deleted:
                guard byAuthorOrOwner else { state.refused.append(event.id); continue }
                state.trashed = true
                state.deletedBy = event.author
            case .restored:
                guard byAuthorOrOwner else { state.refused.append(event.id); continue }
                state.trashed = false
                state.deletedBy = nil
            case .moved:
                guard byAuthorOrOwner, let anchor = event.movedAnchor else { state.refused.append(event.id); continue }
                state.anchor = anchor
                state.removed = event.data?["removed"]?.boolValue ?? false
            }
        }
        return state
    }
}
