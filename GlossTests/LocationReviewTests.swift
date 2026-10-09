import Core
import Foundation
import GRDB
import Testing
import Viewers
@testable import Gloss

@MainActor struct LocationReviewTests {
    private func wait(_ condition: () -> Bool) async {
        for _ in 0..<150 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Timed out waiting for review state")
    }

    @Test func switchingLocationsHidesOldNotesAndKeepsGlobalMarkers() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        for path in ["/Context/README.md", "/Playground/a.md", "/Playground/sub/b.md", "/Playground-other/c.md"] {
            let doc = try await store.upsertDocument(hostID: .local, path: path, kind: .markdown, fingerprint: Fingerprint())
            _ = try await store.createNote(documentID: doc.id, anchor: .wholeFile, body: path, color: .yellow)
        }
        let panel = NotesPanelModel(noteStore: store)
        panel.setLocation(NotesLocation(hostID: .local, path: "/Context"))
        panel.start()
        defer { panel.stop() }
        await wait { panel.allGroups.count == 4 }
        #expect(panel.groups.map(\.document.path) == ["/Context/README.md"])
        panel.selection = Set(panel.groups.flatMap { $0.notes.map(\.id) })
        panel.setLocation(NotesLocation(hostID: .local, path: "/Playground"))
        #expect(panel.groups.map(\.document.path) == ["/Playground/a.md", "/Playground/sub/b.md"])
        #expect(panel.selection.isEmpty)
        #expect(panel.count(for: .all) == 2)
        #expect(panel.allGroups.count == 4)
        panel.setLocation(NotesLocation(hostID: .local, path: "/Context"))
        #expect(panel.groups.first?.document.fileName == "README.md")
        panel.setLocation(nil)
        #expect(panel.groups.isEmpty)
    }

    @Test func locationMatchesHostAliasesAndWholePathComponents() {
        let location = NotesLocation(hostID: .local, path: "/tmp/review")
        #expect(location.contains(hostID: .local, path: "/private/tmp/review/sub/file"))
        #expect(!location.contains(hostID: .local, path: "/tmp/reviewer/file"))
        #expect(!location.contains(hostID: HostID(rawValue: "other"), path: "/tmp/review/file"))
        let page = NotesLocation(hostID: .web, path: "https://example.com/a", exactDocument: true)
        #expect(!page.contains(hostID: .web, path: "https://example.com/a/b"))
    }

    @Test func anEmptyCurrentIterationKeepsHistoryInItsLocation() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let doc = try await store.upsertDocument(hostID: .local, path: "/review/a.md", kind: .markdown, fingerprint: Fingerprint())
        _ = try await store.createNote(documentID: doc.id, anchor: .wholeFile, body: "old", color: .yellow)
        try await store.startIteration(documentID: doc.id, openNotes: .leave, snapshot: Data())
        let panel = NotesPanelModel(noteStore: store)
        panel.setLocation(NotesLocation(hostID: .local, path: "/review"))
        panel.start()
        defer { panel.stop() }
        await wait { panel.visibleGroups.count == 1 }
        #expect(panel.visibleGroups.first?.notes.isEmpty == true)
        panel.showIteration(0, of: try #require(try await store.document(doc.id)))
        await wait { panel.visibleGroups.first?.notes.count == 1 }
        panel.setLocation(NotesLocation(hostID: .local, path: "/elsewhere"))
        #expect(panel.groups.isEmpty && panel.viewedIteration == nil)
    }

    @Test func fileNameErrorsPreserveTypedInputAndAllowRetry() async {
        var names: [String] = []
        let request = FileNameRequest(title: "Create", actionTitle: "Create", name: "existing", directory: "/tmp") { name in
            names.append(name)
            if name == "existing" { throw FileSystemError.alreadyExists(name) }
        }
        #expect(await request.submit() == false)
        #expect(request.name == "existing" && request.error != nil)
        request.name = ".."
        #expect(await request.submit() == false)
        #expect(names == ["existing"])
        request.name = "new"
        #expect(await request.submit())
    }
}

