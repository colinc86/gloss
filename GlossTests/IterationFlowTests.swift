import Core
import Foundation
import Testing
import Viewers
@testable import Gloss

/// The iteration flow through the app model (issue #18 live checks): files keep reloading after an earlier iteration
/// was looked at, and a file named two ways (`/tmp/a`, `/private/tmp/a`) is one session with one set of notes.
@MainActor
struct IterationFlowTests {
    func waitUntil(_ condition: @escaping @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<250 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("timed out waiting", sourceLocation: sourceLocation)
    }

    /// A folder spelled without `/private` (as the tree stores `/tmp/x`), whose file events name `/private/…`.
    func makeFolder() throws -> String {
        let folder = ExplorerModel.aliasFree(FileManager.default.temporaryDirectory.appendingPathComponent("gloss-iterflow-\(UUID().uuidString)").path)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        #expect(folder.hasPrefix("/var/") || folder.hasPrefix("/tmp/"), "the test needs a folder under a /private link")
        return folder
    }

    func append(_ text: String, to path: String) throws {
        let handle = try #require(FileHandle(forWritingAtPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    @Test func anAppendReloadsAFileOpenedWithoutPrivate() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = "\(folder)/a.md"
        try "one\n".write(toFile: path, atomically: true, encoding: .utf8)
        let store = NoteStore(database: try AppDatabase.inMemory())
        let session = DocumentSession(hostID: .local, path: path, fileSystem: LocalFileSystem(), noteStore: store)
        await session.open()
        try await Task.sleep(for: .milliseconds(500))
        // Written in place, not renamed over: the event names `/private/var/…/a.md`.
        try append("two\n", to: path)
        await waitUntil { session.textController?.text == "one\ntwo\n" }
        session.close()
    }

    @Test func externalEditsKeepReloadingAfterLookingAtAnEarlierIteration() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let plan = "\(folder)/plan.md", diagrams = "\(folder)/diagrams.md"
        try "one\ntwo\nthree\n".write(toFile: plan, atomically: true, encoding: .utf8)
        try "alpha\nbeta\n".write(toFile: diagrams, atomically: true, encoding: .utf8)
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        model.notesPanel.start()

        // diagrams.md is first opened the way an agent names it, with its note made there.
        model.openDocument(hostID: .local, path: "/private" + diagrams)
        let other = try #require(model.activeSession)
        await waitUntil { other.document != nil && other.textController != nil }
        let otherDocument = try #require(other.document)
        let otherNote = try await model.noteStore.createNote(documentID: otherDocument.id, anchor: .text(TextAnchor(start: .init(line: 1, col: 1), end: .init(line: 1, col: 6), text: "alpha", before: "", after: "beta", hash: nil)), body: "d", color: .pink)
        await waitUntil { other.textController?.highlights.count == 1 }

        model.openDocument(hostID: .local, path: plan)
        let session = try #require(model.activeSession)
        await waitUntil { session.document != nil && session.textController != nil }
        let document = try #require(session.document)
        let kept = try await model.noteStore.createNote(documentID: document.id, anchor: .text(TextAnchor(start: .init(line: 2, col: 1), end: .init(line: 2, col: 4), text: "two", before: "one", after: "three", hash: nil)), body: "kept", color: .blue)
        let done = try await model.noteStore.createNote(documentID: document.id, anchor: .wholeFile, body: "done", color: .yellow)
        try await model.noteStore.resolve(done.id)
        await waitUntil { session.notes.count == 2 }

        await model.iterations.start(document, openNotes: .carry)
        try "one\nTWO\nthree\n".write(toFile: plan, atomically: true, encoding: .utf8)
        await waitUntil { session.textController?.text == "one\nTWO\nthree\n" }

