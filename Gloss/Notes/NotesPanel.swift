import Core
import SwiftUI
import Viewers

struct NotesPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var panel = model.notesPanel
        VStack(spacing: 0) {
            header
            Divider()
            if panel.visibleGroups.isEmpty {
                ContentUnavailableView("No notes", systemImage: "note.text", description: Text("Select something in a file and click Add Note."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $panel.selectedNoteID) {
                    ForEach(panel.visibleGroups) { group in
                        Section {
                            ForEach(group.notes) { note in
                                NoteCard(note: note, document: group.document)
                                    .tag(note.id)
                            }
                        } header: {
                            HStack {
                                Text(group.document.fileName).font(.headline)
                                Spacer()
                                Text(group.document.hostID == .local ? "local" : group.document.hostID.rawValue)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .help(group.document.path)
                        }
                    }
                }
                .listStyle(.inset)
            }
            if let outcome = model.send.lastOutcome ?? model.send.lastError {
                Divider()
                Text(outcome)
                    .font(.caption)
                    .foregroundStyle(model.send.lastError == nil ? Color.secondary : Color.red)
                    .lineLimit(2)
                    .padding(6)
            }
        }
        .task { await model.send.refreshTargets() }
    }

    private var header: some View {
        @Bindable var panel = model.notesPanel
        return VStack(spacing: 6) {
            Picker("Filter", selection: $panel.filter) {
                ForEach(NotesPanelModel.Filter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack(spacing: 6) {
                TargetPicker()
                Spacer()
                Button {
                    Task { await model.sendAllDrafts(scope: .activeDocument) }
                } label: {
                    Label("Send drafts", systemImage: "paperplane")
                }
                .help("Send all drafts in the current document (⌘⇧↩)")
                .disabled(model.send.lastTarget == nil || model.send.isSending)
                Menu {
                    Button("Send all drafts in every document") { Task { await model.sendAllDrafts(scope: .all) } }
                    Button("Copy drafts of current document as packet") { Task { await model.copyPacket(scope: .activeDocument) } }
                    Button("Refresh targets") { Task { await model.send.refreshTargets() } }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
            }
        }
        .padding(8)
    }
}

struct TargetPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            ForEach(model.send.targets) { target in
                Button {
                    model.send.rememberTarget(target)
                } label: {
                    HStack {
                        Text(target.label)
                        if let status = target.status { Text(status).foregroundStyle(.secondary) }
                    }
                }
            }
            if model.send.targets.isEmpty {
                Text("No targets found")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon(for: model.send.lastTarget?.transport))
                Text(model.send.lastTarget?.label ?? "Choose target")
                    .lineLimit(1)
                if model.send.isDiscovering { ProgressView().controlSize(.mini) }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func icon(for kind: TransportKind?) -> String {
        switch kind {
        case .clipboard: "doc.on.clipboard"
        case .herdr: "terminal"
        case .tmux: "rectangle.split.3x1"
        case .opencode: "network"
        case .mcp, .claudeHook, .codexHook: "point.3.connected.trianglepath.dotted"
        case nil: "paperplane"
        }
    }
}

struct NoteCard: View {
    @Environment(AppModel.self) private var model
    let note: Note
    let document: Core.Document

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(nsColor: Theme.color(for: note.color)))
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(note.anchor.summary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    stateBadge
                }
                Text(bodyText)
                    .font(.callout)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Reveal") { model.reveal(note: note, in: document) }
                    if note.state == .draft || note.state == .sent {
                        Button("Send") { Task { await model.send(noteIDs: [note.id]) } }
                            .disabled(model.send.lastTarget == nil)
                    }
                    if note.state != .resolved {
                        Button("Resolve") { Task { await model.notesPanel.resolve(note.id) } }
                    }
                    if note.state == .orphaned {
                        Button("Re-anchor") { model.reanchor(note: note, in: document) }
                        Button("Restore") { Task { await model.notesPanel.restoreDraft(note) } }
                    }
                    Button("Edit") { model.edit(note: note, in: document) }
                    Button("Delete", role: .destructive) { Task { await model.notesPanel.delete(note.id) } }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    private var bodyText: AttributedString {
        (try? AttributedString(markdown: note.body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(note.body)
    }

    @ViewBuilder
    private var stateBadge: some View {
        let (label, color): (String, Color) = switch note.state {
        case .draft: ("draft", .secondary)
        case .sent: ("sent", .blue)
        case .resolved: (note.resolveOutcome == .needsInput ? "needs input" : "resolved", .green)
        case .orphaned: ("orphaned", .orange)
        }
        Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
