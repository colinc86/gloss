import Core
import Foundation
import Testing
import SwiftUI
import Transports
@testable import Gloss

/// Issue #4: where an agent's question lands in the file it names.
struct AgentControlTests {
    @Test func aQuotedTextIsFoundNearestTheGivenLine() {
        let text = "intro\nTODO: decide\nmiddle\nmore\nTODO: decide\nend\n"
        let index = LineIndex(text)
        let near = AppModel.occurrence(of: "TODO: decide", in: text, index: index, nearLine: 5)
        #expect(near.map { index.position(forUTF16Offset: $0.location).line } == 5)
        let first = AppModel.occurrence(of: "TODO: decide", in: text, index: index, nearLine: nil)
        #expect(first.map { index.position(forUTF16Offset: $0.location).line } == 2)
        #expect(AppModel.occurrence(of: "absent", in: text, index: index, nearLine: 1) == nil)
    }

    /// Agents quote lines joined by "\n"; a Windows file joins them with "\r\n", and the quote still finds them.
    @Test func aQuoteOfSeveralLinesIsFoundInACRLFFile() {
        let text = "intro\r\nfirst line\r\nsecond line\r\nend\r\n"
        let index = LineIndex(text)
        let found = AppModel.occurrence(of: "first line\nsecond line", in: text, index: index, nearLine: nil)
        #expect(found.map { (text as NSString).substring(with: $0) } == "first line\r\nsecond line")
        #expect(found.map { index.position(forUTF16Offset: $0.location).line } == 2)
    }

    /// A question (or a linked note) with a line on a picture or a PDF is on the whole file: their bytes are not lines.
    @Test func onlyTextFilesTakeLineAnchors() {
        let text = Data("one\ntwo\n".utf8)
        let binary = Data([0x25, 0x50, 0x44, 0x46, 0x00, 0x01, 0x02])
        #expect(AppModel.takesLineAnchors(.markdown, text))
        #expect(AppModel.takesLineAnchors(.csv, text))
        #expect(!AppModel.takesLineAnchors(.pdf, binary))
        #expect(!AppModel.takesLineAnchors(.image, binary))
        #expect(AppModel.takesLineAnchors(.file, text), "an unlisted extension holding text opens as text")
        #expect(!AppModel.takesLineAnchors(.file, binary))
    }

    /// `open_in_viewer` given a folder opens it in the explorer rather than failing in the viewer.
    @Test @MainActor func anAgentOpeningAFolderOpensItInTheExplorer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-agent-folder-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: "\(root)/docs", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        await model.start()
        await model.showForAgent(hostID: .local, path: "\(root)/docs", line: nil, endLine: nil)
        #expect(model.explorer.selectedTab?.path == "\(root)/docs")
        #expect(model.session(hostID: .local, path: "\(root)/docs") == nil, "no document tab trying to read a folder")
        await model.shutDown()
    }

    /// An agent opening a file in a folder already open but not in front switches to it, so notes on the file
    /// are listed; the folder in front stays when it holds the file.
    @Test @MainActor func anAgentOpeningAFileInAnotherOpenFolderSwitchesToIt() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-agent-switch-\(UUID().uuidString)").path
        for folder in ["a", "b/inner"] { try FileManager.default.createDirectory(atPath: "\(base)/\(folder)", withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(atPath: base) }
        for file in ["a/one.md", "b/two.md", "b/inner/three.md"] { try "text\n".write(toFile: "\(base)/\(file)", atomically: true, encoding: .utf8) }
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        await model.start()
        await model.explorer.openRoot(hostID: .local, path: "\(base)/a")
        await model.explorer.openRoot(hostID: .local, path: "\(base)/b")
        await model.explorer.openRoot(hostID: .local, path: "\(base)/b/inner")
        await model.showForAgent(hostID: .local, path: "\(base)/a/one.md", line: nil, endLine: nil)
        #expect(model.explorer.selectedTab?.path.hasSuffix("/a") == true)
        #expect(model.notesPanel.location?.path.hasSuffix("/a") == true)
        await model.showForAgent(hostID: .local, path: "\(base)/b/inner/three.md", line: nil, endLine: nil)
        #expect(model.explorer.selectedTab?.path.hasSuffix("/b/inner") == true, "the deepest folder holding it")
        await model.explorer.openRoot(hostID: .local, path: "\(base)/b")
        await model.showForAgent(hostID: .local, path: "\(base)/b/inner/three.md", line: nil, endLine: nil)
        #expect(model.explorer.selectedTab?.path.hasSuffix("/b") == true, "the folder in front holds it")
        model.pickedHost = .web
        await model.showForAgent(hostID: .local, path: "\(base)/b/two.md", line: nil, endLine: nil)
        #expect(model.shownTab?.path.hasSuffix("/b") == true, "back from another host's section")
        await model.shutDown()
    }

    /// The review card's excerpt keeps what the note is about in view when the block is short.
    @Test func aReviewExcerptCentersOnItsSelection() {
        func excerpt(_ selected: ClosedRange<Int>) -> ReviewExcerpt {
            ReviewExcerpt(lines: (0..<9).map { .init(number: $0 + 1, text: "line", selected: selected.contains($0)) })
        }
        let one = ReviewExcerptBlock.focus(of: excerpt(3...3), visibleRows: 4)
        #expect(one?.row == 3 && one?.anchor == .center)
        let many = ReviewExcerptBlock.focus(of: excerpt(2...6), visibleRows: 3)
        #expect(many?.row == 2 && many?.anchor == .top, "taller than the block: from its top")
        #expect(ReviewExcerptBlock.focus(of: ReviewExcerpt(lines: []), visibleRows: 4) == nil)
    }

    /// `ask_user` given `path:line` (as agents print a location) asks about that line of that file.
    @Test @MainActor func anAgentsQuestionOnAPathAndLineLandsOnTheLine() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gloss-ask-line-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "one\ntwo\nthree\nfour\n".write(toFile: "\(root)/a.swift", atomically: true, encoding: .utf8)
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        await model.start()
        let id = try await model.ask(AgentQuestion(host: "local", path: "\(root)/a.swift:3", question: "Why three?", agent: "claude"))
        let note = try #require(try await model.noteStore.note(id))
        let document = try #require(try await model.noteStore.document(note.documentID))
        #expect(document.path == "\(root)/a.swift")
        #expect(note.anchor.summary == "Line 3")
        await model.shutDown()
    }

    /// An agent's `~/…` path is the host's home: this Mac's here.
    @Test @MainActor func aHomePathIsTheHostsHome() async throws {
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        #expect(model.expandingHome("~/proj/a.md", on: .local) == NSHomeDirectory() + "/proj/a.md")
        #expect(model.expandingHome("~", on: .local) == NSHomeDirectory())
        #expect(model.expandingHome("/p/~x", on: .local) == "/p/~x", "only a leading ~")
        #expect(model.expandingHome("~/a", on: HostID(rawValue: "h_unknown")) == "~/a", "a host whose home isn't known yet: as written")
        await model.shutDown()
    }
}
