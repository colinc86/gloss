import Foundation
import Testing
@testable import Core

struct NoteStoreTests {
    func makeStore() throws -> NoteStore {
        NoteStore(database: try AppDatabase.inMemory())
    }

    func makeDocument(_ store: NoteStore, path: String = "/home/colin/proj/PLAN.md") async throws -> Document {
        try await store.upsertDocument(hostID: .local, path: path, kind: .markdown, fingerprint: Fingerprint(mtime: Date(timeIntervalSince1970: 1), size: 10, hash: "h"))
    }

    @Test func createsDraftNotes() async throws {
        let store = try makeStore()
        let document = try await makeDocument(store)
        let anchor = Anchor.text(TextAnchor(start: .init(line: 4, col: 1), end: .init(line: 6, col: 2), text: "t", before: "", after: ""))
        let note = try await store.createNote(documentID: document.id, anchor: anchor, body: "Fix this", color: .green)
        #expect(note.state == .draft)
        #expect(note.anchor == anchor)
        let fetched = try await store.note(note.id)
        #expect(fetched == note)
        #expect(try await store.notes(for: document.id) == [note])
    }

    @Test func upsertDocumentRefreshesFingerprint() async throws {
        let store = try makeStore()
        let first = try await makeDocument(store)
        let second = try await store.upsertDocument(hostID: .local, path: first.path, kind: .markdown, fingerprint: Fingerprint(mtime: Date(timeIntervalSince1970: 2), size: 11, hash: "h2"))
        #expect(first.id == second.id)
        #expect(second.fingerprint.hash == "h2")
        #expect(second.fingerprint.size == 11)
    }

    @Test func lifecycleTransitions() async throws {
        let store = try makeStore()
        let document = try await makeDocument(store)
        let note = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "a", color: .blue)

