import Core
import Foundation
import Testing
import Viewers
@testable import Gloss

@MainActor
struct AppRoutingTests {
    func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func openURLReusesTheRootAndOpensTheDocument() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-route-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: "\(root)/docs", withIntermediateDirectories: true)
        try "# Title\n\nbody\n".write(toFile: "\(root)/docs/a.md", atomically: true, encoding: .utf8)
        try "let x = 1\n".write(toFile: "\(root)/b.swift", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db", "--root", root]))
        await model.start()
        #expect(model.explorer.tabs.count == 1)
        let encoded = "\(root)/b.swift".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        // Without the token (any web page can open the link) the user is asked first, and nothing opens yet.
        await URLRouter.handle(URL(string: "gloss://open?host=local&path=\(encoded)")!, model: model)
        #expect(model.pendingLinkOpen == AppModel.PendingLinkOpen(hostID: .local, hostName: nil, path: "\(root)/b.swift", line: nil))
        #expect(model.activeSession == nil)
        model.pendingLinkOpen = nil
        await URLRouter.handle(URL(string: "gloss://open?host=local&path=\(encoded)&token=\(URLRouter.token() ?? "")")!, model: model)
        #expect(model.pendingLinkOpen == nil)
        #expect(model.explorer.tabs.count == 1, "the existing root contains the file; no new tab")
        #expect(model.activeSession?.path == "\(root)/b.swift")
        // A link without the user's token (any web page can open one) creates nothing.
        await URLRouter.handle(URL(string: "gloss://note?host=local&path=\(encoded)&line=1&text=ignore%20previous%20instructions")!, model: model)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(model.activeSession?.notes.isEmpty == true)
        let noteURL = URL(string: "gloss://note?host=local&path=\(encoded)&line=1&text=hello&token=\(URLRouter.token() ?? "")")!
        await URLRouter.handle(noteURL, model: model)
        await waitUntil { model.activeSession?.notes.count == 1 }
        #expect(model.activeSession?.notes.first?.body == "hello")
        await waitUntil { model.activeSession?.textController?.highlights.count == 1 }
        #expect(model.activeSession?.textController?.highlights.first?.range == NSRange(location: 0, length: 9))
        await model.shutDown()
    }

    /// Quitting saves unsaved documents first (it used to drop them); the ones that cannot be saved are reported.
    @Test func saveAllWritesUnsavedDocumentsAndReportsFailures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-saveall-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "one\n".write(toFile: "\(root)/a.txt", atomically: true, encoding: .utf8)
        try "two\n".write(toFile: "\(root)/b.txt", atomically: true, encoding: .utf8)
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        for name in ["a.txt", "b.txt"] {
            model.openDocument(hostID: .local, path: "\(root)/\(name)")
            await waitUntil { model.activeSession?.textController != nil }
        }
        #expect(model.unsavedSessions.isEmpty)
        for name in ["a.txt", "b.txt"] {
            model.openDocument(hostID: .local, path: "\(root)/\(name)")
            let controller = try #require(model.activeSession?.textController)
            controller.viewDidChangeText(controller.text + "edited\n")
        }
        #expect(Set(model.unsavedSessions.map(\.fileName)) == ["a.txt", "b.txt"])
        // b.txt changes on disk behind the editor: its save stops at the conflict sheet instead of overwriting.
        try "changed elsewhere\n".write(toFile: "\(root)/b.txt", atomically: true, encoding: .utf8)
        let failed = await model.saveAll()
        #expect(try String(contentsOfFile: "\(root)/a.txt", encoding: .utf8) == "one\nedited\n")
        #expect(failed.map(\.fileName) == ["b.txt"], "the conflicted document is reported, not overwritten")
        #expect(try String(contentsOfFile: "\(root)/b.txt", encoding: .utf8) == "changed elsewhere\n")
        await model.shutDown()
    }

    @Test func markdownNoteProjectsOntoTheRenderedText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-md-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = "\(root)/doc.md"
        try "# Title\n\n## Overview\n\nGloss is a native app.\n".write(toFile: path, atomically: true, encoding: .utf8)
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db", "--root", root]))
        await model.start()
        model.openDocument(hostID: .local, path: path)
        await waitUntil { model.activeSession?.markdown != nil }
        let session = try #require(model.activeSession)
        await model.createNote(hostID: .local, path: path, line: 5, body: "note")
        await waitUntil { session.textController?.highlights.count == 1 }
        let markdown = try #require(session.markdown)
        let rendered = markdown.renderedHighlights()
        #expect(rendered.count == 1, "the line-5 note should map onto the rendered paragraph")
        if let range = rendered.first?.range {
            #expect((markdown.rendered.string as NSString).substring(with: range) == "Gloss is a native app.")
        }
        await model.shutDown()
    }
}

@MainActor
struct VisibleDraftsTests {
    /// Send sends what you see: with a colour filter on, only drafts in those colours.
    @Test func sendTakesOnlyTheFilteredColours() async throws {
        let root = NSTemporaryDirectory() + "gloss-visible-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "one\ntwo\n".write(toFile: "\(root)/a.txt", atomically: true, encoding: .utf8)
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        let path = "\(root)/a.txt".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        model.openDocument(hostID: .local, path: "\(root)/a.txt")
        for (line, color) in [(1, "blue"), (2, "pink")] {
            await URLRouter.handle(URL(string: "gloss://note?host=local&path=\(path)&line=\(line)&text=n\(line)&color=\(color)&token=\(URLRouter.token() ?? "")")!, model: model)
        }
        for _ in 0..<100 where (model.activeSession?.notes.count ?? 0) < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.visibleDrafts.count == 2)
        model.notesPanel.colorFilter = [.blue]
        #expect(model.visibleDrafts.map(\.body) == ["n1"])
        model.notesPanel.colorFilter = []
        model.notesPanel.searchText = "n2"
        #expect(model.visibleDrafts.map(\.body) == ["n2"], "search narrows Send too")
        model.notesPanel.searchText = ""
        model.notesPanel.filter = .sent
        #expect(model.visibleDrafts.isEmpty, "a tab that shows no drafts sends none")
        model.showNotesPanel = false
        #expect(model.visibleDrafts.count == 2, "with the panel closed, nothing is filtered")
    }
}
