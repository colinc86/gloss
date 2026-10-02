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

        try await store.markOrphaned(note.id)
        #expect(try await store.note(note.id)?.state == .orphaned)
        try await store.restoreDraft(note.id, anchor: .wholeFile)
        #expect(try await store.note(note.id)?.state == .draft)
        try await store.resolve(note.id)
        #expect(try await store.note(note.id)?.state == .resolved)
    }

    @Test func failedSendLeavesDrafts() async throws {
        let store = try makeStore()
        let document = try await makeDocument(store)
        let note = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "a", color: .blue)
        _ = try await store.recordSend(transport: "herdr", targetJSON: "{}", packetText: "p", noteIDs: [note.id], outcome: .failed("agent blocked"))
        #expect(try await store.note(note.id)?.state == .draft)
        #expect(try await store.lastSend(for: note.id)?.outcome == "failed: agent blocked")
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

    @Test func rootsTargetsStagedFilesAndSettings() async throws {
        let store = try makeStore()
        let root = try await store.recordRootOpened(hostID: .local, path: "/tmp/proj", at: Date(timeIntervalSince1970: 5))
        let again = try await store.recordRootOpened(hostID: .local, path: "/tmp/proj", at: Date(timeIntervalSince1970: 9))
        #expect(root.id == again.id)
        try await store.setRootPinned(root.id, true)
        #expect(try await store.roots(for: .local).first?.pinned == true)

        let target = try await store.upsertTarget(hostID: .local, transport: "herdr", identityJSON: #"{"pane_id":"w1:p1"}"#, label: "claude w1:p1")
        let sameTarget = try await store.upsertTarget(hostID: .local, transport: "herdr", identityJSON: #"{"pane_id":"w1:p1"}"#, label: "claude · w1:p1", usedAt: Date())
        #expect(target.id == sameTarget.id)
        #expect(try await store.targets(transport: "herdr").map(\.label) == ["claude · w1:p1"])

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
        try await store.resolve(note.id, outcome: .needsInput, message: "Which TTL?")
        let resolved = try #require(try await store.note(note.id))
        #expect(resolved.state == .resolved)
        #expect(resolved.resolveOutcome == .needsInput)
        #expect(resolved.resolveMessage == "Which TTL?")
    }
}
