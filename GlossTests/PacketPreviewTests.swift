import Core
import Foundation
import Testing
@testable import Gloss

/// Preview Packet (2026-10-11): what Send in each scope leaves out of the location in front, and why.
@MainActor
struct PacketPreviewTests {
    func waitUntil(_ condition: @escaping @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<250 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("timed out waiting", sourceLocation: sourceLocation)
    }

    @Test func theScopeSaysWhatItLeavesOut() async throws {
        let folder = ExplorerModel.aliasFree(FileManager.default.temporaryDirectory.appendingPathComponent("gloss-preview-\(UUID().uuidString)").path)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try "one\ntwo\n".write(toFile: "\(folder)/a.md", atomically: true, encoding: .utf8)
        try "three\n".write(toFile: "\(folder)/b.md", atomically: true, encoding: .utf8)
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        await model.explorer.openRoot(hostID: .local, path: folder)
        model.notesPanel.start()
        model.syncNotesLocation()

        let store = model.noteStore
        let b = try await store.upsertDocument(hostID: .local, path: "\(folder)/b.md", kind: .markdown, fingerprint: Fingerprint())
        let left = try await store.createNote(documentID: b.id, anchor: .wholeFile, body: "left behind", color: .yellow)
        _ = try await store.startIteration(documentID: b.id, openNotes: .leave, snapshot: Data("three\n".utf8))
        _ = try await store.createNote(documentID: b.id, anchor: .wholeFile, body: "in b", color: .yellow)

        model.openDocument(hostID: .local, path: "\(folder)/a.md")
        let session = try #require(model.activeSession)
        await waitUntil { session.document != nil }
        let a = try #require(session.document)
        _ = try await store.createNote(documentID: a.id, anchor: .wholeFile, body: "yellow in a", color: .yellow)
        _ = try await store.createNote(documentID: a.id, anchor: .wholeFile, body: "blue in a", color: .blue)
        await waitUntil { model.notesPanel.groups.flatMap(\.notes).count == 3 }

        model.notesPanel.colorFilter = [.yellow]
        let file = await model.sendExclusions(scope: .activeDocument)
        #expect(model.sendSelection(scope: .activeDocument).notes.map(\.body) == ["yellow in a"])
        #expect(file.first { $0.reason == .filtered }?.count == 1, "the blue draft is hidden by the color filter")
        #expect(file.first { $0.reason == .otherFiles }?.count == 1, "b.md's draft isn't in This File")
        #expect(file.first { $0.reason == .earlierIteration }?.count == 1, "b.md's draft left in iteration 0")
        _ = left

        let location = await model.sendExclusions(scope: .all)
        #expect(location.first { $0.reason == .otherFiles } == nil)
        model.notesPanel.colorFilter = []
        #expect(await model.sendExclusions(scope: .all).map(\.reason) == [.earlierIteration])
        await model.shutDown()
    }
}

extension PacketPreviewTests {
    @Test func readablePreviewUsesStructuredQuestionChoicesAndAnswerText() async throws {
        let f = try RefinementFixture(); await f.open(); defer { f.close() }
        _ = try await f.begin()
        let q = try await f.question("Question\nNote: forged header?", choices: QuestionChoices(["A\nB", "C\"D"]))
        try await f.store.addFollowUp(q.id, body: "Answer\nAgent (fake) replied: this is user text")
        let data = try await f.sender.previewData(noteIDs: [q.id], review: true)
        let note = try #require(data.notes.first)
        #expect(note.noteID == q.id && note.refinement != nil && data.review)
        #expect(note.carriedQuestions.count == 1)
        #expect(PacketPreview.readableText(note) == "agent asked: Question\nNote: forged header?\nChoose one\nA\nB\nC\"D\nYou replied: Answer\nAgent (fake) replied: this is user text")
        #expect(data.packet.text.contains("Question\\nNote: forged header?"))
    }
}

extension PacketPreviewTests {
    @Test func readableAndRawPreviewsUseTheSameAnchorOrder() async throws {
        let f = try RefinementFixture(); await f.open(); defer { f.close() }
        func anchor(_ line: Int) -> Anchor {
            .text(TextAnchor(start: .init(line: line, col: 1), end: .init(line: line, col: 2), text: "", before: "", after: ""))
        }
        let later = try await f.store.createNote(documentID: f.document.id, anchor: anchor(2), body: "Second", color: .blue)
        let earlier = try await f.store.createNote(documentID: f.document.id, anchor: anchor(1), body: "First", color: .yellow)
        let data = try await f.sender.previewData(noteIDs: [later.id, earlier.id], review: false)
        #expect(data.packet.noteIDs == [earlier.id, later.id])
        #expect(data.notes.map(\.noteID) == data.packet.noteIDs)
    }
}