@MainActor struct RenameAndSendScopeTests {
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw FileSystemError.io("Timed out waiting for document")
    }

    @Test func renamingADirtyAnnotatedFolderKeepsTheSessionAndSavesAtTheNewPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-rename-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root + "/old", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let oldPath = root + "/old/a.txt", newPath = root + "/new/a.txt"
        try Data("original".utf8).write(to: URL(fileURLWithPath: oldPath))
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        await model.explorer.openRoot(hostID: .local, path: root)
        model.openDocument(hostID: .local, path: oldPath)
        let session = try #require(model.activeSession)
        try await wait { session.document != nil && session.textController != nil }
        let document = try #require(session.document), editor = try #require(session.textController)
        let note = try await model.noteStore.createNote(documentID: document.id, anchor: .wholeFile, body: "Review", color: .yellow)
        editor.viewDidProcessEdit(edit: NSRange(location: 0, length: 8), replacementLength: 5, newText: "dirty")
        editor.viewDidChangeText("dirty")
        try await wait { session.isDirty }
        #expect(session.isDirty)
        let move = DocumentRelocation(hostID: .local, from: root + "/old", to: root + "/new", directory: true)
        try await model.renameFile(move)
        #expect(model.activeSession === session && session.textController === editor)
        #expect(session.path == newPath && session.isDirty && editor.text == "dirty")
        #expect(try await model.noteStore.document(document.id)?.path == newPath)
        #expect(try await model.noteStore.note(note.id)?.documentID == document.id)
        await session.save()
        #expect(try String(contentsOfFile: newPath, encoding: .utf8) == "dirty")
        #expect(!FileManager.default.fileExists(atPath: oldPath))
        #expect(try await model.noteStore.pendingRelocation(hostID: .local) == nil)
        await model.shutDown()
    }

    @Test func locationSendRespectsFiltersAndNeverIncludesOldLocationOrOldIteration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-scope-\(UUID().uuidString)").path
        for dir in ["first", "second"] { try FileManager.default.createDirectory(atPath: root + "/" + dir, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(atPath: root) }
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        var docs: [Core.Document] = []
        for path in [root + "/first/readme.md", root + "/second/a.md", root + "/second/b.md"] {
            try Data("text".utf8).write(to: URL(fileURLWithPath: path))
            let doc = try await model.noteStore.upsertDocument(hostID: .local, path: path, kind: .markdown, fingerprint: Fingerprint())
            docs.append(doc)
            _ = try await model.noteStore.createNote(documentID: doc.id, anchor: .wholeFile, body: path, color: docs.count == 3 ? .blue : .yellow)
        }
        await model.explorer.openRoot(hostID: .local, path: root + "/first")
        model.openDocument(hostID: .local, path: docs[0].path)
        try await wait { model.notesPanel.groups.count == 1 && model.activeSession?.document != nil }
        await model.explorer.openRoot(hostID: .local, path: root + "/second")
        #expect(model.sendSelection(scope: .activeDocument).notes.isEmpty, "the old viewer does not expand the new location")
        #expect(model.sendSelection(scope: .all).notes.count == 2)
        model.notesPanel.colorFilter = [.blue]
        #expect(model.sendSelection(scope: .all).notes.map(\.documentID) == [docs[2].id])
        model.notesPanel.colorFilter = []
        try await model.noteStore.startIteration(documentID: docs[1].id, openNotes: .leave, snapshot: Data())
        try await wait { model.sendSelection(scope: .all).notes.count == 1 }
        #expect(model.sendSelection(scope: .all).notes.map(\.documentID) == [docs[2].id])
        await model.shutDown()
    }

    @Test func interruptedRenameIsRecoveredBeforeOpeningTheMovedDocument() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-recovery-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        let old = root + "/old.txt", new = root + "/new.txt"
        try Data("text".utf8).write(to: URL(fileURLWithPath: old))
        let doc = try await model.noteStore.upsertDocument(hostID: .local, path: old, kind: .text, fingerprint: Fingerprint())
        var move = DocumentRelocation(hostID: .local, from: old, to: new, directory: false)
        move.expectedFingerprint = try await LocalFileSystem().stat(old).fingerprint
        try await model.noteStore.prepareRelocation(move)
        try await LocalFileSystem().rename(old, to: new)
        await model.recoverRename(hostID: .local)
        #expect(try await model.noteStore.document(doc.id)?.path == new)
        #expect(try await model.noteStore.pendingRelocation(hostID: .local) == nil)
        model.openDocument(hostID: .local, path: new)
        try await wait { model.activeSession?.document != nil }
        #expect(model.activeSession?.document?.id == doc.id)
        await model.shutDown()
    }
}

