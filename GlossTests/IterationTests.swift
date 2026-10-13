import Core
import Foundation
import GRDB
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
        #expect(NotesPanelModel.merged(live, past: DocumentNotes(document: a, notes: [])).map(\.document.path) == ["/a.md", "/c.md"],
                "an earlier iteration with no notes keeps its header")
        #expect(NotesPanelModel.merged(live, past: nil) == live)
    }

    /// The panel lists documents as the explorer lists files: case aside, numbers in order.
    @Test func thePanelListsDocumentsInTheExplorersOrder() {
        func group(_ path: String) -> DocumentNotes {
            DocumentNotes(document: Core.Document(id: .new(), hostID: .local, path: path, kind: .markdown, fingerprint: Fingerprint()), notes: [])
        }
        let byDatabase = ["/r/Sources/a.md", "/r/docs/file10.md", "/r/docs/file2.md"].map(group)
        #expect(NotesPanelModel.inPathOrder(byDatabase).map(\.document.path) == ["/r/docs/file2.md", "/r/docs/file10.md", "/r/Sources/a.md"])
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
        let (directory, path) = try makeFile("before\n")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (model, store, settings) = try makeModel()
        defer { model.stop() }
        #expect(settings.iteratesAfterResolved, "on by default")
        let document = try await store.upsertDocument(hostID: .local, path: path, kind: .markdown, fingerprint: Fingerprint())
        await model.prepareForNote(document.id)
        let first = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "a", color: .yellow)
        let last = try await store.askUser(documentID: document.id, anchor: .wholeFile, question: "Which?", author: "codex")
        model.observeResolutions()
        try "after\n".write(toFile: path, atomically: true, encoding: .utf8)
        try await store.resolve(first.id)
        await model.processCompletions()
        #expect(try await store.document(document.id)?.currentIteration == 0, "a question is still open")
        try await store.resolveSent(last.id, agent: "codex")
        await waitForIteration(1, document.id, store)
        #expect(try await store.notes(for: document.id).isEmpty, "no new note is needed")
        let ended = try #require(try await store.iterations(for: document.id).first)
        #expect(try await store.snapshot(hash: try #require(ended.snapshotHash)) == Data("after\n".utf8))
        await model.processCompletions()
        #expect(try await store.document(document.id)?.currentIteration == 1, "one transition, one rollover")
    }

    func waitForIteration(_ number: Int, _ documentID: DocumentID, _ store: NoteStore,
                          sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<100 {
            if (try? await store.document(documentID)?.currentIteration) == number { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("timed out waiting for iteration \(number)", sourceLocation: sourceLocation)
    }

    @Test func unchangedContentDoesNotStartAnIteration() async throws {
        let (directory, path) = try makeFile("same\n")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (model, store, _) = try makeModel()
        defer { model.stop() }
        let document = try await store.upsertDocument(hostID: .local, path: path, kind: .markdown, fingerprint: Fingerprint())
        await model.prepareForNote(document.id)
        let note = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "a", color: .yellow)
        try await store.resolve(note.id)
        await model.processCompletions()
        #expect(try await store.document(document.id)?.currentIteration == 0)
        #expect(try await store.pendingIterationCompletions().isEmpty)
        // A later edit is not a resolution transition, and must not resurrect the consumed completion.
        try "later\n".write(toFile: path, atomically: true, encoding: .utf8)
        await model.prepareForNote(document.id)
        let question = try await store.askUser(documentID: document.id, anchor: .wholeFile, question: "Keep?", author: "codex")
        #expect(question.iteration == 0)
        #expect(try await store.document(document.id)?.currentIteration == 0)
    }

    @Test func concurrentResolvesStartOnlyOneIteration() async throws {
        let (directory, path) = try makeFile("before\n")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (model, store, _) = try makeModel()
        defer { model.stop() }
        let document = try await store.upsertDocument(hostID: .local, path: path, kind: .markdown, fingerprint: Fingerprint())
        await model.prepareForNote(document.id)
        let a = try await store.askUser(documentID: document.id, anchor: .wholeFile, question: "A?", author: "codex")
        let b = try await store.askUser(documentID: document.id, anchor: .wholeFile, question: "B?", author: "codex")
        try "after\n".write(toFile: path, atomically: true, encoding: .utf8)
        model.observeResolutions()
        async let first: Void = store.resolveSent(a.id, agent: "codex")
        async let second: Void = store.resolveSent(b.id, agent: "codex")
        _ = try await (first, second)
        async let processA: Void = model.processCompletions()
        async let processB: Void = model.processCompletions()
        _ = await (processA, processB)
        #expect(try await store.document(document.id)?.currentIteration == 1)
        #expect(try await store.iterations(for: document.id).count == 2)
        #expect(try await store.pendingIterationCompletions().isEmpty)
    }

    @Test func carriedReviewResultsDoNotCompleteTheNewIteration() async throws {
        let (directory, path) = try makeFile("before\n")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (model, store, _) = try makeModel()
        defer { model.stop() }
        let document = try await store.upsertDocument(hostID: .local, path: path, kind: .markdown, fingerprint: Fingerprint())
        await model.prepareForNote(document.id)
        let note = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "a", color: .yellow)
        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "p", noteIDs: [note.id], outcome: .delivered, review: true)
        try "after\n".write(toFile: path, atomically: true, encoding: .utf8)
        try await store.resolveSent(note.id, agent: "codex")
        await model.processCompletions()
        #expect(try await store.note(note.id)?.iteration == 1)
        #expect(try await store.note(note.id)?.awaitsReview == true)
        try "later\n".write(toFile: path, atomically: true, encoding: .utf8)
        try await store.accept([note.id])
        await model.processCompletions()
        #expect(try await store.document(document.id)?.currentIteration == 1)
        await model.prepareForNote(document.id)
        let question = try await store.askUser(documentID: document.id, anchor: .wholeFile, question: "Next?", author: "codex")
        #expect(question.iteration == 1, "a later question joins the new round")
    }

    @Test func laterQuestionsAreSavedDuringCompletionThenCarriedForward() async throws {
        let (directory, path) = try makeFile("before\n")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (model, store, settings) = try makeModel()
        defer { model.stop() }
        let document = try await store.upsertDocument(hostID: .local, path: path, kind: .markdown, fingerprint: Fingerprint())
        await model.prepareForNote(document.id)
        let old = try await store.askUser(documentID: document.id, anchor: .wholeFile, question: "Old?", author: "codex")
        try "after\n".write(toFile: path, atomically: true, encoding: .utf8)
        try await store.resolveSent(old.id, agent: "codex")
        await model.prepareForNote(document.id)
        let next = try await store.askUser(documentID: document.id, anchor: .wholeFile, question: "Next?", author: "codex")
        #expect(next.iteration == 0, "insertion does not wait for completion")
        await model.processCompletions()
        #expect(try await store.note(next.id)?.iteration == 1, "the pending question comes into the next round")
        settings.iteratesAfterResolved = false
        try "disabled\n".write(toFile: path, atomically: true, encoding: .utf8)
        try await store.resolveSent(next.id, agent: "codex")
        await model.processCompletions()
        #expect(try await store.document(document.id)?.currentIteration == 1, "setting off suppresses rollover")
    }

    @Test func unsavedDocumentChangesDoNotDecideWhetherToRollOver() async throws {
        let (directory, path) = try makeFile("before\n")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (model, store, _) = try makeModel()
        defer { model.stop() }
        let session = DocumentSession(hostID: .local, path: path, fileSystem: LocalFileSystem(), noteStore: store)
        await session.open()
        defer { session.close() }
        let document = try #require(session.document)
        model.liveSession = { $0 == document.id ? session : nil }
        await model.prepareForNote(document.id)
        let note = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "a", color: .yellow)
        let editor = try #require(session.textController)
        editor.viewDidChangeText("unsaved\n")
        #expect(session.isDirty)
        try await store.resolve(note.id)
        await model.processCompletions()
        #expect(try await store.document(document.id)?.currentIteration == 0, "unsaved edits do not change the agent's file")
        #expect(try await store.pendingIterationCompletions().isEmpty)
        let next = try await model.createNote(documentID: document.id, anchor: .wholeFile, body: "next", color: .yellow)
        try "agent\n".write(toFile: path, atomically: true, encoding: .utf8)
        try await store.resolve(next.id)
        await model.processCompletions()
        #expect(try await store.document(document.id)?.currentIteration == 1, "the disk change now qualifies")
        let ended = try #require(try await store.iterations(for: document.id).first)
        #expect(try await store.snapshot(hash: try #require(ended.snapshotHash)) == Data("unsaved\n".utf8), "snapshot can show editor text")
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "agent\n", "rollover never saves the editor")
    }

    @Test func aStartingHashIsReadOnlyWhenNeeded() async throws {
        let (directory, path) = try makeFile("before\n")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (model, store, _) = try makeModel()
        defer { model.stop() }
        let counter = IterationReadCounter()
        let fileSystem = CountedIterationFiles(counter: counter)
        model.fileSystem = { $0 == .local ? fileSystem : nil }
        let document = try await store.upsertDocument(hostID: .local, path: path, kind: .markdown, fingerprint: Fingerprint())
        await model.prepareForNote(document.id)
        #expect(await counter.count == 1)
        _ = try await model.createNote(documentID: document.id, anchor: .wholeFile, body: "first", color: .yellow)
        _ = try await model.createNote(documentID: document.id, anchor: .wholeFile, body: "second", color: .yellow)
        #expect(await counter.count == 1, "adding more notes does not read the file")
        let legacy = try await store.upsertDocument(hostID: .local, path: path + ".legacy", kind: .markdown, fingerprint: Fingerprint())
        _ = try await store.createNote(documentID: legacy.id, anchor: .wholeFile, body: "old", color: .yellow)
        await model.prepareForNote(legacy.id)
        #expect(await counter.count == 1, "unknown baseline with live notes cannot be reconstructed by reading now")
    }

    @Test func pluginDraftsSaveWithoutAConnectedHost() async throws {
        let app = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        let host = try await app.noteStore.upsertHost(name: "offline", kind: .ssh)
        let id = try await app.createPluginDraft(hostID: host.id, path: "/tmp/demo.md", text: "remember this")
        let note = try #require(try await app.noteStore.note(id))
        #expect(note.body == "remember this" && note.state == .draft)
        await app.shutDown()
    }

    @Test func aFailedCompletionDoesNotBlockAnotherDocumentOrNewNotes() async throws {
        let (directory, path) = try makeFile("before\n")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let otherPath = path + ".other"
        try "before\n".write(toFile: otherPath, atomically: true, encoding: .utf8)
        let (model, store, _) = try makeModel()
        defer { model.stop() }
        let a = try await store.upsertDocument(hostID: .local, path: path, kind: .markdown, fingerprint: Fingerprint())
        let b = try await store.upsertDocument(hostID: .local, path: otherPath, kind: .markdown, fingerprint: Fingerprint())
        let noteA = try await model.createNote(documentID: a.id, anchor: .wholeFile, body: "a", color: .yellow)
        let noteB = try await model.createNote(documentID: b.id, anchor: .wholeFile, body: "b", color: .yellow)
        try "bad\n".write(toFile: path, atomically: true, encoding: .utf8)
        try "good\n".write(toFile: otherPath, atomically: true, encoding: .utf8)
        let badHash = Data("bad\n".utf8).sha256Hex
        try await store.database.queue.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_snapshot BEFORE INSERT ON snapshot WHEN NEW.hash = '\(badHash)' BEGIN SELECT RAISE(ABORT, 'test snapshot failure'); END")
        }
        try await store.resolve(noteA.id)
        try await store.resolve(noteB.id)
        await model.processCompletions()
        #expect(try await store.document(a.id)?.currentIteration == 0)
        #expect(try await store.document(b.id)?.currentIteration == 1)
        #expect(try await store.pendingIterationCompletions().isEmpty, "failed completion was handled")
        _ = try await model.createNote(documentID: a.id, anchor: .wholeFile, body: "still saves", color: .yellow)
        #expect(try await store.notes(for: a.id).count == 2)
    }

    @Test func answeringAQuestionKeepsItOpenUntilResolved() async throws {
        let (directory, path) = try makeFile("before\n")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (model, store, _) = try makeModel()
        defer { model.stop() }
        let document = try await store.upsertDocument(hostID: .local, path: path, kind: .markdown, fingerprint: Fingerprint())
        await model.prepareForNote(document.id)
        let question = try await store.askUser(documentID: document.id, anchor: .wholeFile, question: "Keep?", author: "codex")
        try await store.addFollowUp(question.id, body: "Yes")
        _ = try await store.recordSend(transport: "clipboard", targetJSON: "{}", packetText: "p", noteIDs: [question.id], outcome: .delivered)
        try "after\n".write(toFile: path, atomically: true, encoding: .utf8)
        await model.processCompletions()
        #expect(try await store.note(question.id)?.waitingOnUser == false)
        #expect(try await store.note(question.id)?.state == .sent)
        #expect(try await store.document(document.id)?.currentIteration == 0)
        try await store.resolveSent(question.id, agent: "codex")
        await model.processCompletions()
        #expect(try await store.document(document.id)?.currentIteration == 1)
    }

    @Test func aManualPromptDoesNotAdvanceARoundThatAlreadyCompleted() async throws {
        let (directory, path) = try makeFile("before\n")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (model, store, settings) = try makeModel()
        defer { model.stop() }
        settings.iterationOpenNotes = .ask
        let document = try await store.upsertDocument(hostID: .local, path: path, kind: .markdown, fingerprint: Fingerprint())
        let note = try await model.createNote(documentID: document.id, anchor: .wholeFile, body: "a", color: .yellow)
        await model.requestNewIteration(for: document)
        let prompt = try #require(model.prompt)
        try "after\n".write(toFile: path, atomically: true, encoding: .utf8)
        try await store.resolve(note.id)
        await model.processCompletions()
        #expect(try await store.document(document.id)?.currentIteration == 1)
        await model.answer(prompt, .carry, remember: false)
        #expect(try await store.document(document.id)?.currentIteration == 1, "automatic completion already satisfied the request")
    }

    /// Show Changes Since on a file being edited: the tints follow the edit instead of keeping their line numbers.
    @Test func changesFollowTypingWhileShown() async throws {
        let (directory, path) = try makeFile("one\ntwo\nthree\n")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (_, store, _) = try makeModel()
        let session = DocumentSession(hostID: .local, path: path, fileSystem: LocalFileSystem(deleteBehavior: .permanent), noteStore: store)
        await session.open()
        let controller = try #require(session.textController)
        session.showChanges(since: 0, snapshot: "one\ntwo\nthree\n")
        controller.viewDidChangeText("one\ntwo\nTHREE\n")
        await waitUntil { controller.lineChanges == LineChanges(added: [3...3]) }
        #expect(controller.lineChanges == LineChanges(added: [3...3]))
        // A line typed above the change moves its tint down with it.
        controller.viewDidChangeText("zero\none\ntwo\nTHREE\n")
        await waitUntil { controller.lineChanges == LineChanges(added: [1...1, 4...4]) }
        #expect(controller.lineChanges == LineChanges(added: [1...1, 4...4]))
        session.close()
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

    @Test func earlierNotesAreFoundAgainInTheFileAsItIs() async throws {
        let (directory, path) = try makeFile("alpha\nbeta\ngamma\ndelta\n")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (model, store, settings) = try makeModel()
        settings.iterationOpenNotes = .leave
        let session = DocumentSession(hostID: .local, path: path, fileSystem: LocalFileSystem(deleteBehavior: .permanent), noteStore: store)
        model.liveSession = { _ in session }
        await session.open()
        let document = try #require(session.document)
        func anchor(_ line: Int, _ text: String, before: String, after: String) -> Anchor {
            .text(TextAnchor(start: .init(line: line, col: 1), end: .init(line: line, col: text.count + 1), text: text, before: before, after: after, hash: nil))
        }
        let moved = try await store.createNote(documentID: document.id, anchor: anchor(2, "beta", before: "alpha", after: "gamma"), body: "moved", color: .blue)
        let gone = try await store.createNote(documentID: document.id, anchor: anchor(4, "delta", before: "gamma", after: ""), body: "gone", color: .yellow)
        _ = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "whole file", color: .green)
        await model.requestNewIteration(for: document)
        try "intro\nalpha\nbeta\ngamma\n".write(toFile: path, atomically: true, encoding: .utf8)
        await session.reloadFromDisk()
        await waitUntil { session.notes.isEmpty }

        session.showsEarlierNotes = true
        await waitUntil { !session.earlierNotes.isEmpty }
        #expect(session.earlierNotes.map(\.note.id) == [moved.id], "a removed line's note and a whole-file note aren't drawn")
        let text = try #require(session.textController?.text) as NSString
        #expect(text.substring(with: try #require(session.earlierNotes.first).range) == "beta")
        #expect(session.textController?.earlierMarks.map(\.id) == [moved.id])
        #expect(session.textController?.drawnHighlights.isEmpty == true, "earlier notes are not this iteration's notes")
        _ = gone

        session.showsEarlierNotes = false
        #expect(session.earlierNotes.isEmpty && session.textController?.earlierMarks.isEmpty == true)

        await model.view(0, for: session)
        let past = model.shownSession(for: session)
        past.showsEarlierNotes = true
        try await Task.sleep(for: .milliseconds(200))
        #expect(past.earlierNotes.isEmpty, "an earlier iteration on screen draws only its own notes")
        session.close()
    }

    /// The last commit is the named file's, a name with pattern characters in it read as written.
    @Test func theLastCommitIsTheNamedFilesOwn() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { return }
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-git-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: repo) }
        func git(_ arguments: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", repo, "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
        }
        try git("init", "-q")
        try "d".write(toFile: "\(repo)/d.md", atomically: true, encoding: .utf8)
        try git("add", "d.md")
        try git("commit", "-q", "-m", "d")
        try "draft".write(toFile: "\(repo)/[draft].md", atomically: true, encoding: .utf8)
        #expect(await IterationsModel.lastCommit(of: "\(repo)/d.md") != nil)
        #expect(await IterationsModel.lastCommit(of: "\(repo)/[draft].md") == nil, "never committed: not d.md's commit")
        #expect(await IterationsModel.lastCommit(of: "\(repo)/:memo.md") == nil)
    }
}

private actor IterationReadCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

private struct CountedIterationFiles: FileSystemProvider {
    let counter: IterationReadCounter
    let base = LocalFileSystem()
    var hostID: HostID { .local }
    func read(_ path: String) async throws -> Data { await counter.record(); return try await base.read(path) }
    func list(_ directory: String) async throws -> [DirectoryEntry] { try await base.list(directory) }
    func stat(_ path: String) async throws -> FileAttributes { try await base.stat(path) }
    func writeAtomically(_ data: Data, to path: String, preservingModeFrom original: FileAttributes?) async throws -> FileAttributes {
        try await base.writeAtomically(data, to: path, preservingModeFrom: original)
    }
    func makeDirectory(_ path: String) async throws { try await base.makeDirectory(path) }
    func rename(_ path: String, to newPath: String) async throws { try await base.rename(path, to: newPath) }
    func delete(_ path: String) async throws { try await base.delete(path) }
    func watch(_ path: String) -> AsyncStream<FileSystemEvent> { base.watch(path) }
}
