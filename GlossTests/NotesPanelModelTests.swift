import Core
import Foundation
import SwiftUI
import Testing
@testable import Gloss

/// Filtering, search, and sort orders of the notes panel, against an in-memory store.
@MainActor
struct NotesPanelModelTests {
    private static let text = (1...20).map { "line \($0)" }.joined(separator: "\n")

    private func anchor(line: Int) -> Core.Anchor {
        let index = LineIndex(Self.text)
        return .text(ReAnchorer.make(from: index.contentRange(ofLine: line), in: Self.text, index: index, hash: Data(Self.text.utf8).sha256Hex))
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Two documents: `alpha.swift` with notes on lines 9 (oldest, blue), 2 (yellow, resolved with a message) and
    /// `beta.md` with one note on line 5 (newest, green).
    private func makeModel() async throws -> (NotesPanelModel, NoteStore) {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let alpha = try await store.upsertDocument(hostID: .local, path: "/p/alpha.swift", kind: .code, fingerprint: Fingerprint())
        let beta = try await store.upsertDocument(hostID: .local, path: "/p/beta.md", kind: .markdown, fingerprint: Fingerprint())
        let start = Date(timeIntervalSince1970: 1_000_000)
        _ = try await store.createNote(documentID: alpha.id, anchor: anchor(line: 9), body: "Rename the helper", color: .blue, at: start)
        let second = try await store.createNote(documentID: alpha.id, anchor: anchor(line: 2), body: "Check the café import", color: .yellow, at: start.addingTimeInterval(60))
        try await store.resolve(second.id, message: "Moved to Utilities", at: start.addingTimeInterval(90))
        _ = try await store.createNote(documentID: beta.id, anchor: anchor(line: 5), body: "Expand this section", color: .green, at: start.addingTimeInterval(120))
        let model = NotesPanelModel(noteStore: store)
        model.start()
        await waitUntil { model.groups.reduce(0) { $0 + $1.notes.count } == 3 }
        return (model, store)
    }

    private func bodies(_ model: NotesPanelModel) -> [String] {
        model.visibleGroups.flatMap(\.notes).map(\.body)
    }

    @Test func positionSortsByLineWithinEachDocument() async throws {
        let (model, _) = try await makeModel()
        defer { model.stop() }
        #expect(bodies(model) == ["Check the café import", "Rename the helper", "Expand this section"])
    }

    @Test func dateSortsOrderDocumentsByTheirFirstNote() async throws {
        let (model, _) = try await makeModel()
        defer { model.stop() }
        model.sort = .newest
        #expect(model.visibleGroups.map(\.document.fileName) == ["beta.md", "alpha.swift"])
        #expect(bodies(model) == ["Expand this section", "Check the café import", "Rename the helper"])
        model.sort = .oldest
        #expect(bodies(model) == ["Rename the helper", "Check the café import", "Expand this section"])
    }

    @Test func colorAndStateSortsGroupByThoseKeys() async throws {
        let (model, _) = try await makeModel()
        defer { model.stop() }
        model.sort = .color
        let alpha = try #require(model.visibleGroups.first { $0.document.fileName == "alpha.swift" })
        #expect(alpha.notes.map(\.color) == [.yellow, .blue], "palette order, yellow first")
        model.sort = .state
        let byState = try #require(model.visibleGroups.first { $0.document.fileName == "alpha.swift" })
        #expect(byState.notes.map(\.state) == [.draft, .resolved], "drafts lead")
    }

    @Test func searchMatchesBodiesFileNamesAndResolveMessagesIgnoringCaseAndAccents() async throws {
        let (model, _) = try await makeModel()
        defer { model.stop() }
        model.searchText = "CAFE"
        #expect(bodies(model) == ["Check the café import"])
        model.searchText = "beta"
        #expect(bodies(model) == ["Expand this section"], "a file-name match keeps every note in that file")
        model.searchText = "utilities"
        #expect(bodies(model) == ["Check the café import"], "resolve messages are searchable")
        model.searchText = "   "
        #expect(bodies(model).count == 3, "whitespace is no filter")
        #expect(!model.isFiltering)
    }

    @Test func stateAndColorFiltersCombineAndClear() async throws {
        let (model, _) = try await makeModel()
        defer { model.stop() }
        model.filter = .drafts
        #expect(Set(bodies(model)) == ["Rename the helper", "Expand this section"])
        model.colorFilter = [.green]
        #expect(bodies(model) == ["Expand this section"])
        model.searchText = "helper"
        #expect(model.visibleGroups.isEmpty && model.isFiltering)
        model.clearFilters()
        #expect(bodies(model).count == 3 && !model.isFiltering)
    }

    @Test func selectedEntryFindsTheNoteAndItsDocument() async throws {
        let (model, _) = try await makeModel()
        defer { model.stop() }
        let note = try #require(model.groups.flatMap(\.notes).first { $0.body == "Expand this section" })
        model.selectedNoteID = note.id
        #expect(model.selectedEntry?.document.fileName == "beta.md")
        #expect(model.draftCount == 2)
        #expect(model.count(for: .all) == 3 && model.count(for: .drafts) == 2 && model.count(for: .resolved) == 1 && model.count(for: .sent) == 0)
        model.searchText = "helper"
        #expect(model.count(for: .drafts) == 2, "counts ignore search and color filters")
    }

    @Test func deliveryLinesNameTheTargetAndTheOutcome() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let target = AgentTarget(transport: .herdr, hostID: .local, label: "claude · fix bug (w1:p1)", identityJSON: "{}")
        let json = String(data: try JSONEncoder().encode(target), encoding: .utf8)!
        let sent = SendSummary(id: .new(), transport: "herdr", targetJSON: json, sentAt: now.addingTimeInterval(-10), outcome: "delivered")
        #expect(NotesPanelModel.deliveryLine(sent, now: now) == ("Sent to claude · fix bug (w1:p1) · just now", false))
        let hook = SendSummary(id: .new(), transport: "claude-hook", targetJSON: #"{"cwd":"/p"}"#, sentAt: now.addingTimeInterval(-7200), outcome: "delivered")
        let hookLine = NotesPanelModel.deliveryLine(hook, now: now)
        #expect(hookLine.text.hasPrefix("Sent to Claude Code hook · ") && hookLine.text.contains("2") && !hookLine.failed)
        let failed = SendSummary(id: .new(), transport: "herdr", targetJSON: json, sentAt: now, outcome: "failed: The agent is waiting on a permission prompt")
        #expect(NotesPanelModel.deliveryLine(failed, now: now) == ("Sending to claude · fix bug (w1:p1) failed just now: The agent is waiting on a permission prompt", true))
    }

    @Test func aResolvedNoteCanBeReopenedAsADraft() async throws {
        let (model, store) = try await makeModel()
        defer { model.stop() }
        let resolved = try #require(model.groups.flatMap(\.notes).first { $0.state == .resolved })
        await model.reopen(resolved.id)
        #expect(try await store.note(resolved.id)?.state == .draft)
        await waitUntil { model.draftCount == 3 }
        #expect(model.draftCount == 3)
    }

    @Test func replyingToAQuestionAddsTheExchangeAndMakesTheNoteADraft() async throws {
        let (model, store) = try await makeModel()
        defer { model.stop() }
        let note = try #require(model.groups.flatMap(\.notes).first { $0.body == "Expand this section" })
        try await store.resolve(note.id, outcome: .needsInput, message: "Which section?")
        #expect(await model.reply(to: note.id, with: "  The install steps \n"))
        let replied = try #require(try await store.note(note.id))
        #expect(replied.state == .draft)
        #expect(replied.body == "Expand this section\n\nAgent asked: Which section?\nAnswer: The install steps")
    }

    @Test func anAnsweredQuestionReadsAsAConversationOnTheCard() {
        let body = "Tighten *this*\n\nAgent asked: Shorter?\nAnswer: Agent asked: no, plainer"
        let styled = NoteCard.styledBody(body)
        #expect(String(styled.characters) == "Tighten this\n\nAgent asked: Shorter?\nAnswer: Agent asked: no, plainer")
        let colored = styled.runs.compactMap { run in run.foregroundColor.map { _ in String(styled[run.range].characters) } }
        // Only the labels at the start of a line, never the same words inside an answer.
        #expect(colored == ["Agent asked:", "Answer:"])
    }

    @Test func answeringUsesTheNoteAsItIsNowAndOnlyOnce() async throws {
        let (model, store) = try await makeModel()
        defer { model.stop() }
        let note = try #require(model.groups.flatMap(\.notes).first { $0.body == "Expand this section" })
        try await store.resolve(note.id, outcome: .needsInput, message: "Which section?")
        // Edited elsewhere while the field was open: the answer goes on the current text, not the card's copy.
        try await store.updateBody(note.id, body: "Expand the setup section")
        #expect(await model.reply(to: note.id, with: "Mac"))
        #expect(try await store.note(note.id)?.body == "Expand the setup section\n\nAgent asked: Which section?\nAnswer: Mac")
        // A second answer to a question already answered changes nothing.
        #expect(await model.reply(to: note.id, with: "Linux") == false)
        #expect(try await store.note(note.id)?.body == "Expand the setup section\n\nAgent asked: Which section?\nAnswer: Mac")
    }

    @Test func theAgentsTurnIsHeadedByWhoSpokeAndHow() {
        #expect(AgentMessageBubble.heading(agent: "claude", needsInput: true) == "claude asks")
        #expect(AgentMessageBubble.heading(agent: "codex", needsInput: false) == "codex replied")
        #expect(AgentMessageBubble.heading(agent: nil, needsInput: true) == "Agent asks")
        #expect(AgentMessageBubble.heading(agent: "  ", needsInput: false) == "Agent replied")
    }

    @Test func anEmptyListSaysWhyItIsEmpty() {
        let search = NotesPanelModel.emptyCopy(filter: .drafts, colors: [.blue], search: "  café ")
        #expect(search.title == "No notes match “café”" && search.action == "Clear Search", "a search speaks first")
        #expect(NotesPanelModel.emptyCopy(filter: .all, colors: [.pink, .blue], search: "").title == "No blue or pink notes")
        #expect(NotesPanelModel.emptyCopy(filter: .drafts, colors: [], search: "").title == "No drafts")
        #expect(NotesPanelModel.emptyCopy(filter: .sent, colors: [], search: "").title == "Nothing waiting on an agent")
        let clear = NotesPanelModel.emptyCopy(filter: .attention, colors: [], search: "")
        #expect(clear.title == "All clear" && clear.goodNews, "an empty Attention list is good news")
        #expect(!NotesPanelModel.emptyCopy(filter: .resolved, colors: [], search: "").goodNews)
    }

    @Test func aCardQuotesTheFirstLineItIsAbout() {
        let text = "\n    var isSteep: Bool {\n        true\n    }"
        let index = LineIndex(text)
        let anchor = Core.Anchor.text(ReAnchorer.make(from: NSRange(location: 0, length: (text as NSString).length), in: text, index: index, hash: Data(text.utf8).sha256Hex))
        #expect(NoteCard.excerpt(of: anchor) == "var isSteep: Bool {", "the first line with something on it, trimmed")
        #expect(NoteCard.excerpt(of: .wholeFile) == nil)
    }

    @Test func aNewNoteArrivesButTheFirstLoadDoesNot() async throws {
        let (model, store) = try await makeModel()
        defer { model.stop() }
        #expect(model.arrivedIDs.isEmpty, "nothing arrives on the first load")
        let document = try #require(model.groups.first).document
        let note = try await store.createNote(documentID: document.id, anchor: anchor(line: 12), body: "Fresh", color: .pink)
        await waitUntil { model.arrivedIDs.contains(note.id) }
        #expect(model.arrivedIDs == [note.id])
    }

    @Test func anUndoThatFailsSaysSoAndKeepsTheToast() async throws {
        let (model, store) = try await makeModel()
        defer { model.stop() }
        let note = try #require(model.groups.flatMap(\.notes).first { $0.body == "Expand this section" })
        await model.delete(note.id)
        let deleted = try #require(model.lastDeleted.first)
        // Brought back elsewhere first, so this restore collides with the row that is already there.
        try await store.restore(deleted)
        await model.undoDelete(deleted)
        #expect(model.undoFailure != nil, "a failed undo is said, not silent")
        #expect(model.lastDeleted == [deleted], "the toast stays, with Try Again")
        model.dismissUndo()
        #expect(model.undoFailure == nil && model.lastDeleted.isEmpty)
    }

    @Test func aBlankReplyChangesNothing() async throws {
        let (model, store) = try await makeModel()
        defer { model.stop() }
        let note = try #require(model.groups.flatMap(\.notes).first { $0.body == "Expand this section" })
        try await store.resolve(note.id, outcome: .needsInput, message: "Which section?")
        #expect(await model.reply(to: note.id, with: "   ") == false)
        #expect(try await store.note(note.id)?.state == .resolved)
        #expect(try await store.note(note.id)?.body == "Expand this section")
    }

    @Test func theSortChoiceIsRestoredOnTheNextStart() async throws {
        let (model, store) = try await makeModel()
        model.sort = .oldest
        model.stop()
        for _ in 0..<100 where (try? await store.setting("notes.sort")) != "oldest" { try? await Task.sleep(for: .milliseconds(20)) }
        let again = NotesPanelModel(noteStore: store)
        again.start()
        await waitUntil { again.sort == .oldest }
        #expect(again.sort == .oldest)
        again.stop()
    }
}

@MainActor
struct NoteDeleteUndoTests {
    @Test func deletingOffersUndoAndUndoBringsTheNoteBack() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let document = try await store.upsertDocument(hostID: .local, path: "/tmp/undo-panel.md", kind: .markdown, fingerprint: Fingerprint())
        let note = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "come back", color: .yellow)
        let panel = NotesPanelModel(noteStore: store)