extension RenameAndSendScopeTests {
    @Test func aMetadataFailureRollsTheFilesystemBackWithoutDetachingNotes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-rollback-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let old = root + "/old.txt", new = root + "/new.txt"
        try Data("keep".utf8).write(to: URL(fileURLWithPath: old))
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        let doc = try await model.noteStore.upsertDocument(hostID: .local, path: old, kind: .text, fingerprint: Fingerprint())
        try await model.database.queue.write { db in
            try db.execute(sql: "CREATE TRIGGER refuse_rename BEFORE UPDATE OF path ON document BEGIN SELECT RAISE(ABORT, 'simulated storage failure'); END")
        }
        await #expect(throws: (any Error).self) {
            try await model.renameFile(DocumentRelocation(hostID: .local, from: old, to: new, directory: false))
        }
        #expect(try String(contentsOfFile: old, encoding: .utf8) == "keep")
        #expect(!FileManager.default.fileExists(atPath: new))
        #expect(try await model.noteStore.document(doc.id)?.path == old)
        #expect(try await model.noteStore.pendingRelocation(hostID: .local) == nil)
        await model.shutDown()
    }
}

extension RenameAndSendScopeTests {
    @Test func aStandalonePageHasItsOwnScopeUntilAFolderIsSelectedAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-page-scope-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        await model.explorer.openRoot(hostID: .local, path: root)
        let tab = try #require(model.explorer.selectedTabID)
        model.openWebPage(try #require(URL(string: "https://example.com/review")))
        try await wait { model.activeSession?.document != nil }
        #expect(model.notesPanel.location?.exactDocument == true)
        #expect(model.notesPanel.location?.path == "https://example.com/review")
        model.explorer.selectedTabID = tab
        #expect(model.notesPanel.location?.exactDocument == false)
        #expect(model.notesPanel.location?.contains(hostID: .local, path: root + "/file") == true)
        #expect(model.sendSelection(scope: .activeDocument).notes.isEmpty)
        await model.shutDown()
    }
}

extension RenameAndSendScopeTests {
    @Test func explicitHistoricalCopyRemainsAvailableWithoutMakingItBulkSendable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-history-copy-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = root + "/note.txt"
        try Data("context".utf8).write(to: URL(fileURLWithPath: path))
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        await model.explorer.openRoot(hostID: .local, path: root)
        let document = try await model.noteStore.upsertDocument(hostID: .local, path: path, kind: .text, fingerprint: Fingerprint())
        let note = try await model.noteStore.createNote(documentID: document.id, anchor: .wholeFile, body: "Historical feedback", color: .yellow)
        try await model.noteStore.startIteration(documentID: document.id, openNotes: .leave, snapshot: Data())
        model.notesPanel.showIteration(0, of: try #require(try await model.noteStore.document(document.id)))
        try await wait { model.notesPanel.visibleGroups.flatMap(\.notes).count == 1 }
        var copied = ""
        model.send.writeClipboard = { copied = $0 }
        await model.copyPacket(noteIDs: [note.id])
        #expect(copied.contains("Historical feedback"))
        #expect(model.sendSelection(scope: .all).notes.isEmpty)
        #expect(try await model.noteStore.note(note.id)?.state == .draft)
        await model.shutDown()
    }
}

