import Core
import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class NotesPanelModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all, drafts, sent, resolved, orphaned
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    private let noteStore: NoteStore
    private(set) var groups: [DocumentNotes] = []
    var filter: Filter = .all
    var selectedNoteID: NoteID?
    @ObservationIgnored private var observation: Task<Void, Never>?

    init(noteStore: NoteStore) {
        self.noteStore = noteStore
    }

    func start() {
        observation?.cancel()
        let stream = noteStore.observeDocumentsWithNotes()
        observation = Task { [weak self] in
            do {
                for try await groups in stream {
                    guard let self else { return }
                    self.groups = groups
                }
            } catch {
                Log.notes.error("notes panel observation failed: \(error, privacy: .public)")
            }
        }
    }

    func stop() {
        observation?.cancel()
    }

    var visibleGroups: [DocumentNotes] {
        groups.compactMap { group in
            let notes = group.notes.filter { note in
                switch filter {
                case .all: true
                case .drafts: note.state == .draft
                case .sent: note.state == .sent
                case .resolved: note.state == .resolved
                case .orphaned: note.state == .orphaned
                }
            }
            return notes.isEmpty ? nil : DocumentNotes(document: group.document, notes: notes)
        }
    }

    var draftCount: Int { groups.reduce(0) { $0 + $1.notes.filter { $0.state == .draft }.count } }

    var selectedNote: Note? {
        guard let selectedNoteID else { return nil }
        return groups.lazy.flatMap(\.notes).first { $0.id == selectedNoteID }
    }

    func resolve(_ id: NoteID) async {
        do { try await noteStore.resolve(id) } catch { Log.notes.error("resolve failed: \(error, privacy: .public)") }
    }

    func delete(_ id: NoteID) async {
        do { try await noteStore.deleteNote(id) } catch { Log.notes.error("delete failed: \(error, privacy: .public)") }
    }

    func restoreDraft(_ note: Note) async {
        do { try await noteStore.updateAnchor(note.id, anchor: note.anchor, state: .draft) } catch { Log.notes.error("restore failed: \(error, privacy: .public)") }
    }
}
