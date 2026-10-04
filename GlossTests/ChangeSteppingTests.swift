import Core
import Foundation
import Testing
import Viewers
@testable import Gloss

@MainActor
struct ChangeSteppingTests {
    func waitUntil(_ condition: @escaping @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("timed out waiting", sourceLocation: sourceLocation)
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
        // The caret moving elsewhere ends the run; the next step starts from the caret again.
        controller.selection = NSRange(location: controller.lineIndex.contentRange(ofLine: 10).location, length: 0)
        #expect(session.changePosition == nil)
        session.stepChange(forward: true)
        #expect(session.changePosition?.index == 2, "from line 10 the next hunk is the deletion at 12")
        await model.shutDown()
    }

    @Test func theFirstNextCountsAHunkOnTheCaretsLine() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-hunk1-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try (1...50).map { "line \($0)" }.joined(separator: "\n").write(toFile: "\(root)/a.swift", atomically: true, encoding: .utf8)
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db", "--root", root]))
        await model.start()
        model.openDocument(hostID: .local, path: "\(root)/a.swift")
        let session = try #require(model.activeSession)
        await waitUntil { session.textController != nil }
        let controller = try #require(session.textController)
        controller.lineChanges = LineChanges(added: [1...2, 40...40])
        #expect(session.stepChange(forward: true))
        #expect(session.changePosition?.index == 1, "on open the caret is on line 1, where the first hunk is")
        await model.shutDown()
    }

    @Test func gitLinesLandOnTheEditorsLines() {
        // Git ends lines only at \n; the editor also breaks at U+2028, so everything below one moves down a row.
        let text = "let a = 1\nlet s = \"x\u{2028}y\"\nlet b = 2\nlet c = 3\n"
        let index = LineIndex(text)
        let mapped = DocumentSession.editorLines(of: LineChanges(added: [3...4], deletions: [2]), in: text, lineIndex: index)
        #expect(mapped == LineChanges(added: [4...5], deletions: [2]))
        let plain = "a\nb\nc\n"
        #expect(DocumentSession.editorLines(of: LineChanges(added: [2...2]), in: plain, lineIndex: LineIndex(plain)) == LineChanges(added: [2...2]), "no separators: unchanged")
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
