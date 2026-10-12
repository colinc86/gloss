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
