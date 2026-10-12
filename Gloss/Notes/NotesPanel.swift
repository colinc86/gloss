import AppKit
import Core
import Integrations
import os
import SwiftUI
import Transports
import UniformTypeIdentifiers
import Viewers

struct NotesPanel: View {
    @Environment(AppModel.self) private var model
    /// Clicking a card's text does not move first responder off the viewer by itself; selecting a note claims the
    /// keyboard for the list so arrows browse, Return reveals, and Delete deletes.
    @FocusState private var listFocused: Bool
    @FocusState private var searchFocused: Bool
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        if model.notesPanel.showsRecentlyDeleted {
            RecentlyDeletedView()
        } else {
            notes
        }
    }

    @ViewBuilder private var notes: some View {
        @Bindable var panel = model.notesPanel
        // Worked out once per pass: the runs, and every group in them.
        let runs = panel.sections
        let visible = runs.flatMap(\.groups)
        // Adjacent selected cards are outlined once, together, over the list (issue #19); each of them draws none.
        let selectionRuns = NotesPanelModel.selectionRuns(panel.selection, in: visible)
            .filter { $0.count > 1 }
            .map { $0.map { NoteLinkModel.SelectedCard(id: $0.id, color: $0.color) } }
        let inRuns = Set(selectionRuns.joined().map(\.id))
        VStack(spacing: 0) {
            header
            Divider()
            if panel.location == nil {
                EmptyState(symbol: "folder", title: "Choose a location", message: "Open a folder or page to see its notes.")
            } else if visible.isEmpty, panel.isFiltering {
                let copy = NotesPanelModel.emptyCopy(filter: panel.filter, colors: panel.colorFilter, search: panel.searchText,
                                                     hidingResolved: panel.isHidingResolved)
                EmptyState(symbol: copy.symbol, title: copy.title, message: copy.message,
                           tint: copy.goodNews ? .green : .secondary) {
                    // Clear Search clears only the search; the tab and colours were chosen on purpose.
                    Button(copy.action) {
                        if copy.showsResolved { panel.showResolved = true }
                        else if panel.searchText.trimmingCharacters(in: .whitespaces).isEmpty { panel.clearFilters() } else { panel.searchText = "" }
                    }
                        .buttonStyle(.glass)
                }
                // A new reason to be empty is a new message: fade between them as the tab changes.
                .id(copy)
                .transition(.opacity)
            } else if visible.isEmpty {
                EmptyState(
                    symbol: "note.text",
                    title: "No notes in this location",
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
                List(selection: $panel.selection) {
                    // One run normally; with Separate Resolved Notes, open notes, then a thin rule, then resolved ones.
                    // Keyed by kind, so a run appearing or going (the first note resolved) keeps the other's rows.
                    ForEach(runs) { run in
                        if run.id == .resolved, runs.count > 1 {
                            Divider()
                                .padding(.vertical, DS.Space.xs)
                                .listRowSeparator(.hidden)
                                .accessibilityLabel("Resolved notes follow")
                        }
                        ForEach(run.groups) { group in
                            Section {
                                if group.notes.isEmpty {
                                    Text("No notes in this iteration")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .padding(.vertical, DS.Space.xs)
                                        .listRowSeparator(.hidden)
                                }
                                let iterationStarts = panel.iterationStarts(in: group)
                                ForEach(group.notes) { note in
                                    // All Iterations: a small header where each iteration's notes begin.
                                    if let header = iterationStarts[note.id] {
                                        IterationRunHeader(title: header, isCurrent: note.iteration == group.document.currentIteration)
                                    }
                                    NoteCard(note: note, document: group.document, listActive: listFocused && controlActiveState == .key,
                                             inRun: inRuns.contains(note.id))
                                        .background(NoSystemSelectionHighlight())
                                        // Where the card is, for the path drawn from its note on the page: from AppKit,
                                        // which knows when the table places or re-tiles a row (SwiftUI's first report
                                        // can come before, and none after, so paths waited for a first selection).
                                        .background(CardFrameProbe(id: note.id) { frame, probe in model.noteLink.card(note.id, movedTo: frame, owner: probe) })
                                        .tag(note.id)
                                        .id(note.id)
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
                }
                .id(panel.locationGeneration)
                .listStyle(.inset)
                .focused($listFocused)
                // Clicking the card that is already selected changes no selection, so it would leave the keyboard
                // in the viewer, and Delete would then edit the file instead of the list.
                // A click into a card's own field (a follow-up, an edit) keeps the keyboard there: taking it for the
                // list after the text view became first responder left typing going nowhere.
                .simultaneousGesture(TapGesture().onEnded { if Self.cardField(under: NSApp.currentEvent) == nil { listFocused = true } })
                // Return shows the selected note with its range selected and the viewer focused; Delete deletes at
                // once, with Undo in a toast and in the Edit menu.
                .onKeyPress(.return) {
                    guard !Self.isTypingInCard(NSApp.keyWindow?.firstResponder), let entry = panel.selectedEntry else { return .ignored }
                    model.reveal(note: entry.note, in: entry.document)
                    return .handled
                }
                .onDeleteCommand {
                    guard !Self.isTypingInCard(NSApp.keyWindow?.firstResponder) else { return }
                    // An earlier iteration's cards are read-only.
                    let ids = panel.selectedNotes.filter { !panel.isPast($0) }.map(\.id)
                    guard !ids.isEmpty else { return }
                    Task { await model.notesPanel.delete(ids) }
                }
                // Linked, the list follows the page: the note nearest the middle of the page comes to the middle.
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.noteLink.panelViewport = $0 }
                .onHover { model.noteLink.isPointerInPanel = $0 }
                .onChange(of: visible.flatMap { $0.notes.map(\.id) }, initial: true) { _, ids in
                    model.noteLink.listedIDs = Set(ids)
                }
                .onChange(of: selectionRuns, initial: true) { _, runs in model.noteLink.selectionRuns = runs }
                .onChange(of: listFocused && controlActiveState == .key, initial: true) { _, active in model.noteLink.listActive = active }
                .onDisappear { model.noteLink.selectionRuns = [] }
                .onChange(of: model.noteLink.focusRequest) {
                    guard let id = model.noteLink.focusNoteID else { return }
                    withAnimation(Motion.isReduced ? nil : DS.Motion.smooth) { proxy.scrollTo(id, anchor: .center) }
                }
                }
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: DS.Space.s) {
                AgentsUpdateToast()
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
        .onChange(of: panel.selection) { _, _ in
            model.noteLink.selectedNoteID = panel.selectedNoteID
            // The selected card's note shows at full strength on the page whatever its state (#12).
            model.activeSession?.textController?.focusedNoteID = panel.selectedNoteID
            if !panel.selection.isEmpty,
               !Self.keepsKeyboard(NSApp.keyWindow?.firstResponder, selected: panel.selectedNoteID) { listFocused = true }
            guard let entry = panel.selectedEntry, model.fileSystem(for: entry.document.hostID) != nil else { return }
            model.reveal(note: entry.note, in: entry.document, select: false)
        }
    }

    /// The keyboard is in a card's text field (a follow-up, an edited comment or follow-up), not on the list.
    static func isTypingInCard(_ responder: NSResponder?) -> Bool {
        responder is NoteBodyEditor.SubmitTextView
    }

    /// On a change of selection, the keyboard stays in a card's field only if that card is the one now selected:
    /// typing in one card and then selecting another hands the keyboard to the list.
    static func keepsKeyboard(_ responder: NSResponder?, selected: NoteID?) -> Bool {
        guard let field = responder as? NoteBodyEditor.SubmitTextView, let owner = field.owner else { return false }
        return owner == selected
    }

    /// The card field a click landed in, if any: a click there keeps the keyboard in it; anywhere else in the list,
    /// even while another card's field had it, the list takes it.
    static func cardField(under event: NSEvent?) -> NoteBodyEditor.SubmitTextView? {
        guard let event, let content = event.window?.contentView, let frame = content.superview else { return nil }
        var view = content.hitTest(frame.convert(event.locationInWindow, from: nil))
        while let current = view {
            if let field = current as? NoteBodyEditor.SubmitTextView { return field }
            view = current.superview
        }
        return nil
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
            // Several selected: the bar acts on them all. One selected card carries its own actions, so selecting
            // a note (a click) never pushes the list down.
            if panel.selectedNotes.count > 1 {
                BulkActionBar(notes: panel.selectedNotes)
                    .transition((AnyTransition.move(edge: .top).combined(with: .opacity)).calmed)
            }
            // Results agents resolved for a send that asked for review: reviewed when the user has time.
            if model.review.waitingCount > 0 {
                Button { model.review.start() } label: {
                    Label("Review \(model.review.waitingCount) Result\(model.review.waitingCount == 1 ? "" : "s")", systemImage: "eye")
                        .frame(maxWidth: .infinity)
                }
                .tint(.teal)
                .help("Step through what the agent did on each note, and accept it or follow up")
                .transition(.opacity.calmed)
            }
            // Where notes go, and this document's drafts as ⌘↩ sends them. Several selected bring the selection bar
            // above, which sends what's selected instead (issue #8).
            HStack(spacing: 6) {
                TargetPicker()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                if panel.selectedNotes.count <= 1 {
                    SendDraftsButton(
                        count: model.visibleDrafts.count,
                        colors: panel.colorFilter,
                        filtered: model.draftsAreFiltered,
                        isSending: model.send.isSending,
                        hasTarget: model.send.isTargetAvailable,
                        action: { Task { await model.sendVisibleDrafts() } },
                        menu: { sendMenuItems }
                    )
                    .popover(isPresented: Binding(get: { model.showsPacketPreview }, set: { model.showsPacketPreview = $0 }), arrowEdge: .bottom) {
                        PacketPreview()
                    }
                    .transition(.opacity.calmed)
                }
            }
            // As tall as the chip, which wraps to two lines when the agent has a task: Send fills that height.
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .animation(DS.Motion.snappy, value: panel.selectedNotes.count > 1)
    }

    /// Sends beyond this document's drafts, titled like the Notes menu, with how many notes each touches.
    private var sendMenuItems: some View {
        let fileDrafts = model.sendSelection(scope: .activeDocument).notes.count
        let locationDrafts = model.sendSelection(scope: .all).notes.count
        let shown = model.visibleDrafts.count
        return Group {
            Picker("Send", selection: Binding(get: { model.sendScope }, set: { model.sendScope = $0 })) {
                Text("This File\(fileDrafts > 0 ? " (\(fileDrafts))" : "")").tag(AppModel.SendScope.activeDocument)
                Text("This Location\(locationDrafts > 0 ? " (\(locationDrafts))" : "")").tag(AppModel.SendScope.all)
            }
            .pickerStyle(.inline)
            Toggle("Review When Done", isOn: Binding(get: { model.settings.reviewsResults }, set: { model.settings.reviewsResults = $0 }))
            Divider()
            Button("Preview Packet…") { model.showsPacketPreview = true }
            Button("Copy Shown Notes as Packet\(shown > 0 ? " (\(shown))" : "")") {
                Task { await model.copyVisibleDrafts() }
            }
            .disabled(shown == 0)
        }
    }

    /// Notes per colour across every document (before search and filters, like the state counts).
    private var colorCounts: [(color: NoteColor, count: Int)] {
        var tally: [NoteColor: Int] = [:]
        for group in model.notesPanel.groups { for note in group.notes { tally[note.color, default: 0] += 1 } }
        return NoteColor.allCases.compactMap { color in tally[color].map { (color, $0) } }
    }

    /// Sort order, and whether resolved notes show; the symbol names the current order.
    private var sortMenu: some View {
        @Bindable var panel = model.notesPanel
        return Menu {
            Picker("Sort by", selection: $panel.sort) {
                ForEach(NotesPanelModel.Sort.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Show Resolved Notes", isOn: $panel.showResolved)
            // Nothing to separate while resolved notes are hidden.
            Toggle("Separate Resolved Notes", isOn: $panel.separateResolved)
                .disabled(!panel.showResolved)
            // Earlier iterations' notes, faintly, where they still are in a text document.
            Toggle("Show Earlier Notes", isOn: $panel.showEarlierNotes)
            Divider()
            Button("Recently Deleted", systemImage: "trash") { panel.showsRecentlyDeleted = true }
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
            Button("Refresh Agents") { Task { await model.send.refreshTargets() } }
        } label: {
            AgentChip(
                target: model.send.lastTarget,
                symbol: icon(for: model.send.lastTarget?.transport),
                isDiscovering: model.send.isDiscovering,
                inFolder: model.send.lastTarget.map { target in
                    model.explorer.selectedTab.map { target.runs(inHost: $0.hostID, path: $0.path) } ?? false
                } ?? false,
                isAvailable: model.send.lastTarget == nil || model.send.isTargetAvailable
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        // Pointing at the chip looks for agents started since the last look, so the menu it opens lists them.
        .onHover { inside in
            guard inside, model.send.discoveredAt.map({ Date().timeIntervalSince($0) > 10 }) ?? false else { return }
            Task { await model.send.refreshTargets() }
        }
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
    /// The list has the keyboard in the key window: a selected card's outline is at full strength, muted otherwise,
    /// as the system's selection greys when a list isn't focused.
    var listActive = true
    /// One of two or more adjacent selected cards: the list outlines them together, so the card draws no outline.
    var inRun = false
    @State private var lastSend: SendSummary?
    @State private var thumbnail: NoteThumbnail?
    @State private var attachmentUnavailable = false
    /// The anchored line in the editor's colours, worked out once per note.
    @State private var colouredExcerpt: AttributedString?
    @State private var hovering = false
    /// The whole thread open: every turn and move, the full comment, and the follow-up field.
    @State private var opening = CardOpening()
    /// The collapsed card cuts the comment short, so it offers to open (the latest turn is never cut).
    @State private var commentCut = false
    /// Follow Up… opens the card and puts the caret in its field; the field otherwise waits to be clicked.
    @State private var followUpFocusPending = false
    @State private var followUpFocusRequest = 0
    @State private var followUpFailed = false
    /// Changing a follow-up not yet sent, in place.
    /// Moves whose old text is shown, struck through.
    @State private var openMoves: Set<MessageID> = []
    /// Editing the comment in place (#14), kept in the panel model (`commentEdits`) so a recycled row keeps it.
    private var edit: NotesPanelModel.CommentEdit? { model.notesPanel.commentEdits[note.id] }
    private var editing: Bool { edit != nil }
    private var editRefusal: NotesPanelModel.EditRefusal? { edit?.refusal }
    private var editBody: Binding<String> {
        Binding(get: { model.notesPanel.commentEdits[note.id]?.body ?? "" }, set: { model.notesPanel.commentEdits[note.id]?.body = $0 })
    }
    private var editColor: Binding<NoteColor> {
        Binding(get: { model.notesPanel.commentEdits[note.id]?.color ?? note.color }, set: { model.notesPanel.commentEdits[note.id]?.color = $0 })
    }
    /// The follow-up of this card being changed in place, if any (`followUpEdits`, also in the model).
    private var editingMessageID: MessageID? {
        model.notesPanel.messages(for: note.id).first { model.notesPanel.followUpEdits[$0.id] != nil }?.id
    }

    private var arrived: Bool { model.notesPanel.arrivedIDs.contains(note.id) }

    private var tint: Color { Color(nsColor: Theme.color(for: note.color)) }
    private var isSelected: Bool { model.notesPanel.selectedNoteID == note.id }
    /// Selected alone or among several: drawn as selected either way.
    private var isInSelection: Bool { model.notesPanel.selection.contains(note.id) }
    /// Resolved notes step back so open work leads the eye; a question from the agent leaves its note open, and so
    /// does a result waiting for the user's review.
    private var isSettled: Bool { note.state == .resolved && !note.awaitsReview }
    /// A settled note at rest is one line, plus its latest turn if it has one; selected or opened it shows its actions.
    /// The pointer never changes its size: a card that grows under the pointer moves the one below it.
    private var isCompact: Bool { isSettled && !isSelected && !expanded }
    /// Open: selected (a click), or opened with its toggle.
    private var expanded: Bool { opening.isOpen(selected: isSelected) }

    /// The comment and its thread, from the panel's one observation of every note's messages.
    private var thread: NoteThread { NoteThread(comment: note.body, messages: model.notesPanel.messages(for: note.id)) }

    /// A note of an earlier iteration (issue #18): read-only, offering only Reveal, Bring Forward and the copies.
    private var isPast: Bool { note.iteration < document.currentIteration }

    /// A follow-up needs someone to follow: every note but a draft never sent, whose comment is edited instead.
    private func canFollowUp(_ thread: NoteThread) -> Bool {
        guard !isPast else { return false }
        return note.state != .draft || lastSend != nil || note.author != nil || !thread.entries.isEmpty
    }

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            // The note's colour, as a soft rail that glows on hover; only selection, which the pointer doesn't change,
            // widens it.
            Capsule()
                .fill(tint.gradient)
                .frame(width: isInSelection ? 4 : 3)
                .opacity(isSettled && !isInSelection ? 0.45 : 1)
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
                // Brought forward from an earlier iteration: Gloss's own line in the thread says from where.
                if let origin = model.notesPanel.messages(for: note.id).first(where: { $0.author == .app && $0.kind == .comment })?.body {
                    Label(origin, systemImage: "arrow.uturn.forward")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !isCompact { excerptWell }
                // An agent's own question (ask_user) has no comment of the user's above it: the bubble is the note.
                if editing {
                    editField
                        .transition((AnyTransition.opacity.combined(with: .move(edge: .top))).calmed)
                    if let pending = thread.latest, pending.speaker == .agent {
                        turnView(pending, latest: true, thread: thread)
                    }
                } else {
                    threadView
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
        .animation(DS.Motion.smooth, value: expanded)
        .onChange(of: isSelected) { _, selected in if !selected { opening.deselected() } }
        .animation(DS.Motion.smooth, value: editing)
        .animation(DS.Motion.smooth, value: editingMessageID)
        .animation(DS.Motion.smooth, value: openMoves)
        // Selected, the card is outlined in the note's own colour on a lifted ground, as its highlight and path
        // strengthen on the page; the list draws no selection of its own. A note that just arrived glows in its
        // colour, then settles: the panel answers "where did it go?".
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .fill(Color.primary.opacity(isInSelection ? 0.06 : 0))
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .strokeBorder(tint, lineWidth: 1.5)
                    .opacity(isInSelection && !inRun ? (listActive ? 1 : 0.5) : 0)
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .fill(tint.opacity(arrived ? 0.2 : 0))
                    .animation(arrived ? DS.Motion.snappy : .easeOut(duration: 0.9), value: arrived)
            }
            .padding(-DS.Space.xs)
            .animation(DS.Motion.snappy, value: isInSelection)
        }
        .contextMenu {
            // Right-clicking one of several selected cards acts on all of them, as in Finder and Mail.
            let selected = model.notesPanel.selectedNotes
            if selected.count > 1, selected.contains(where: { $0.id == note.id }) {
                BulkNoteCommands(notes: selected)
            } else {
                commands(dividers: true)
            }
        }
        // One element for VoiceOver: the card is read as a sentence, and every button and menu command is an action
        // on it, instead of a walk through the rail, the pill, and six unlabeled-looking icons.
        // Open, the thread and its follow-up field have to stay reachable, so the card opens up to its children.
        .accessibilityElement(children: expanded || editing ? .contain : .ignore)
        .accessibilityLabel(Self.spokenSummary(note, latest: thread.latest))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityActions {
            commands(dividers: false)
            let thread = thread
            if showsThreadToggle(thread) { Button(threadToggleTitle(thread)) { opening.toggle(selected: isSelected) } }
        }
        // Refetched when the note changes and after every send, so a failure shows without a state change.
        .task(id: "\(note.updatedAt.timeIntervalSince1970)-\(model.send.completedSends)") {
            lastSend = try? await model.noteStore.lastSend(for: note.id)
        }
        // Image and PDF region notes keep a PNG of the region; show it so the card says what was marked.
        .task(id: note.updatedAt) {
            let attachments = (try? await model.noteStore.attachments(for: note.id)) ?? []
            attachmentUnavailable = attachments.contains { !FileManager.default.fileExists(atPath: $0.localPath) }
            guard note.anchor.type == .image || note.anchor.type == .pdf, let attachment = attachments.first else {
                thumbnail = nil
                return
            }
            thumbnail = await NoteThumbnail.load(attachment)
        }
    }

    @ViewBuilder
    private func commands(dividers: Bool) -> some View {
        if isPast {
            Button("Reveal in Viewer") { model.reveal(note: note, in: document) }
            Button("Bring Forward") { Task { await model.iterations.bringForward(note, in: document) } }
            if dividers { Divider() }
            copyCommands
        } else {
            currentCommands(dividers: dividers)
        }
    }

    @ViewBuilder
    private var copyCommands: some View {
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
    }

    @ViewBuilder
    private func currentCommands(dividers: Bool) -> some View {
        if canFollowUp(thread) {
            Button("Follow Up…", action: startFollowUp)
            if dividers { Divider() }
        }
        Button("Reveal in Viewer") { model.reveal(note: note, in: document) }
        Button("Edit…", action: startEdit)
        if note.state == .orphaned {
            Button("Re-anchor to a New Selection") { model.reanchor(note: note, in: document) }
        }
        if note.originalAnchor != nil {
            Button("Restore Original") { Task { await model.notesPanel.restoreOriginalPlace(note.id) } }
        }
        if dividers { Divider() }
        if NotesPanelModel.sendable([note]).count == 1, let target = model.send.lastTarget {
            Button("Send to \(target.label)") { Task { await model.send(noteIDs: [note.id]) } }
        }
        copyCommands
        if dividers { Divider() }
        if note.state == .sent {
            Button("Back to Draft") { Task { await model.notesPanel.unsend(note.id) } }
                .help("Change it and send it again. The agent may already have read it.")
        }
        if note.state != .resolved {
            Button("Resolve") { Task { await model.notesPanel.resolve(note.id) } }
        } else {
            Button("Reopen as Draft") { Task { await model.notesPanel.reopen(note.id) } }
        }
        Button("Delete", role: .destructive) { Task { await model.notesPanel.delete(note.id) } }
    }

    /// The badge's words: orphaned first (nothing else matters until it has a place), then whose turn it is.
    nonisolated static func badgeLabel(_ note: Note) -> String {
        if note.state == .orphaned { return "Orphaned" }
        if note.waitingOnUser || note.hasUnsentFollowUps { return "Your turn" }
        if note.awaitsReview { return "To review" }
        return note.state.rawValue.capitalized
    }

    /// The badge on a card and on the page's peek: Your turn is orange, with a question mark while an agent waits on
    /// an answer and a draft's dashed circle while a follow-up waits to be sent.
    static func badge(_ note: Note) -> StatusPill {
        let style = note.state.style
        let yourTurn = note.state != .orphaned && (note.waitingOnUser || note.hasUnsentFollowUps)
        if !yourTurn, note.awaitsReview {
            return StatusPill(label: badgeLabel(note), symbol: "eye.circle.fill", tint: .teal)
        }
        return StatusPill(label: badgeLabel(note),
                          symbol: yourTurn ? (note.waitingOnUser ? "questionmark.circle.fill" : NoteState.draft.style.symbol) : style.symbol,
                          tint: yourTurn ? .orange : style.tint)
    }

    /// What VoiceOver says for a card: state, colour, where, the comment, and the agent's latest message if the
    /// thread ends with one (else a resolved note's reply).
    nonisolated static func spokenSummary(_ note: Note, latest: NoteThread.Turn? = nil) -> String {
        var parts = ["\(badgeLabel(note)) note, \(note.color.rawValue), \(note.anchor.summary)"]
        // What a sighted reader sees in the excerpt well: the line the note is about, or that it was removed.
        if note.anchor.isRemovalPoint {
            parts.append("Its text was removed")
        } else if let excerpt = excerpt(of: note.anchor) {
            parts.append("On: \(excerpt)")
        }
        parts.append(note.body.trimmingCharacters(in: .whitespacesAndNewlines))
        if let latest, latest.speaker == .agent, !latest.text.isEmpty {
            // As the bubble shows it: who spoke, the words, and whether it waits on you.
            parts.append(AgentMessageBubble.spoken(agent: latest.agent ?? note.author ?? note.resolveAgent, message: latest.text,
                                                   waiting: latest.asks && note.waitingOnUser))
        } else if let latest, latest.speaker == .user, !latest.text.isEmpty {
            parts.append("\(latest.unsent ? "You, not sent" : "You"): \(latest.text)")
        } else if latest == nil, note.state == .resolved, let reply = note.resolveMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty {
            parts.append(AgentMessageBubble.spoken(agent: note.resolveAgent, message: reply, waiting: false))
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

    /// What the note is about, as GitHub review comments show their line: the first line of the anchored text, in the
    /// editor's colours, so a list of notes across files reads without opening each one. A note whose text was
    /// removed says so where the text would be.
    @ViewBuilder
    private var excerptWell: some View {
        if note.anchor.isRemovalPoint {
            Label("Removed", systemImage: "minus.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, DS.Space.xxs + 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
                .help("The text this note was on has been removed; the note marks where it was")
                .accessibilityHidden(true)
                .transition(.opacity)
        } else if let excerpt = Self.excerpt(of: note.anchor) {
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
    }

    /// Collapsed: the comment, the move that took the note from where it was made (while it is still away), and the
    /// latest turn. Open: every turn and move in order, then the follow-up field. The rest of long text and the
    /// earlier turns wait behind "Show conversation", so the latest turn is always in sight and hovering never
    /// resizes the card.
    @ViewBuilder
    private var threadView: some View {
        let thread = thread
        if attachmentUnavailable {
            Label("Original attachment unavailable", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
        if !thread.comment.isEmpty || thumbnail != nil {
            HStack(alignment: .top, spacing: DS.Space.m) {
                TruncatingText(text: Text(Self.styledBody(thread.comment)).font(.callout).foregroundStyle(isSettled ? .secondary : .primary),
                               lineLimit: isCompact ? 1 : 2, expanded: expanded, isCut: $commentCut)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let thumbnail {
                    thumbnailView(thumbnail)
                }
            }
        }
        if expanded {
            ForEach(thread.entries) { entry in
                switch entry {
                case .turn(let turn):
                    turnView(turn, latest: turn.id != nil && turn.id == thread.latest?.id, thread: thread)
                case .move(let move):
                    moveLine(move, isLatest: move.id == thread.latestMove?.id)
                }
            }
            .transition(.opacity)
            if canFollowUp(thread) {
                followUpField
                    .transition(.opacity)
            }
        } else {
            if !isCompact, note.originalAnchor != nil, let move = thread.latestMove {
                moveLine(move, isLatest: true)
            }
            if let latest = thread.latest {
                turnView(latest, latest: true, thread: thread)
            }
        }
        if showsThreadToggle(thread) {
            Button {
                withAnimation(DS.Motion.smooth) { opening.toggle(selected: isSelected) }
            } label: {
                HStack(spacing: DS.Space.xs) {
                    // Down to open, up to close, as the content goes.
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .contentTransition(.symbolEffect(.replace))
                    Text(threadToggleTitle(thread))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Show only the latest turn" : "Show the whole comment and every turn with the agent")
        }
    }

    /// One turn: the agent's as its bubble (orange only for the question still waiting on you), the user's as a
    /// quieter block, marked "Not sent" with Edit and Delete until it goes.
    @ViewBuilder
    private func turnView(_ turn: NoteThread.Turn, latest: Bool, thread: NoteThread) -> some View {
        switch turn.speaker {
        case .agent:
            AgentMessageBubble(message: turn.text, asks: turn.asks,
                               waiting: note.waitingOnUser && turn.id == thread.turns.last(where: { $0.speaker == .agent })?.id,
                               agent: turn.agent ?? note.author ?? note.resolveAgent ?? lastSend.flatMap(NotesPanelModel.agentName))
                // The agent's turn arrives from where the comment ends, like a reply landing in a thread.
                .transition(AnyTransition.asymmetric(insertion: .scale(scale: 0.92, anchor: .topLeading).combined(with: .opacity),
                                                     removal: .opacity).calmed)
        case .user:
            userTurnView(turn)
        }
    }

    private func userTurnView(_ turn: NoteThread.Turn) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            HStack(spacing: DS.Space.xs) {
                Text("You")
                    .foregroundStyle(Color.accentColor)
                if turn.unsent {
                    Text("Not sent")
                        .fontWeight(.regular)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if turn.unsent, !isPast, let id = turn.id, editingMessageID != id {
                    InlineIconButton(title: "Edit this follow-up", symbol: "pencil", emphasized: hovering || isSelected) {
                        model.notesPanel.followUpEdits[id] = turn.text
                    }
                    InlineIconButton(title: "Delete this follow-up", symbol: "trash", role: .destructive, emphasized: hovering || isSelected) {
                        Task { await model.notesPanel.deleteFollowUp(id) }
                    }
                }
            }
            .font(.caption2.weight(.semibold))
            if let id = turn.id, editingMessageID == id {
                messageEditor(id)
            } else {
                Text(Self.styledBody(turn.text))
                    .font(.callout)
                    .foregroundStyle(isSettled ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(turn.unsent ? 0.1 : 0.06), in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
        .overlay {
            // An unsent follow-up is outlined dashed, as a draft's highlight is: it hasn't left the app.
            if turn.unsent {
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.35), style: StrokeStyle(lineWidth: 0.75, dash: [3, 2]))
            }
        }
        .padding(.leading, DS.Space.l)
        .accessibilityElement(children: .combine)
    }

    /// A follow-up not yet sent, changed in place: Return saves (empty deletes it), Escape cancels.
    private func messageEditor(_ id: MessageID) -> some View {
        let panel = model.notesPanel
        let save = {
            let text = panel.followUpEdits[id] ?? ""
            Task {
                if await panel.updateFollowUp(id, text) { panel.followUpEdits[id] = nil }
            }
        }
        let text = Binding(get: { panel.followUpEdits[id] ?? "" }, set: { panel.followUpEdits[id] = $0 })
        return NoteBodyEditor(text: text, onSubmit: save, onCancel: { panel.followUpEdits[id] = nil }, owner: note.id)
            .frame(minHeight: 28, maxHeight: 120)
            .padding(DS.Space.xs)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
    }

    /// A move, as one quiet line: who moved the note, or that its text was removed. Its chevron shows the text the
    /// note was on, struck through; for the move that brought it where it is, Restore Original sits there too.
    private func moveLine(_ move: NoteThread.Move, isLatest: Bool) -> some View {
        let open = openMoves.contains(move.id)
        let canRestore = isLatest && note.originalAnchor != nil
        let hasDetail = move.oldExcerpt != nil || canRestore
        return VStack(alignment: .leading, spacing: DS.Space.xs) {
            Button {
                guard hasDetail else { return }
                if open { openMoves.remove(move.id) } else { openMoves.insert(move.id) }
            } label: {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: move.removed ? "minus.circle" : "pencil")
                    Text(move.title)
                    if hasDetail {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(hasDetail ? (open ? "Hide the original" : "Show the original") : move.title)
            if open {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    if let old = move.oldExcerpt {
                        Text(old)
                            .strikethrough()
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .padding(.horizontal, DS.Space.s)
                            .padding(.vertical, DS.Space.xxs + 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
                            .accessibilityLabel("Was on: \(old)")
                    }
                    if canRestore {
                        Button("Restore Original") { Task { await model.notesPanel.restoreOriginalPlace(note.id) } }
                            .controlSize(.small)
                    }
                }
                .padding(.leading, DS.Space.l)
                .transition(.opacity)
            }
        }
    }

    /// The follow-up field at the bottom of an open card. Return adds what is typed to the thread, unsent; the card's
    /// Send hands it over. Shift-Return starts a new line; Escape clears it. What is typed lives in the panel model,
    /// so it survives the row being recycled.
    private var followUpField: some View {
        let text = Binding(get: { model.notesPanel.followUpText[note.id] ?? "" },
                           set: { model.notesPanel.followUpText[note.id] = $0.isEmpty ? nil : $0 })
        return VStack(alignment: .leading, spacing: DS.Space.xs) {
            NoteBodyEditor(text: text, onSubmit: commitFollowUp, onCancel: { model.notesPanel.followUpText[note.id] = nil },
                           focusesOnAppear: followUpFocusPending, focusRequest: followUpFocusRequest, owner: note.id)
                .frame(minHeight: 28, maxHeight: 120)
                .padding(DS.Space.xs)
                .overlay(alignment: .topLeading) {
                    if text.wrappedValue.isEmpty {
                        // Where the text view draws its first character: its line padding and inset, plus ours.
                        Text(note.waitingOnUser ? "Your answer" : "Follow up")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, DS.Space.xs + 5)
                            .padding(.top, DS.Space.xs + 2)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .strokeBorder(note.waitingOnUser ? Color.orange.opacity(0.5) : Color.primary.opacity(0.12)))
                .onAppear { DispatchQueue.main.async { followUpFocusPending = false } }
                .accessibilityLabel(note.waitingOnUser ? "Your answer" : "Follow up")
            if followUpFailed {
                Label("The follow-up couldn't be added. It's still here.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .transition(.opacity)
            }
        }
    }

    private func startFollowUp() {
        followUpFailed = false
        if expanded {
            followUpFocusRequest += 1
        } else {
            followUpFocusPending = true
            opening.open()
        }
    }

    /// The field clears only once the follow-up is in the thread; if it couldn't be added, the text stays.
    private func commitFollowUp() {
        guard !(model.notesPanel.followUpText[note.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task { followUpFailed = !(await model.notesPanel.commitFollowUp(for: note.id)) }
    }

    /// Offered when there's more than the collapsed card shows: earlier turns or moves, or a comment cut short (the
    /// latest turn is never cut). Whether the comment is cut is measured on its collapsed form, so the button stays
    /// put while the card is open.
    private func showsThreadToggle(_ thread: NoteThread) -> Bool {
        thread.entries.count > 1 || commentCut
            || (thread.latestMove != nil && note.originalAnchor == nil) || expanded
    }

    private func threadToggleTitle(_ thread: NoteThread) -> String {
        let count = thread.turns.count
        if count > 1 { return expanded ? "Hide conversation" : "Show conversation (\(count))" }
        return expanded ? "Show less" : "Show more"
    }

    /// The first line with something on it of a text note's anchored text, trimmed; nil for regions, cells, and
    /// whole-file notes.
    nonisolated static func excerpt(of anchor: Core.Anchor) -> String? {
        guard case .text(let text) = anchor, text.cells == nil else { return nil }
        return text.text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    /// A comment or follow-up with its inline markdown drawn. Only the card changes; the stored text, and so the
    /// packet, stays plain.
    nonisolated static func styledBody(_ body: String) -> AttributedString {
        (try? AttributedString(markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(body)
    }

    private var stateBadge: some View {
        Self.badge(note)
            .id(Self.badgeLabel(note))
        .transition((AnyTransition.scale(scale: 0.85).combined(with: .opacity)).calmed)
    }

    /// The comment, editable where it is: Return saves, Shift-Return adds a line, Escape cancels. Works whether or
    /// not the note is on screen in the viewer. Only the comment: the thread's turns are their own messages.
    private var editField: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            NoteBodyEditor(text: editBody, onSubmit: commitEdit, onCancel: cancelEdit, owner: note.id)
                .frame(minHeight: 44, maxHeight: 160)
                .padding(DS.Space.xs)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(Color(nsColor: Theme.color(for: editColor.wrappedValue)).opacity(0.6)))
            HStack(spacing: DS.Space.s) {
                ColorSwatches(selection: editColor)
                Spacer(minLength: DS.Space.xs)
                Button("Cancel", action: cancelEdit)
                    .controlSize(.small)
                Button("Save", action: commitEdit)
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                    .disabled(editBody.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            // Said in place, with the typing kept: the note changed meanwhile, or the write failed.
            if let editRefusal {
                Label(editRefusal == .changedMeanwhile ? "This note changed while you were editing. Your text is still here." : "The edit couldn't be saved. It's still here.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .transition(.opacity)
            }
        }
    }

    private func startEdit() {
        model.notesPanel.commentEdits[note.id] = .init(body: note.body, color: note.color, original: note.body)
    }

    private func cancelEdit() {
        model.notesPanel.commentEdits[note.id] = nil
    }

    private func commitEdit() {
        let panel = model.notesPanel
        let id = note.id
        guard let edit = panel.commentEdits[id] else { return }
        let body = edit.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        Task {
            if let refusal = await panel.update(id, body: body, color: edit.color, editedFrom: edit.original) {
                panel.commentEdits[id]?.refusal = refusal
                // Changed meanwhile: what's there now becomes the base, so a second Save is a decision made seeing it.
                if refusal == .changedMeanwhile, let current = panel.groups.flatMap(\.notes).first(where: { $0.id == id }) {
                    panel.commentEdits[id]?.original = current.body
                }
            } else {
                panel.commentEdits[id] = nil
            }
        }
    }

    /// Icon actions, quiet until the card is hovered or selected. Send leads for notes still waiting on an agent;
    /// Follow Up leads while the agent waits on the user.
    private var actions: some View {
        let lit = hovering || isSelected
        return HStack(spacing: DS.Space.xxs) {
            if isPast {
                InlineIconButton(title: "Reveal in viewer", symbol: "scope", emphasized: lit) { model.reveal(note: note, in: document) }
                InlineIconButton(title: "Bring forward to the current iteration", symbol: "arrow.uturn.forward", emphasized: lit) {
                    Task { await model.iterations.bringForward(note, in: document) }
                }
                Spacer(minLength: 0)
            } else {
                currentActions(lit: lit)
            }
        }
        .padding(.top, DS.Space.xxs)
    }

    @ViewBuilder
    private func currentActions(lit: Bool) -> some View {
        if !NotesPanelModel.sendable([note]).isEmpty {
            InlineIconButton(title: model.send.lastTarget.map { "Send to \($0.label)" } ?? "Choose an agent to send to",
                             symbol: "paperplane.fill", prominent: true, emphasized: lit || note.hasUnsentFollowUps) {
                Task { await model.send(noteIDs: [note.id]) }
            }
            .disabled(!model.send.isTargetAvailable)
        }
        if canFollowUp(thread) {
            InlineIconButton(title: note.waitingOnUser ? "Answer the agent" : "Follow up", symbol: "arrowshape.turn.up.left.fill",
                             prominent: note.waitingOnUser, emphasized: lit, action: startFollowUp)
        }
        InlineIconButton(title: "Reveal in viewer", symbol: "scope", emphasized: lit) { model.reveal(note: note, in: document) }
        if note.state == .orphaned {
            InlineIconButton(title: "Re-anchor to a new selection", symbol: "link", emphasized: lit) { model.reanchor(note: note, in: document) }
            InlineIconButton(title: "Restore as draft", symbol: "arrow.uturn.backward", emphasized: lit) { Task { await model.notesPanel.restoreDraft(note) } }
        }
        InlineIconButton(title: "Edit the comment", symbol: "pencil", emphasized: lit, action: startEdit)
        if note.state == .sent {
            InlineIconButton(title: "Back to draft (the agent may already have read it)", symbol: "arrow.uturn.backward", emphasized: lit) {
                Task { await model.notesPanel.unsend(note.id) }
            }
        }
        if note.state == .resolved {
            InlineIconButton(title: "Reopen as draft", symbol: "arrow.counterclockwise", emphasized: lit) { Task { await model.notesPanel.reopen(note.id) } }
        } else {
            InlineIconButton(title: "Resolve", symbol: "checkmark", emphasized: lit) { Task { await model.notesPanel.resolve(note.id) } }
        }
        Spacer(minLength: 0)
        InlineIconButton(title: "Delete", symbol: "trash", role: .destructive, emphasized: lit) { Task { await model.notesPanel.delete(note.id) } }
    }
}

/// Reports where a card is on screen, in top-left window coordinates (SwiftUI's `.global`), whenever AppKit moves it:
/// when it enters a window, when its row moves or resizes, when the table resizes, and when the list scrolls. Only a
/// rect that changed is reported; nil when the card leaves the window.
struct CardFrameProbe: NSViewRepresentable {
    /// The note whose card this is: a probe reused for another note reports for it from scratch.
    let id: NoteID
    /// The card's rect (nil when it left the window), and which probe says so.
    let onFrame: (CGRect?, ObjectIdentifier) -> Void
    /// Posted by `NoSystemSelectionHighlight` once it has restyled the table.
    static let tableRestyled = Notification.Name("CardFrameProbe.tableRestyled")

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.onFrame = onFrame
        view.noteID = id
        view.report()
    }

    final class Probe: NSView {
        var onFrame: (CGRect?, ObjectIdentifier) -> Void = { _, _ in }
        /// Changed, nothing has been reported for the new note yet.
        var noteID: NoteID? {
            didSet { if noteID != oldValue { last = nil } }
        }
        private var last: CGRect??
        private var observed: [NSObjectProtocol] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observe()
            report()
            // Once more after this pass, when the table has tiled its rows.
            DispatchQueue.main.async { [weak self] in self?.report() }
        }

        override func layout() {
            super.layout()
            report()
        }

        isolated deinit {
            for token in observed { NotificationCenter.default.removeObserver(token) }
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            report()
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            report()
        }

        func report() {
            let frame = window == nil ? nil : topLeftWindowRect(bounds)
            guard last != .some(frame) else { return }
            last = .some(frame)
            onFrame(frame, ObjectIdentifier(self))
        }

        /// The row, the table, the clip view it scrolls in and the scroll view, the window, and the notes list as a
        /// whole: any of them moving moves the card. Watching stops when the card leaves the window.
        private func observe() {
            for token in observed { NotificationCenter.default.removeObserver(token) }
            observed = []
            guard let window else { return }
            var targets: [(AnyObject?, Notification.Name)] = [(window, NSWindow.didResizeNotification), (nil, NoteLinkModel.panelMoved)]
            var view = superview
            while let current = view {
                if current is NSTableRowView { targets.append((current, NSView.frameDidChangeNotification)) }
                if let table = current as? NSTableView {
                    targets.append((table, NSView.frameDidChangeNotification))
                    targets.append((table, CardFrameProbe.tableRestyled))
                    if let scroll = table.enclosingScrollView {
                        scroll.contentView.postsBoundsChangedNotifications = true
                        targets.append((scroll.contentView, NSView.boundsDidChangeNotification))
                        scroll.postsFrameChangedNotifications = true
                        targets.append((scroll, NSView.frameDidChangeNotification))
                    }
                    break
                }
                view = current.superview
            }
            for (target, name) in targets {
                (target as? NSView)?.postsFrameChangedNotifications = true
                observed.append(NotificationCenter.default.addObserver(forName: name, object: target, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                })
            }
        }
    }
}

/// Turns off the list's own selection fill (the accent or grey band behind a selected row): a selected card draws its
/// own outline in its note's colour. SwiftUI has no modifier for it, so a probe in a row finds the table the list is
/// built on and sets its highlight style to none, a drawing rule only: clicking, ⌘- and ⇧-clicking and arrows still
/// select. Set again on every update, in case the list resets it.
struct NoSystemSelectionHighlight: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) { (view as? Probe)?.apply() }

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            // After this pass: the row may not be in its table yet.
            DispatchQueue.main.async { [weak self] in
                guard let table = self?.enclosingTable, table.selectionHighlightStyle != .none else { return }
                table.selectionHighlightStyle = .none
                // Restyling can re-tile the rows: the cards say where they are now.
                NotificationCenter.default.post(name: CardFrameProbe.tableRestyled, object: table)
            }
        }

        var enclosingTable: NSTableView? {
            var view = superview
            while let current = view {
                if let table = current as? NSTableView { return table }
                view = current.superview
            }
            return nil
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Whether a card shows its whole thread: while it is selected (a click opens it, as before), unless its toggle
/// closed it then; and whenever its toggle opened it, selected or not. Deselecting closes what selection opened.
nonisolated struct CardOpening: Equatable {
    /// Opened by the toggle (or Follow Up…); stays open when the card is deselected.
    private(set) var pinned = false
    /// Closed by the toggle while selected; forgotten when the card is deselected.
    private(set) var closedWhileSelected = false

    func isOpen(selected: Bool) -> Bool { pinned || (selected && !closedWhileSelected) }

    mutating func toggle(selected: Bool) {
        if isOpen(selected: selected) {
            pinned = false
            closedWhileSelected = selected
        } else {
            open()
        }
    }

    mutating func open() {
        pinned = true
        closedWhileSelected = false
    }

    mutating func deselected() { closedWhileSelected = false }
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
            // The document's rounds of notes (issue #18), at the trailing edge; the file name gives way first.
            IterationMenu(document: document)
                .layoutPriority(2)
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
    /// Each path's name, with the folders that tell it apart when another has the same name (`app — work/app`), for
    /// a list that shows names alone, such as the Dock menu's recent folders.
    nonisolated static func titles(for paths: [String]) -> [String] {
        let places = places(for: paths)
        return paths.map { path in
            let name = (path as NSString).lastPathComponent
            return places[path].map { "\(name) — \($0)" } ?? name
        }
    }

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
    /// False when the chosen agent has gone away: the chip keeps its name, marked, rather than swapping in another.
    var isAvailable = true
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
            } else if !isAvailable {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Unavailable")
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
        .help(!isAvailable ? "\(target?.label ?? "This agent") is unavailable. Click to choose another agent or refresh."
              : target.map { "Notes go to \($0.label)\($0.status.map { " (\($0))" } ?? ""). Click to choose another agent." } ?? "Choose where notes are sent")
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

/// A prominent button as tall as the row it sits in, in the agent chip's shape: an accent rounded rectangle with a
/// white label, a secondary fill while disabled, and a small press. `.glassProminent` is a fixed-height capsule, half
/// the chip's height once the chip wraps.
private struct SendHalfButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.leading, DS.Space.m)
            .padding(.trailing, DS.Space.s)
            .padding(.vertical, DS.Space.s)
            .frame(maxHeight: .infinity)
            .background(Color.black.opacity(configuration.isPressed ? 0.12 : 0))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(DS.Motion.snappy, value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

/// The panel's primary action: send the drafts in the chosen scope. Says how many will go, and why it is unavailable.
/// One accent shape split by a hairline: Send on the left, and a chevron on the right whose menu picks the scope
/// (This File or This Location) and copies the packet instead.
private struct SendDraftsButton<MenuItems: View>: View {
    let count: Int
    /// The notes panel's colour filter; the button sends only those colours while it is set.
    var colors: Set<NoteColor> = []
    /// The panel's tab, colours, or search narrow what goes: the tooltip says "shown".
    var filtered = false

    /// "blue " or "blue and pink " while a color filter is on; nothing otherwise.
    private var colorWords: String {
        guard !colors.isEmpty else { return "" }
        let names = colors.map(\.rawValue).sorted()
        return (names.count <= 2 ? names.joined(separator: " and ") : "\(names.count)-color") + " "
    }
    let isSending: Bool
    let hasTarget: Bool
    let action: () -> Void
    @ViewBuilder let menu: () -> MenuItems
    @Environment(\.isEnabled) private var isEnabled
    @State private var hoveringChevron = false

    private var canSend: Bool { isEnabled && hasTarget && count > 0 && !isSending }

    var body: some View {
        HStack(spacing: 0) {
            sendButton
            Rectangle()
                .fill((canSend ? Color.white : Color.secondary).opacity(0.35))
                .frame(width: 1)
                .padding(.vertical, DS.Space.s)
            Menu {
                menu()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, DS.Space.s)
                    .frame(maxHeight: .infinity)
                    .background(Color.white.opacity(hoveringChevron && canSend ? 0.12 : 0))
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: true, vertical: false)
            .onHover { hoveringChevron = $0 }
            .help("Choose what Send sends, or copy it as a packet")
            .accessibilityLabel("Send options")
        }
        .foregroundStyle(canSend ? Color.white : Color.secondary)
        .background(canSend ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.fill.secondary),
                    in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
        .animation(DS.Motion.snappy, value: canSend)
    }

    private var sendButton: some View {
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
        .buttonStyle(SendHalfButtonStyle())
        .disabled(!hasTarget || count == 0 || isSending)
        .animation(DS.Motion.smooth, value: count)
        .animation(DS.Motion.bouncy, value: colors)
        .help(!hasTarget ? "Choose an available agent first" : count == 0 ? "No eligible notes in this scope" : count == 1 ? "Send the shown note in the selected scope (⌘↩)" : "Send the \(count) shown notes in the selected scope (⌘↩)")
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
                if let reason = result.failure, result.cancelled {
                    card(symbol: "exclamationmark.triangle.fill", tint: .orange,
                         title: result.copied ? "Didn't copy \(noun(result.noteIDs.count))" : "Didn't send \(noun(result.noteIDs.count))", detail: reason) {
                        dismissButton
                    }
                    .transition((AnyTransition.move(edge: .bottom).combined(with: .opacity)).calmed)
                    .id(result.id)
                } else if let failure = result.failure {
                    card(symbol: "exclamationmark.circle.fill", tint: .red, title: "Couldn't send \(noun(result.noteIDs.count))", detail: failure) {
                        Button("Retry") { Task { await model.retrySend() } }
                            .buttonStyle(.glassProminent)
                            .controlSize(.small)
                        dismissButton
                    }
                    .transition((AnyTransition.move(edge: .bottom).combined(with: .opacity)).calmed)
                    .id(result.id)
                } else {
                    card(symbol: result.copied ? "doc.on.clipboard.fill" : "checkmark.circle.fill", tint: .green,
                         title: result.copied ? "Copied \(noun(result.noteIDs.count))" : "Sent \(noun(result.noteIDs.count))",
                         detail: result.copied ? "Still drafts until you send them" : "to " + name(result.target)) {
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
            if let first = panel.lastDeleted.first {
                let deleted = panel.lastDeleted
                let failure = panel.undoFailure
                HStack(spacing: DS.Space.m) {
                    Image(systemName: failure == nil ? "trash" : "exclamationmark.triangle.fill")
                        .foregroundStyle(failure == nil ? Color.secondary : Color.orange)
                        .contentTransition(.symbolEffect(.replace))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(failure != nil ? "Undo didn't work" : deleted.count == 1 ? "Note deleted" : "\(deleted.count) notes deleted")
                            .font(.callout.weight(.semibold))
                        Text(failure ?? (deleted.count == 1 ? first.body : deleted.map { $0.body.split(separator: "\n").first.map(String.init) ?? "" }.joined(separator: " · ")))
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
                .task(id: "\(deleted.map(\.id))-\(hovering)-\(failure != nil)") {
                    // A failure stays until dismissed: it needs reading, and the deleted notes are still recoverable.
                    guard !hovering, failure == nil else { return }
                    try? await Task.sleep(for: .seconds(6))
                    guard !Task.isCancelled else { return }
                    if panel.lastDeleted == deleted { panel.dismissUndo() }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(deleted.count == 1 ? "Note deleted" : "\(deleted.count) notes deleted")
            }
        }
        .animation(DS.Motion.bouncy, value: panel.lastDeleted.map(\.id))
    }
}

/// An agent's set-up needs updating (#10): an update changed what Gloss installs (the old prompt hook, an MCP url).
/// Says which agent and why, and opens Settings › Agents, where Update fixes it. Dismissing it holds until something
/// else needs updating.
struct AgentsUpdateToast: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let hooks = model.hooks
        ZStack {
            if hooks.showsUpdateNotice, let first = hooks.needsUpdate.first {
                let count = hooks.needsUpdate.count
                let host = first.key.hostID == .local ? "" : " on \(model.hosts.entry(for: first.key.hostID)?.name ?? first.key.hostID.rawValue)"
                HStack(spacing: DS.Space.m) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(count == 1 ? "\(first.key.agent.displayName)\(host) needs an update" : "\(count) agent set-ups need an update")
                            .font(.callout.weight(.semibold))
                        Text(count == 1 ? first.reason : "Settings › Agents shows which, and Update fixes each.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: DS.Space.s)
                    InlineIconButton(title: "Dismiss", symbol: "xmark", emphasized: true) { hooks.dismissUpdateNotice() }
                    Button("Open Settings") {
                        model.settingsTab = .agents
                        openSettings()
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                }
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, DS.Space.s + 2)
                .readableGlass(in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
                .transition((AnyTransition.move(edge: .bottom).combined(with: .opacity)).calmed)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Agent set-up needs an update")
            }
        }
        .animation(DS.Motion.bouncy, value: hooks.showsUpdateNotice)
    }
}

/// What several selected notes can have done to them at once (issue #8). Each action takes only the notes it makes
/// sense for (Send the drafts and sent notes, Reopen the resolved ones) and says how many in its title.
struct BulkNoteCommands: View {
    @Environment(AppModel.self) private var model
    let notes: [Note]

    var body: some View {
        let ids = notes.map(\.id)
        let sendable = NotesPanelModel.sendable(notes)
        let resolvable = NotesPanelModel.resolvable(notes)
        let reopenable = NotesPanelModel.reopenable(notes)
        if let target = model.send.lastTarget, !sendable.isEmpty {
            Button("Send \(Self.noun(sendable.count)) to \(target.label)") { Task { await model.send(noteIDs: sendable.map(\.id)) } }
        }
        Button("Copy \(Self.noun(notes.count)) as Packet") { Task { await model.copyPacket(noteIDs: ids) } }
        Divider()
        if !resolvable.isEmpty {
            Button("Resolve \(Self.noun(resolvable.count))") { Task { await model.notesPanel.resolve(resolvable.map(\.id)) } }
        }
        if !reopenable.isEmpty {
            Button("Back to Draft (\(Self.noun(reopenable.count)))") { Task { await model.notesPanel.reopen(reopenable.map(\.id)) } }
        }
        Menu("Color") {
            ForEach(NoteColor.allCases, id: \.self) { color in
                Button(color.rawValue.capitalized) { Task { await model.notesPanel.setColor(ids, color) } }
            }
        }
        Divider()
        Button("Delete \(Self.noun(notes.count))", role: .destructive) { Task { await model.notesPanel.delete(ids) } }
    }

    nonisolated static func noun(_ count: Int) -> String { count == 1 ? "1 Note" : "\(count) Notes" }
}

/// Shown above the list while notes are selected (one or more): how many, and the actions that apply to them all.
private struct BulkActionBar: View {
    @Environment(AppModel.self) private var model
    let notes: [Note]

    var body: some View {
        let sendable = NotesPanelModel.sendable(notes)
        let resolvable = NotesPanelModel.resolvable(notes)
        let reopenable = NotesPanelModel.reopenable(notes)
        HStack(spacing: DS.Space.s) {
            Text("\(notes.count) selected")
                .font(.callout.weight(.semibold))
                .contentTransition(.numericText(value: Double(notes.count)))
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: DS.Space.xs)
            if !sendable.isEmpty {
                Button {
                    Task { await model.send(noteIDs: sendable.map(\.id)) }
                } label: {
                    HStack(spacing: DS.Space.xs) {
                        LaunchingPlane(isSending: model.send.isSending)
                        Text(notes.count == 1 ? "Send" : "Send \(sendable.count)")
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(!model.send.isTargetAvailable || model.send.isSending)
                .help(model.send.lastTarget.map { sendable.count == 1 ? "Send the note to \($0.label)" : "Send the \(sendable.count) drafts and sent notes to \($0.label)" } ?? "Choose an agent above first")
            }
            if !resolvable.isEmpty {
                InlineIconButton(title: "Resolve \(resolvable.count)", symbol: "checkmark.circle", emphasized: true) {
                    Task { await model.notesPanel.resolve(resolvable.map(\.id)) }
                }
            }
            if !reopenable.isEmpty {
                InlineIconButton(title: "Back to draft (\(reopenable.count))", symbol: "arrow.uturn.backward", emphasized: true) {
                    Task { await model.notesPanel.reopen(reopenable.map(\.id)) }
                }
            }
            Menu {
                BulkNoteCommands(notes: notes)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions for the selected notes")
            InlineIconButton(title: "Delete \(notes.count)", symbol: "trash", role: .destructive, emphasized: true) {
                Task { await model.notesPanel.delete(notes.map(\.id)) }
            }
            InlineIconButton(title: "Clear the selection", symbol: "xmark", emphasized: true) {
                model.notesPanel.selection = []
            }
        }
        .controlSize(.small)
        .padding(.horizontal, DS.Space.s + 2)
        .padding(.vertical, DS.Space.xs + 1)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(Color.accentColor.opacity(0.25)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(notes.count.counted("note")) selected")
    }
}

/// Above each iteration's notes while a document lists every iteration: "Iteration 2 · Oct 8 · 5 notes".
private struct IterationRunHeader: View {
    let title: String
    let isCurrent: Bool

    var body: some View {
        Label(title, systemImage: isCurrent ? "square.stack.3d.up" : "clock.arrow.circlepath")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .padding(.top, DS.Space.s)
            .listRowSeparator(.hidden)
            .selectionDisabled()
            .accessibilityAddTraits(.isHeader)
    }
}
