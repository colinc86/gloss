import AppKit
import Core
import Integrations
import SwiftUI
import UniformTypeIdentifiers
import Viewers

struct NotesPanel: View {
    @Environment(AppModel.self) private var model
    /// Clicking a card's text does not move first responder off the viewer by itself; selecting a note claims the
    /// keyboard for the list so arrows browse, Return reveals, and Delete deletes.
    @FocusState private var listFocused: Bool
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var panel = model.notesPanel
        let visible = panel.visibleGroups
        VStack(spacing: 0) {
            header
            Divider()
            if visible.isEmpty, panel.isFiltering {
                let copy = NotesPanelModel.emptyCopy(filter: panel.filter, colors: panel.colorFilter, search: panel.searchText)
                EmptyState(symbol: copy.symbol, title: copy.title, message: copy.message,
                           tint: copy.goodNews ? .green : .secondary) {
                    // Clear Search clears only the search; the tab and colours were chosen on purpose.
                    Button(copy.action) {
                        if panel.searchText.trimmingCharacters(in: .whitespaces).isEmpty { panel.clearFilters() } else { panel.searchText = "" }
                    }
                        .buttonStyle(.glass)
                }
                // A new reason to be empty is a new message: fade between them as the tab changes.
                .id(copy)
                .transition(.opacity)
            } else if visible.isEmpty {
                EmptyState(
                    symbol: "note.text",
                    title: "No notes yet",
                    message: "Mark up any file, then hand your notes to an agent in one go.",
                    steps: [
                        .init(symbol: "text.cursor", text: "Select text, a region, or cells in a file"),
                        .init(symbol: "plus.circle.fill", text: "Click Add Note beside the selection"),
                        .init(symbol: "paperplane.fill", text: "Send to an agent, which resolves them"),
                    ]
                )
            } else {
                let places = PathDisambiguator.places(for: visible.map(\.document.path))
                ScrollViewReader { proxy in
                List(selection: $panel.selectedNoteID) {
                    ForEach(visible) { group in
                        Section {
                            ForEach(group.notes) { note in
                                NoteCard(note: note, document: group.document)
                                    .tag(note.id)
                                    .id(note.id)
                                    // Where the card is, for the path drawn from its note on the page.
                                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                                        model.noteLink.card(note.id, movedTo: frame)
                                    }
                                    .onDisappear { model.noteLink.card(note.id, movedTo: nil) }
                            }
                        } header: {
                            DocumentGroupHeader(document: group.document, count: group.notes.count, place: places[group.document.path],
                                                host: group.document.hostID == .local || group.document.hostID == .web ? nil
                                                    : group.document.hostID == .github ? PullRequestPath(group.document.path).map { "\($0.repository) #\($0.number)" }
                                                    : group.document.hostID == .atlassian ? Self.atlassianLabel(group.document.path)
                                                    : (model.hosts.entry(for: group.document.hostID)?.name).map { group.document.kind == .web ? "via \($0)" : $0 } ?? "remote",
                                                // A previous Atlassian site's documents are kept to read, not to open.
                                                open: group.document.path.hasPrefix("/previous-sites/") ? {} : { model.openDocument(hostID: group.document.hostID, path: group.document.path) })
                        }
                    }
                }
                .listStyle(.inset)
                .focused($listFocused)
                // Clicking the card that is already selected changes no selection, so it would leave the keyboard
                // in the viewer, and Delete would then edit the file instead of the list.
                .simultaneousGesture(TapGesture().onEnded { listFocused = true })
                // Return shows the selected note with its range selected and the viewer focused; Delete deletes at
                // once, with Undo in a toast and in the Edit menu.
                .onKeyPress(.return) {
                    guard let entry = panel.selectedEntry else { return .ignored }
                    model.reveal(note: entry.note, in: entry.document)
                    return .handled
                }
                .onDeleteCommand {
                    guard let note = panel.selectedEntry?.note else { return }
                    Task { await model.notesPanel.delete(note.id) }
                }
                // Linked, the list follows the page: the note nearest the middle of the page comes to the middle.
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.noteLink.panelViewport = $0 }
                .onHover { model.noteLink.isPointerInPanel = $0 }
                .onChange(of: visible.flatMap { $0.notes.map(\.id) }, initial: true) { _, ids in
                    model.noteLink.listedIDs = Set(ids)
                }
                .onChange(of: model.noteLink.focusRequest) {
                    guard let id = model.noteLink.focusNoteID else { return }
                    withAnimation(Motion.isReduced ? nil : DS.Motion.smooth) { proxy.scrollTo(id, anchor: .center) }
                }
                }
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: DS.Space.s) {
                UndoDeleteToast()
                SendToast()
            }
            .padding(DS.Space.m)
            // Paths stop short of cards these cover.
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                model.noteLink.panelToasts = frame.height > 2 * DS.Space.m + 1 ? frame : nil
            }
        }
        .task { await model.send.refreshTargets() }
        // Clicking a card, or arrowing through the list, shows the note in the viewer; the list keeps focus.
        // A note on a host that is not connected stays put: arrowing past it must not start an ssh connect (and a
        // key prompt); its Reveal button connects on purpose.
        .onChange(of: panel.selectedNoteID) { _, _ in
            model.noteLink.selectedNoteID = panel.selectedNoteID
            if panel.selectedNoteID != nil { listFocused = true }
            guard let entry = panel.selectedEntry, model.fileSystem(for: entry.document.hostID) != nil else { return }
            model.reveal(note: entry.note, in: entry.document, select: false)
        }
    }

    /// `Jira`, `Confluence`, or, for notes on a site the account no longer uses, that site.
    static func atlassianLabel(_ path: String) -> String {
        if path.hasPrefix("/previous-sites/") {
            let host = path.split(separator: "/").dropFirst().first.map(String.init) ?? "another site"
            return "\(host) (previous site)"
        }
        switch AtlassianPath(path) {
        case .jiraIssue(let project, _)?: return "Jira · \(project)"
        case .confluencePage(let space, _, _, _)?: return "Confluence · \(space)"
        default: return path.hasPrefix("/jira/") ? "Jira" : "Confluence"
        }
    }

    private var header: some View {
        @Bindable var panel = model.notesPanel
        return VStack(spacing: 6) {
            FilterBar(
                options: NotesPanelModel.Filter.allCases,
                selection: $panel.filter,
                title: \.title, symbol: \.symbol, tint: \.tint,
                count: { panel.count(for: $0) },
                urgent: { $0 == .attention }
            )
            HStack(spacing: DS.Space.s) {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search notes", text: $panel.searchText)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onChange(of: panel.searchFocusRequest) { _, _ in
                            searchFocused = true
                            panel.searchFocusPending = false
                        }
                        .onAppear {
                            guard panel.searchFocusPending else { return }
                            panel.searchFocusPending = false
                            DispatchQueue.main.async { searchFocused = true }
                        }
                        // As in any Mac search field: Escape clears the text, and a second Escape leaves the field.
                        .onKeyPress(.escape) {
                            if panel.searchText.isEmpty { searchFocused = false } else { panel.searchText = "" }
                            return .handled
                        }
                    if !panel.searchText.isEmpty {
                        Button {
                            panel.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear the search")
                        .transition((AnyTransition.scale.combined(with: .opacity)).calmed)
                    }
                }
                .padding(.horizontal, DS.Space.s + 2)
                .padding(.vertical, DS.Space.xs + 1)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                .animation(DS.Motion.snappy, value: panel.searchText.isEmpty)
                sortMenu
            }
            ColorFilterStrip(counts: colorCounts, selection: $panel.colorFilter)
            HStack(spacing: 6) {
                TargetPicker()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                SendDraftsButton(
                    count: model.visibleDrafts.count,
                    colors: model.showNotesPanel ? model.notesPanel.colorFilter : [],
                    filtered: model.draftsAreFiltered,
                    isSending: model.send.isSending,
                    hasTarget: model.send.lastTarget != nil
                ) {
                    Task { await model.sendVisibleDrafts() }
                }
                // Title case like every Mac menu, with how many notes each command touches; nothing to act on, no item.
                let allDrafts = model.notesPanel.draftCount
                let documentDrafts = model.visibleDrafts.count
                Menu {
                    Button("Send All Drafts\(allDrafts > 0 ? " (\(allDrafts))" : "")") { Task { await model.sendAllDrafts(scope: .all) } }
                        .disabled(allDrafts == 0 || model.send.lastTarget == nil)
                    Button("\(model.draftsAreFiltered ? "Copy Shown Drafts as Packet" : "Copy This Document's Drafts as Packet")\(documentDrafts > 0 ? " (\(documentDrafts))" : "")") {
                        Task { await model.copyVisibleDrafts() }
                    }
                    .disabled(documentDrafts == 0)
                    Divider()
                    Button("Refresh Agents") { Task { await model.send.refreshTargets() } }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
                .help("More send options")
                .accessibilityLabel("More send options")
            }
        }
        .padding(8)
    }

    /// Notes per colour across every document (before search and filters, like the state counts).
    private var colorCounts: [(color: NoteColor, count: Int)] {
        var tally: [NoteColor: Int] = [:]
        for group in model.notesPanel.groups { for note in group.notes { tally[note.color, default: 0] += 1 } }
        return NoteColor.allCases.compactMap { color in tally[color].map { (color, $0) } }
    }

    /// Sort order; the symbol names the current order.
    private var sortMenu: some View {
        @Bindable var panel = model.notesPanel
        return Menu {
            Picker("Sort by", selection: $panel.sort) {
                ForEach(NotesPanelModel.Sort.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: panel.sort.symbol)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort: \(panel.sort.title)")
    }
}

/// The colours in use, each with its count; click to show only that colour (several may be on), click again to
/// clear. Off chips dim while a filter is on, so what is shown is obvious.
private struct ColorFilterStrip: View {
    let counts: [(color: NoteColor, count: Int)]
    @Binding var selection: Set<NoteColor>

    var body: some View {
        if counts.count > 1 || !selection.isEmpty {
            HStack(spacing: DS.Space.xs) {
                ForEach(counts, id: \.color) { entry in
                    chip(entry.color, entry.count)
                }
                Spacer(minLength: 0)
                if !selection.isEmpty {
                    Button("Clear") { withAnimation(DS.Motion.smooth) { selection = [] } }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .transition(.opacity)
                }
            }
            .animation(DS.Motion.smooth, value: selection)
            .transition(.opacity)
        }
    }

    private func chip(_ color: NoteColor, _ count: Int) -> some View {
        let tint = Color(nsColor: Theme.color(for: color))
        let on = selection.contains(color)
        let dimmed = !selection.isEmpty && !on
        return Button {
            if on { selection.remove(color) } else { selection.insert(color) }
        } label: {
            HStack(spacing: DS.Space.xs) {
                Circle().fill(tint.gradient).frame(width: 8, height: 8)
                Text("\(count)").font(.caption2.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText(value: Double(count)))
            }
            .foregroundStyle(on ? Color.primary : Color.secondary)
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, DS.Space.xxs + 1)
            .background(on ? tint.opacity(0.22) : Color.primary.opacity(0.05), in: Capsule())
            .overlay(Capsule().strokeBorder(on ? tint.opacity(0.7) : .clear, lineWidth: 1))
            .opacity(dimmed ? 0.45 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .help(on ? "Showing \(color.rawValue) notes; click to stop" : "Show only \(color.rawValue) notes")
        .accessibilityLabel("\(color.rawValue.capitalized), \(count)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

struct TargetPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            let agents = model.send.targets.filter { $0.transport != .clipboard }
            let root = model.explorer.selectedTab
            let local = Set(agents.filter { target in root.map { target.runs(inHost: $0.hostID, path: $0.path) } ?? false }.map(\.id))
            if let root, !local.isEmpty {
                Text("\(Image(systemName: "folder.fill")) Running in \(root.title)")
            }
            ForEach(TransportKind.allCases, id: \.self) { kind in
                // Agents working in the explorer's folder lead their section and carry a folder icon.
                let section = agents.filter { $0.transport == kind }.sorted { local.contains($0.id) && !local.contains($1.id) }
                if !section.isEmpty {
                    Section(kind.displayName) {
                        ForEach(section) { target in
                            Button {
                                model.choose(target: target)
                            } label: {
                                targetTitle(target, inFolder: local.contains(target.id))
                            }
                        }
                    }
                }
            }
            if agents.isEmpty {
                Text(model.send.isDiscovering ? "Looking for Agents…" : "No Agents Found")
            }
            Divider()
            Button {
                model.choose(target: ClipboardTransport.target)
            } label: {
                Label("Copy Packet to Clipboard", systemImage: "doc.on.clipboard")
            }
            .help("Paste it into any terminal yourself")
        } label: {
            AgentChip(
                target: model.send.lastTarget,
                symbol: icon(for: model.send.lastTarget?.transport),
                isDiscovering: model.send.isDiscovering,
                inFolder: model.send.lastTarget.map { target in
                    model.explorer.selectedTab.map { target.runs(inHost: $0.hostID, path: $0.path) } ?? false
                } ?? false
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    /// Menus drop a `Label`'s icon, so the folder mark is an inline image in the text.
    private func targetTitle(_ target: AgentTarget, inFolder: Bool) -> Text {
        var title = inFolder ? Text("\(Image(systemName: "folder.fill")) \(target.label)") : Text(target.label)
        if let status = target.status { title = Text("\(title)  \(Text(status).foregroundStyle(.secondary))") }
        return title
    }

    private func icon(for kind: TransportKind?) -> String {
        switch kind {
        case .clipboard: "doc.on.clipboard"
        case .herdr: "terminal"
        case .tmux: "rectangle.split.3x1"
        case .opencode: "network"
        case .mcp, .claudeHook, .codexHook, .promptHook: "point.3.connected.trianglepath.dotted"
        case nil: "paperplane"
        }
    }
}

struct NoteCard: View {
    @Environment(AppModel.self) private var model
    let note: Note
    let document: Core.Document
    @State private var lastSend: SendSummary?
    @State private var thumbnail: NoteThumbnail?
    /// The anchored line in the editor's colours, worked out once per note.
    @State private var colouredExcerpt: AttributedString?
    @State private var hovering = false
    /// Answering an agent's question in place.
    @State private var replying = false
    @State private var answer = ""
    @State private var replyFailed = false
    @FocusState private var answerFocused: Bool

    private var arrived: Bool { model.notesPanel.arrivedIDs.contains(note.id) }

    private var needsInput: Bool { note.state == .resolved && note.resolveOutcome == .needsInput }

    private var tint: Color { Color(nsColor: Theme.color(for: note.color)) }
    private var isSelected: Bool { model.notesPanel.selectedNoteID == note.id }
    /// Resolved notes step back so open work leads the eye; a question back from the agent is still open work.
    private var isSettled: Bool { note.state == .resolved && note.resolveOutcome != .needsInput }
    /// A settled note at rest is one line; under the pointer or selected it opens to its reply and actions.
    private var isCompact: Bool { isSettled && !hovering && !isSelected }

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            // The note's colour, as a soft rail that warms up on hover.
            Capsule()
                .fill(tint.gradient)
                .frame(width: hovering || isSelected ? 4 : 3)
                .opacity(isSettled ? 0.45 : 1)
                .shadow(color: tint.opacity(hovering ? 0.45 : 0), radius: 4)
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(spacing: DS.Space.s) {
                    Label(note.anchor.summary, systemImage: note.anchor.symbol)
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: DS.Space.xs)
                    stateBadge
                }
                // What the note is about, as GitHub review comments show their line: the first line of the anchored
                // text, in the editor's colours, so a list of notes across files reads without opening each one.
                if !isCompact, let excerpt = Self.excerpt(of: note.anchor) {
                    Group {
                        if let colouredExcerpt { Text(colouredExcerpt) } else { Text(excerpt) }
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, DS.Space.s)
                    .padding(.vertical, DS.Space.xxs + 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
                    .help(excerpt)
                    .accessibilityHidden(true)
                    .transition(.opacity)
                    .task(id: excerpt) {
                        colouredExcerpt = SyntaxTheme.highlighted(excerpt, language: GrammarCatalog.languageName(forPath: document.path))
                    }
                }
                HStack(alignment: .top, spacing: DS.Space.m) {
                    Text(bodyText)
                        .font(.callout)
                        .foregroundStyle(isSettled ? .secondary : .primary)
                        .lineLimit(isCompact ? 1 : 6)
                        .fixedSize(horizontal: false, vertical: true)
                    if let thumbnail {
                        Spacer(minLength: 0)
                        thumbnailView(thumbnail)
                    }
                }
                if !isCompact, note.state == .resolved, let message = note.resolveMessage, !message.isEmpty {
                    AgentMessageBubble(message: message, needsInput: needsInput, agent: lastSend.flatMap(NotesPanelModel.agentName))
                        // The agent's turn arrives from where the comment ends, like a reply landing in a thread.
                        .transition(AnyTransition.asymmetric(insertion: .scale(scale: 0.92, anchor: .topLeading).combined(with: .opacity),
                                                             removal: .opacity).calmed)
                }
                if !isCompact, lastSend != nil {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        if let delivery = delivery(now: context.date) {
                            Text(delivery.text)
                                .font(.caption2)
                                .foregroundStyle(delivery.failed ? Color.red : Color.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                if replying {
                    replyField
                        .transition((AnyTransition.opacity.combined(with: .move(edge: .top))).calmed)
                }
                if !isCompact {
                    actions
                        .transition(.opacity)
                }
            }
        }
        .padding(.vertical, DS.Space.s)
        .padding(.horizontal, DS.Space.xs)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            // The note's path on the page is drawn strong while its card is under the pointer.
            if inside { model.noteLink.hoveredNoteID = note.id } else if model.noteLink.hoveredNoteID == note.id { model.noteLink.hoveredNoteID = nil }
        }
        .animation(DS.Motion.snappy, value: hovering)
        .animation(DS.Motion.bouncy, value: note.state)
        .animation(DS.Motion.smooth, value: isCompact)
        .animation(DS.Motion.smooth, value: replying)
        .onChange(of: needsInput) { _, waiting in
            if !waiting, answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { replying = false }
        }
        // A note that just arrived glows in its colour, then settles: the panel answers "where did it go?".
        .background {
            RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                .fill(tint.opacity(arrived ? 0.2 : 0))
                .padding(-DS.Space.xs)
                .animation(arrived ? DS.Motion.snappy : .easeOut(duration: 0.9), value: arrived)
        }
        .contextMenu { commands(dividers: true) }
        // One element for VoiceOver: the card is read as a sentence, and every button and menu command is an action
        // on it, instead of a walk through the rail, the pill, and six unlabeled-looking icons.
        // While answering, the field has to stay reachable, so the card opens up to its children.
        .accessibilityElement(children: replying ? .contain : .ignore)
        .accessibilityLabel(Self.spokenSummary(note))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityActions { commands(dividers: false) }
        // Refetched when the note changes and after every send, so a failure shows without a state change.
        .task(id: "\(note.updatedAt.timeIntervalSince1970)-\(model.send.completedSends)") {
            lastSend = try? await model.noteStore.lastSend(for: note.id)
        }
        // Image and PDF region notes keep a PNG of the region; show it so the card says what was marked.
        .task(id: note.updatedAt) {
            guard note.anchor.type == .image || note.anchor.type == .pdf, let attachment = try? await model.noteStore.attachments(for: note.id).first else {
                thumbnail = nil
                return
            }
            thumbnail = await NoteThumbnail.load(attachment)
        }
    }

    @ViewBuilder
    private func commands(dividers: Bool) -> some View {
        if needsInput {
            Button("Reply to Agent…", action: startReply)
            if dividers { Divider() }
        }
        Button("Reveal in Viewer") { model.reveal(note: note, in: document) }
        Button("Edit…") { model.edit(note: note, in: document) }
        if note.state == .orphaned {
            Button("Re-anchor to a New Selection") { model.reanchor(note: note, in: document) }
        }
        if dividers { Divider() }
        if note.state == .draft || note.state == .sent, let target = model.send.lastTarget {
            Button("Send to \(target.label)") { Task { await model.send(noteIDs: [note.id]) } }
        }
        Button("Copy as Packet") { Task { await model.copyPacket(noteIDs: [note.id]) } }
        Button("Copy Comment") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(note.body, forType: .string)
            model.flashCopied("Comment copied")
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(document.path, forType: .string)
            model.flashCopied("Path copied")
        }
        if dividers { Divider() }
        if note.state != .resolved {
            Button("Resolve") { Task { await model.notesPanel.resolve(note.id) } }
        } else {
            Button("Reopen as Draft") { Task { await model.notesPanel.reopen(note.id) } }
        }
        Button("Delete", role: .destructive) { Task { await model.notesPanel.delete(note.id) } }
    }

    /// What VoiceOver says for a card: state, colour, where, the comment, and the agent's reply if there is one.
    nonisolated static func spokenSummary(_ note: Note) -> String {
        let needsInput = note.state == .resolved && note.resolveOutcome == .needsInput
        let state = needsInput ? "Needs input" : note.state.rawValue.capitalized
        var parts = ["\(state) note, \(note.color.rawValue), \(note.anchor.summary)"]
        // What a sighted reader sees in the excerpt well: the line the note is about.
        if let excerpt = excerpt(of: note.anchor) { parts.append("On: \(excerpt)") }
        parts.append(note.body.trimmingCharacters(in: .whitespacesAndNewlines))
        if note.state == .resolved, let reply = note.resolveMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty {
            // As the bubble says it: a question asks, a finished note replies.
            parts.append("\(needsInput ? "Agent asks" : "Agent replied"): \(reply)")
        }
        return parts.filter { !$0.isEmpty }.map { $0.hasSuffix(".") || $0.hasSuffix("?") || $0.hasSuffix("!") ? $0 : $0 + "." }.joined(separator: " ")
    }

    private func thumbnailView(_ thumbnail: NoteThumbnail) -> some View {
        Image(nsImage: thumbnail.image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: 56, maxHeight: 56)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5))
            .contentShape(Rectangle())
            .onTapGesture { model.reveal(note: note, in: document) }
            .help(thumbnail.help)
            .accessibilityLabel(thumbnail.help)
    }

    /// The latest send, shown once a note left the app or a send of it failed.
    private func delivery(now: Date) -> (text: String, failed: Bool)? {
        guard let lastSend else { return nil }
        let line = NotesPanelModel.deliveryLine(lastSend, now: now)
        return note.state == .draft && !line.failed ? nil : line
    }

    private var bodyText: AttributedString { Self.styledBody(note.body) }

    /// The first line with something on it of a text note's anchored text, trimmed; nil for regions, cells, and
    /// whole-file notes.
    nonisolated static func excerpt(of anchor: Core.Anchor) -> String? {
        guard case .text(let text) = anchor, text.cells == nil else { return nil }
        return text.text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    /// The comment with inline markdown, and the labels of an answered question ("Agent asked:", "Answer:") drawn
    /// as a little conversation: the agent's in the question's orange, yours in the accent colour. Only the card
    /// changes; the stored text, and so the packet, stays plain.
    nonisolated static func styledBody(_ body: String) -> AttributedString {
        var text = (try? AttributedString(markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(body)
        let labels: [(String, Color)] = [(NoteStore.askedLabel, .orange), (NoteStore.answerLabel, .accentColor)]
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let rest = text[lineStart...]
            let lineEnd = rest.characters.firstIndex(of: "\n") ?? text.endIndex
            let line = String(text[lineStart..<lineEnd].characters)
            if let (label, color) = labels.first(where: { line.hasPrefix($0.0) }) {
                let end = text.characters.index(lineStart, offsetBy: label.count)
                text[lineStart..<end].foregroundColor = color
                text[lineStart..<end].font = .callout.weight(.semibold)
            }
            lineStart = lineEnd < text.endIndex ? text.characters.index(after: lineEnd) : text.endIndex
        }
        return text
    }

    private var stateBadge: some View {
        let style = note.state.style
        let needsInput = note.state == .resolved && note.resolveOutcome == .needsInput
        return StatusPill(
            label: needsInput ? "Needs input" : note.state.rawValue.capitalized,
            symbol: needsInput ? "questionmark.circle.fill" : style.symbol,
            tint: needsInput ? .orange : style.tint
        )
        .id(note.state)
        .transition((AnyTransition.scale(scale: 0.85).combined(with: .opacity)).calmed)
    }

    /// Icon actions, quiet until the card is hovered or selected. Send leads for notes still waiting on an agent.
    /// The answer, written where the question is: Return adds it to the note and makes it a draft to send;
    /// Escape puts it away.
    private var replyField: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
        HStack(spacing: DS.Space.s) {
            TextField("Your answer", text: $answer)
                .textFieldStyle(.plain)
                .focused($answerFocused)
                // Focus once the field exists: set together with `replying`, it can land before the field does.
                .onAppear { answerFocused = true }
                .onSubmit(commitReply)
                .onKeyPress(.escape) {
                    replying = false
                    answer = ""
                    return .handled
                }
            Button("Reply", action: commitReply)
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .disabled(!needsInput || answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        // Said in place, with the typed answer kept so it can be copied: the note moved on, or the write failed.
        if !needsInput || replyFailed {
            Label(needsInput ? "The answer couldn't be added. It's still here." : "This note isn't waiting for an answer any more.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .transition(.opacity)
        }
        }
        .font(.callout)
        .padding(DS.Space.s)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(Color.orange.opacity(0.5)))
    }

    private func startReply() {
        replyFailed = false
        replying = true
    }

    /// The field closes only once the answer is in the note; if the note changed meanwhile, the text stays.
    private func commitReply() {
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            if await model.notesPanel.reply(to: note.id, with: answer) {
                replying = false
                answer = ""
            } else {
                replyFailed = true
            }
        }
    }

    private var actions: some View {
        let lit = hovering || isSelected
        return HStack(spacing: DS.Space.xxs) {
            if note.state == .draft || note.state == .sent {
                InlineIconButton(title: model.send.lastTarget.map { "Send to \($0.label)" } ?? "Choose an agent to send to",
                                 symbol: "paperplane.fill", prominent: true, emphasized: lit) {
                    Task { await model.send(noteIDs: [note.id]) }
                }
                .disabled(model.send.lastTarget == nil)
            }
            if needsInput {
                InlineIconButton(title: "Reply to the agent", symbol: "arrowshape.turn.up.left.fill", prominent: true, emphasized: lit, action: startReply)
            }
            InlineIconButton(title: "Reveal in viewer", symbol: "scope", emphasized: lit) { model.reveal(note: note, in: document) }
            if note.state == .orphaned {
                InlineIconButton(title: "Re-anchor to a new selection", symbol: "link", emphasized: lit) { model.reanchor(note: note, in: document) }
                InlineIconButton(title: "Restore as draft", symbol: "arrow.uturn.backward", emphasized: lit) { Task { await model.notesPanel.restoreDraft(note) } }
            }
            InlineIconButton(title: "Edit", symbol: "pencil", emphasized: lit) { model.edit(note: note, in: document) }
            if note.state == .resolved {
                InlineIconButton(title: "Reopen as draft", symbol: "arrow.counterclockwise", emphasized: lit) { Task { await model.notesPanel.reopen(note.id) } }
            } else {
                InlineIconButton(title: "Resolve", symbol: "checkmark", emphasized: lit) { Task { await model.notesPanel.resolve(note.id) } }
            }
            Spacer(minLength: 0)
            InlineIconButton(title: "Delete", symbol: "trash", role: .destructive, emphasized: lit) { Task { await model.notesPanel.delete(note.id) } }
        }
        .padding(.top, DS.Space.xxs)
    }
}

/// A small preview of a note's cropped region or page render.
struct NoteThumbnail {
    let image: NSImage
    let help: String

    /// Decodes a downsampled copy off the main actor; crops can be full-resolution regions of large images.
    static func load(_ attachment: Attachment) async -> NoteThumbnail? {
        let path = attachment.localPath
        guard let image = await decode(path: path, maximumPixelSize: 160) else { return nil }
        let what = attachment.kind == .crop ? "Cropped region" : "Page region"
        return NoteThumbnail(image: image, help: "\(what), \(attachment.width) × \(attachment.height) px")
    }

    @concurrent nonisolated private static func decode(path: String, maximumPixelSize: Int) async -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // Points at 2x, so the 56 pt frame shows the crop's real proportions sharply.
        return NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / 2, height: CGFloat(cgImage.height) / 2))
    }
}

