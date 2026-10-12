import Core
import Foundation
import Testing
@testable import Gloss

/// Review (2026-10-10): stepping through what agents resolved for a send that asked for review, in the location in
/// front, document by document and in file order.
@MainActor struct ReviewModelTests {
    private func wait(_ condition: () -> Bool) async {
        for _ in 0..<150 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Timed out waiting for the panel")
    }

    private func line(_ n: Int) -> Anchor {
        .text(TextAnchor(start: .init(line: n, col: 1), end: .init(line: n, col: 2), text: "x", before: "", after: ""))
    }

    /// Three resolved results in /p (two in a.md, out of order, one in b.md), one elsewhere, one sent without review.
    private func setUp() async throws -> (NoteStore, NotesPanelModel, ReviewModel, [String: NoteID]) {
        let store = NoteStore(database: try AppDatabase.inMemory())
        var ids: [String: NoteID] = [:]
        func add(_ path: String, _ name: String, line n: Int, review: Bool = true) async throws {
            let document = try await store.upsertDocument(hostID: .local, path: path, kind: .markdown, fingerprint: Fingerprint())
            let note = try await store.createNote(documentID: document.id, anchor: line(n), body: name, color: .yellow)
            _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "p", noteIDs: [note.id], outcome: .delivered, review: review)
            try await store.resolveSent(note.id, message: "Did \(name).", agent: "claude")
            ids[name] = note.id
        }
        try await add("/p/a.md", "a9", line: 9)
        try await add("/p/a.md", "a2", line: 2)
        try await add("/p/b.md", "b1", line: 1)
        try await add("/q/c.md", "elsewhere", line: 1)
        try await add("/p/b.md", "plain", line: 5, review: false)

        let panel = NotesPanelModel(noteStore: store)
        let location = NotesLocation(hostID: .local, path: "/p")
        panel.setLocation(location)
        panel.start()
        await wait { panel.allGroups.flatMap(\.notes).count == 5 }
        let review = ReviewModel(noteStore: store)
        review.notes = { panel.allGroups.filter { location.contains($0.document) } }
        review.followUp = { id, text in await panel.addFollowUp(to: id, text) }
        return (store, panel, review, ids)
    }

    @Test func theQueueIsTheLocationsResultsInFileOrder() async throws {
        let (_, panel, review, ids) = try await setUp()
        defer { panel.stop() }
        #expect(review.toReview.map(\.note.id) == [ids["a2"], ids["a9"], ids["b1"]].compactMap { $0 },
                "another location's result and one sent without review are left out")
        review.start()
        #expect(review.isActive && review.current?.note.id == ids["a2"] && review.queue.count == 3)
    }

    @Test func acceptLaterAndStepping() async throws {
        let (store, panel, review, ids) = try await setUp()
        defer { panel.stop() }
        review.start()
        review.later()
        #expect(review.current?.note.id == ids["a9"], "Later moves on")
        #expect(review.queue.last == ids["a2"], "and puts the note at the end")
        await review.accept()
        #expect(try await store.note(ids["a9"]!)?.acceptedAt != nil)
        #expect(abs(review.reviewedFraction - 1.0 / 3) < 0.001)
        #expect(review.current?.note.id == ids["b1"])
        review.previous()
        #expect(review.current?.note.id == ids["a9"] && review.isCurrentReviewed, "back steps over reviewed notes too")
        review.next()
        #expect(review.current?.note.id == ids["b1"], "forward goes to what's still to review")
        review.next()
        #expect(review.current?.note.id == ids["a2"])
        await review.acceptAll()
        #expect(review.isFinished && review.current == nil && review.reviewedFraction == 1)
        #expect(review.outcomes == (accepted: 3, followedUp: 0))
        review.previous()
        #expect(review.current?.note.id == ids["a2"] && review.isCurrentReviewed, "Back from the end shows the last note")
        review.next()
        #expect(review.current == nil, "and forward goes back to the end")
        #expect(try await store.note(ids["a2"]!)?.awaitsReview == false)
        #expect(try await store.note(ids["b1"]!)?.awaitsReview == false)
        await wait { review.waitingCount == 0 }
        review.end()
        #expect(!review.isActive)
    }

    @Test func aFollowUpReopensTheNoteAndMovesOn() async throws {
        let (store, panel, review, ids) = try await setUp()
        defer { panel.stop() }
        review.start()
        #expect(await review.followUp("Also the title."))
        let reopened = try #require(try await store.note(ids["a2"]!))
        #expect(reopened.state == .sent && reopened.hasUnsentFollowUps && reopened.reviewRequested)
        #expect(review.current?.note.id == ids["a9"])
        #expect(await !review.followUp("   "), "nothing to add")
        await wait { review.unsentFollowUps == [ids["a2"]!] }
        #expect(review.outcomes == (accepted: 0, followedUp: 1))
        var sent: [NoteID] = []
        review.send = { sent = $0 }
        await review.sendFollowUps()
        #expect(sent == [ids["a2"]!], "Send Follow-Ups sends what was followed up in this review")
    }

    @Test func aResultWaitingForReviewIsDrawnOpen() {
        var note = Note(id: NoteID(rawValue: "n_1"), documentID: DocumentID(rawValue: "d_1"), anchor: .wholeFile, body: "b",
                        state: .resolved, color: .yellow, createdAt: Date(), updatedAt: Date(), reviewRequested: true)
        #expect(note.awaitsReview && note.displayState == .sent && NotesPanelModel.isOpen(note))
        #expect(NoteCard.badgeLabel(note) == "To review")
        note.acceptedAt = Date()
        #expect(!note.awaitsReview && note.displayState == .resolved && !NotesPanelModel.isOpen(note))
    }
}
