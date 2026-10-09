import Foundation
import Testing
@testable import Core

struct ReviewSafetyTests {
    @Test func exclusiveCreationNeverReplacesExistingEntries() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem()
        let file = root.appendingPathComponent("original").path
        try Data("keep me".utf8).write(to: URL(fileURLWithPath: file))
        let link = root.appendingPathComponent("dangling").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: root.appendingPathComponent("absent").path)
        for path in [file, root.path, link] {
            await #expect(throws: FileSystemError.alreadyExists(path)) { _ = try await fs.createFile(at: path) }
        }
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "keep me")
        let new = root.appendingPathComponent("new").path
        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<8 { group.addTask { (try? await fs.createFile(at: new)) != nil } }
            var count = 0
            for await success in group where success { count += 1 }
            return count
        }
        #expect(successes == 1)
        #expect(try await fs.stat(new).size == 0)
    }

    @Test func newFolderNeverAdoptsAnExistingEntry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = LocalFileSystem()
        let folder = root.appendingPathComponent("made").path
        try await fs.createDirectory(at: folder)
        await #expect(throws: FileSystemError.alreadyExists(folder)) { try await fs.createDirectory(at: folder) }
        let file = root.appendingPathComponent("file").path
        try Data().write(to: URL(fileURLWithPath: file))
        await #expect(throws: FileSystemError.alreadyExists(file)) { try await fs.createDirectory(at: file) }
    }

    /// A file whose only note was deleted leaves the panel; one whose current iteration is empty keeps its header.
    @Test func thePanelListsDocumentsWithReviewHistoryOnly() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let deleted = try await store.upsertDocument(hostID: .local, path: "/r/deleted.md", kind: .markdown, fingerprint: Fingerprint())
        let note = try await store.createNote(documentID: deleted.id, anchor: .wholeFile, body: "gone", color: .yellow)
        try await store.trashNotes([note.id])
        let emptied = try await store.upsertDocument(hostID: .local, path: "/r/emptied.md", kind: .markdown, fingerprint: Fingerprint())
        _ = try await store.createNote(documentID: emptied.id, anchor: .wholeFile, body: "left behind", color: .yellow)
        try await store.startIteration(documentID: emptied.id, openNotes: .leave, snapshot: Data())
        var stream = store.observeDocumentsWithNotes().makeAsyncIterator()
        let listed = try #require(try await stream.next())
        #expect(listed.map(\.document.path) == ["/r/emptied.md"])
        #expect(listed.first?.notes.isEmpty == true)
    }

    @Test func bringForwardPreservesAttachmentsAndBulkQueryExcludesHistory() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let doc = try await store.upsertDocument(hostID: .local, path: "/review/picture.png", kind: .image, fingerprint: Fingerprint())
        let note = try await store.createNote(documentID: doc.id, anchor: .wholeFile, body: "Contrast", color: .yellow)
        let attachment = try await store.addAttachment(noteID: note.id, kind: .crop, localPath: "/crops/original.png", width: 40, height: 30)
        try await store.startIteration(documentID: doc.id, openNotes: .leave, snapshot: Data([1, 2]))
        #expect(try await store.pendingNotes(currentIterationOnly: true).isEmpty)
        #expect(try await store.pendingNotes().count == 1, "historical MCP reads retain their semantics")
        let copy = try await store.bringForward(note.id, anchor: note.anchor, origin: "Brought forward from Iteration 0")
        let copied = try #require(try await store.attachments(for: copy.id).first)
        #expect(copied.id != attachment.id)
        #expect(copied.localPath == attachment.localPath)
        #expect(copied.width == 40 && copied.height == 30)
        #expect(try await store.pendingNotes(currentIterationOnly: true).map(\.note.id) == [copy.id])
        _ = try await store.deleteNote(note.id)
        #expect(try await store.allAttachmentPaths().contains(attachment.localPath))
    }

    @Test func renamePreservesIDsIterationsAndDescendantBoundaries() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let doc = try await store.upsertDocument(hostID: .local, path: "/review/old/a.md", kind: .markdown, fingerprint: Fingerprint())
        let neighbor = try await store.upsertDocument(hostID: .local, path: "/review/older/b.md", kind: .markdown, fingerprint: Fingerprint())
        let old = try await store.createNote(documentID: doc.id, anchor: .wholeFile, body: "first", color: .yellow)
        try await store.startIteration(documentID: doc.id, openNotes: .leave, snapshot: Data("snapshot".utf8))
        let current = try await store.createNote(documentID: doc.id, anchor: .wholeFile, body: "second", color: .blue)
        let move = DocumentRelocation(hostID: .local, from: "/review/old", to: "/review/new", directory: true)
        try await store.prepareRelocation(move)
        try await store.applyRelocation(move)
        try await store.applyRelocation(move)
        #expect(try await store.document(hostID: .local, path: "/review/new/a.md")?.id == doc.id)
        #expect(try await store.document(neighbor.id)?.path == "/review/older/b.md")
        #expect(try await store.note(old.id)?.iteration == 0)
        #expect(try await store.note(current.id)?.iteration == 1)
        #expect(try await store.iterations(for: doc.id).count == 2)
        #expect(try await store.pendingRelocation(hostID: .local) != nil)
        try await store.finishRelocation(move)
        #expect(try await store.pendingRelocation(hostID: .local) == nil)
    }

    @Test func renameRefusesToMergeExistingReviewHistory() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        for path in ["/a", "/b"] {
            let doc = try await store.upsertDocument(hostID: .local, path: path, kind: .text, fingerprint: Fingerprint())
            _ = try await store.createNote(documentID: doc.id, anchor: .wholeFile, body: path, color: .yellow)
        }
        await #expect(throws: (any Error).self) {
            try await store.prepareRelocation(DocumentRelocation(hostID: .local, from: "/a", to: "/b", directory: false))
        }
        #expect(try await store.pendingRelocation(hostID: .local) == nil)
    }
}

extension ReviewSafetyTests {
    @Test func anUnreviewedSourceCannotTakeOverDestinationHistory() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let doc = try await store.upsertDocument(hostID: .local, path: "/review/used-name", kind: .text, fingerprint: Fingerprint())
        _ = try await store.createNote(documentID: doc.id, anchor: .wholeFile, body: "keep", color: .yellow)
        await #expect(throws: (any Error).self) {
            try await store.prepareRelocation(DocumentRelocation(hostID: .local, from: "/review/unopened", to: doc.path, directory: false))
        }
        #expect(try await store.document(doc.id)?.path == doc.path)
    }
}