/// A file's section in the notes list: its icon and name, how many notes it has, and the host when not this Mac.
private struct DocumentGroupHeader: View {
    let document: Core.Document
    let count: Int
    /// Parent folders that tell this file from another of the same name in the list; nil when the name is unique.
    var place: String? = nil
    let host: String?
    /// Opens the document, as clicking a group's header does in Mail or Xcode's issue navigator.
    var open: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        HStack(spacing: DS.Space.s) {
            if document.kind == .web {
                Image(systemName: "globe")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (document.path as NSString).pathExtension) ?? .data))
                    .resizable()
                    .frame(width: 14, height: 14)
            }
            Text(document.fileName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if let place {
                Text(place)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .transition(.opacity)
            }
            Text("\(count)")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, DS.Space.xs + 1)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.07), in: Capsule())
                .contentTransition(.numericText(value: Double(count)))
            Spacer(minLength: DS.Space.s)
            // A quiet arrow under the pointer says the header goes somewhere.
            Image(systemName: "arrow.up.forward.square")
                .font(.caption)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
                .offset(x: hovering ? 0 : -4)
            if let host {
                Label(host, systemImage: document.hostID == .github ? "arrow.triangle.pull" : document.hostID == .atlassian ? (document.path.hasPrefix("/jira/") ? "ticket" : "doc.text") : "network")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, DS.Space.xxs)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .animation(DS.Motion.snappy, value: hovering)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens \(document.fileName)")
        .contextMenu {
            Button("Open") { open() }
            if document.hostID == .local {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: document.path)]) }
            }
        }
        .help("Open \(document.path)")
        .animation(DS.Motion.smooth, value: count)
        .animation(DS.Motion.smooth, value: place)
    }
}

