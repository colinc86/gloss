import Core
import Foundation
import Observation

/// Review (2026-10-10): a send that asked for review leaves its notes, once the agent resolves them, waiting for the
/// user to accept the result. Review steps through them in the location in front, one at a time, in the document as
/// it is: Accept, a follow-up, or Later. The agent's message says what it changed; nothing is diffed.
@MainActor
@Observable
final class ReviewModel {
    @ObservationIgnored private let noteStore: NoteStore
    /// The notes of the location in front, by document, in the panel's order.
    @ObservationIgnored var notes: () -> [DocumentNotes] = { [] }
    /// Shows a note in its document, opening it (or leaving an earlier iteration) as needed.
    @ObservationIgnored var reveal: (Note, Core.Document) -> Void = { _, _ in }
    /// Adds a follow-up to a note; false when it couldn't be added.
    @ObservationIgnored var followUp: (NoteID, String) async -> Bool = { _, _ in false }
    /// Sends notes to the agent in front, as Send does.
    @ObservationIgnored var send: ([NoteID]) async -> Void = { _ in }
    /// Says why something failed, in a sentence.
    @ObservationIgnored var onError: (String) -> Void = { _ in }

    /// The notes being stepped through, in order; Later moves one to the end.
    private(set) var queue: [NoteID] = []
    private(set) var index = 0
    private(set) var isActive = false
    /// A write is under way: the bar's actions wait for it, so a second press acts on nothing twice.
    private(set) var isBusy = false
    /// Notes accepted or followed up in this review: done here, whatever the panel's observation still says.
    private var settled: Set<NoteID> = []

    init(noteStore: NoteStore) {
        self.noteStore = noteStore
    }

    /// Notes waiting for review in the location in front: document by document, then by place in the file.
    var toReview: [(note: Note, document: Core.Document)] {
        notes().flatMap { group in
            group.notes.filter(\.awaitsReview)
                .sorted { $0.anchor.sortKey != $1.anchor.sortKey ? $0.anchor.sortKey < $1.anchor.sortKey : $0.id.rawValue < $1.id.rawValue }
                .map { (note: $0, document: group.document) }
        }
    }

    var waitingCount: Int { toReview.count }

    /// The note on screen, and its document; nil once every note is reviewed.
    var current: (note: Note, document: Core.Document)? {
        guard isActive, queue.indices.contains(index) else { return nil }
        return lookUp(queue[index])
    }

    /// Notes of the queue not yet accepted or followed up.
    var remaining: [NoteID] { queue.filter(isPending) }

    var isFinished: Bool { isActive && remaining.isEmpty }

    /// Starts review, or starts it over (a review left without its bar, the document closed, stays restartable).
    func start() {
        let ids = toReview.map(\.note.id)
        guard !ids.isEmpty else { return }
        queue = ids
        index = 0
        settled = []
        isActive = true
        showCurrent()
    }

    func end() {
        isActive = false
        queue = []
        index = 0
        settled = []
    }

    /// The next note still to review (after this one, then from the top); with none left, the next note of the
    /// queue, so stepping back over reviewed notes can step forward again, and past the last, the end of review.
    func next() {
        guard isActive, !queue.isEmpty else { return }
        let after = queue.indices.filter { $0 > index }
        let before = queue.indices.filter { $0 < index }
        if let found = (after + before).first(where: { isPending(queue[$0]) }) {
            index = found
            showCurrent()
        } else if queue.indices.contains(index), isPending(queue[index]) {
            return
        } else if index + 1 < queue.count {
            index += 1
            showCurrent()
        } else {
            index = queue.count
        }
    }

    /// The note before this one in the queue, reviewed or not, to look at it again.
    func previous() {
        guard isActive, index > 0 else { return }
        index = min(index, queue.count) - 1
        showCurrent()
    }

    var canGoBack: Bool { isActive && index > 0 }
    var canGoForward: Bool { current != nil && (index + 1 < queue.count || queue.contains { $0 != queue[index] && isPending($0) }) }

    /// How much of the queue is reviewed, 0 to 1, for the bar's progress line.
    var reviewedFraction: Double {
        queue.isEmpty ? 0 : Double(queue.count - remaining.count) / Double(queue.count)
    }

    /// What became of the notes reviewed so far: accepted (still resolved) or followed up (reopened).
    var outcomes: (accepted: Int, followedUp: Int) {
        queue.filter { !isPending($0) }.reduce(into: (accepted: 0, followedUp: 0)) { counts, id in
            guard let note = lookUp(id)?.note else { return }
            if note.state == .resolved { counts.accepted += 1 } else { counts.followedUp += 1 }
        }
    }

    /// Notes followed up in this review whose follow-up hasn't been sent yet.
    var unsentFollowUps: [NoteID] { queue.filter { lookUp($0)?.note.hasUnsentFollowUps == true } }

    /// Whether the note on screen was accepted or followed up in this review (or elsewhere since it began).
    var isCurrentReviewed: Bool { current.map { !isPending($0.note.id) } ?? false }

    /// Sends the follow-ups written during this review, in one packet.
    func sendFollowUps() async {
        let ids = unsentFollowUps
        guard !isBusy, !ids.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        await send(ids)
    }

    /// Puts the note on screen at the end of the queue and moves on.
    func later() {
        guard isActive, queue.indices.contains(index), remaining.count > 1 else { return }
        let id = queue.remove(at: index)
        queue.append(id)
        index -= 1
        next()
    }

    func accept() async {
        guard !isBusy, let id = current?.note.id else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await noteStore.accept([id])
            settled.insert(id)
            moveOn(from: id)
        } catch {
            onError("The note couldn't be accepted: \(error.userMessage)")
        }
    }

    /// Accepts every note left in the queue.
    func acceptAll() async {
        let ids = remaining
        guard !isBusy, !ids.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await noteStore.accept(ids)
            settled.formUnion(ids)
            index = queue.count
        } catch {
            onError("The notes couldn't be accepted: \(error.userMessage)")
        }
    }

    /// A follow-up reopens the note; it goes to the agent with the next Send, and comes back to review when resolved.
    @discardableResult
    func followUp(_ text: String) async -> Bool {
        guard !isBusy, let id = current?.note.id, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        isBusy = true
        defer { isBusy = false }
        // A failure is said in the bar, beside the text it keeps.
        guard await followUp(id, text) else { return false }
        settled.insert(id)
        moveOn(from: id)
        return true
    }

    /// The note on screen went away (deleted, say) while others wait: shows the next.
    func skipMissing() {
        guard isActive, current == nil, !remaining.isEmpty else { return }
        next()
    }

    /// Steps on after acting on `id`, unless the user already stepped elsewhere meanwhile.
    private func moveOn(from id: NoteID) {
        guard queue.indices.contains(index), queue[index] == id else { return }
        next()
    }

    private func isPending(_ id: NoteID) -> Bool {
        !settled.contains(id) && lookUp(id)?.note.awaitsReview == true
    }

    private func lookUp(_ id: NoteID) -> (note: Note, document: Core.Document)? {
        for group in notes() {
            if let note = group.notes.first(where: { $0.id == id }) { return (note, group.document) }
        }
        return nil
    }

    private func showCurrent() {
        guard let current else { return }
        reveal(current.note, current.document)
    }
}