        await panel.delete(note.id)
        let deleted = try #require(panel.lastDeleted.first)
        #expect(deleted.id == note.id)
        #expect(try await store.documentsWithNotes().flatMap(\.notes).isEmpty)

        await panel.undoDelete(deleted)
        #expect(panel.lastDeleted.isEmpty)
        #expect(panel.selectedNoteID == note.id)
        #expect(try await store.documentsWithNotes().flatMap(\.notes).map(\.body) == ["come back"])
    }

    /// Issue #8: several notes deleted at once come back with one Undo, selected again.
    @Test func aBulkDeleteIsOneUndo() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let document = try await store.upsertDocument(hostID: .local, path: "/tmp/undo-bulk.md", kind: .markdown, fingerprint: Fingerprint())
        var ids: [NoteID] = []
        for body in ["one", "two", "three"] { ids.append(try await store.createNote(documentID: document.id, anchor: .wholeFile, body: body, color: .yellow).id) }
        let panel = NotesPanelModel(noteStore: store)
        panel.selection = Set(ids)
        #expect(panel.selectedNoteID == nil, "several selected: no single note")

        await panel.delete(ids)
        #expect(panel.lastDeleted.count == 3 && panel.selection.isEmpty)
        #expect(try await store.documentsWithNotes().isEmpty)
        await panel.undoDelete(panel.lastDeleted)
        #expect(panel.lastDeleted.isEmpty && panel.selection == Set(ids))
        #expect(Set(try await store.documentsWithNotes().flatMap(\.notes).map(\.body)) == ["one", "two", "three"])
    }
}

