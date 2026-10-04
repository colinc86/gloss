import Core
import Foundation
import Testing
@testable import Gloss

struct OpenWorkTests {
    private func note(_ state: NoteState, at seconds: TimeInterval, outcome: ResolveOutcome? = nil) -> Note {
        Note(id: .new(), documentID: .new(), anchor: .wholeFile, body: "x", state: state, color: .yellow,
             createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: seconds), resolveOutcome: outcome)
    }

    private func document(_ path: String, host: HostID = .local) -> Core.Document {
        Core.Document(id: .new(), hostID: host, path: path, kind: .code, fingerprint: Fingerprint())
    }

    @Test func listsOpenWorkInTheRootNewestFirst() {
        let groups = [
            DocumentNotes(document: document("/private/tmp/p/README.md"), notes: [note(.draft, at: 10), note(.sent, at: 20)]),
            DocumentNotes(document: document("/tmp/p/src/app/a.swift"), notes: [note(.resolved, at: 50, outcome: .needsInput)]),
            DocumentNotes(document: document("/tmp/p/done.md"), notes: [note(.resolved, at: 90)]),
            DocumentNotes(document: document("/tmp/elsewhere/b.md"), notes: [note(.draft, at: 99)]),
            DocumentNotes(document: document("/tmp/p/c.md", host: HostID(rawValue: "remote")), notes: [note(.draft, at: 99)]),
        ]
        let items = OpenWorkItem.items(from: groups, rootPath: "/tmp/p", hostID: .local)
        #expect(items.map(\.document.fileName) == ["a.swift", "README.md"])
        #expect(items[0].place == "src/app")
        #expect(items[0].attention == 1)
        #expect(items[1].place == "")
        #expect((items[1].drafts, items[1].sent) == (1, 1))
    }

    @Test func keepsOnlyTheNewestFew() {
        let groups = (0..<8).map { DocumentNotes(document: document("/r/f\($0).txt"), notes: [note(.draft, at: Double($0))]) }
        #expect(OpenWorkItem.items(from: groups, rootPath: "/r", hostID: .local, limit: 3).map(\.document.fileName) == ["f7.txt", "f6.txt", "f5.txt"])
    }
}
