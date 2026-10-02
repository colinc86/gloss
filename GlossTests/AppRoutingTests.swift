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
        await URLRouter.handle(URL(string: "gloss://open?host=local&path=\(encoded)")!, model: model)
        #expect(model.explorer.tabs.count == 1, "the existing root contains the file; no new tab")
        #expect(model.activeSession?.path == "\(root)/b.swift")
        let noteURL = URL(string: "gloss://note?host=local&path=\(encoded)&line=1&text=hello")!
        await URLRouter.handle(noteURL, model: model)
        await waitUntil { model.activeSession?.notes.count == 1 }
        #expect(model.activeSession?.notes.first?.body == "hello")
        await waitUntil { model.activeSession?.textController?.highlights.count == 1 }
        #expect(model.activeSession?.textController?.highlights.first?.range == NSRange(location: 0, length: 9))
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
