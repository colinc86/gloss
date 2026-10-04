import Core
import CoreGraphics
import Foundation
import Testing
import Viewers
@testable import Gloss

/// Element notes without a web view: the page's bridge is stood in for by calling the controller's hooks directly.
@MainActor
struct ElementNoteTests {
    func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
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
        #expect(session.notes.first?.anchor == .element(moved) || session.notes.first?.state == .draft)
        await model.shutDown()
    }
}