/// Issue #8: actions on several selected notes take only the notes they apply to.
@MainActor
struct NoteBulkActionTests {
    @Test func bulkStatusAndColourChanges() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let document = try await store.upsertDocument(hostID: .local, path: "/tmp/bulk.md", kind: .markdown, fingerprint: Fingerprint())
        let draft = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "draft", color: .yellow)
        let sent = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "sent", color: .yellow)
        let done = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "done", color: .yellow)
        _ = try await store.recordSend(transport: "tmux", targetJSON: "{}", packetText: "p", noteIDs: [sent.id, done.id], outcome: .delivered)
        try await store.resolve(done.id)
        let all = [draft.id, sent.id, done.id]
        let notes = [draft, sent, done].map { note in Note(id: note.id, documentID: note.documentID, anchor: note.anchor, body: note.body,
                                                             state: note.id == draft.id ? .draft : note.id == sent.id ? .sent : .resolved,
                                                             color: .yellow, createdAt: note.createdAt, updatedAt: note.updatedAt) }
        #expect(NotesPanelModel.sendable(notes).map(\.id) == [draft.id, sent.id], "resolved notes are not sent again")
        #expect(NotesPanelModel.reopenable(notes).map(\.id) == [done.id])

        let panel = NotesPanelModel(noteStore: store)
        panel.start()
        defer { panel.stop() }
        for _ in 0..<100 where panel.groups.flatMap(\.notes).count < 3 { try? await Task.sleep(for: .milliseconds(20)) }
        await panel.resolve(all)
        #expect(try await store.note(draft.id)?.state == .resolved)
        #expect(try await store.note(sent.id)?.state == .resolved)
        await panel.setColor(all, .green)
        for id in all { #expect(try await store.note(id)?.color == .green) }
        for _ in 0..<100 where panel.groups.flatMap(\.notes).contains(where: { $0.state != .resolved }) { try? await Task.sleep(for: .milliseconds(20)) }
        await panel.reopen(all)
        for id in all { #expect(try await store.note(id)?.state == .draft) }
    }
}

@MainActor
struct OpenWorkLeadsTests {
    @Test func documentsWithOpenWorkComeFirstInPositionOrder() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let done = try await store.upsertDocument(hostID: .local, path: "/a/done.md", kind: .markdown, fingerprint: Fingerprint())
        let open = try await store.upsertDocument(hostID: .local, path: "/b/open.md", kind: .markdown, fingerprint: Fingerprint())
        let finished = try await store.createNote(documentID: done.id, anchor: .wholeFile, body: "finished", color: .green)
        try await store.resolve(finished.id)
        _ = try await store.createNote(documentID: open.id, anchor: .wholeFile, body: "todo", color: .yellow)
        let panel = NotesPanelModel(noteStore: store)
        panel.start()
        for _ in 0..<50 where panel.groups.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(panel.visibleGroups.map(\.document.fileName) == ["open.md", "done.md"])
    }
}