/// Tells same-named files apart the way editors label tabs: only names that collide get a place, and each gets the
/// shortest run of parent folders that no other file with that name shares ("docs" or "…/app/docs").
enum PathDisambiguator {
    nonisolated static func places(for paths: [String]) -> [String: String] {
        let unique = Array(Set(paths))
        var result: [String: String] = [:]
        for (_, same) in Dictionary(grouping: unique, by: { ($0 as NSString).lastPathComponent }) where same.count > 1 {
            let parents = same.map { path in Array((path as NSString).deletingLastPathComponent.split(separator: "/").map(String.init).reversed()) }
            let deepest = parents.map(\.count).max() ?? 0
            var depth = 1
            while depth < deepest, Set(parents.map { $0.prefix(depth) }).count < same.count { depth += 1 }
            for (path, folders) in zip(same, parents) {
                let shown = folders.prefix(depth).reversed().joined(separator: "/")
                result[path] = shown.isEmpty ? "/" : (folders.count > depth ? "…/" + shown : shown)
            }
        }
        return result
    }
}

/// Where notes go: the agent's state as a live dot, its name, its task, and its pane; a folder badge when it works
/// in the explorer's folder. Reads at a glance whether the agent is free to take notes.
struct AgentChip: View {
    let target: AgentTarget?
    let symbol: String
    let isDiscovering: Bool
    let inFolder: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: DS.Space.s) {
            if let target {
                StatusDot(status: target.status)
                let parts = Self.parts(target.label)
                // The task on the same line when it fits whole; otherwise on a line of its own, never cut to "Reor…".
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DS.Space.s) {
                        agentLine(parts)
                        if let title = parts.title {
                            Text(title).font(.callout).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        }
                        trailingMarks(parts)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: DS.Space.s) {
                            agentLine(parts)
                            trailingMarks(parts)
                        }
                        if let title = parts.title {
                            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        }
                    }
                }
            } else {
                Image(systemName: symbol).foregroundStyle(.secondary)
                Text(isDiscovering ? "Looking for agents…" : "Choose an agent")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DS.Space.xs)
            if isDiscovering {
                ProgressView().controlSize(.mini)
            }
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .background(Color.primary.opacity(hovering ? 0.08 : 0.05), in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(DS.Motion.snappy, value: hovering)
        .help(target.map { "Notes go to \($0.label)\($0.status.map { " (\($0))" } ?? ""). Click to choose another agent." } ?? "Choose where notes are sent")
    }

    private func agentLine(_ parts: (agent: String, title: String?, pane: String?)) -> some View {
        Text(parts.agent)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
    }

    @ViewBuilder private func trailingMarks(_ parts: (agent: String, title: String?, pane: String?)) -> some View {
        if let pane = parts.pane {
            Text(pane)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
        }
        if inFolder {
            Image(systemName: "folder.fill")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .help("Running in the folder open in the explorer")
        }
    }

    /// `claude · Fix the parser (w1:p2)` → agent, title, pane.
    static func parts(_ label: String) -> (agent: String, title: String?, pane: String?) {
        var rest = label
        var pane: String?
        if rest.hasSuffix(")"), let open = rest.lastIndex(of: "(") {
            pane = String(rest[rest.index(after: open)..<rest.index(before: rest.endIndex)])
            rest = String(rest[..<open]).trimmingCharacters(in: .whitespaces)
        }
        let pieces = rest.components(separatedBy: " · ")
        let title = pieces.dropFirst().joined(separator: " · ")
        return (pieces.first ?? rest, title.isEmpty ? nil : title, pane)
    }
}

