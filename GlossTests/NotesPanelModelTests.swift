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

    @Test func thePageListsWhatThePanelListsPerTabColorAndSearch() async throws {
        let (model, _) = try await makeModel()
        defer { model.stop() }
        let alpha = try #require(model.groups.first { $0.document.fileName == "alpha.swift" })
        let ids = Dictionary(uniqueKeysWithValues: alpha.notes.map { ($0.body, $0.id) })
        let helper = try #require(ids["Rename the helper"]), cafe = try #require(ids["Check the café import"])
        #expect(model.listedIDs(for: alpha.document.id) == [helper, cafe])
        model.filter = .drafts
        #expect(model.listedIDs(for: alpha.document.id) == [helper])
        #expect(model.hiddenIDs(for: alpha.document.id, panelShown: true) == [cafe])
        // With the panel closed nothing is filtered on screen, so the page draws everything.
        #expect(model.hiddenIDs(for: alpha.document.id, panelShown: false).isEmpty)
        model.filter = .all
        model.colorFilter = [.yellow]
        #expect(model.listedIDs(for: alpha.document.id) == [cafe])
        model.colorFilter = []
        model.searchText = "helper"
        #expect(model.listedIDs(for: alpha.document.id) == [helper])
    }

    @Test func hidingResolvedNotesLeavesThemOutOfEveryTabButResolved() async throws {
        let (model, store) = try await makeModel()
        defer { model.stop() }
        let alpha = try #require(model.groups.first { $0.document.fileName == "alpha.swift" })
        let cafe = try #require(alpha.notes.first { $0.body == "Check the café import" }?.id)
        #expect(model.count(for: .all) == 3)
        model.showResolved = false
        #expect(bodies(model) == ["Rename the helper", "Expand this section"])
        #expect(model.count(for: .all) == 2, "the tab counts follow")
        #expect(model.hiddenIDs(for: alpha.document.id, panelShown: true) == [cafe])
        #expect(model.hiddenIDs(for: alpha.document.id, panelShown: false) == [cafe], "closed, the panel still hides resolved notes")
        model.filter = .resolved
        #expect(bodies(model) == ["Check the café import"])
        #expect(model.count(for: .resolved) == 1)
        // A question back from an agent is open work: it stays.
        model.filter = .all
        let helper = try #require(alpha.notes.first { $0.body == "Rename the helper" }?.id)
        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "p", noteIDs: [helper], outcome: .delivered)
        try await store.agentReply(helper, body: "Which helper?", asks: true, agent: "claude")
        await waitUntil { model.groups.flatMap(\.notes).contains(where: \.waitingOnUser) }
        #expect(bodies(model) == ["Rename the helper", "Expand this section"])
        // Saved like the sort.
        for _ in 0..<100 where (try? await store.setting("notes.showResolved")) != "0" { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(try await store.setting("notes.showResolved") == "0")
    }

    @Test func aNoteRevealedFromElsewhereIsBroughtIntoTheList() async throws {
        let (model, _) = try await makeModel()
        defer { model.stop() }
        let cafe = try #require(model.groups.flatMap(\.notes).first { $0.body == "Check the café import" })
        model.filter = .drafts
        model.showResolved = false
        model.colorFilter = [.blue]
        model.searchText = "helper"
        model.selectedNoteID = cafe.id
        #expect(model.filter == .all)
        #expect(model.showResolved)
        #expect(model.colorFilter.isEmpty)
        #expect(model.searchText.isEmpty)
        #expect(bodies(model).contains("Check the café import"))
        // A note already listed changes nothing.
        model.filter = .resolved
        model.makeListed(cafe)
        #expect(model.filter == .resolved)
    }

    @Test func hidingResolvedFiltersOnlyWhenThereAreResolvedNotes() async throws {
        let (model, store) = try await makeModel()
        defer { model.stop() }
        model.showResolved = false
        #expect(model.isHidingResolved)
        let cafe = try #require(model.groups.flatMap(\.notes).first { $0.state == .resolved })
        try await store.reopen(cafe.id)
        await waitUntil { !model.groups.flatMap(\.notes).contains { $0.state == .resolved } }
        #expect(!model.isHidingResolved, "nothing to hide: an empty list is just empty")
        #expect(!model.isFiltering)
    }

    @Test func aNoteJustMadeUnderAFilterIsBroughtIntoTheList() async throws {
        let (model, store) = try await makeModel()
        defer { model.stop() }
        let alpha = try #require(model.groups.first { $0.document.fileName == "alpha.swift" })
        model.filter = .sent
        model.colorFilter = [.blue]
        model.searchText = "helper"
        // Not yet in the panel's groups: what the page's commit hands over.
        let made = try await store.createNote(documentID: alpha.document.id, anchor: anchor(line: 4), body: "New one", color: .pink)
        model.makeListed(made)
        #expect(model.filter == .all)
        #expect(model.colorFilter.isEmpty)
        #expect(model.searchText.isEmpty)
    }

    @Test func anEmptyListBecauseResolvedNotesAreHiddenSaysSo() {
        let copy = NotesPanelModel.emptyCopy(filter: .all, colors: [], search: "", hidingResolved: true)
        #expect(copy.showsResolved)
        #expect(copy.action == "Show Resolved Notes")
        #expect(!NotesPanelModel.emptyCopy(filter: .drafts, colors: [], search: "", hidingResolved: true).showsResolved)
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

    @Test func replyingToAQuestionAddsAnUnsentFollowUp() async throws {
        let (model, store) = try await makeModel()
        defer { model.stop() }
        let note = try #require(model.groups.flatMap(\.notes).first { $0.body == "Expand this section" })
        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "p", noteIDs: [note.id], outcome: .delivered)
        try await store.agentReply(note.id, body: "Which section?", asks: true, agent: "claude")
        #expect(await model.addFollowUp(to: note.id, "  The install steps \n"))
        let replied = try #require(try await store.note(note.id))
        #expect(replied.state == .sent && replied.hasUnsentFollowUps && replied.waitingOnUser, "the user's turn until it is sent")
        #expect(replied.body == "Expand this section", "the comment is left as it was")
        let followUp = try #require(try await store.messages(for: note.id).last)
        #expect(followUp.body == "The install steps" && followUp.author == .user && !followUp.isSent)
    }

    @Test func aCommentKeepsItsInlineMarkdownAndNothingElse() {
        let styled = NoteCard.styledBody("Tighten *this*\nAgent asked: Shorter?")
        #expect(String(styled.characters) == "Tighten this\nAgent asked: Shorter?")
        #expect(styled.runs.allSatisfy { $0.foregroundColor == nil }, "a comment is only the comment: no turn labels are coloured in it")
    }

    @Test func anAnswerNeverTouchesTheComment() async throws {
        let (model, store) = try await makeModel()
        defer { model.stop() }
        let note = try #require(model.groups.flatMap(\.notes).first { $0.body == "Expand this section" })
        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "p", noteIDs: [note.id], outcome: .delivered)
        try await store.agentReply(note.id, body: "Which section?", asks: true, agent: "claude")
        // Edited elsewhere while the field was open: the comment keeps the edit, and the answer is its own turn.
        try await store.updateBody(note.id, body: "Expand the setup section")
        #expect(await model.addFollowUp(to: note.id, "Mac"))
        #expect(await model.addFollowUp(to: note.id, "and Linux"))
        #expect(try await store.note(note.id)?.body == "Expand the setup section")
        #expect(try await store.messages(for: note.id).map(\.body) == ["Which section?", "Mac", "and Linux"])
        #expect(await model.addFollowUp(to: NoteID.new(), "Lost") == false, "a note that is gone takes no answer")
    }

    /// Threads in the panel: a follow-up not yet sent counts as a draft, an agent's question as the user's turn
    /// (Attention, not Sent), and search reads every message.
    @Test func followUpsAndQuestionsAreCountedAndFoundAsThreads() async throws {
        let (model, store) = try await makeModel()
        defer { model.stop() }
        let note = try #require(model.groups.flatMap(\.notes).first { $0.body == "Expand this section" })
        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "p", noteIDs: [note.id], outcome: .delivered)
        await waitUntil { model.count(for: .sent) == 1 }
        #expect(model.draftCount == 1 && model.count(for: .sent) == 1, "sent and waiting on the agent")

        try await store.agentReply(note.id, body: "Which platform, Mac or Linux?", asks: true, agent: "claude")
        await waitUntil { model.count(for: .attention) == 1 && model.messages(for: note.id).count == 1 }
        #expect(model.count(for: .attention) == 1 && model.count(for: .sent) == 0, "a question is the user's turn")
        model.searchText = "platform"
        #expect(bodies(model) == ["Expand this section"], "search reads the agent's messages")
        model.searchText = ""

        model.followUpText[note.id] = "  Both \n"
        #expect(await model.commitFollowUp(for: note.id))
        #expect(model.followUpText[note.id] == nil, "the field clears once the follow-up is in the thread")
        await waitUntil { model.draftCount == 2 }
        #expect(model.draftCount == 2 && model.count(for: .drafts) == 2, "a note with an unsent follow-up is sendable")
        model.filter = .drafts
        #expect(Set(bodies(model)) == ["Rename the helper", "Expand this section"])

        let followUp = try #require(model.messages(for: note.id).last)
        #expect(followUp.body == "Both" && !followUp.isSent)
        #expect(await model.updateFollowUp(followUp.id, "Both, Mac first"))
        await waitUntil { model.messages(for: note.id).last?.body == "Both, Mac first" }
        #expect(await model.updateFollowUp(followUp.id, "  "), "a blank edit deletes it")
        await waitUntil { model.draftCount == 1 }
        #expect(model.messages(for: note.id).map(\.body) == ["Which platform, Mac or Linux?"] && model.draftCount == 1)
    }

    /// Return pressed twice while the first follow-up is still being written adds it once; an orphan with a follow-up
    /// waiting can be sent like any other.
    @Test func aFollowUpIsAddedOnceAndAnOrphanWithOneIsSendable() async throws {
        let (model, store) = try await makeModel()
        defer { model.stop() }
        let note = try #require(model.groups.flatMap(\.notes).first { $0.body == "Expand this section" })
        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "p", noteIDs: [note.id], outcome: .delivered)
        model.followUpText[note.id] = "Once"
        async let first = model.commitFollowUp(for: note.id)
        async let second = model.commitFollowUp(for: note.id)
        let results = await [first, second]
        #expect(results.filter { $0 }.count == 1)
        #expect(try await store.messages(for: note.id).map(\.body) == ["Once"])
        try await store.markOrphaned(note.id)
        let orphan = try #require(try await store.note(note.id))
        #expect(orphan.state == .orphaned && orphan.hasUnsentFollowUps)
        #expect(NotesPanelModel.sendable([orphan]).count == 1, "its Send is on the card")
    }

    /// A follow-up that can't be added (the note is gone) goes back into the field.
    @Test func aFollowUpThatFailsStaysInTheField() async throws {
        let (model, _) = try await makeModel()
        defer { model.stop() }
        let gone = NoteID.new()
        model.followUpText[gone] = "Still here"
        #expect(await model.commitFollowUp(for: gone) == false)
        #expect(model.followUpText[gone] == "Still here")
    }

    /// A note an agent moved goes back with Restore Original Place, and the thread says both.
    @Test func aMovedNoteGoesBackToWhereItWasMade() async throws {
        let (model, store) = try await makeModel()
        defer { model.stop() }
        let note = try #require(model.groups.flatMap(\.notes).first { $0.body == "Expand this section" })
        try await store.applyRelocation(note.id, to: anchor(line: 7), removed: false, author: "claude")
        await waitUntil { model.groups.flatMap(\.notes).first { $0.id == note.id }?.originalAnchor != nil }
        await model.restoreOriginalPlace(note.id)
        let restored = try #require(try await store.note(note.id))
        #expect(restored.anchor == note.anchor && restored.originalAnchor == nil)
        await waitUntil { model.messages(for: note.id).count == 2 }
        let thread = NoteThread(comment: restored.body, messages: model.messages(for: note.id))
        #expect(thread.entries.compactMap { if case .move(let move) = $0 { move.title } else { nil } } == ["Moved by Claude Code", "Moved back to where it was made"])
        #expect(thread.turns.isEmpty)
    }

    @Test func theAgentsTurnIsHeadedByWhoSpokeAndHow() {
        #expect(AgentMessageBubble.heading(agent: "claude") == "Claude Code", "only who spoke: the words say how")
        #expect(AgentMessageBubble.heading(agent: "codex") == "Codex")
        #expect(AgentMessageBubble.heading(agent: "opencode") == "OpenCode")
        #expect(AgentMessageBubble.heading(agent: "zed") == "zed", "another client keeps its own name")
        #expect(AgentMessageBubble.heading(agent: nil) == "Agent")
        #expect(AgentMessageBubble.heading(agent: "  ") == "Agent")
        #expect(AgentMessageBubble.spoken(agent: "claude", message: "Km or miles?", waiting: true) == "Claude Code: Km or miles?, waiting for your answer")
        #expect(AgentMessageBubble.spoken(agent: "codex", message: "Done.", waiting: false) == "Codex: Done.")
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
        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "p", noteIDs: [note.id], outcome: .delivered)
        try await store.agentReply(note.id, body: "Which section?", asks: true, agent: "claude")
        #expect(await model.addFollowUp(to: note.id, "   ") == false)
        #expect(try await store.messages(for: note.id).count == 1)
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
        #expect(NotesPanelModel.reopenable(notes).map(\.id) == [sent.id, done.id], "sent notes go back to drafts too (#13)")

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

/// Issue #14: a note edited in its card, whether or not it is on screen in the viewer.
@MainActor
struct NoteInlineEditTests {
    @Test func anEditSavesBodyAndColourUnlessTheNoteChangedMeanwhile() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let document = try await store.upsertDocument(hostID: .local, path: "/tmp/edit.md", kind: .markdown, fingerprint: Fingerprint())
        let note = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "first words", color: .yellow)
        let panel = NotesPanelModel(noteStore: store)

        #expect(await panel.update(note.id, body: "better words", color: .green, editedFrom: "first words") == nil)
        let saved = try #require(try await store.note(note.id))
        #expect(saved.body == "better words" && saved.color == .green)

        // An agent's answer lands while the card is being edited: the edit is refused, nothing is overwritten.
        try await store.updateBody(note.id, body: "better words\nAgent asked: why?")
        #expect(await panel.update(note.id, body: "mine", color: .blue, editedFrom: "better words") == .changedMeanwhile)
        #expect(try await store.note(note.id)?.body == "better words\nAgent asked: why?")
    }
}

