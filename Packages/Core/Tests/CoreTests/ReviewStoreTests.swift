import Foundation
import Testing
@testable import Core

/// Review (2026-10-10): a send can ask the user to review what the agent did. Its notes, once resolved, wait for the
/// user to accept them; a later send makes them new work again.
struct ReviewStoreTests {
    private func setUp() async throws -> (NoteStore, Note, Note) {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let document = try await store.upsertDocument(hostID: .local, path: "/p/a.md", kind: .markdown,
                                                      fingerprint: Fingerprint(mtime: Date(timeIntervalSince1970: 1), size: 1, hash: "h"))
        let a = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "a", color: .yellow)
        let b = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "b", color: .yellow)
        return (store, a, b)
    }

    @Test func aReviewSendsResolvedNotesWaitForAcceptance() async throws {
        let (store, a, b) = try await setUp()
        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "p", noteIDs: [a.id], outcome: .delivered, review: true)
        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "p", noteIDs: [b.id], outcome: .delivered)
        try await store.resolveSent(a.id, message: "Renamed it.", agent: "claude")
        try await store.resolveSent(b.id, agent: "claude")
        let resolvedA = try #require(try await store.note(a.id))
        let resolvedB = try #require(try await store.note(b.id))
        #expect(resolvedA.awaitsReview && resolvedA.reviewRequested)
        #expect(!resolvedB.awaitsReview && !resolvedB.reviewRequested, "a send that didn't ask leaves the note settled")

        try await store.accept([a.id, b.id])
        let acceptedA = try #require(try await store.note(a.id))
        #expect(!acceptedA.awaitsReview && acceptedA.acceptedAt != nil && acceptedA.state == .resolved)
        #expect(try await store.note(b.id)?.acceptedAt == nil, "only notes awaiting review are accepted")
    }

    @Test func aFollowUpIsNewWorkToReview() async throws {
        let (store, a, _) = try await setUp()
        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "p", noteIDs: [a.id], outcome: .delivered, review: true)
        try await store.resolveSent(a.id, agent: "claude")
        try await store.accept([a.id])
        try await store.addFollowUp(a.id, body: "Also the header.")
        // Sent without asking again: the note keeps asking for review.
        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "p", noteIDs: [a.id], outcome: .delivered)
        let reopened = try #require(try await store.note(a.id))
        #expect(reopened.state == .sent && reopened.reviewRequested && reopened.acceptedAt == nil)
        try await store.resolveSent(a.id, agent: "claude")
        #expect(try await store.note(a.id)?.awaitsReview == true)
    }

    /// Review shows the lines as sent: the anchor at the last delivered send is kept while the live one follows edits.
    @Test func aDeliveredSendRemembersTheAnchorAsSent() async throws {
        let (store, a, b) = try await setUp()
        func line(_ n: Int) -> Anchor {
            .text(TextAnchor(start: .init(line: n, col: 1), end: .init(line: n, col: 2), text: "x\(n)", before: "", after: ""))
        }
        try await store.updateAnchor(a.id, anchor: line(1))
        #expect(try await store.note(a.id)?.sentAnchor == nil, "nothing sent yet")
        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "p", noteIDs: [a.id], outcome: .delivered, review: true)
        #expect(try await store.note(a.id)?.sentAnchor == line(1))

        _ = try await store.applyReanchor(a.id, to: line(5))
        let moved = try #require(try await store.note(a.id))
        #expect(moved.anchor == line(5) && moved.sentAnchor == line(1), "following an edit leaves the sent copy alone")

        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "p", noteIDs: [a.id], outcome: .delivered)
        #expect(try await store.note(a.id)?.sentAnchor == line(5), "a later send overwrites it")

        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "p", noteIDs: [b.id], outcome: .failed("no pane"))
        #expect(try await store.note(b.id)?.sentAnchor == nil, "a failed send didn't reach an agent")

        let json = try JSONEncoder().encode(moved)
        let withoutField = try #require(String(data: json, encoding: .utf8)).replacingOccurrences(of: "\"sentAnchor\"", with: "\"sentAnchorOld\"")
        let decoded = try JSONDecoder().decode(Note.self, from: Data(withoutField.utf8))
        #expect(decoded.sentAnchor == nil, "a note snapshot written before the field decodes")
    }

    @Test func aFailedSendOrAHandResolveLeavesNothingToReview() async throws {
        let (store, a, b) = try await setUp()
        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "p", noteIDs: [a.id], outcome: .failed("no pane"), review: true)
        #expect(try await store.note(a.id)?.reviewRequested == false)
        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "p", noteIDs: [b.id], outcome: .delivered, review: true)
        try await store.resolve(b.id)
        let byHand = try #require(try await store.note(b.id))
        #expect(!byHand.awaitsReview && byHand.acceptedAt != nil, "resolving by hand is the user's own verdict")
    }

    /// An agent resolving again is new work, even without a send between (a stale packet, a follow-up taken back).
    @Test func anAgentsResolveIsAlwaysNewWork() async throws {
        let (store, a, _) = try await setUp()
        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "p", noteIDs: [a.id], outcome: .delivered, review: true)
        try await store.resolveSent(a.id, agent: "claude")
        try await store.accept([a.id])
        try await store.addFollowUp(a.id, body: "And this.")
        let followUp = try #require(try await store.messages(for: a.id).last)
        try await store.deleteFollowUp(followUp.id)
        try await store.resolveSent(a.id, agent: "claude")
        #expect(try await store.note(a.id)?.awaitsReview == true)
    }

    /// Review doesn't follow iterations: a result waiting for review comes along to a new one, and a note resolved
    /// after its iteration ended joins the current one.
    @Test func resultsToReviewStayInTheCurrentIteration() async throws {
        let (store, a, b) = try await setUp()
        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "p", noteIDs: [a.id, b.id], outcome: .delivered, review: true)
        try await store.resolveSent(a.id, agent: "claude")
        let next = try await store.startIteration(documentID: a.documentID, openNotes: .leave, snapshot: nil)
        #expect(try await store.note(a.id)?.iteration == next, "waiting for review, it comes along")
        #expect(try await store.note(b.id)?.iteration == 0, "left behind, as chosen")
        try await store.resolveSent(b.id, agent: "claude")
        #expect(try await store.note(b.id)?.iteration == next, "resolved later, it joins the round the user is on")
    }
}