        let sendID = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "packet", noteIDs: [note.id], outcome: .delivered)
        #expect(try await store.note(note.id)?.state == .sent)
        let sends = try await store.sends(for: note.id)
        #expect(sends.map(\.id) == [sendID])
        #expect(sends.first?.outcome == "delivered")

        try await store.resolve(note.id, outcome: .done)
        #expect(try await store.note(note.id)?.state == .resolved)

        await #expect(throws: NoteStoreError.illegalTransition(from: .resolved, to: .draft)) {
            try await store.restoreDraft(note.id, anchor: .wholeFile)
        }
        await #expect(throws: NoteStoreError.illegalTransition(from: .resolved, to: .resolved)) {
            try await store.resolve(note.id)
        }
        try await store.reopen(note.id)
        let reopened = try await store.note(note.id)
        #expect(reopened?.state == .draft && reopened?.resolveOutcome == nil && reopened?.resolveMessage == nil)
        await #expect(throws: NoteStoreError.illegalTransition(from: .draft, to: .draft)) { try await store.reopen(note.id) }
        try await store.resolve(note.id)

        // Resolved work stays resolved when its text goes: the agent rewriting it is the expected outcome.
        try await store.markOrphaned(note.id)
        #expect(try await store.note(note.id)?.state == .resolved)
        try await store.reopen(note.id)
        try await store.markOrphaned(note.id)
        #expect(try await store.note(note.id)?.state == .orphaned)
        try await store.restoreDraft(note.id, anchor: .wholeFile)
        #expect(try await store.note(note.id)?.state == .draft)
        try await store.resolve(note.id)
        #expect(try await store.note(note.id)?.state == .resolved)
    }

    /// Issue #6: an orphan found again returns to the state it had. A sent note does not come back as a draft that
    /// could be sent a second time.
    @Test func aRecoveredOrphanKeepsItsState() async throws {
        let store = try makeStore()
        let document = try await makeDocument(store)
        let sent = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "sent", color: .blue)
        let draft = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "draft", color: .blue)
        _ = try await store.recordSend(transport: "tmux", targetJSON: "{}", packetText: "p", noteIDs: [sent.id], outcome: .delivered)
        let moved = Anchor.text(TextAnchor(start: .init(line: 9, col: 1), end: .init(line: 9, col: 4), text: "abc", before: "", after: ""))
        for id in [sent.id, draft.id] { try await store.markOrphaned(id) }
        #expect(try await store.note(sent.id)?.state == .orphaned)
        #expect(try await store.note(draft.id)?.state == .orphaned)
        for id in [sent.id, draft.id] { try await store.recoverOrphan(id, anchor: moved) }
        #expect(try await store.note(sent.id)?.state == .sent)
        #expect(try await store.note(draft.id)?.state == .draft)
        #expect(try await store.note(sent.id)?.anchor == moved)
        // Recovering a note that isn't orphaned only moves it.
        try await store.recoverOrphan(sent.id, anchor: .wholeFile)
        let after = try await store.note(sent.id)
        #expect(after?.state == .sent && after?.anchor == .wholeFile)
    }

    /// A sent note whose text went (often because the agent did what it asked: "remove this") can still be
    /// resolved, and doesn't come back when the text does.
    @Test func aSentOrphanCanBeResolved() async throws {
        let store = try makeStore()
        let document = try await makeDocument(store)
        let sent = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "remove this", color: .blue)
        let draft = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "draft", color: .blue)
        _ = try await store.recordSend(transport: "tmux", targetJSON: "{}", packetText: "p", noteIDs: [sent.id], outcome: .delivered)
        for id in [sent.id, draft.id] { try await store.markOrphaned(id) }
        #expect(try await store.sentOrphanIDs() == [sent.id])
        try await store.resolve(sent.id, outcome: .done, message: "Removed.")
        #expect(try await store.note(sent.id)?.state == .resolved)
        #expect(try await store.sentOrphanIDs().isEmpty)
        // Taken back, it is an orphan again (its text is still gone), never a draft drawn on other text.
        try await store.reopen(sent.id)
        #expect(try await store.note(sent.id)?.state == .orphaned)
        // Only a note sent when its text went is the agent's to resolve.
        await #expect(throws: NoteStoreError.illegalTransition(from: .draft, to: .resolved)) { try await store.resolveSent(sent.id) }
        try await store.resolve(sent.id)
        try await store.recoverOrphan(sent.id, anchor: .wholeFile)
        #expect(try await store.note(sent.id)?.state == .resolved)
        // The user may resolve an orphaned draft by hand too.
        try await store.resolve(draft.id)
        #expect(try await store.note(draft.id)?.state == .resolved)
        // Errors read as words, since agents see them.
        #expect(NoteStoreError.illegalTransition(from: .resolved, to: .resolved).localizedDescription == "The note is already resolved.")
    }

    /// Issue #4: an agent's question arrives as a sent note waiting on the user, whose thread opens with the question;
    /// the answer is a follow-up that goes back only on Send; a document takes a bounded number of them.
    @Test func anAgentQuestionIsAnsweredWithAFollowUp() async throws {
        let store = try makeStore()
        let document = try await makeDocument(store)
        let anchor = Anchor.text(TextAnchor(start: .init(line: 3, col: 1), end: .init(line: 4, col: 2), text: "t", before: "", after: ""))
        let asked = try await store.askUser(documentID: document.id, anchor: anchor, question: "Is the 15 minute TTL right?", author: "claude")
        #expect(asked.state == .sent && asked.waitingOnUser && asked.needsAttention && asked.resolveOutcome == nil)
        #expect(asked.author == "claude" && asked.body.isEmpty && asked.anchor == anchor)
        let question = try #require(try await store.messages(for: asked.id).first)
        #expect(question.kind == .question && question.author == .agent("claude") && question.body == "Is the 15 minute TTL right?" && question.isSent)
        try await store.addFollowUp(asked.id, body: "Yes, keep it.")
        let answered = try #require(try await store.note(asked.id))
        #expect(answered.state == .sent && answered.waitingOnUser && answered.hasUnsentFollowUps, "waiting until the answer is sent")
        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "p", noteIDs: [asked.id], outcome: .delivered)
        let sent = try #require(try await store.note(asked.id))
        #expect(sent.state == .sent && !sent.waitingOnUser && !sent.hasUnsentFollowUps)

        for n in 0..<(NoteStore.agentQuestionLimit - 1) {
            _ = try await store.askUser(documentID: document.id, anchor: .wholeFile, question: "q\(n)", author: "codex")
        }
        _ = try await store.askUser(documentID: document.id, anchor: .wholeFile, question: "last one that fits", author: "codex")
        await #expect(throws: NoteStoreError.tooManyQuestions(NoteStore.agentQuestionLimit)) {
            _ = try await store.askUser(documentID: document.id, anchor: .wholeFile, question: "one too many", author: "codex")
        }
    }

    /// Issue #13: a sent note goes back to a draft, keeping its send history.
    @Test func aSentNoteCanBeUnsent() async throws {
        let store = try makeStore()
        let document = try await makeDocument(store)
        let note = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "b", color: .blue)
        _ = try await store.recordSend(transport: "tmux", targetJSON: "{}", packetText: "p", noteIDs: [note.id], outcome: .delivered)
        try await store.unsend(note.id)
        #expect(try await store.note(note.id)?.state == .draft)
        #expect(try await store.sends(for: note.id).count == 1, "it was sent: the history stays")
        await #expect(throws: NoteStoreError.illegalTransition(from: .draft, to: .draft)) { try await store.unsend(note.id) }
    }

    /// Issue #14: an edit made in a card is saved only over the comment it started from.
    @Test func anEditNeverOverwritesAChangedComment() async throws {
        let store = try makeStore()
        let document = try await makeDocument(store)
        let note = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "first", color: .blue)
        #expect(try await store.updateBody(note.id, body: "edited", color: .pink, ifBodyIs: "first"))
        let edited = try await store.note(note.id)
        #expect(edited?.body == "edited" && edited?.color == .pink)
        let stale = try await store.updateBody(note.id, body: "stale", color: .green, ifBodyIs: "first")
        #expect(!stale, "the comment changed meanwhile")
        #expect(try await store.note(note.id)?.body == "edited")
    }

    @Test func failedSendLeavesDrafts() async throws {
        let store = try makeStore()
        let document = try await makeDocument(store)
        let note = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "a", color: .blue)
        _ = try await store.recordSend(transport: "herdr", targetJSON: "{}", packetText: "p", noteIDs: [note.id], outcome: .failed("agent blocked"))
        #expect(try await store.note(note.id)?.state == .draft)
        #expect(try await store.lastSend(for: note.id)?.outcome == "failed: agent blocked")
        let later = Date().addingTimeInterval(60)
        _ = try await store.recordSend(transport: "tmux", targetJSON: #"{"t":1}"#, packetText: "p2", noteIDs: [note.id], outcome: .delivered, at: later)
        let other = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "b", color: .blue)
        _ = try await store.recordSend(transport: "herdr", targetJSON: "{}", packetText: "p3", noteIDs: [other.id], outcome: .delivered, at: later.addingTimeInterval(60))
        let last = try #require(try await store.lastSend(for: note.id))
        #expect(last.transport == "tmux" && last.outcome == "delivered" && last.targetJSON == #"{"t":1}"#, "the newest send of this note, not of another")
        #expect(abs(last.sentAt.timeIntervalSince(later)) < 1)
        #expect(try await store.sends(for: note.id).count == 2)
    }

    @Test func pathPrefixMatchesNonASCIIDirectories() async throws {
        let store = try makeStore()
        let accented = try await store.upsertDocument(hostID: .local, path: "/Users/c/Café Notes/plan.md", kind: .markdown, fingerprint: Fingerprint())
        let emoji = try await store.upsertDocument(hostID: .local, path: "/Users/c/🚀 launch/a.txt", kind: .text, fingerprint: Fingerprint())
        let sibling = try await store.upsertDocument(hostID: .local, path: "/Users/c/Café Notes2/x.md", kind: .markdown, fingerprint: Fingerprint())
        _ = try await store.createNote(documentID: accented.id, anchor: .wholeFile, body: "a", color: .yellow)
        _ = try await store.createNote(documentID: emoji.id, anchor: .wholeFile, body: "b", color: .yellow)
        _ = try await store.createNote(documentID: sibling.id, anchor: .wholeFile, body: "c", color: .yellow)
        #expect(try await store.pendingNotes(pathPrefix: "/Users/c/Café Notes").map(\.note.body) == ["a"])
        #expect(try await store.pendingNotes(pathPrefix: "/Users/c/🚀 launch/").map(\.note.body) == ["b"])
        #expect(try await store.pendingNotes(pathPrefix: "/Users/c/Café Notes/plan.md").map(\.note.body) == ["a"], "an exact file still matches")
    }

    @Test func pendingNotesFilterByHostAndPathPrefix() async throws {
        let store = try makeStore()
        let asus = try await store.upsertHost(name: "asus", kind: .ssh)
        let localDocument = try await makeDocument(store, path: "/Users/colin/proj/a.md")
        let remoteDocument = try await store.upsertDocument(hostID: asus.id, path: "/home/colin/proj/b.md", kind: .markdown, fingerprint: Fingerprint())
        let remoteOther = try await store.upsertDocument(hostID: asus.id, path: "/home/colin/proj_2/c.md", kind: .markdown, fingerprint: Fingerprint())
        let local = try await store.createNote(documentID: localDocument.id, anchor: .wholeFile, body: "l", color: .yellow)
        let remote = try await store.createNote(documentID: remoteDocument.id, anchor: .wholeFile, body: "r", color: .yellow)
        let other = try await store.createNote(documentID: remoteOther.id, anchor: .wholeFile, body: "o", color: .yellow)
        let resolved = try await store.createNote(documentID: remoteDocument.id, anchor: .wholeFile, body: "done", color: .yellow)
        try await store.resolve(resolved.id)

        let all = try await store.pendingNotes()
        #expect(Set(all.map(\.note.id)) == [local.id, remote.id, other.id])
        let onAsus = try await store.pendingNotes(hostID: asus.id)
        #expect(Set(onAsus.map(\.note.id)) == [remote.id, other.id])
        let inProj = try await store.pendingNotes(hostID: asus.id, pathPrefix: "/home/colin/proj")
        #expect(inProj.map(\.note.id) == [remote.id], "the LIKE prefix must not match proj_2")
        let oneFile = try await store.pendingNotes(pathPrefix: "/Users/colin/proj/a.md")
        #expect(oneFile.map(\.note.id) == [local.id])
    }

    @Test func notesSortInReadingOrder() async throws {
        let store = try makeStore()
        let document = try await makeDocument(store)
        func text(_ line: Int) -> Anchor {
            .text(TextAnchor(start: .init(line: line, col: 1), end: .init(line: line, col: 2), text: "", before: "", after: ""))
        }
        let whole = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "w", color: .pink)
        let line9 = try await store.createNote(documentID: document.id, anchor: text(9), body: "9", color: .pink)
        let line2 = try await store.createNote(documentID: document.id, anchor: text(2), body: "2", color: .pink)
        #expect(try await store.notes(for: document.id).map(\.id) == [line2.id, line9.id, whole.id])
        let grouped = try await store.documentsWithNotes()
        #expect(grouped.count == 1)
        #expect(grouped.first?.notes.map(\.id) == [line2.id, line9.id, whole.id])
    }

    @Test func observationEmitsOnChange() async throws {
        let store = try makeStore()
        let document = try await makeDocument(store)
        var iterator = store.observeNotes(for: document.id).makeAsyncIterator()
        let initial = try await iterator.next()
        #expect(initial == [])
        let note = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "n", color: .orange)
        let afterInsert = try await iterator.next()
        #expect(afterInsert?.map(\.id) == [note.id])
    }

    @Test func webPagesAreRecordedTitledPinnedAndRemoved() async throws {
        let store = try makeStore()
        let at = { (seconds: Double) in Date(timeIntervalSince1970: seconds) }
        try await store.recordWebPageVisit(url: "https://example.com/", hostID: .web, at: at(1))
        try await store.recordWebPageVisit(url: "http://localhost:3000/", hostID: .web, title: "Here", at: at(2))
        let remote = try await store.upsertHost(name: "box", kind: .ssh)
        try await store.recordWebPageVisit(url: "http://localhost:3000/", hostID: remote.id, at: at(3))
        #expect(try await store.webPages().map(\.hostID) == [remote.id, .web, .web], "the same address on two hosts is two pages, newest first")

        // A visit without a title keeps the one known; a title arriving later fills it in.
        try await store.recordWebPageVisit(url: "http://localhost:3000/", hostID: .web, at: at(4))
        try await store.setWebPageTitle(url: "https://example.com/", hostID: .web, title: "Example")
        try await store.setWebPageTitle(url: "https://nowhere.example/", hostID: .web, title: "Never visited")
        var pages = try await store.webPages()
        #expect(pages.map(\.url) == ["http://localhost:3000/", "http://localhost:3000/", "https://example.com/"])
        #expect(pages.map(\.title) == ["Here", nil, "Example"])

        // Pinned pages come first whatever their age.
        try await store.setWebPagePinned(url: "https://example.com/", hostID: .web, true)
        pages = try await store.webPages()
        #expect(pages.first?.url == "https://example.com/" && pages.first?.pinned == true)
        try await store.recordWebPageVisit(url: "https://example.com/", hostID: .web, at: at(5))
        #expect(try await store.webPages().first?.pinned == true, "a visit keeps the pin")

        try await store.removeWebPage(url: "http://localhost:3000/", hostID: remote.id)
        #expect(try await store.webPages().count == 2)
        // Removing the host removes the pages reached through it.
        try await store.recordWebPageVisit(url: "http://localhost:8080/", hostID: remote.id, at: at(6))
        try await store.deleteHost(remote.id)
        #expect(try await store.webPages().allSatisfy { $0.hostID == .web })
    }

    @Test func recentWebPagesAreCappedButPinnedOnesKept() async throws {
        let store = try makeStore()
        try await store.recordWebPageVisit(url: "https://pinned.example/", hostID: .web, at: Date(timeIntervalSince1970: 0))
        try await store.setWebPagePinned(url: "https://pinned.example/", hostID: .web, true)
        let total = NoteStore.maximumRecentWebPages + 5
        for index in 1...total {
            try await store.recordWebPageVisit(url: "https://example.com/\(index)", hostID: .web, at: Date(timeIntervalSince1970: Double(index)))
        }
        let pages = try await store.webPages()
        #expect(pages.count == NoteStore.maximumRecentWebPages + 1)
        #expect(pages.first?.url == "https://pinned.example/", "the oldest page survives because it is pinned")
        #expect(pages.dropFirst().first?.url == "https://example.com/\(total)")
        #expect(!pages.contains { $0.url == "https://example.com/5" } && pages.contains { $0.url == "https://example.com/6" }, "the oldest unpinned ones went")
    }

    @Test func rootsTargetsStagedFilesAndSettings() async throws {
        let store = try makeStore()
        let root = try await store.recordRootOpened(hostID: .local, path: "/tmp/proj", at: Date(timeIntervalSince1970: 5))
        let again = try await store.recordRootOpened(hostID: .local, path: "/tmp/proj", at: Date(timeIntervalSince1970: 9))
        #expect(root.id == again.id)
        try await store.setRootPinned(root.id, true)
        #expect(try await store.roots(for: .local).first?.pinned == true)
        let box = try await store.saveHost(id: nil, name: "box", options: HostOptions(hostName: "box.example"))
        let remote = try await store.recordRootOpened(hostID: box.id, path: "/srv/app", at: Date(timeIntervalSince1970: 7))
        _ = try await store.recordRootOpened(hostID: box.id, path: "/srv/other", at: Date(timeIntervalSince1970: 8))
        try await store.setRootPinned(remote.id, true)
        #expect(try await store.pinnedRoots().map(\.path) == ["/tmp/proj", "/srv/app"], "every host's favorites, the most recently opened first")

        let target = try await store.upsertTarget(hostID: .local, transport: "herdr", identityJSON: #"{"pane_id":"w1:p1"}"#, label: "claude w1:p1")
        let sameTarget = try await store.upsertTarget(hostID: .local, transport: "herdr", identityJSON: #"{"pane_id":"w1:p1"}"#, label: "claude · w1:p1", usedAt: Date())
        #expect(target.id == sameTarget.id)
        #expect(try await store.targets(transport: "herdr").map(\.label) == ["claude · w1:p1"])
        // The same pane under a new agent name, its keys in another order: still the one row, holding the newest JSON.
        let renamed = try await store.upsertTarget(hostID: .local, transport: "tmux", identityJSON: #"{"target":"%3","command":"node","cwd":"/a"}"#, label: "node")
        let moved = try await store.upsertTarget(hostID: .local, transport: "tmux", identityJSON: #"{"cwd":"/b","target":"%3","command":"claude"}"#, label: "claude")
        #expect(renamed.id == moved.id, "a tmux pane is its target, whatever runs in it")
        #expect(try await store.targets(transport: "tmux").map(\.identityJSON) == [#"{"cwd":"/b","target":"%3","command":"claude"}"#])
        _ = try await store.upsertTarget(hostID: .local, transport: "tmux", identityJSON: #"{"target":"%4"}"#, label: "other")
        #expect(try await store.targets(transport: "tmux").count == 2, "another pane is another target")

        let sendID = try await store.recordSend(transport: "herdr", targetJSON: "{}", packetText: "p", noteIDs: [], outcome: .delivered)
        try await store.recordStagedFiles(sendID: sendID, hostID: .local, remotePaths: ["/tmp/gloss/x/a.png"], expiresAt: Date(timeIntervalSince1970: 100))
        let expired = try await store.expiredStagedFiles(now: Date(timeIntervalSince1970: 101))
        #expect(expired.map(\.remotePath) == ["/tmp/gloss/x/a.png"])
        #expect(try await store.expiredStagedFiles(now: Date(timeIntervalSince1970: 99)).isEmpty)
        try await store.deleteStagedFiles(expired.map(\.id))
        #expect(try await store.expiredStagedFiles(now: Date(timeIntervalSince1970: 101)).isEmpty)

        try await store.setSetting("lastTarget:r1", "t_x")
        #expect(try await store.setting("lastTarget:r1") == "t_x")
        try await store.setSetting("lastTarget:r1", nil)
        #expect(try await store.setting("lastTarget:r1") == nil)
    }

    @Test func prefixFilterIsLiteralAndCaseSensitive() async throws {
        let store = try makeStore()
        let underscore = try await store.upsertDocument(hostID: .local, path: "/home/colin/my_proj/a.md", kind: .markdown, fingerprint: Fingerprint())
        let upper = try await store.upsertDocument(hostID: .local, path: "/home/colin/MY_PROJ/b.md", kind: .markdown, fingerprint: Fingerprint())
        let note = try await store.createNote(documentID: underscore.id, anchor: .wholeFile, body: "u", color: .yellow)
        _ = try await store.createNote(documentID: upper.id, anchor: .wholeFile, body: "U", color: .yellow)
        #expect(try await store.pendingNotes(pathPrefix: "/home/colin/my_proj").map(\.note.id) == [note.id])
        #expect(try await store.pendingNotes(pathPrefix: "/home/colin/my_pro").isEmpty, "a prefix must end at a path component")
    }

    @Test func resolveStoresOutcomeAndMessage() async throws {
        let store = try makeStore()
        let document = try await makeDocument(store)
        let note = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "q", color: .blue)
        try await store.resolve(note.id, outcome: .done, message: "Shortened it.")
        let resolved = try #require(try await store.note(note.id))
        #expect(resolved.state == .resolved)
        #expect(resolved.resolveOutcome == .done)
        #expect(resolved.resolveMessage == "Shortened it.")
    }

    /// `needs_input` from an agent with older instructions is a question: the note stays open, waiting on the user.
    @Test func needsInputAsksInsteadOfResolving() async throws {
        let store = try makeStore()
        let document = try await makeDocument(store)
        let note = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "q", color: .blue)
        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "p", noteIDs: [note.id], outcome: .delivered)
        try await store.resolveSent(note.id, outcome: .needsInput, message: "Which TTL?", agent: "codex")
        let asked = try #require(try await store.note(note.id))
        #expect(asked.state == .sent && asked.waitingOnUser && asked.resolveOutcome == nil)
        #expect(try await store.messages(for: note.id).map(\.kind) == [.question])
    }
}

struct NoteUndoTests {
    @Test func aDeletedNoteComesBackWithItsAttachmentsAndSends() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let document = try await store.upsertDocument(hostID: .local, path: "/tmp/undo.md", kind: .markdown, fingerprint: Fingerprint(mtime: Date(timeIntervalSince1970: 1), size: 1, hash: "h"))
        let note = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "keep me", color: .pink)
        _ = try await store.addAttachment(noteID: note.id, kind: .crop, localPath: "/tmp/crop.png", width: 10, height: 10)
        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "p", noteIDs: [note.id], outcome: .delivered)

        let deleted = try #require(try await store.deleteNoteForUndo(note.id))
        #expect(try await store.attachments(for: note.id).isEmpty)
        #expect(try await store.lastSend(for: note.id) == nil)

        try await store.restore(deleted)
        let notes = try await store.documentsWithNotes().flatMap(\.notes)
        #expect(notes.map(\.id) == [note.id])
        #expect(notes.first?.body == "keep me" && notes.first?.color == .pink)
        #expect(try await store.attachments(for: note.id).count == 1)
        #expect(try await store.lastSend(for: note.id) != nil)
    }

    @Test func undoBringsTheThreadBack() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let document = try await store.upsertDocument(hostID: .local, path: "/tmp/undo.md", kind: .markdown, fingerprint: Fingerprint())
        let note = try await store.askUser(documentID: document.id, anchor: .wholeFile, question: "Which one?", author: "claude")
        try await store.addFollowUp(note.id, body: "The first.")
        let before = try await store.messages(for: note.id)
        let deleted = try #require(try await store.deleteNoteForUndo(note.id))
        #expect(try await store.messages(for: note.id).isEmpty)
        try await store.restore(deleted)
        #expect(try await store.messages(for: note.id) == before)
        #expect(try await store.note(note.id)?.hasUnsentFollowUps == true)
    }
}

