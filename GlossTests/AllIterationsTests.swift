import Core
import Foundation
import Testing
@testable import Gloss

/// All Iterations (2026-10-11): one document lists every iteration's notes, newest first, under a header per iteration;
/// earlier notes are only looked at.
@MainActor
struct AllIterationsTests {
    private func wait(_ condition: () -> Bool) async {
        for _ in 0..<150 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Timed out waiting for the panel")
    }

    private func line(_ n: Int) -> Anchor {
        .text(TextAnchor(start: .init(line: n, col: 1), end: .init(line: n, col: 2), text: "x", before: "", after: ""))
    }

    /// Two notes in iteration 0, one in iteration 1, and two drafts in the current iteration 2 (one blue).
    private func setUp() async throws -> (NotesPanelModel, Document, [String: NoteID], NoteStore) {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let document = try await store.upsertDocument(hostID: .local, path: "/p/a.md", kind: .markdown, fingerprint: Fingerprint())
        var ids: [String: NoteID] = [:]
        func add(_ name: String, line n: Int, color: NoteColor = .yellow) async throws {
            ids[name] = try await store.createNote(documentID: document.id, anchor: line(n), body: name, color: color).id
        }
        try await add("zero-b", line: 5)
        try await add("zero-a", line: 1)
        _ = try await store.startIteration(documentID: document.id, openNotes: .leave, snapshot: Data("v0".utf8))
        try await add("one", line: 3)
        _ = try await store.startIteration(documentID: document.id, openNotes: .leave, snapshot: Data("v1".utf8))
        try await add("two", line: 2)
        try await add("two-blue", line: 4, color: .blue)

        let panel = NotesPanelModel(noteStore: store)
        panel.setLocation(NotesLocation(hostID: .local, path: "/p"))
        panel.start()
        await wait { panel.allGroups.flatMap(\.notes).count == 2 }
        let live = try #require(panel.allGroups.first?.document)
        return (panel, live, ids, store)
    }

    @Test func everyIterationIsListedNewestFirstUnderItsHeader() async throws {
        let (panel, document, ids, _) = try await setUp()
        defer { panel.stop() }
        panel.sort = .position
        panel.showAllIterations(of: document)
        #expect(panel.listsAllIterations(document))
        await wait { panel.visibleGroups.first?.notes.count == 5 && !panel.iterationsListed.isEmpty }
        let group = try #require(panel.visibleGroups.first)
        #expect(group.notes.map(\.id) == ["two", "two-blue", "one", "zero-a", "zero-b"].compactMap { ids[$0] },
                "newest iteration first, each in the panel's order")
        let starts = panel.iterationStarts(in: group)
        #expect(Set(starts.keys) == Set(["two", "one", "zero-a"].compactMap { ids[$0] }))
        #expect(starts[ids["two"]!]?.hasPrefix("Iteration 2 · Current") == true)
        #expect(starts[ids["one"]!]?.hasPrefix("Iteration 1 · ") == true)

        panel.colorFilter = [.blue]
        #expect(panel.visibleGroups.first?.notes.map(\.id) == [ids["two-blue"]!], "the panel's filters apply to every iteration")
        panel.colorFilter = []

        panel.showAllIterations(of: nil)
        #expect(!panel.listsAllIterations(document))
        #expect(panel.visibleGroups.first?.notes.count == 2, "back to the current iteration")
    }

    @Test func earlierNotesAreNeverActedOnInBulk() async throws {
        let (panel, document, ids, _) = try await setUp()
        defer { panel.stop() }
        panel.showAllIterations(of: document)
        await wait { panel.visibleGroups.first?.notes.count == 5 }
        panel.selection = Set(ids.values)
        #expect(Set(panel.selectedNotes.map(\.id)) == Set([ids["two"]!, ids["two-blue"]!]), "only the current iteration's notes")
        let earlier = try #require(panel.visibleGroups.first?.notes.first { $0.id == ids["one"] })
        #expect(panel.isPast(earlier))
    }

    @Test func anEarlierIterationOnScreenKeepsTheListAndPickingOneEndsIt() async throws {
        let (panel, document, _, _) = try await setUp()
        defer { panel.stop() }
        panel.showAllIterations(of: document)
        await wait { panel.visibleGroups.first?.notes.count == 5 }
        // Revealing an earlier note shows its iteration in the viewer; the panel keeps listing every iteration.
        panel.showIteration(1, of: document)
        #expect(panel.listsAllIterations(document) && panel.viewedIteration?.number == 1)
        #expect(panel.visibleGroups.first?.notes.count == 5)
        // Picking one iteration in the header's menu ends All Iterations first.
        panel.showAllIterations(of: nil)
        await wait { panel.visibleGroups.first?.notes.count == 1 }
        #expect(!panel.listsAllIterations(document) && panel.viewedIteration?.number == 1)
    }

    @Test func anotherDocumentGoingBackToCurrentLeavesTheListAlone() async throws {
        let (panel, document, _, store) = try await setUp()
        defer { panel.stop() }
        let other = try await store.upsertDocument(hostID: .local, path: "/p/b.md", kind: .markdown, fingerprint: Fingerprint())
        panel.showAllIterations(of: document)
        await wait { panel.visibleGroups.first { $0.document.id == document.id }?.notes.count == 5 }
        panel.showIteration(nil, of: other)
        try await Task.sleep(for: .milliseconds(100))
        #expect(panel.listsAllIterations(document))
        #expect(panel.visibleGroups.first { $0.document.id == document.id }?.notes.count == 5, "the listed document keeps its notes")
    }
}
