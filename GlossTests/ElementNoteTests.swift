import Core
import CoreGraphics
import Foundation
import Testing
import Viewers
@testable import Gloss

/// Element notes without a web view: the page's bridge is stood in for by calling the controller's hooks directly.
@MainActor
struct ElementNoteTests {
    func waitUntil(_ condition: @escaping @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("timed out waiting", sourceLocation: sourceLocation)
    }

    @Test func aPickOpensTheEditorAndCommitsAnElementNote() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-element-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "<html><body>\n<p>Intro</p>\n<div id=\"toolbar\"><button class=\"primary\">Save</button></div>\n</body></html>\n".write(toFile: "\(root)/page.html", atomically: true, encoding: .utf8)
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db", "--root", root]))
        await model.start()
        model.openDocument(hostID: .local, path: "\(root)/page.html")
        let session = try #require(model.activeSession)
        await waitUntil { session.html != nil }
        let html = try #require(session.html)
        // The page's text as the bridge would report it, aligned so the pick's text offset maps to a source line.
        html.alignment = html.projection.alignment(withDOM: html.projection.text)
        let offset = (html.projection.text as NSString).range(of: "Save").location

        html.isNoteMode = true
        html.onPick(ElementPick(
            selector: "#toolbar > button", tag: "button", text: "Save", html: "<button class=\"primary\">Save</button>",
            windowRect: CGRect(x: 100, y: 200, width: 60, height: 24), pageRect: ElementRect(x: 20, y: 40, w: 60, h: 24), textOffset: offset
        ))
        #expect(!html.isNoteMode, "a pick ends note mode")
        let editor = try #require(session.noteEditor)
        guard case .element(let anchor) = editor.anchor else { Issue.record("expected an element anchor"); return }
        #expect(anchor.selector == "#toolbar > button" && anchor.text == "Save")
        #expect(anchor.line == 3, "the element's text sits on the third line of the file")
        #expect(editor.anchorRect == CGRect(x: 100, y: 200, width: 60, height: 24), "the editor opens at the element")

        var state = editor
        state.body = "Make this the default button"
        await session.commitNote(state)
        await waitUntil { session.notes.count == 1 }
        let note = try #require(session.notes.first)
        #expect(note.anchor == .element(anchor))
        await waitUntil { html.elementHighlights.count == 1 }
        #expect(html.elementHighlights.first?.selector == "#toolbar > button")
        #expect(note.anchor.summary == "Element button")

        let packet = PacketBuilder.build([PacketNote(noteID: note.id, agentPath: "\(root)/page.html", source: .code, anchor: note.anchor, comment: note.body)]).text
        #expect(packet.contains("Element: #toolbar > button\nText: \"Save\"\nRect: x=20 y=40 w=60 h=24\nLine 3\nSnippet:\n> <button class=\"primary\">Save</button>\nUser comment: \"Make this the default button\""))

        // The page changes under the note. The bridge's answers are stood in for; the session decides.
        let controller = try #require(session.textController)
        let original = controller.text
        let candidate = ElementCandidate(selector: "#store", tag: "button", text: "Save", html: "<button id=\"store\">Save</button>", rect: .init(x: 20, y: 40, w: 60, h: 24))
        html.resolveElements = { _ in [note.id: ElementResolution(bySelector: nil, byText: [candidate])] }
        controller.replaceAll(with: original.replacingOccurrences(of: "class=\"primary\"", with: "id=\"store\""))
        html.onPageChanged()
        await waitUntil { if case .element(let a) = session.notes.first?.anchor { a.selector == "#store" } else { false } }
        #expect(session.needsReview.contains(note.id), "found again by its text under a new selector: flagged for a glance")
        #expect(session.notes.first?.state == .draft)

        html.resolveElements = { _ in [note.id: ElementResolution()] }
        controller.replaceAll(with: original.replacingOccurrences(of: "<button class=\"primary\">Save</button>", with: ""))
        html.onPageChanged()
        await waitUntil { session.notes.first?.state == .orphaned }
        #expect(session.notes.first?.state == .orphaned)

        // The element comes back exactly as the note last saw it: the page's hash matches the anchor's again.
        guard case .element(let moved) = session.notes.first?.anchor else { Issue.record("expected an element anchor"); return }
        controller.replaceAll(with: original.replacingOccurrences(of: "class=\"primary\"", with: "id=\"store\""))
        html.resolveElements = { _ in [note.id: ElementResolution(bySelector: candidate)] }
        html.onPageChanged()
        await waitUntil { session.notes.first?.state == .draft }
        #expect(session.notes.first?.state == .draft)
        #expect(session.notes.first?.anchor == .element(moved), "the element is back where the note last saw it")
        await model.shutDown()
    }
}

/// A live page's changes: nothing is written for a page without notes, and only the newest change's results land.
@MainActor
struct PageChangeTests {
    func waitUntil(_ what: String, _ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<150 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("timed out waiting for \(what)")
    }

    @Test func aPageWithoutNotesWritesNothing() async throws {
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        await model.start()
        model.openWebPage(URL(string: "http://localhost:9/busy")!)
        let session = try #require(model.activeSession)
        await waitUntil("the page controller") { session.html != nil }
        let html = try #require(session.html)
        for tick in 0..<5 {
            html.source.replaceAll(with: "<html><body><p>tick \(tick)</p></body></html>")
            html.onPageChanged()
        }
        try await Task.sleep(for: .milliseconds(200))
        let document = try #require(try await model.noteStore.document(hostID: .web, path: session.path))
        #expect(document.fingerprint.hash == nil, "no fingerprint written for a page nobody annotated")
        await model.shutDown()
    }

    @Test func onlyTheNewestChangeLands() async throws {
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        await model.start()
        model.openWebPage(URL(string: "http://localhost:9/app")!)
        let session = try #require(model.activeSession)
        await waitUntil("the page controller") { session.html != nil }
        let html = try #require(session.html)
        let document = try #require(try await model.noteStore.document(hostID: .web, path: session.path))
        let anchor = ElementAnchor(selector: "#save", tag: "button", text: "Save", html: "<button id=\"save\">Save</button>", rect: ElementRect(x: 1, y: 2, w: 3, h: 4))
        _ = try await model.noteStore.createNote(documentID: document.id, anchor: .element(anchor), body: "Rename", color: .yellow)
        await waitUntil("the note") { session.notes.count == 1 }

        // The first change's answer is slow and says the element is gone; the second's is quick and finds it.
        var calls = 0
        html.resolveElements = { items in
            calls += 1
            if calls == 1 {
                try? await Task.sleep(for: .milliseconds(400))
                return [:].merging(items.map { ($0.id, ElementResolution()) }) { a, _ in a }
            }
            let found = ElementCandidate(selector: "#save", tag: "button", text: "Save", html: "", rect: ElementRect(x: 1, y: 2, w: 3, h: 4))
            return [:].merging(items.map { ($0.id, ElementResolution(bySelector: found)) }) { a, _ in a }
        }
        html.onPageChanged()
        try await Task.sleep(for: .milliseconds(50))
        html.onPageChanged()
        try await Task.sleep(for: .milliseconds(700))
        #expect(calls == 2)
        #expect(session.notes.first?.state == .draft, "the stale 'gone' answer must not orphan the note after the newer one found it")
        await model.shutDown()
    }
}
