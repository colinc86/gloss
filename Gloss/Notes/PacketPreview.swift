import Core
import SwiftUI
import Viewers

/// Preview Packet (2026-10-11): what Send will hand over, hanging from the Send button. Where it goes and how many notes
/// in how many files; each note as it goes; what the scope leaves out and why; and the packet's exact text. Built as
/// Send builds it, but writes nothing; Send itself stays one click.
struct PacketPreview: View {
    @Environment(AppModel.self) private var model
    @State private var preview: SendCoordinator.PreviewData?
    private var packet: Packet? { preview?.packet }
    @State private var attachments: [NoteID: Int] = [:]
    @State private var exclusions: [AppModel.SendExclusion] = []
    @State private var failure: String?
    @State private var isBuilding = true
    @State private var builtKey: [String] = []
    @State private var showsRaw = false

    private var selection: AppModel.SendSelection { model.sendSelection(scope: model.sendScope) }

    /// What the preview is built from: rebuilt when a note in it, the scope, or Review When Done changes.
    private var key: [String] {
        [model.sendScope.rawValue, model.settings.reviewsResults ? "review" : ""]
            + selection.notes.compactMap { note in model.refinement.state(for: note.documentID).map { "\($0.generation):\($0.status.rawValue)" } }
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
        let notes = preview?.notes ?? []
        let ids = notes.reduce(into: [DocumentID]()) { result, note in
            if let id = note.documentID, !result.contains(id) { result.append(id) }
        }
        let review = preview?.review ?? false
        return ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                ForEach(ids, id: \.self) { id in
                    let notes = notes.filter { $0.documentID == id }
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        Label(PathUtilities.name(of: notes.first?.agentPath ?? ""), systemImage: "doc.text")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if let directive = notes.compactMap(\.refinement).first {
                            Text(directive.line).font(.caption).foregroundStyle(Color.accentColor).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(notes, id: \.noteID) { note in row(note) }
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

    private func row(_ note: PacketNote) -> some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Capsule().fill(Color(nsColor: Theme.color(for: selection.notes.first { $0.id == note.noteID }?.color ?? .yellow)).gradient).frame(width: 3)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                HStack(spacing: DS.Space.s) {
                    Label(note.anchor.summary, systemImage: note.anchor.symbol)
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                    if !note.carriedMessages.isEmpty {
                        Text("Follow-up").font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)
                    }
                    if let count = attachments[note.noteID], count > 0 {
                        Label(count == 1 ? "1 picture" : "\(count) pictures", systemImage: "paperclip")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if !note.excerptLines.isEmpty {
                    CodeQuote(text: note.excerptLines.joined(separator: "\n"),language: GrammarCatalog.languageName(forPath: note.agentPath))
                        .font(.caption.monospaced()).lineLimit(4)
                }
                Text(NoteCard.styledBody(Self.readableText(note)))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    /// Human-readable values come from the snapshot, never from escaped protocol text.
    nonisolated static func readableText(_ note: PacketNote) -> String {
        var lines = note.comment.isEmpty ? [] : [note.comment]
        for turn in note.thread.turns {
            switch turn {
            case .agent(let name, let asked, let body): lines.append("\(name) \(asked ? "asked" : "replied"): \(body)")
            case .contributor(let name,let body): lines.append("\(name) replied: \(body)")
            case .user(let body): lines.append("You replied: \(body)")
            case .choices(let choices):
                lines.append(choices.multi ? "Choose any that apply" : "Choose one")
                lines.append(contentsOf: choices.options)
            case .moved(let move, _): lines.append("Moved to \(move.to.summary)")
            }
        }
        return lines.joined(separator: "\n")
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
                Task {
                    if let current = try? await model.send.preview(noteIDs: selection.ids, review: model.settings.reviewsResults) {
                        model.send.writeClipboard(current.text)
                        model.flashCopied("Packet copied")
                    }
                    model.showsPacketPreview = false
                }
            }
            .disabled(count == 0 || packet == nil || isBuilding || builtKey != key)
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
        let requestedKey = key
        // Typing in a card, or a burst of agent replies, settles before the packet is built again.
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        let ids = selection.ids
        let scope = model.sendScope
        let excluded = await model.sendExclusions(scope: scope)
        guard !Task.isCancelled else { return }
        exclusions = excluded
        guard !ids.isEmpty else {
            preview = nil
            failure = nil
            isBuilding = false
            return
        }
        do {
            let built = try await model.send.previewData(noteIDs: ids, review: model.settings.reviewsResults)
            guard !Task.isCancelled else { return }
            var counts: [NoteID: Int] = [:]
            for id in ids { counts[id] = (try? await model.noteStore.attachments(for: id).count) ?? 0 }
            guard !Task.isCancelled, requestedKey == key else { return }
            preview = built
            builtKey = requestedKey
            attachments = counts.filter { $0.value > 0 }
            failure = nil
        } catch {
            guard !Task.isCancelled else { return }
            failure = "The packet couldn't be prepared: \(error.userMessage)"
        }
        isBuilding = false
    }
}