/// An agent's state as colour and motion: working pulses blue, waiting on a prompt is orange, idle is green.
struct StatusDot: View {
    let status: String?

    private var style: (color: Color, pulses: Bool, label: String) {
        switch status?.lowercased() {
        case "working", "busy", "running", "thinking": (.blue, true, "Working")
        case "blocked", "waiting", "permission", "needs_input": (.orange, false, "Waiting for you")
        case "idle", "done", "ready": (.green, false, "Idle")
        case nil: (.secondary, false, "Status unknown")
        default: (.secondary, false, status ?? "")
        }
    }

    var body: some View {
        Circle()
            .fill(style.color.gradient)
            .frame(width: 8, height: 8)
            .overlay {
                if style.pulses {
                    // Core Animation runs the loop in the render server: a SwiftUI phase animation re-rendered the
                    // view every frame and kept the app near 20% CPU while an agent worked.
                    PulseRing(color: NSColor(style.color))
                        .frame(width: 8, height: 8)
                        .allowsHitTesting(false)
                }
            }
            .help(style.label)
            .accessibilityLabel(style.label)
    }
}

/// The panel's primary action: send this document's drafts. Says how many will go, and why it is unavailable.
private struct SendDraftsButton: View {
    let count: Int
    /// The notes panel's colour filter; the button sends only those colours while it is set.
    var colors: Set<NoteColor> = []
    /// The panel's tab, colours, or search narrow what goes: the tooltip says "shown".
    var filtered = false

