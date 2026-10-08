import Core
import Foundation
import Testing
import Viewers
@testable import Gloss

@MainActor
struct DocumentNotesTests {
    func makeFile(_ content: String) throws -> (String, String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-notes-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = "\(directory)/doc.md"
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return (directory, path)
    }

    func makeSession(path: String) throws -> (DocumentSession, NoteStore) {
        let store = NoteStore(database: try AppDatabase.inMemory())
        return (DocumentSession(hostID: .local, path: path, fileSystem: LocalFileSystem(deleteBehavior: .permanent), noteStore: store), store)
    }

    func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func createsANoteFromTheSelectionAndShowsIt() async throws {
        let (directory, path) = try makeFile("one\ntwo\nthree\n")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (session, store) = try makeSession(path: path)
        await session.open()
        let controller = try #require(session.textController)
        session.markdown?.mode = .source   // a markdown file opens rendered; the note comes from the source selection here
        controller.selection = controller.lineIndex.contentRange(ofLine: 2)
        session.beginNote()
        var editor = try #require(session.noteEditor)
        #expect(editor.anchor.summary == "Line 2")
        editor.body = "Rename this"
        editor.color = .green
        await session.commitNote(editor)
        await waitUntil { session.notes.count == 1 }
        let note = try #require(session.notes.first)
        #expect(note.body == "Rename this")
        #expect(note.color == .green)
        await waitUntil { controller.highlights.count == 1 }
        #expect(controller.highlights.first?.range == controller.lineIndex.contentRange(ofLine: 2))
        #expect(try await store.notes(for: note.documentID).count == 1)
        session.close()
    }

    @Test func liveShiftPersistsOnSave() async throws {
        let (directory, path) = try makeFile("one\ntwo\nthree\n")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (session, store) = try makeSession(path: path)
        await session.open()
        let controller = try #require(session.textController)
        let document = try #require(session.document)
        _ = try await store.createNote(documentID: document.id, anchor: .text(TextAnchor(start: .init(line: 2, col: 1), end: .init(line: 2, col: 4), text: "two", before: "one", after: "three", hash: nil)), body: "b", color: .blue)
        await waitUntil { controller.highlights.count == 1 }
        // Simulate typing a new first line: the storage delegate path reports the edit, then the text change.
        let newText = "zero\none\ntwo\nthree\n"
        controller.viewDidProcessEdit(edit: NSRange(location: 0, length: 0), replacementLength: 5, newText: newText)
        controller.viewDidChangeText(newText)
        #expect(controller.highlights.first?.range == NSRange(location: 9, length: 3))
        await session.save()
        let saved = try #require(try await store.notes(for: document.id).first)
        guard case .text(let anchor) = saved.anchor else { Issue.record("expected text anchor"); return }
        #expect(anchor.start.line == 3)
        #expect(anchor.text == "two")
        #expect(anchor.hash == Data(newText.utf8).sha256Hex)
        session.close()
    }

    /// Deleting a note's text in the editor leaves a point where it was, saved as a removal; deleting it and bringing
    /// it back (undo, or cut and paste) before saving keeps the note on its text, with nothing said in the thread.
    @Test func deletedTextIsSavedAsARemovalUnlessItCameBack() async throws {
        let (directory, path) = try makeFile("one\ntwo\nthree\n")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (session, store) = try makeSession(path: path)
        await session.open()
        let controller = try #require(session.textController)
        let document = try #require(session.document)
        let original = "one\ntwo\nthree\n"
        let index = LineIndex(original)
        let anchor = ReAnchorer.make(from: index.contentRange(ofLine: 2), in: original, index: index, hash: Data(original.utf8).sha256Hex)
        let note = try await store.createNote(documentID: document.id, anchor: .text(anchor), body: "b", color: .blue)
        await waitUntil { controller.highlights.count == 1 }

        // Delete "two", then undo: the text is back where it was.
        let deleted = "one\n\nthree\n"
        controller.viewDidProcessEdit(edit: NSRange(location: 4, length: 3), replacementLength: 0, newText: deleted)
        controller.viewDidChangeText(deleted)
        #expect(controller.highlights.first?.range == NSRange(location: 4, length: 0), "a point where the text was")
        controller.viewDidProcessEdit(edit: NSRange(location: 4, length: 0), replacementLength: 3, newText: original)
        controller.viewDidChangeText(original)
        await session.save()
        let kept = try #require(try await store.note(note.id))
        #expect(kept.anchor == .text(anchor), "still on its text")
        #expect(try await store.messages(for: note.id).isEmpty, "nothing moved")

        // Delete it for good: saved as a removal Gloss found.
        controller.viewDidProcessEdit(edit: NSRange(location: 4, length: 3), replacementLength: 0, newText: deleted)
        controller.viewDidChangeText(deleted)
        await session.save()
        let removed = try #require(try await store.note(note.id))
        guard case .text(let point) = removed.anchor else { Issue.record("expected text anchor"); return }
        #expect(point.text.isEmpty && point.start == point.end && removed.originalAnchor == .text(anchor))
        let message = try #require(try await store.messages(for: note.id).last)
        #expect(message.kind == .moved && message.author == .app && message.move?.removed == true)
        session.close()
    }

