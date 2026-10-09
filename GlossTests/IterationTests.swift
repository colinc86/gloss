import Core
import Foundation
import Testing
import Viewers
@testable import Gloss

/// Iterations (issue #18): starting one, asking about open notes, looking back at a snapshot, and changes since.
@MainActor
struct IterationTests {
    func makeFile(_ content: String) throws -> (String, String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-iterations-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = "\(directory)/doc.md"
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return (directory, path)
    }

    func makeModel() throws -> (IterationsModel, NoteStore, SettingsStore) {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let settings = SettingsStore(noteStore: store)
        let model = IterationsModel(noteStore: store, settings: settings)
        let local = LocalFileSystem()
        model.fileSystem = { $0 == .local ? local : nil }
        return (model, store, settings)
    }

    func waitUntil(_ condition: @escaping @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("timed out waiting", sourceLocation: sourceLocation)
    }

    @Test func changesSinceAnIterationAreTheLinesADiffTouched() {
        let old = "one\ntwo\nthree\nfour\n"
        let new = "one\nTWO\nthree\nfive\nsix\n"
        // Line 2 rewritten, line 4 replaced by two lines.
        #expect(IterationDiff.lineChanges(from: old, to: new) == LineChanges(added: [2...2, 4...5]))
        // A pure deletion marks the line after it.
        #expect(IterationDiff.lineChanges(from: "a\nb\nc\n", to: "a\nc\n") == LineChanges(deletions: [2]))
        #expect(IterationDiff.lineChanges(from: old, to: old).isEmpty)
        // CRLF files compare line for line too.
        #expect(IterationDiff.lineChanges(from: "a\r\nb\r\n", to: "a\r\nB\r\n") == LineChanges(added: [2...2]))
    }