    /// "blue " or "blue and pink " while a colour filter is on; nothing otherwise.
    private var colorWords: String {
        guard !colors.isEmpty else { return "" }
        let names = colors.map(\.rawValue).sorted()
        return (names.count <= 2 ? names.joined(separator: " and ") : "\(names.count)-colour") + " "
    }
    let isSending: Bool
    let hasTarget: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.xs) {
                LaunchingPlane(isSending: isSending)
                Text("Send")
                // While a colour filter is on, Send sends only those colours: the button says so in their colours.
                if !colors.isEmpty {
                    // On a white capsule: a blue dot on the blue button would vanish (and its ring read as ○, the draft symbol).
                    HStack(spacing: -2) {
                        ForEach(colors.sorted { $0.rawValue < $1.rawValue }.prefix(3), id: \.self) { color in
                            Circle()
                                .fill(Color(nsColor: Theme.color(for: color)))
                                .frame(width: 8, height: 8)
                                .overlay(Circle().strokeBorder(.white, lineWidth: 1))
                        }
                    }
                    .padding(.horizontal, 3)
                    .padding(.vertical, 2)
                    .background(.white, in: Capsule())
                    .transition((AnyTransition.scale(scale: 0.6).combined(with: .opacity)).calmed)
                    .accessibilityLabel(colorWords.trimmingCharacters(in: .whitespaces) + " only")
                }
                if count > 0 {
                    Text("\(count)")
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(count)))
                }
            }
            .font(.callout.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
        }
        .buttonStyle(.glassProminent)
        .controlSize(.regular)
        .disabled(!hasTarget || count == 0 || isSending)
        .animation(DS.Motion.smooth, value: count)
        .animation(DS.Motion.bouncy, value: colors)
        .help(!hasTarget ? "Choose an agent first"
              : count == 0 ? (filtered ? "No drafts shown for this document" : "No drafts in this document")
              : filtered ? "Send the \(count) \(colorWords)draft\(count == 1 ? "" : "s") shown for this document (⌘↩)"
              : "Send this document's \(count) draft\(count == 1 ? "" : "s") (⌘↩)")
    }
}

