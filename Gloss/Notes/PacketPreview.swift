import Core
import SwiftUI
import Viewers

/// Preview Packet (2026-10-11): what Send will hand over, hanging from the Send button. Where it goes and how many notes
/// in how many files; each note as it goes; what the scope leaves out and why; and the packet's exact text. Built as
/// Send builds it, but writes nothing; Send itself stays one click.
struct PacketPreview: View {
    @Environment(AppModel.self) private var model
    @State private var packet: Packet?
    @State private var attachments: [NoteID: Int] = [:]
    @State private var exclusions: [AppModel.SendExclusion] = []
    @State private var failure: String?
    @State private var isBuilding = true
    @State private var showsRaw = false

    private var selection: AppModel.SendSelection { model.sendSelection(scope: model.sendScope) }

    /// What the preview is built from: rebuilt when a note in it, the scope, or Review When Done changes.
    private var key: [String] {
        [model.sendScope.rawValue, model.settings.reviewsResults ? "review" : ""]
            + selection.notes.map { "\($0.id.rawValue)@\($0.updatedAt.timeIntervalSince1970)@\($0.hasUnsentFollowUps)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            if !exclusions.isEmpty { excluded }
            footer
        }
        .padding(DS.Space.m)
        .frame(width: 420)
        .task(id: key) { await build() }
    }

    // MARK: Parts