struct RelocateDocumentTests {
    @Test func notesFollowAMovedDocument() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let old = try await store.upsertDocument(hostID: .atlassian, path: "/confluence/ENG/101/Old name.md", kind: .markdown, fingerprint: Fingerprint())
        let note = try await store.createNote(documentID: old.id, anchor: .wholeFile, body: "keep me", color: .yellow)
        try await store.relocateDocument(hostID: .atlassian, from: old.path, to: "/confluence/ENG/100/101/New name.md")
        let moved = try #require(try await store.document(hostID: .atlassian, path: "/confluence/ENG/100/101/New name.md"))
        #expect(moved.id == old.id, "the row moves when nothing is at the new path")
        #expect(try await store.note(note.id)?.documentID == old.id)

        // When the new path already has a row (opened there before), the notes join it.
        let elsewhere = try await store.upsertDocument(hostID: .atlassian, path: "/confluence/ENG/101/Older.md", kind: .markdown, fingerprint: Fingerprint())
        let second = try await store.createNote(documentID: elsewhere.id, anchor: .wholeFile, body: "me too", color: .blue)
        try await store.relocateDocument(hostID: .atlassian, from: elsewhere.path, to: moved.path)
        #expect(try await store.note(second.id)?.documentID == moved.id)
        #expect(try await store.document(hostID: .atlassian, path: "/confluence/ENG/101/Older.md") == nil)
    }
}
