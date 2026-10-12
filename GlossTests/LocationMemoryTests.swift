import Core
import Foundation
import Testing
@testable import Gloss

/// Each location remembers where you were (2026-10-11): its last document, its selected notes and its panel's tab,
/// colors and search come back when you return to it.
@MainActor
struct LocationMemoryTests {
    func waitUntil(_ condition: @escaping @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        for _ in 0..<250 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("timed out waiting", sourceLocation: sourceLocation)
    }

    @Test func locationStatesRoundTripAndOldWorkspacesStillRead() throws {
        var workspace = Workspace()
        workspace.locations = ["h_local:/a": .init(document: .init(place: .init(host: "h_local", path: "/a/b.md"), line: 9),
                                                 selectedNotes: ["n_1"], filter: "drafts", colors: ["blue"], search: "button")]
        let value = try #require(workspace.encoded())
        #expect(Workspace.decoded(value) == workspace)
        let old = try #require(Workspace.decoded(#"{"folders":[],"back":[],"forward":[],"showsNotesPanel":true}"#))
        #expect(old.locations == nil)

        let moved = Workspace.relocated(workspace.locations ?? [:], DocumentRelocation(hostID: .local, from: "/a", to: "/z", directory: true))
        #expect(moved["h_local:/z"]?.document?.place.path == "/z/b.md", "a renamed folder keeps its state")
    }

    @Test func returningToALocationBringsBackItsFileFiltersAndSelection() async throws {
        let base = ExplorerModel.aliasFree(FileManager.default.temporaryDirectory.appendingPathComponent("gloss-loc-\(UUID().uuidString)").path)
        let one = "\(base)/one", two = "\(base)/two", three = "\(base)/three"
        for folder in [one, two, three] { try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(atPath: base) }
        try (1...60).map { "Line \($0)" }.joined(separator: "\n").write(toFile: "\(one)/a.md", atomically: true, encoding: .utf8)
        try "b\n".write(toFile: "\(two)/b.md", atomically: true, encoding: .utf8)

        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        await model.start()
        defer { Task { await model.shutDown() } }
        await model.explorer.openRoot(hostID: .local, path: one)
        let tabOne = try #require(model.explorer.selectedTabID)
        model.openDocument(hostID: .local, path: "\(one)/a.md")
        let a = try #require(model.activeSession)
        await waitUntil { a.document != nil }
        let note = try await model.noteStore.createNote(documentID: try #require(a.document).id, anchor: .wholeFile, body: "x", color: .blue)
        await waitUntil { model.notesPanel.groups.flatMap(\.notes).count == 1 }
        model.notesPanel.filter = .drafts
        model.notesPanel.colorFilter = [.blue]
        model.notesPanel.searchText = "x"
        model.notesPanel.selection = [note.id]

        // A folder never visited: the viewer clears rather than keep one's file, and the panel starts clear.
        await model.explorer.openRoot(hostID: .local, path: two)
        let tabTwo = try #require(model.explorer.selectedTabID)
        #expect(model.notesPanel.location?.path == two)
        #expect(model.activeSession == nil, "another folder's file doesn't stay up")
        #expect(model.notesPanel.filter == .all && model.notesPanel.colorFilter.isEmpty && model.notesPanel.searchText.isEmpty)
        model.openDocument(hostID: .local, path: "\(two)/b.md")
        await waitUntil { model.activeSession?.path == "\(two)/b.md" }

        // Back to one: its file, filters and selection.
        model.explorer.selectedTabID = tabOne
        await waitUntil { model.activeSession?.path == "\(one)/a.md" }
        #expect(model.notesPanel.filter == .drafts && model.notesPanel.colorFilter == [.blue] && model.notesPanel.searchText == "x")
        #expect(model.notesPanel.selection == [note.id])

        // And two again: its own file.
        model.explorer.selectedTabID = tabTwo
        await waitUntil { model.activeSession?.path == "\(two)/b.md" }
        #expect(model.notesPanel.filter == .all)

        // Opening a file from another folder (as a reveal or a link does) keeps it, whatever that folder remembered.
        await model.explorer.openRoot(hostID: .local, path: three)
        try "c\n".write(toFile: "\(three)/c.md", atomically: true, encoding: .utf8)
        model.explorer.selectedTabID = tabTwo
        model.openDocument(hostID: .local, path: "\(one)/a.md")
        await waitUntil { model.activeSession?.path == "\(one)/a.md" }
        model.explorer.selectedTabID = tabOne
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.activeSession?.path == "\(one)/a.md")

        #expect(model.currentWorkspace().locations?[Workspace.locationKey(host: HostID.local.rawValue, path: two)]?.document?.place.path == "\(two)/b.md", "saved with the workspace")
    }
}