/// The Send button's paper plane, which takes off when a send starts (from the button or ⌘↩): it flies up and away,
/// tilting as it goes, a small spinner holds its place while the packet is in flight, and a fresh plane glides back in
/// from below when the send is over. Under Reduce Motion the plane and spinner simply cross-fade.
struct LaunchingPlane: View {
    let isSending: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = Phase.rest
    /// When the plane took off; a send that finishes at once (the clipboard) still lets the takeoff play out.
    @State private var launchedAt = Date.distantPast
    @State private var launches = 0
    private static let takeoff: Duration = .milliseconds(320)

    enum Phase {
        case rest, away, below

        var offset: CGSize {
            switch self {
            case .rest: .zero
            case .away: CGSize(width: 16, height: -12)
            case .below: CGSize(width: -8, height: 8)
            }
        }
    }

    var body: some View {
        ZStack {
            Image(systemName: "paperplane.fill")
                .rotationEffect(.degrees(phase == .away && !reduceMotion ? -14 : 0))
                .scaleEffect(phase == .rest ? 1 : 0.7)
                .offset(reduceMotion ? .zero : phase.offset)
                .opacity(phase == .rest ? 1 : 0)
            if isSending && phase != .rest {
                ProgressView()
                    .controlSize(.mini)
                    .transition(.opacity.animation(.easeIn(duration: 0.2).delay(reduceMotion ? 0 : 0.2)))
            }
        }
        .frame(width: 14, height: 14)
        .onChange(of: isSending) { _, sending in
            if sending {
                launchedAt = .now
                launches += 1
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .easeIn(duration: 0.32)) { phase = .away }
            } else {
                let flown = Duration.seconds(Date.now.timeIntervalSince(launchedAt))
                let launch = launches
                Task { @MainActor in
                    if flown < Self.takeoff { try? await Task.sleep(for: Self.takeoff - flown) }
                    guard launches == launch else { return }   // another send took off meanwhile; it brings the plane home
                    // Jump below unseen, then glide home: a new plane, not the old one coming back the way it went.
                    var instant = Transaction()
                    instant.disablesAnimations = true
                    withTransaction(instant) { phase = .below }
                    try? await Task.sleep(for: .milliseconds(30))
                    withAnimation(reduceMotion ? .easeOut(duration: 0.15) : DS.Motion.bouncy) { phase = .rest }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Feedback for a send, floating over the bottom of the panel: progress while it goes, a check that bounces and
/// leaves on its own when it arrived, and the reason plus Retry when it did not (that one stays until dismissed).
private struct SendToast: View {
    @Environment(AppModel.self) private var model
    /// How long a success stays up; hovering pauses the countdown.
    private static let lifetime: Double = 4
    @State private var remaining: Double = 1
    @State private var hovering = false

    var body: some View {
        ZStack {
            if let flight = model.send.inFlight {
                card(symbol: nil, tint: .accentColor, title: "Sending \(noun(flight.count))…", detail: name(flight.target)) { EmptyView() }
                    .transition((AnyTransition.move(edge: .bottom).combined(with: .opacity)).calmed)
                    .id("sending")
            } else if let result = model.send.lastResult {
                if let failure = result.failure {
                    card(symbol: "exclamationmark.circle.fill", tint: .red, title: "Couldn't send \(noun(result.noteIDs.count))", detail: failure) {
                        Button("Retry") { Task { await model.send.retry() } }
                            .buttonStyle(.glassProminent)
                            .controlSize(.small)
                        dismissButton
                    }
                    .transition((AnyTransition.move(edge: .bottom).combined(with: .opacity)).calmed)
                    .id(result.id)
                } else {
                    card(symbol: "checkmark.circle.fill", tint: .green, title: "Sent \(noun(result.noteIDs.count))", detail: "to " + name(result.target)) {
                        dismissButton
                    }
                    .overlay(alignment: .bottom) {
                        // Time left before it goes, as a hairline that drains.
                        GeometryReader { proxy in
                            Capsule().fill(Color.green.opacity(0.6))
                                .frame(width: proxy.size.width * remaining, height: 2)
                        }
                        .frame(height: 2)
                        .padding(.horizontal, DS.Space.m)
                        .padding(.bottom, 3)
                    }
                    .onHover { hovering = $0 }
                    .task(id: result.id) { await countDown() }
                    .transition((AnyTransition.move(edge: .bottom).combined(with: .opacity)).calmed)
                    .id(result.id)
                }
            }
        }
        .animation(DS.Motion.bouncy, value: model.send.inFlight?.count)
        .animation(DS.Motion.bouncy, value: model.send.lastResult)
    }

    private func countDown() async {
        remaining = 1
        let step = 0.05
        while remaining > 0 {
            try? await Task.sleep(for: .seconds(step))
            if Task.isCancelled { return }
            if !hovering { withAnimation(.linear(duration: step)) { remaining = max(0, remaining - step / Self.lifetime) } }
        }
        model.send.clearResult()
    }

    private var dismissButton: some View {
        InlineIconButton(title: "Dismiss", symbol: "xmark", emphasized: true) { model.send.clearResult() }
    }

    private func noun(_ count: Int) -> String { count == 1 ? "1 note" : "\(count) notes" }

    private func name(_ target: AgentTarget) -> String {
        let parts = AgentChip.parts(target.label)
        return [parts.agent, parts.title].compactMap { $0 }.joined(separator: " · ")
    }

    private func card<Actions: View>(symbol: String?, tint: Color, title: String, detail: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .center, spacing: DS.Space.m) {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.title2)
                        .foregroundStyle(tint)
                        .symbolEffect(.bounce, options: .nonRepeating)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            Spacer(minLength: DS.Space.s)
            actions()
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.m)
        .readableGlass(in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }
}

/// A ring that grows and fades from the centre of its frame, forever, at no cost to the app's main thread.
private struct PulseRing: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let ring = CAShapeLayer()
        ring.fillColor = nil
        ring.lineWidth = 1.5
        view.layer?.addSublayer(ring)
        context.coordinator.ring = ring
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let ring = context.coordinator.ring else { return }
        ring.frame = view.bounds
        ring.path = CGPath(ellipseIn: view.bounds.insetBy(dx: 0.75, dy: 0.75), transform: nil)
        ring.strokeColor = color.withAlphaComponent(0.6).cgColor
        // With Reduce Motion on, the dot stays still: its colour already says the agent is working.
        guard Motion.allowsLooping else {
            ring.removeAllAnimations()
            ring.opacity = 0
            return
        }
        ring.opacity = 1
        guard ring.animation(forKey: "pulse") == nil else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 2.2
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.8
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 1.2
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        ring.add(group, forKey: "pulse")
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var ring: CAShapeLayer?
    }
}

/// "Note deleted · Undo", floating over the bottom of the panel for six seconds after a delete (paused while the
/// pointer is on it). Deleting asks no question; this is the way back, alongside Edit › Undo.
private struct UndoDeleteToast: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        let panel = model.notesPanel
        ZStack {
            if let deleted = panel.lastDeleted {
                let failure = panel.undoFailure
                HStack(spacing: DS.Space.m) {
                    Image(systemName: failure == nil ? "trash" : "exclamationmark.triangle.fill")
                        .foregroundStyle(failure == nil ? Color.secondary : Color.orange)
                        .contentTransition(.symbolEffect(.replace))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(failure == nil ? "Note deleted" : "Undo didn't work").font(.callout.weight(.semibold))
                        Text(failure ?? deleted.note.body)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(failure == nil ? 1 : 2)
                    }
                    Spacer(minLength: DS.Space.s)
                    if failure != nil {
                        InlineIconButton(title: "Dismiss", symbol: "xmark", emphasized: true) { panel.dismissUndo() }
                    }
                    Button(failure == nil ? "Undo" : "Try Again") { Task { await panel.undoDelete(deleted) } }
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                }
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, DS.Space.s + 2)
                .readableGlass(in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
                .onHover { hovering = $0 }
                // Removed under the pointer (after Undo) it gets no hover-out; the next toast must still time out.
                .onDisappear { hovering = false }
                .transition((AnyTransition.move(edge: .bottom).combined(with: .opacity)).calmed)
                .task(id: "\(deleted.note.id)-\(hovering)-\(failure != nil)") {
                    // A failure stays until dismissed: it needs reading, and the deleted note is still recoverable.
                    guard !hovering, failure == nil else { return }
                    try? await Task.sleep(for: .seconds(6))
                    guard !Task.isCancelled else { return }
                    if panel.lastDeleted == deleted { panel.dismissUndo() }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Note deleted")
            }
        }
        .animation(DS.Motion.bouncy, value: panel.lastDeleted?.note.id)
    }
}
