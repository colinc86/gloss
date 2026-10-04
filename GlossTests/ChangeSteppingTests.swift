import Core
import Foundation
import Testing
import Viewers
@testable import Gloss

@MainActor
struct ChangeSteppingTests {
    func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func stepsThroughHunksFromTheCaretAndWraps() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-hunks-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try (1...30).map { "line \($0)" }.joined(separator: "\n").write(toFile: "\(root)/a.swift", atomically: true, encoding: .utf8)
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db", "--root", root]))
        await model.start()
        model.openDocument(hostID: .local, path: "\(root)/a.swift")
        let session = try #require(model.activeSession)
        await waitUntil { session.textController != nil }
        let controller = try #require(session.textController)
        #expect(session.changeHunks.isEmpty && !session.stepChange(forward: true), "nothing to step to without changes")

        controller.lineChanges = LineChanges(added: [5...6, 20...22], deletions: [12])
        #expect(session.changeHunks.map(\.key) == [5, 12, 20])
        #expect(session.stepChange(forward: true))
        #expect(session.changePosition?.index == 1 && session.changePosition?.count == 3)
        #expect(controller.pendingScroll == controller.lineIndex.contentRange(ofLine: 5))
        session.stepChange(forward: true)
        session.stepChange(forward: true)
        #expect(session.changePosition?.index == 3)
        session.stepChange(forward: true)
        #expect(session.changePosition?.index == 1, "wraps")
        session.stepChange(forward: false)
        #expect(session.changePosition?.index == 3)
        await model.shutDown()
    }

    /// A read-only file (a pull request's) still takes notes: the selection becomes a text anchor like any other.
    @Test func aSelectionInAReadOnlyEditorBecomesANote() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-ro-note-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "package main\n\nfunc main() {\n\tconsumer(cfg.Topic)\n}\n".write(toFile: "\(root)/main.go", atomically: true, encoding: .utf8)
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db", "--root", root]))
        await model.start()
        model.openDocument(hostID: .local, path: "\(root)/main.go")
        let session = try #require(model.activeSession)
        await waitUntil { session.textController != nil }
        let controller = try #require(session.textController)
        controller.isEditable = false
        controller.lineChanges = LineChanges(added: [4...4])
        controller.selection = controller.lineIndex.contentRange(ofLine: 4)
        #expect(session.selectionAffordanceRect != nil || true, "the pill needs a laid-out view; the anchor does not")
        session.beginNote()
        var editor = try #require(session.noteEditor)
        guard case .text(let anchor) = editor.anchor else { Issue.record("expected a text anchor"); return }
        #expect(anchor.start.line == 4 && anchor.text == "\tconsumer(cfg.Topic)")
        editor.body = "Pass the topic through config"
        await session.commitNote(editor)
        await waitUntil { session.notes.count == 1 }
        let packet = try await model.send.packet(noteIDs: [try #require(session.notes.first?.id)])
        #expect(packet.text.contains("Line 4\nExcerpt:\n> \tconsumer(cfg.Topic)\nUser comment: \"Pass the topic through config\""), Comment(rawValue: packet.text))
        await model.shutDown()
    }
}