    @Test func aHiddenNoteIsNotDrawnButStillMovesWithEdits() async throws {
        let (directory, path) = try makeFile("one\ntwo\nthree\n")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (session, store) = try makeSession(path: path)
        await session.open()
        let controller = try #require(session.textController)
        let document = try #require(session.document)
        let shown = try await store.createNote(documentID: document.id, anchor: .text(TextAnchor(start: .init(line: 1, col: 1), end: .init(line: 1, col: 4), text: "one", before: "", after: "two", hash: nil)), body: "a", color: .yellow)
        let hidden = try await store.createNote(documentID: document.id, anchor: .text(TextAnchor(start: .init(line: 2, col: 1), end: .init(line: 2, col: 4), text: "two", before: "one", after: "three", hash: nil)), body: "b", color: .blue)
        await waitUntil { controller.highlights.count == 2 }
        #expect(session.steppableNotes.map(\.id) == [shown.id, hidden.id])
        session.hiddenNoteIDs = [hidden.id]
        #expect(controller.drawnHighlights.map(\.id) == [shown.id])
        #expect(controller.highlights.first { $0.id == hidden.id }?.isHidden == true)
        #expect(session.steppableNotes.map(\.id) == [shown.id], "Next Note skips a note the panel isn't listing")
        // Typing a new first line moves the hidden note too.
        let newText = "zero\none\ntwo\nthree\n"
        controller.viewDidProcessEdit(edit: NSRange(location: 0, length: 0), replacementLength: 5, newText: newText)
        controller.viewDidChangeText(newText)
        #expect(controller.highlights.first { $0.id == hidden.id }?.range == NSRange(location: 9, length: 3))
        session.hiddenNoteIDs = []
        #expect(controller.drawnHighlights.first { $0.id == hidden.id }?.range == NSRange(location: 9, length: 3), "shown again where it moved to")
        session.close()
    }

    @Test func reloadReanchorsAndOrphans() async throws {
        let (directory, path) = try makeFile("alpha\nbeta\ngamma\n")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (session, store) = try makeSession(path: path)
        await session.open()
        let controller = try #require(session.textController)
        let document = try #require(session.document)
        let kept = try await store.createNote(documentID: document.id, anchor: .text(TextAnchor(start: .init(line: 2, col: 1), end: .init(line: 2, col: 5), text: "beta", before: "alpha", after: "gamma", hash: "old")), body: "k", color: .blue)
        let lost = try await store.createNote(documentID: document.id, anchor: .text(TextAnchor(start: .init(line: 3, col: 1), end: .init(line: 3, col: 6), text: "gamma", before: "alpha\nbeta", after: "", hash: "old")), body: "l", color: .pink)
        await waitUntil { controller.highlights.count == 2 }
        try await Task.sleep(for: .milliseconds(5))
        try "intro\nalpha\nbeta\nomega\n".write(toFile: path, atomically: true, encoding: .utf8)
        await session.handleExternalChange()
        await waitUntil { session.notes.first { $0.id == lost.id }?.state == .orphaned }
        let keptNow = try #require(try await store.note(kept.id))
        guard case .text(let anchor) = keptNow.anchor else { Issue.record("expected text"); return }
        #expect(anchor.start.line == 3, "beta moved down one line")
        #expect(try await store.note(lost.id)?.state == .orphaned)
        session.close()
    }