        await model.iterations.view(0, for: session)
        let past = model.iterations.shownSession(for: session)
        #expect(past !== session && past.pastIteration == 0)
        await waitUntil { past.notes.map(\.id) == [done.id] }
        #expect(model.notesPanel.isPast(try #require(past.notes.first)), "its card is read-only")
        model.reveal(note: try #require(past.notes.first), in: try #require(past.document), select: false)
        await model.iterations.showChanges(since: 0, in: past)
        #expect(model.iterations.shownSession(for: session) === session)
        await model.iterations.view(0, for: session)
        await model.iterations.bringForward(done, in: document)
        model.iterations.backToCurrent(model.iterations.shownSession(for: session))
        #expect(model.activeSession === session && model.iterations.shownSession(for: session) === session)
        #expect(model.notesPanel.viewedIteration == nil)

        try append("four\n", to: plan)
        await waitUntil { session.textController?.text == "one\nTWO\nthree\nfour\n" }
        #expect(session.notes.contains { $0.id == kept.id }, "the carried note is still on the page")

        // The tree names diagrams.md without /private: the same session, its note and its iterations.
        model.openDocument(hostID: .local, path: diagrams)
        #expect(model.activeSession === other)
        try append("gamma\n", to: diagrams)
        await waitUntil { other.textController?.text == "alpha\nbeta\ngamma\n" }
        #expect(other.notes.map(\.id) == [otherNote.id])
        await waitUntil { other.textController?.highlights.count == 1 }
        #expect(try await model.noteStore.iterations(for: otherDocument.id).count == 1, "its header has its iteration menu")
        await model.shutDown()
    }

    /// A document's header in the notes panel shows an earlier iteration, opening the document first, and its menu
    /// starts the next one.
    @Test func aDocumentsHeaderShowsAndStartsIterations() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = "\(folder)/a.md"
        try "one\ntwo\n".write(toFile: path, atomically: true, encoding: .utf8)
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        model.notesPanel.start()
        let document = try await model.noteStore.upsertDocument(hostID: .local, path: path, kind: .markdown, fingerprint: Fingerprint())
        _ = try await model.noteStore.createNote(documentID: document.id, anchor: .wholeFile, body: "n", color: .yellow)
        model.settings.iterationOpenNotes = .leave
        model.newIteration(for: document)
        for _ in 0..<100 where (try? await model.noteStore.document(document.id))?.currentIteration != 1 { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(try await model.noteStore.document(document.id)?.currentIteration == 1, "it ends the iteration in progress")

        model.showIteration(0, of: document)
        await waitUntil { model.activeSession.map { model.iterations.shownSession(for: $0).pastIteration == 0 } ?? false }
        #expect(model.notesPanel.viewedIteration?.number == 0, "the header names the iteration shown")
        await model.shutDown()
    }

    /// Opened again under the other spelling (after a relaunch, from the tree), a file keeps the document row its
    /// notes were made on.
    @Test func aFileOpenedUnderItsOtherSpellingKeepsItsNotes() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = "\(folder)/a.md"
        try "one\n".write(toFile: path, atomically: true, encoding: .utf8)
        let store = NoteStore(database: try AppDatabase.inMemory())
        let document = try await store.upsertDocument(hostID: .local, path: "/private" + path, kind: .markdown, fingerprint: Fingerprint())
        let note = try await store.createNote(documentID: document.id, anchor: .wholeFile, body: "n", color: .yellow)
        let session = DocumentSession(hostID: .local, path: path, fileSystem: LocalFileSystem(), noteStore: store)
        await session.open()
        #expect(session.document?.id == document.id, "no second row for the same file")
        await waitUntil { session.notes.map(\.id) == [note.id] }
        #expect(try await store.document(hostID: .local, path: path) == nil)
        session.close()
        #expect(DocumentSession.spellings(of: "/tmp/x/a.md") == ["/tmp/x/a.md", "/tmp/x/a.md", "/private/tmp/x/a.md"])
        #expect(DocumentSession.spellings(of: "/Users/a/b.md") == ["/Users/a/b.md"])
    }
}
