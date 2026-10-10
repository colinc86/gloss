import Core
import Viewers
import SwiftUI

/// Recently Deleted (issue #15): the notes deleted under the location in front, newest first, read-only. Each can be
/// restored to its document or deleted now; Empty Recently Deleted deletes them all, after asking.
struct RecentlyDeletedView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingEmpty = false

    var body: some View {
        let panel = model.notesPanel
        let scope = model.shownTab.map { RecentlyDeletedScope(hostID: $0.hostID, path: $0.path) }
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.s) {
                Button {
                    panel.showsRecentlyDeleted = false
                } label: {
                    // One target: the chevron and the word both go back.
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.backward")
                        Text("Notes")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Back to Notes")
                .help("Back to the notes")
                Spacer(minLength: DS.Space.s)
                Text("Recently Deleted")
                    .font(.headline)
                Spacer(minLength: DS.Space.s)
                Button("Empty…", role: .destructive) { confirmingEmpty = true }
                    .buttonStyle(.borderless)
                    .disabled(panel.trashed.isEmpty)
                    .help("Delete every note here for good")
            }
            .padding(8)
            Divider()
            if scope == nil {
                EmptyState(symbol: "folder", title: "No folder open",
                           message: "Recently Deleted lists the notes deleted under the folder in front.") {}
            } else if panel.trashed.isEmpty {
                EmptyState(symbol: "trash", title: "Nothing deleted",
                           message: retentionMessage) {}
            } else {
                List {
                    ForEach(Self.sections(panel.trashed), id: \.document.id) { group in
                        Section {
                            ForEach(group.notes) { trashed in
                                TrashedNoteCard(trashed: trashed)
                            }
                        } header: {
                            HStack(spacing: DS.Space.s) {
                                Text(group.document.fileName)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .layoutPriority(1)
                                if let place = group.place {
                                    Text(place)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                Text(retentionMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(DS.Space.s)
            }
        }
        .task(id: scope) { panel.observeTrash(scope) }
        .onDisappear { panel.observeTrash(nil) }
        .confirmationDialog("Delete every note in Recently Deleted for good?", isPresented: $confirmingEmpty) {
            Button("Empty Recently Deleted", role: .destructive) { Task { await panel.emptyRecentlyDeleted() } }
        } message: {
            Text("\(panel.trashed.count == 1 ? "The note" : "All \(panel.trashed.count) notes") deleted under this folder will be gone, with their threads. This can't be undone.")
        }
    }

    private var retentionMessage: String {
        let days = model.settings.trashRetentionDays
        return days == 0 ? "Deleted notes stay here until you empty it." : "Deleted notes stay here for \(days) days, then go for good."
    }

    /// `grouped`, each document with the folders that tell it from another of the same name in the list (nil when
    /// its name is unique), as the notes list labels them: two README.md headers read alike.
    static func sections(_ trashed: [TrashedNote]) -> [(document: Core.Document, notes: [TrashedNote], place: String?)] {
        let groups = grouped(trashed)
        let places = PathDisambiguator.places(for: groups.map(\.document.path))
        return groups.map { ($0.document, $0.notes, places[$0.document.path]) }
    }

    /// The trashed notes by document, documents in the order their newest deletion comes.
    static func grouped(_ trashed: [TrashedNote]) -> [(document: Core.Document, notes: [TrashedNote])] {
        var order: [DocumentID] = []
        var byDocument: [DocumentID: (document: Core.Document, notes: [TrashedNote])] = [:]
        for entry in trashed {
            if byDocument[entry.document.id] == nil {
                order.append(entry.document.id)
                byDocument[entry.document.id] = (entry.document, [])
            }
            byDocument[entry.document.id]?.notes.append(entry)
        }
        return order.compactMap { byDocument[$0] }
    }
}

/// The location Recently Deleted lists: the folder in front, on its host.
struct RecentlyDeletedScope: Hashable, Sendable {
    let hostID: HostID
    let path: String
}

/// A deleted note: read-only, saying when it was deleted, with Restore and Delete Now.
private struct TrashedNoteCard: View {
    @Environment(AppModel.self) private var model
    let trashed: TrashedNote

    private var tint: Color { Color(nsColor: Theme.color(for: trashed.note.color)) }

    var body: some View {
        let note = trashed.note
        HStack(alignment: .top, spacing: DS.Space.m) {
            Capsule()
                .fill(tint.gradient)
                .frame(width: 3)
                .opacity(0.6)
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Label(note.anchor.summary, systemImage: note.anchor.symbol)
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(note.body.isEmpty ? (model.notesPanel.messages(for: note.id).first?.body ?? "") : note.body)
                    .font(.callout)
                    .lineLimit(4)
                    .textSelection(.enabled)
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text("Deleted \(trashed.deletedAt.formatted(.relative(presentation: .named, unitsStyle: .wide)))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .id(context.date)
                }
                HStack(spacing: DS.Space.s) {
                    Button("Restore") { Task { await model.notesPanel.restoreFromTrash([note.id]) } }
                        .controlSize(.small)
                        .help("Put the note back in \(trashed.document.fileName)")
                    Button("Delete Now", role: .destructive) { Task { await model.notesPanel.deleteNow([note.id]) } }
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, DS.Space.s)
        .padding(.horizontal, DS.Space.xs)
        .contextMenu {
            Button("Restore") { Task { await model.notesPanel.restoreFromTrash([note.id]) } }
            Button("Delete Now", role: .destructive) { Task { await model.notesPanel.deleteNow([note.id]) } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Deleted note: \(note.body)")
    }
}
