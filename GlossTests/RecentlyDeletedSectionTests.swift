import Core
import Foundation
import Testing
@testable import Gloss

/// Recently Deleted's sections: one per document, and same-named files told apart by their folders.
@MainActor
struct RecentlyDeletedSectionTests {
    @Test func likeNamedFilesGetTheirFolders() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        var ids: [NoteID] = []
        for path in ["/p/app/README.md", "/p/web/README.md", "/p/app/PLAN.md"] {
            let document = try await store.upsertDocument(hostID: .local, path: path, kind: .markdown, fingerprint: Fingerprint())
            ids.append(try await store.createNote(documentID: document.id, anchor: .wholeFile, body: path, color: .yellow).id)
        }
        try await store.trashNotes(ids)
        let sections = RecentlyDeletedView.sections(try await store.trashedNotes(underRoot: "/p", hostID: .local))
        let labels = Dictionary(uniqueKeysWithValues: sections.map { ($0.document.path, $0.place) })
        #expect(labels.count == 3)
        #expect(labels["/p/app/README.md"] == "…/app")
        #expect(labels["/p/web/README.md"] == "…/web")
        #expect(labels["/p/app/PLAN.md"] == .some(nil), "a unique name needs no folder")
    }
}