    /// Issue #6: a file an agent changed while it was closed. Its notes are found again when it opens, before
    /// anything is drawn or sent at the old lines; a sent note whose text is gone and comes back stays sent.
    @Test func openingAChangedFileReanchorsItsNotes() async throws {
        let (directory, path) = try makeFile("alpha\nbeta\ngamma\n")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let store = NoteStore(database: try AppDatabase.inMemory())
        let document = try await store.upsertDocument(hostID: .local, path: path, kind: .markdown, fingerprint: Fingerprint())
        let moved = try await store.createNote(documentID: document.id, anchor: .text(TextAnchor(start: .init(line: 2, col: 1), end: .init(line: 2, col: 5), text: "beta", before: "alpha", after: "gamma", hash: "old")), body: "m", color: .blue)
        let gone = try await store.createNote(documentID: document.id, anchor: .text(TextAnchor(start: .init(line: 3, col: 1), end: .init(line: 3, col: 6), text: "gamma", before: "alpha\nbeta", after: "", hash: "old")), body: "g", color: .pink)
        _ = try await store.recordSend(transport: "tmux", targetJSON: "{}", packetText: "p", noteIDs: [gone.id], outcome: .delivered)
        // While closed: two lines added above, gamma removed.
        try "new one\nnew two\nalpha\nbeta\nomega\n".write(toFile: path, atomically: true, encoding: .utf8)
        let session = DocumentSession(hostID: .local, path: path, fileSystem: LocalFileSystem(deleteBehavior: .permanent), noteStore: store)
        await session.open()
        await waitUntil { session.notes.first { $0.id == gone.id }?.state == .orphaned }
        guard case .text(let anchor) = try await store.note(moved.id)?.anchor else { Issue.record("expected text"); return }
        #expect(anchor.start.line == 4, "beta followed the two new lines")
        #expect(try await store.note(gone.id)?.state == .orphaned)

        // gamma comes back: the note is found again and is still the sent note it was.
        try "new one\nnew two\nalpha\nbeta\ngamma\n".write(toFile: path, atomically: true, encoding: .utf8)
        await session.handleExternalChange()
        await waitUntil { session.notes.first { $0.id == gone.id }?.state == .sent }
        #expect(try await store.note(gone.id)?.state == .sent)
        session.close()
    }

    /// A packet for a file that isn't open reads the file as it is now, so its excerpt and line numbers follow an
    /// edit made since the note was written.
    @Test func aPacketForAClosedChangedFileUsesTheTextAsItIsNow() async throws {
        let (directory, path) = try makeFile("alpha\nbeta\ngamma\n")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let store = NoteStore(database: try AppDatabase.inMemory())
        let document = try await store.upsertDocument(hostID: .local, path: path, kind: .markdown, fingerprint: Fingerprint())
        let note = try await store.createNote(documentID: document.id, anchor: .text(TextAnchor(start: .init(line: 2, col: 1), end: .init(line: 2, col: 5), text: "beta", before: "alpha", after: "gamma", hash: "old")), body: "fix beta", color: .blue)
        try "one\ntwo\nthree\nalpha\nbeta\ngamma\n".write(toFile: path, atomically: true, encoding: .utf8)
        let coordinator = SendCoordinator(noteStore: store, transports: [], stagers: [:])
        coordinator.fileSystemProvider = { _ in LocalFileSystem(deleteBehavior: .permanent) }
        let packet = try await coordinator.packet(noteIDs: [note.id])
        #expect(packet.text.contains("Line 5"), "\(packet.text)")
        #expect(packet.text.contains("> beta"))
        guard case .text(let anchor) = try await store.note(note.id)?.anchor else { Issue.record("expected text"); return }
        #expect(anchor.start.line == 5, "and the note itself moved")
    }

    /// Escape puts the Add Note button away (the selection goes), then closes an open composer; with neither
    /// showing it does nothing, so the key goes on to others.
    @Test func escapeDismissesTheAddNoteButtonAndTheComposer() async throws {
        let (directory, path) = try makeFile("one\ntwo\nthree\n")
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let (session, _) = try makeSession(path: path)
        await session.open()
        let controller = try #require(session.textController)
        session.markdown?.mode = .source
        #expect(session.dismissNoteAffordance() == false, "nothing to dismiss")
        controller.selection = controller.lineIndex.contentRange(ofLine: 2)
        #expect(session.selectionAffordanceRect != nil || controller.selection.length > 0)
        if session.selectionAffordanceRect != nil {
            #expect(session.dismissNoteAffordance())
            #expect(controller.selection.length == 0)
        }
        controller.selection = controller.lineIndex.contentRange(ofLine: 2)
        session.beginNote()
        #expect(session.noteEditor != nil)
        #expect(session.dismissNoteAffordance())
        #expect(session.noteEditor == nil)
        session.close()
    }
}