    private var header: some View {
        let notes = selection.notes
        let files = selection.documentCount
        return VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Text("Preview Packet").font(.headline)
                Spacer(minLength: DS.Space.s)
                Picker("Scope", selection: Binding(get: { model.sendScope }, set: { model.sendScope = $0 })) {
                    ForEach(AppModel.SendScope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            HStack(spacing: DS.Space.xs) {
                Text([model.notesPanel.location?.title,
                      notes.count == 1 ? "1 note" : "\(notes.count) notes",
                      files == 1 ? "1 file" : "\(files) files"].compactMap { $0 }.joined(separator: " · "))
                    .monospacedDigit()
                Image(systemName: "arrow.right").imageScale(.small)
                Text(model.send.lastTarget.map { AgentChip.parts($0.label).agent } ?? "No agent chosen")
                    .fontWeight(.medium)
                    .foregroundStyle(model.send.isTargetAvailable ? Color.primary : Color.orange)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private var content: some View {
        if selection.notes.isEmpty {
            Label("Nothing to send in \(model.sendScope.rawValue.lowercased()).", systemImage: "tray")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, DS.Space.s)
        } else {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Picker("Show", selection: $showsRaw) {
                    Text("Readable").tag(false)
                    Text("Raw").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                ZStack {
                    if showsRaw { raw } else { readable }
                }
                .frame(height: 260)
                .overlay(alignment: .topTrailing) {
                    if isBuilding {
                        ProgressView().controlSize(.small).padding(DS.Space.xs).accessibilityLabel("Preparing")
                    }
                }
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    /// Each note as it goes, by file in the order the packet lists them.
    private var readable: some View {
        let groups = model.notesPanel.visibleGroups.compactMap { group -> (Core.Document, [Note])? in
            let ids = Set(selection.ids)
            let notes = group.notes.filter { ids.contains($0.id) }.sorted { $0.anchor.sortKey < $1.anchor.sortKey }
            return notes.isEmpty ? nil : (group.document, notes)
        }
        let review = model.settings.reviewsResults || selection.notes.contains(where: \.reviewRequested)
        return ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                ForEach(groups, id: \.0.id) { document, notes in
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        Label(document.fileName, systemImage: "doc.text")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(notes) { note in row(note) }
                    }
                }
                if review {
                    Label("Asks the agent to say what it changed, for your review.", systemImage: "eye")
                        .font(.caption)
                        .foregroundStyle(.teal)
                }
            }
            .padding(DS.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
    }

    private func row(_ note: Note) -> some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Capsule().fill(Color(nsColor: Theme.color(for: note.color)).gradient).frame(width: 3)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                HStack(spacing: DS.Space.s) {
                    Label(note.anchor.summary, systemImage: note.anchor.symbol)
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                    if note.state != .draft, note.hasUnsentFollowUps {
                        Text("Follow-up").font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)
                    }
                    if let count = attachments[note.id], count > 0 {
                        Label(count == 1 ? "1 picture" : "\(count) pictures", systemImage: "paperclip")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(NoteCard.styledBody(note.body))
                    .font(.callout)
                    .lineLimit(3)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    /// The packet's exact text, as the agent reads it.
    private var raw: some View {
        ScrollView {
            Text(packet?.text ?? "")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Space.s)
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .overlay(alignment: .bottomLeading) {
            if let target = model.send.lastTarget, target.hostID != .local, !attachments.isEmpty {
                Text("Pictures are copied to \(target.hostID.rawValue) when sent.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(DS.Space.xs)
                    .background(.regularMaterial, in: Capsule())
                    .padding(DS.Space.s)
            }
        }
    }

    /// What the scope leaves out, and the way to bring it in where there is one.
    private var excluded: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("Not included").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(exclusions) { exclusion in
                HStack(spacing: DS.Space.s) {
                    Text(Self.sentence(exclusion)).font(.caption)
                    Spacer(minLength: DS.Space.s)
                    switch exclusion.reason {
                    case .filtered:
                        Button("Show All") { model.notesPanel.clearFilters(); model.notesPanel.showResolved = true }
                    case .otherFiles:
                        Button("Send This Location") { model.sendScope = .all }
                    case .earlierIteration:
                        EmptyView()
                    }
                }
                .controlSize(.small)
                .buttonStyle(.link)
            }
        }
    }

    static func sentence(_ exclusion: AppModel.SendExclusion) -> String {
        let drafts = exclusion.count == 1 ? "1 draft" : "\(exclusion.count) drafts"
        return switch exclusion.reason {
        case .filtered: "\(drafts) hidden by the panel's filters"
        case .earlierIteration: "\(drafts) in an earlier iteration (Bring Forward to send)"
        case .otherFiles: "\(drafts) in other files"
        }
    }

    private var footer: some View {
        let count = selection.notes.count
        return HStack(spacing: DS.Space.s) {
            Spacer(minLength: 0)
            // What Raw shows, review sentence and all.
            Button("Copy") {
                if let text = packet?.text {
                    model.send.writeClipboard(text)
                    model.flashCopied("Packet copied")
                }
                model.showsPacketPreview = false
            }
            .disabled(count == 0 || packet == nil || isBuilding)
            Button(count == 1 ? "Send 1 Note" : "Send \(count) Notes") {
                model.showsPacketPreview = false
                Task { await model.sendVisibleDrafts() }
            }
            .buttonStyle(.glassProminent)
            .disabled(count == 0 || !model.send.isTargetAvailable || model.send.isSending)
            .keyboardShortcut(.defaultAction)
        }
        .controlSize(.small)
    }

    // MARK: Building

    private func build() async {
        isBuilding = true
        // Typing in a card, or a burst of agent replies, settles before the packet is built again.
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        let ids = selection.ids
        let scope = model.sendScope
        let excluded = await model.sendExclusions(scope: scope)
        guard !Task.isCancelled else { return }
        exclusions = excluded
        guard !ids.isEmpty else {
            packet = nil
            failure = nil
            isBuilding = false
            return
        }
        do {
            let built = try await model.send.preview(noteIDs: ids, review: model.settings.reviewsResults)
            guard !Task.isCancelled else { return }
            var counts: [NoteID: Int] = [:]
            for id in ids { counts[id] = (try? await model.noteStore.attachments(for: id).count) ?? 0 }
            packet = built
            attachments = counts.filter { $0.value > 0 }
            failure = nil
        } catch {
            guard !Task.isCancelled else { return }
            failure = "The packet couldn't be prepared: \(error.userMessage)"
        }
        isBuilding = false
    }
}