    /// The header's menu of a document with no notes yet shows "Iteration 0" once its first note is made (it never
    /// appeared in the live check: its observation only started once there was something to show).
    @Test func aHeadersMenuAppearsWithTheFirstNote() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let document = try await store.upsertDocument(hostID: .local, path: "/tmp/proj/plan.md", kind: .markdown, fingerprint: Fingerprint())
        let state = DocumentIterations()
        let observing = Task { await state.observe(document.id, in: store) }
        defer { observing.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(state.label(viewing: nil) == nil, "no note, no menu")
        _ = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "n", color: .yellow)
        await waitUntil { state.label(viewing: nil) == "Iteration 0" }
        try await store.startIteration(documentID: document.id, openNotes: .carry, snapshot: nil)
        await waitUntil { state.label(viewing: nil) == "Iteration 1" }
        #expect(state.label(viewing: 0) == "Iteration 0", "an earlier iteration on screen is named")
    }

    @Test func thePanelListsTheViewedIterationInPlaceOfTheCurrentOne() {
        func document(_ path: String) -> Core.Document { Core.Document(id: .new(), hostID: .local, path: path, kind: .markdown, fingerprint: Fingerprint()) }
        func note(_ document: Core.Document, _ iteration: Int) -> Note {
            Note(id: .new(), documentID: document.id, anchor: .wholeFile, body: "x", state: .draft, color: .yellow, createdAt: Date(), updatedAt: Date(), iteration: iteration)
        }
        let a = document("/a.md"), b = document("/b.md"), c = document("/c.md")
        let live = [DocumentNotes(document: a, notes: [note(a, 1)]), DocumentNotes(document: c, notes: [note(c, 0)])]
        let past = DocumentNotes(document: b, notes: [note(b, 0)])
        #expect(NotesPanelModel.merged(live, past: past).map(\.document.path) == ["/a.md", "/b.md", "/c.md"], "in path order")
        let pastA = DocumentNotes(document: a, notes: [note(a, 0)])
        #expect(NotesPanelModel.merged(live, past: pastA).first?.notes.map(\.iteration) == [0], "in place of its current notes")
        #expect(NotesPanelModel.merged(live, past: DocumentNotes(document: a, notes: [])).map(\.document.path) == ["/c.md"])
        #expect(NotesPanelModel.merged(live, past: nil) == live)
    }

    @Test func theSnapshotProviderServesItsBytesReadOnly() async throws {
        let (directory, path) = try makeFile("now\n")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let snapshot = SnapshotFileSystem(base: LocalFileSystem(), path: path, data: Data("then\n".utf8), date: Date(timeIntervalSince1970: 9))
        #expect(try await snapshot.read(path) == Data("then\n".utf8))
        #expect(try await snapshot.stat(path).size == 5)
        await #expect(throws: FileSystemError.self) { _ = try await snapshot.writeAtomically(Data("x".utf8), to: path, preservingModeFrom: nil) }
        await #expect(throws: FileSystemError.self) { try await snapshot.delete(path) }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "now\n", "the file itself is untouched")
    }

    @Test func newIterationAsksAboutOpenNotesAsSettingsSays() async throws {
        let (directory, path) = try makeFile("one\ntwo\n")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (model, store, settings) = try makeModel()
        let document = try await store.upsertDocument(hostID: .local, path: path, kind: .markdown, fingerprint: Fingerprint())
        let open = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "open", color: .yellow)

        settings.iterationOpenNotes = .ask
        await model.requestNewIteration(for: document)
        let prompt = try #require(model.prompt, "an open note: asked")
        #expect(prompt.openCount == 1)
        #expect(try await store.document(document.id)?.currentIteration == 0, "nothing starts before the answer")
        await model.answer(prompt, .leave, remember: true)
        #expect(model.prompt == nil && settings.iterationOpenNotes == .leave, "Don't ask again remembers the choice")
        #expect(try await store.notes(for: document.id, iteration: 0).map(\.id) == [open.id])
        let ended = try #require(try await store.iterations(for: document.id).first)
        #expect(try await store.snapshot(hash: try #require(ended.snapshotHash)) == Data("one\ntwo\n".utf8), "the file as it was")

        // Remembered: no prompt; Bring Them Along carries the open note.
        _ = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "next", color: .blue)
        settings.iterationOpenNotes = .carry
        let current = try #require(try await store.document(document.id))
        await model.requestNewIteration(for: current)
        #expect(model.prompt == nil)
        #expect(try await store.document(document.id)?.currentIteration == 2)
        #expect(try await store.notes(for: document.id).map(\.body) == ["next"])
    }

    @Test func theFirstNoteAfterEverythingIsResolvedStartsAnIteration() async throws {
        let (model, store, settings) = try makeModel()
        let document = try await store.upsertDocument(hostID: .local, path: "/tmp/never-read.md", kind: .markdown, fingerprint: Fingerprint())
        let note = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "a", color: .yellow)
        settings.iteratesAfterResolved = true
        await model.startIfAllResolved(document.id)
        #expect(try await store.document(document.id)?.currentIteration == 0, "an open note: nothing starts")
        try await store.resolve(note.id)
        #expect(try await store.document(document.id)?.currentIteration == 0, "resolving alone never starts one")
        await model.startIfAllResolved(document.id)
        #expect(try await store.document(document.id)?.currentIteration == 1, "the next note's arrival does")
        await model.startIfAllResolved(document.id)
        #expect(try await store.document(document.id)?.currentIteration == 1, "an empty iteration doesn't start another")

        settings.iteratesAfterResolved = false
        let again = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "b", color: .yellow)
        try await store.resolve(again.id)
        await model.startIfAllResolved(document.id)
        #expect(try await store.document(document.id)?.currentIteration == 1, "off by default")
        #expect(IterationsModel.allResolved([]) == false)
    }

    @Test func anEarlierIterationOpensFromItsSnapshotWithItsNotes() async throws {
        let (directory, path) = try makeFile("one\ntwo\nthree\n")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (model, store, settings) = try makeModel()
        settings.iterationOpenNotes = .leave
        let session = DocumentSession(hostID: .local, path: path, fileSystem: LocalFileSystem(deleteBehavior: .permanent), noteStore: store)
        model.liveSession = { _ in session }
        var listed: [Int?] = []
        model.onViewedIterationChange = { _, number in listed.append(number) }
        await session.open()
        let document = try #require(session.document)
        let old = try await store.createNote(documentID: document.id, anchor: .text(TextAnchor(start: .init(line: 2, col: 1), end: .init(line: 2, col: 4), text: "two", before: "one", after: "three", hash: nil)), body: "b", color: .blue)
        await model.requestNewIteration(for: document)
        try "one\nTWO\nthree\nfour\n".write(toFile: path, atomically: true, encoding: .utf8)
        await session.reloadFromDisk()
        await waitUntil { session.notes.isEmpty }

        await model.view(0, for: session)
        let past = try #require(model.shownSession(for: session).pastIteration == 0 ? model.shownSession(for: session) : nil)
        #expect(listed == [0])
        await waitUntil { past.notes.map(\.id) == [old.id] }
        #expect(past.textController?.text == "one\ntwo\nthree\n", "the file as iteration 0 left it")
        #expect(past.isReadOnly && past.textController?.isEditable == false)
        #expect(past.selectionAffordanceRect == nil, "no notes are added to an earlier iteration")

        await model.showChanges(since: 0, in: past)
        #expect(model.shownSession(for: session) === session, "changes show on the file as it is")
        await waitUntil { session.textController?.lineChanges == LineChanges(added: [2...2, 4...4]) }
        #expect(session.changesSinceIteration == 0)
        await model.showChanges(since: nil, in: session)
        await waitUntil { session.textController?.lineChanges == nil }

        // Bring Forward copies the note into iteration 1, found again on the rewritten line's neighbours or left where it was.
        await model.bringForward(old, in: document)
        let copies = try await store.notes(for: document.id)
        #expect(copies.count == 1 && copies.first?.body == "b" && copies.first?.iteration == 1)
        #expect(try await store.notes(for: document.id, iteration: 0).map(\.id) == [old.id])
        session.close()
    }
}