extension RenameAndSendScopeTests {
    /// Once the database names the new path, a change there since (an agent's edit) can't strand the rename.
    @Test func recoveryAfterTheMetadataMovedIgnoresLaterEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-applied-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        let old = root + "/old.txt", new = root + "/new.txt"
        try Data("text".utf8).write(to: URL(fileURLWithPath: old))
        let doc = try await model.noteStore.upsertDocument(hostID: .local, path: old, kind: .text, fingerprint: Fingerprint())
        var move = DocumentRelocation(hostID: .local, from: old, to: new, directory: false)
        move.expectedFingerprint = try await LocalFileSystem().stat(old).fingerprint
        move.expectedFingerprint?.hash = Data("text".utf8).sha256Hex
        try await model.noteStore.prepareRelocation(move)
        try await LocalFileSystem().rename(old, to: new)
        try await model.noteStore.applyRelocation(move)
        try Data("edited by an agent".utf8).write(to: URL(fileURLWithPath: new))
        #expect(await model.ensureConnected(.local))
        #expect(try await model.noteStore.pendingRelocation(hostID: .local) == nil)
        #expect(try await model.noteStore.document(doc.id)?.path == new)
        #expect(model.renameRecovery == nil)
        await model.shutDown()
    }

    /// A folder's mtime changes with what's in it, so a file added after the move doesn't block recovering it.
    @Test func aRenamedFolderRecoversAfterAFileIsAddedInside() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-folder-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root + "/old", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        try Data("text".utf8).write(to: URL(fileURLWithPath: root + "/old/a.txt"))
        let doc = try await model.noteStore.upsertDocument(hostID: .local, path: root + "/old/a.txt", kind: .text, fingerprint: Fingerprint())
        var move = DocumentRelocation(hostID: .local, from: root + "/old", to: root + "/new", directory: true)
        move.expectedFingerprint = try await LocalFileSystem().stat(root + "/old").fingerprint
        try await model.noteStore.prepareRelocation(move)
        try await LocalFileSystem().rename(root + "/old", to: root + "/new")
        try await Task.sleep(for: .milliseconds(20))
        try Data("new".utf8).write(to: URL(fileURLWithPath: root + "/new/b.txt"))
        #expect(await model.ensureConnected(.local))
        #expect(try await model.noteStore.document(doc.id)?.path == root + "/new/a.txt")
        #expect(try await model.noteStore.pendingRelocation(hostID: .local) == nil)
        await model.shutDown()
    }

    /// A note outside the location in front isn't offered to Send, and a send that is asked for anyway says why
    /// without recording a failed delivery.
    @Test func aSendOutsideTheLocationIsCancelledNotFailed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-outside-\(UUID().uuidString)").path
        for dir in ["here", "there"] { try FileManager.default.createDirectory(atPath: root + "/" + dir, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(atPath: root) }
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        let path = root + "/there/a.md"
        try Data("text".utf8).write(to: URL(fileURLWithPath: path))
        let doc = try await model.noteStore.upsertDocument(hostID: .local, path: path, kind: .markdown, fingerprint: Fingerprint())
        let note = try await model.noteStore.createNote(documentID: doc.id, anchor: .wholeFile, body: "elsewhere", color: .yellow)
        await model.explorer.openRoot(hostID: .local, path: root + "/here")
        model.choose(target: ClipboardTransport.target)
        model.send.writeClipboard = { _ in }
        #expect(!model.isInSendScope(note))
        await model.send(noteIDs: [note.id])
        let result = try #require(model.send.lastResult)
        #expect(result.cancelled && result.failure?.contains("isn't in") == true)
        #expect(try await model.noteStore.lastSend(for: note.id) == nil)
        #expect(try await model.noteStore.note(note.id)?.state == .draft)
        await model.shutDown()
    }
}
