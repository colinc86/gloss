import AppKit
import Core
import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class NotesPanelModel {
    enum Filter: String, CaseIterable, Identifiable {
        /// `attention`: notes that lost their place, and questions back from agents.
        case all, drafts, sent, resolved, attention
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    enum Sort: String, CaseIterable, Identifiable {
        /// Reading order within each document; documents by path.
        case position
        case newest
        case oldest
        case color
        case state

        var id: String { rawValue }
        var title: String {
            switch self {
            case .position: "Position in File"
            case .newest: "Newest First"
            case .oldest: "Oldest First"
            case .color: "Color"
            case .state: "State"
            }
        }
    }

    private let noteStore: NoteStore
    private(set) var groups: [DocumentNotes] = []
    private(set) var location: NotesLocation?
    private(set) var locationGeneration = 0
    /// Global data stays available to explorer markers and the dock badge.
    var allGroups: [DocumentNotes] { liveGroups }

    func setLocation(_ location: NotesLocation?) {
        guard self.location != location else { return }
        self.location = location
        locationGeneration += 1
        resetPast()
        viewedIteration = nil
        if allIterations != nil {
            allIterations = nil
            onEarlierNotesChange()
        }
        selection = []
        arrivedIDs = []
        arrivalReset?.cancel()
        applyGroups()
    }

    /// Every note's thread after its comment, by note, kept current by one observation for all the cards.
    private(set) var messages: [NoteID: [NoteMessage]] = [:]
    /// What is typed in each card's follow-up field and not yet added, kept here so a recycled row doesn't lose it.
    var followUpText: [NoteID: String] = [:]
    /// A comment being edited in its card (#14): what is typed, the color picked, the comment as it was when editing
    /// began (so a change made meanwhile isn't overwritten), and why a save was refused. Kept here, like the follow-up
    /// field, so a card scrolled out of the list and back still has it.
    struct CommentEdit: Equatable {
        var body: String
        var color: NoteColor
        var original: String
        var refusal: EditRefusal?
    }
    var commentEdits: [NoteID: CommentEdit] = [:]
    /// Unsent follow-ups being changed in place, by message: what is typed.
    var followUpEdits: [MessageID: String] = [:]
    /// Notes that just appeared (made, or brought back by Undo); their cards glow briefly so the eye finds them.
    private(set) var arrivedIDs: Set<NoteID> = []
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var arrivalReset: Task<Void, Never>?

    /// The panel's part of a location's state (2026-10-11): its tab, colors, search and selection.
    func capturedState() -> Workspace.LocationState {
        Workspace.LocationState(selectedNotes: selection.map(\.rawValue).sorted(), filter: filter.rawValue,
                                colors: colorFilter.map(\.rawValue).sorted(), search: searchText)
    }

    /// Puts back a location's tab, colors, search and selection; what isn't remembered starts clear.
    func apply(_ state: Workspace.LocationState?) {
        filter = state?.filter.flatMap(Filter.init(rawValue:)) ?? .all
        colorFilter = Set((state?.colors ?? []).compactMap(NoteColor.init(rawValue:)))
        searchText = state?.search ?? ""
        let listed = Set(groups.flatMap { $0.notes.map(\.id) })
        selection = Set((state?.selectedNotes ?? []).map(NoteID.init(rawValue:))).intersection(listed)
    }

    /// A rename changes a location's path without changing what the person is reviewing.
    func relocate(_ move: DocumentRelocation) {
        if let old = location, old.hostID == move.hostID, let path = move.destination(for: old.path) {
            location = NotesLocation(hostID: old.hostID, path: path, exactDocument: old.exactDocument)
        }
        func mapped(_ document: Document) -> Document {
            var document = document
            if document.hostID == move.hostID, let path = move.destination(for: document.path) { document.path = path }
            return document
        }
        liveGroups = liveGroups.map { DocumentNotes(document: mapped($0.document), notes: $0.notes) }
        if let viewed = viewedIteration { viewedIteration = (mapped(viewed.document), viewed.number) }
        if let all = allIterations { allIterations = mapped(all) }
        applyGroups()
    }

    /// The notes in `new` that `old` did not have. Nothing on the first load: everything is new then, nothing arrived.
    nonisolated static func arrivals(from old: [DocumentNotes], to new: [DocumentNotes], loaded: Bool) -> Set<NoteID> {
        guard loaded else { return [] }
        let before = Set(old.flatMap { $0.notes.map(\.id) })
        return Set(new.flatMap { $0.notes.map(\.id) }).subtracting(before)
    }
    /// Called after every refresh of `groups` (the explorer's note markers follow it).
    @ObservationIgnored var onGroupsChange: ([DocumentNotes]) -> Void = { _ in }
    var filter: Filter = .all
    var sort: Sort = .position {
        didSet {
            guard !isRestoringSort else { return }
            Task { try? await noteStore.setSetting("notes.sort", sort.rawValue) }
        }
    }
    @ObservationIgnored private var isRestoringSort = false
    /// Off, resolved notes leave every tab but Resolved, in the list and on the page. A question back from an agent
    /// stays: it's open work.
    var showResolved = true {
        didSet {
            guard !isRestoringShowResolved, showResolved != oldValue else { return }
            Task { try? await noteStore.setSetting("notes.showResolved", showResolved ? "1" : "0") }
        }
    }
    @ObservationIgnored private var isRestoringShowResolved = false
    /// On, earlier iterations' notes are drawn faintly where they still are in a text document (View › Show Earlier
    /// Notes, 2026-10-11); a document listing every iteration draws them whatever this says.
    var showEarlierNotes = false {
        didSet {
            guard showEarlierNotes != oldValue else { return }
            onEarlierNotesChange()
            guard !isRestoringShowEarlierNotes else { return }
            Task { try? await noteStore.setSetting("notes.showEarlier", showEarlierNotes ? "1" : "0") }
        }
    }
    @ObservationIgnored private var isRestoringShowEarlierNotes = false
    /// Whether earlier notes are drawn changed: Show Earlier Notes, or the document listing every iteration.
    @ObservationIgnored var onEarlierNotesChange: () -> Void = {}
    /// On, open notes are listed above resolved ones, the two runs apart (2026-10-08). Only while resolved notes show.
    var separateResolved = false {
        didSet {
            guard !isRestoringSeparateResolved, separateResolved != oldValue else { return }
            Task { try? await noteStore.setSetting("notes.separateResolved", separateResolved ? "1" : "0") }
        }
    }
    @ObservationIgnored private var isRestoringSeparateResolved = false
    /// Matched against note text, file name, resolve message, and the thread's messages, case-insensitively.
    var searchText = ""
    /// Bumped by Notes › Search Notes to put the caret in the search field.
    var searchFocusRequest = 0
    /// Set with a request; consumed by the field, including one that only appears once the panel opens.
    @ObservationIgnored var searchFocusPending = false
    /// Empty means every color.
    var colorFilter: Set<NoteColor> = []
    /// The selected cards: one by a click, several by ⌘-click, ⇧-click or ⌘A (issue #8).
    var selection: Set<NoteID> = [] {
        didSet {
            // A note selected from elsewhere (the page's note popover, Next Note) is never a card nobody can see.
            guard selection != oldValue, selection.count == 1, let id = selection.first,
                  let note = groups.lazy.flatMap(\.notes).first(where: { $0.id == id }) else { return }
            makeListed(note)
        }
    }
    /// The one selected note; nil when none or several are selected. Setting it selects just that note.
    var selectedNoteID: NoteID? {
        get { selection.count == 1 ? selection.first : nil }
        set { selection = newValue.map { [$0] } ?? [] }
    }
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var messageObservation: Task<Void, Never>?

    init(noteStore: NoteStore) {
        self.noteStore = noteStore
    }

    func start() {
        observation?.cancel()
        let initial = sort
        let initialShowResolved = showResolved
        let initialSeparateResolved = separateResolved
        let initialShowEarlierNotes = showEarlierNotes
        Task { [weak self] in
            guard let self, let stored = try? await noteStore.setting("notes.showEarlier") else { return }
            guard showEarlierNotes == initialShowEarlierNotes else { return }
            isRestoringShowEarlierNotes = true
            showEarlierNotes = stored == "1"
            isRestoringShowEarlierNotes = false
        }
        Task { [weak self] in
            guard let self, let stored = try? await noteStore.setting("notes.sort"), let restored = Sort(rawValue: stored) else { return }
            // A pick made while the read was in flight wins over the stored value.
            guard sort == initial else { return }
            isRestoringSort = true
            sort = restored
            isRestoringSort = false
        }
        Task { [weak self] in
            guard let self, let stored = try? await noteStore.setting("notes.showResolved") else { return }
            guard showResolved == initialShowResolved else { return }
            isRestoringShowResolved = true
            showResolved = stored != "0"
            isRestoringShowResolved = false
        }
        Task { [weak self] in
            guard let self, let stored = try? await noteStore.setting("notes.separateResolved") else { return }
            guard separateResolved == initialSeparateResolved else { return }
            isRestoringSeparateResolved = true
            separateResolved = stored == "1"
            isRestoringSeparateResolved = false
        }
        messages = noteStore.allMessagesNow()
        let messageStream = noteStore.observeAllMessages()
        messageObservation?.cancel()
        messageObservation = Task { [weak self] in
            do {
                for try await messages in messageStream { self?.messages = messages }
            } catch {
                Log.notes.error("notes panel message observation failed: \(error, privacy: .public)")
            }
        }
        let stream = noteStore.observeDocumentsWithNotes()
        observation = Task { [weak self] in
            do {
                for try await groups in stream {
                    guard let self else { return }
                    let arrived = Self.arrivals(from: self.liveGroups, to: groups, loaded: self.hasLoaded).intersection(Set(groups.filter { self.location?.contains($0.document) == true }.flatMap { $0.notes.map(\.id) }))
                    self.hasLoaded = true
                    if !arrived.isEmpty {
                        self.arrivedIDs.formUnion(arrived)
                        self.arrivalReset?.cancel()
                        self.arrivalReset = Task { [weak self] in
                            try? await Task.sleep(for: .seconds(1.6))
                            guard !Task.isCancelled else { return }
                            self?.arrivedIDs = []
                        }
                    }
                    self.liveGroups = groups
                    self.applyGroups()
                    self.onGroupsChange(groups)
                }
            } catch {
                Log.notes.error("notes panel observation failed: \(error, privacy: .public)")
            }
        }
    }

    func stop() {
        observation?.cancel()
        messageObservation?.cancel()
        pastObservation?.cancel()
        iterationsObservation?.cancel()
        for task in choiceWrites.values { task.cancel() }
        choiceWrites.removeAll(); pendingChoiceWrites.removeAll()
    }

    // MARK: Iterations

    /// Each document's notes in its current iteration, as observed; `groups` is this with an earlier iteration's
    /// notes in place of its document's while one is looked at (issue #18).
    private var liveGroups: [DocumentNotes] = []
    /// The earlier iteration listed for one document, while the viewer shows it.
    private(set) var viewedIteration: (document: Document, number: Int)?
    @ObservationIgnored private var pastNotes: [Note] = []
    @ObservationIgnored private var pastObservation: Task<Void, Never>?
    @ObservationIgnored private var pastGeneration = 0

    /// The document listing every iteration's notes (All Iterations), newest iteration first; one at a time, and never
    /// together with `viewedIteration`.
    private(set) var allIterations: Document?
    /// That document's iterations, for the headers between them.
    private(set) var iterationsListed: [Iteration] = []
    @ObservationIgnored private var iterationsObservation: Task<Void, Never>?

    /// A note of an earlier iteration than its document's current one: read-only in the panel, and never sent or
    /// acted on in bulk.
    func isPast(_ note: Note) -> Bool {
        guard let document = liveGroups.first(where: { $0.document.id == note.documentID })?.document
            ?? (viewedIteration?.document.id == note.documentID ? viewedIteration?.document : nil) else { return false }
        return note.iteration < document.currentIteration
    }

    /// Whether `document` lists every iteration's notes.
    func listsAllIterations(_ document: Document) -> Bool { allIterations?.id == document.id }

    /// Lists iteration `number` of `document` in place of its current notes; nil goes back to them.
    func showIteration(_ number: Int?, of document: Document) {
        if listsAllIterations(document) {
            // The viewer shows an earlier iteration of the document whose every iteration the panel lists: the list
            // stays, and Back to Current returns to it.
            viewedIteration = number.map { (document, $0) }
            return
        }
        guard let number, location?.contains(document) == true else {
            if allIterations != nil {
                // Another document's every iteration is listed: only this document's earlier one goes.
                if viewedIteration?.document.id == document.id { viewedIteration = nil }
                return
            }
            resetPast()
            viewedIteration = nil
            applyGroups()
            return
        }
        observePast(of: document, noteStore.observeNotes(for: document.id, iteration: number))
        if allIterations != nil {
            allIterations = nil
            onEarlierNotesChange()
        }
        viewedIteration = (document, number)
        applyGroups()
    }

    /// Lists every iteration's notes of `document` in place of its current ones (All Iterations); nil goes back.
    func showAllIterations(of document: Document?) {
        defer { onEarlierNotesChange() }
        guard let document, location?.contains(document) == true else {
            guard allIterations != nil else { return }
            resetPast()
            allIterations = nil
            // The viewer may still show an earlier iteration: the panel lists that one's notes again.
            if let viewed = viewedIteration {
                showIteration(viewed.number, of: viewed.document)
            } else {
                applyGroups()
            }
            return
        }
        observePast(of: document, noteStore.observeNotesInEveryIteration(for: document.id))
        viewedIteration = nil
        allIterations = document
        let iterationStream = noteStore.observeIterations(for: document.id)
        let generation = pastGeneration
        iterationsObservation = Task { [weak self] in
            do {
                for try await iterations in iterationStream {
                    guard let self, !Task.isCancelled, generation == self.pastGeneration else { return }
                    self.iterationsListed = iterations
                }
            } catch {
                Log.notes.error("iterations observation failed: \(error, privacy: .public)")
            }
        }
        applyGroups()
    }

    private func resetPast() {
        pastGeneration += 1
        pastObservation?.cancel()
        pastObservation = nil
        iterationsObservation?.cancel()
        iterationsObservation = nil
        iterationsListed = []
        pastNotes = []
    }

    private func observePast(of document: Document, _ stream: AsyncThrowingStream<[Note], any Error>) {
        resetPast()
        let generation = pastGeneration
        pastObservation = Task { [weak self] in
            do {
                for try await notes in stream {
                    guard let self, !Task.isCancelled, generation == self.pastGeneration else { return }
                    self.pastNotes = notes
                    self.applyGroups()
                }
            } catch {
                Log.notes.error("iteration notes observation failed: \(error, privacy: .public)")
            }
        }
    }

    private func applyGroups() {
        // All Iterations keeps the live document (its current iteration moves on while listed).
        let past = allIterations.map { all in
            DocumentNotes(document: liveGroups.first { $0.document.id == all.id }?.document ?? all, notes: pastNotes)
        } ?? viewedIteration.map { DocumentNotes(document: $0.document, notes: pastNotes) }
        groups = Self.merged(liveGroups, past: past).filter { location?.contains($0.document) == true }
    }

    /// The notes of a group listing every iteration that start each iteration's run, with the header to show above.
    func iterationStarts(in group: DocumentNotes) -> [NoteID: String] {
        guard listsAllIterations(group.document) else { return [:] }
        var starts: [NoteID: String] = [:]
        var previous: Int?
        for note in group.notes where note.iteration != previous {
            previous = note.iteration
            starts[note.id] = iterationHeader(note.iteration, current: group.document.currentIteration)
        }
        return starts
    }

    /// "Iteration 3 · Current · 2 notes" or "Iteration 2 · Oct 8 · 5 notes", as the iteration menu lists them.
    func iterationHeader(_ number: Int, current: Int) -> String {
        let title = iterationsListed.first { $0.number == number }?.name.flatMap { $0.isEmpty ? nil : "Iteration \(number) · \($0)" }
            ?? "Iteration \(number)"
        guard let iteration = iterationsListed.first(where: { $0.number == number }) else { return title }
        return "\(title) · \(IterationMenu.detail(iteration, current: number == current))"
    }

    /// Documents as the explorer lists their files: by host, then by path with numbers in order and case aside
    /// (`docs/` beside `Docs/`, `file2` before `file10`), where the database's order put capitals first.
    nonisolated static func inPathOrder(_ groups: [DocumentNotes]) -> [DocumentNotes] {
        groups.sorted { lhs, rhs in
            if lhs.document.hostID != rhs.document.hostID { return lhs.document.hostID.rawValue < rhs.document.hostID.rawValue }
            return lhs.document.path.localizedStandardCompare(rhs.document.path) == .orderedAscending
        }
    }

    /// `live` with `past`'s document listing `past`'s notes instead, in path order. Kept when it has none: its header
    /// names the iteration on screen and says it has no notes.
    nonisolated static func merged(_ live: [DocumentNotes], past: DocumentNotes?) -> [DocumentNotes] {
        guard let past else { return live }
        var groups = live.filter { $0.document.id != past.document.id }
        let index = groups.firstIndex { ($0.document.hostID.rawValue, $0.document.path) > (past.document.hostID.rawValue, past.document.path) } ?? groups.endIndex
        groups.insert(past, at: index)
        return groups
    }

    /// The earlier iteration listed has no notes at all: its document's header stays, with a line saying so.
    func isEmptyViewedIteration(_ group: DocumentNotes) -> Bool {
        group.notes.isEmpty && viewedIteration?.document.id == group.document.id
    }

    /// A note's messages, oldest first.
    private(set) var pendingChoiceWrites: Set<MessageID> = []
    private var choiceSelections: [MessageID: [Int]] = [:]
    @ObservationIgnored private var choiceWrites: [MessageID: Task<Void, Never>] = [:]
    func selectedChoices(for question: NoteMessage, editable: Bool) -> [Int] {
        if editable, let pending = choiceSelections[question.id] { return pending }
        return messages(for: question.noteID).last { $0.inReplyTo == question.id && $0.selectedOptions != nil && (!editable || !$0.isSent) }?.selectedOptions ?? []
    }
    func selectChoices(_ indexes: [Int], question: MessageID) async {
        choiceSelections[question] = indexes
        pendingChoiceWrites.insert(question)
        let previous = choiceWrites[question]
        let task = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            if await attempt("stage the choice answer", { try await noteStore.setChoiceSelection(questionID: question, indexes: indexes) }) == false {
                if choiceSelections[question] == indexes { choiceSelections[question] = nil }
            }
        }
        choiceWrites[question] = task
        await task.value
        if choiceSelections[question] == indexes || choiceSelections[question] == nil { pendingChoiceWrites.remove(question) }
    }
    func choiceAnswerSummary(for id: NoteID) -> String {
        let staged = messages(for: id).filter { !$0.isSent && ($0.selectedOptions != nil || $0.customAnswer) }
        if staged.contains(where: \.customAnswer) { return ". Custom answer, not sent" }
        return staged.isEmpty ? "" : ". Choice answer staged, not sent"
    }

    func messages(for id: NoteID) -> [NoteMessage] { messages[id] ?? [] }

    var isFiltering: Bool { filter != .all || !colorFilter.isEmpty || !searchText.trimmingCharacters(in: .whitespaces).isEmpty || isHidingResolved }

    /// Show Resolved is off and there are resolved notes for it to hide.
    var isHidingResolved: Bool { !showResolved && groups.contains { $0.notes.contains { !Self.isOpen($0) } } }

    /// What an empty list says, by what made it empty: a search names the words, a colour names the colour, and each tab
    /// says what belongs there and how notes arrive. An empty Attention list is good news and says so.
    struct EmptyCopy: Hashable {
        var symbol: String
        var title: String
        var message: String
        var action: String
        var goodNews = false
        /// The action turns Show Resolved Notes back on, instead of clearing filters.
        var showsResolved = false
    }

    nonisolated static func emptyCopy(filter: Filter, colors: Set<NoteColor>, search: String, hidingResolved: Bool = false) -> EmptyCopy {
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            return EmptyCopy(symbol: "magnifyingglass", title: "No notes match “\(query)”",
                             message: "Search looks through comments, file names, and every message in a thread.", action: "Clear Search")
        }
        if hidingResolved, filter == .all, colors.isEmpty {
            return EmptyCopy(symbol: "checkmark.circle", title: "Every note is resolved",
                             message: "Resolved notes are hidden from the list and the page.", action: "Show Resolved Notes", showsResolved: true)
        }
        let colorWords = colors.map(\.rawValue).sorted().joined(separator: " or ")
        switch filter {
        case .all:
            return EmptyCopy(symbol: "circle.lefthalf.filled", title: "No \(colorWords) notes",
                             message: "Notes of other colors are hidden by the color filter.", action: "Show All Notes")
        case .drafts:
            return EmptyCopy(symbol: "note.text.badge.plus", title: colors.isEmpty ? "No drafts" : "No \(colorWords) drafts",
                             message: "Select text in any file and click Add Note. Drafts wait here until you send them.", action: "Show All Notes")
        case .sent:
            return EmptyCopy(symbol: "paperplane", title: "Nothing waiting on an agent",
                             message: "Sent notes stay here until an agent resolves them or asks you something.", action: "Show All Notes")
        case .resolved:
            return EmptyCopy(symbol: "checkmark.circle", title: "Nothing resolved yet",
                             message: "When an agent finishes a note, it lands here with its reply.", action: "Show All Notes")
        case .attention:
            return EmptyCopy(symbol: "checkmark.seal.fill", title: "All clear",
                             message: "No questions from agents, and every note is where it belongs.", action: "Show All Notes", goodNews: true)
        }
    }

    func clearFilters() {
        filter = .all
        colorFilter = []
        searchText = ""
    }

    /// A run of the list: every note, or with Separate Resolved Notes, the open or the resolved ones. Identified by
    /// its kind, so a run appearing or going leaves the other's rows as they are.
    struct Run: Identifiable {
        enum Kind: Hashable { case all, open, resolved }
        let id: Kind
        let groups: [DocumentNotes]
    }

    /// The list's runs, in the order shown: one normally; with Separate Resolved Notes on, the open notes by
    /// document, then the resolved ones by document in the same document order (only the runs with notes). A
    /// document with both kinds is in both runs.
    var sections: [Run] {
        let groups = sortedGroups
        guard separateResolved, showResolved else { return [Run(id: .all, groups: groups)] }
        func run(_ kind: Run.Kind, _ keep: (Note) -> Bool) -> Run {
            Run(id: kind, groups: groups.compactMap { group in
                if group.notes.isEmpty { return kind == .open ? group : nil }   // an earlier iteration with no notes
                let notes = group.notes.filter(keep)
                return notes.isEmpty ? nil : DocumentNotes(document: group.document, notes: notes)
            })
        }
        let runs = [run(.open, Self.isOpen), run(.resolved) { !Self.isOpen($0) }].filter { !$0.groups.isEmpty }
        return runs.isEmpty ? [Run(id: .open, groups: [])] : runs
    }

    /// Every listed group in the order shown, the runs one after the other (a document can appear in both).
    var visibleGroups: [DocumentNotes] { sections.flatMap(\.groups) }

    /// Groups after the state, color, and text filters, with notes sorted by `sort` and documents ordered by
    /// their first note under that sort (so "newest" lists the document with the newest note first).
    private var sortedGroups: [DocumentNotes] {
        let needle = searchText.trimmingCharacters(in: .whitespaces)
        func contains(_ text: String?) -> Bool { Self.contains(text, needle) }
        let filtered = groups.compactMap { group -> DocumentNotes? in
            if isEmptyViewedIteration(group) || (group.notes.isEmpty && filter == .all && colorFilter.isEmpty && needle.isEmpty) { return group }
            let fileMatches = !needle.isEmpty && contains(group.document.fileName)
            let notes = group.notes.filter { note in
                listed(in: filter, note)
                    && (colorFilter.isEmpty || colorFilter.contains(note.color))
                    && (needle.isEmpty || fileMatches || textMatches(note, needle))
            }
            // Every iteration's notes stay in runs by iteration, newest first, each run in the panel's order.
            let sorted = listsAllIterations(group.document)
                ? notes.sorted { $0.iteration != $1.iteration ? $0.iteration > $1.iteration : ordering($0, $1) }
                : notes.sorted(by: ordering)
            return notes.isEmpty ? nil : DocumentNotes(document: group.document, notes: sorted)
        }
        if sort == .position {
            // Open work leads: documents with anything still open come first, finished ones after, each in path order.
            let open = filtered.filter { $0.notes.contains(where: Self.isOpen) }
            let settled = filtered.filter { !$0.notes.contains(where: Self.isOpen) }
            return Self.inPathOrder(open) + Self.inPathOrder(settled)
        }
        return filtered.sorted { lhs, rhs in
            guard let a = lhs.notes.first, let b = rhs.notes.first else { return false }
            return ordering(a, b)
        }
    }

    nonisolated private static func contains(_ text: String?, _ needle: String) -> Bool {
        text?.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// The note's own words match: its comment, a resolve message, or any message in its thread.
    private func textMatches(_ note: Note, _ needle: String) -> Bool {
        Self.contains(note.body, needle) || Self.contains(note.resolveMessage, needle)
            || Self.contains(Self.quotedText(of: note.anchor), needle)
            || messages(for: note.id).contains { Self.contains($0.body, needle) }
    }

    /// What a note is on, as its card quotes it: the text, a PDF selection, an element's text, a picture's source.
    /// Search finds a note by it too ("the note on fetchForecast").
    nonisolated static func quotedText(of anchor: Anchor) -> String? {
        switch anchor {
        case .text(let text): text.text
        case .pdf(let pdf): pdf.text
        case .element(let element): element.text
        case .embeddedImage(let image): image.source
        case .image, .wholeFile: nil
        }
    }

    /// Open work: anything not resolved (an agent's question leaves its note open, and so does a result waiting for
    /// the user's review).
    nonisolated static func isOpen(_ note: Note) -> Bool {
        note.state != .resolved || note.needsAttention || note.awaitsReview
    }

    /// Notes in each state across every document, for the filter bar's counts (before search and color filters,
    /// so a count says how much work exists, not how much is on screen; hidden resolved notes aren't counted).
    func count(for filter: Filter) -> Int {
        groups.reduce(0) { total, group in total + group.notes.filter { listed(in: filter, $0) }.count }
    }

    /// The tab's rule, with resolved notes left out of every tab but Resolved while they're hidden.
    private func listed(in filter: Filter, _ note: Note) -> Bool {
        matches(filter, note) && (showResolved || filter == .resolved || Self.isOpen(note))
    }

    /// The notes the list shows for a document, for drawing only those on its page.
    func listedIDs(for documentID: DocumentID) -> Set<NoteID> {
        Set(visibleGroups.filter { $0.document.id == documentID }.flatMap { $0.notes.map(\.id) })
    }

    /// A document's notes left off its page: with the panel shown, every note the list doesn't show; with it
    /// closed, nothing is filtered on screen, so only resolved notes while they're hidden (as `AppModel.visibleDrafts`
    /// filters only while the panel shows). A note the panel hasn't heard of yet is drawn, so a new one never blinks.
    func hiddenIDs(for documentID: DocumentID, panelShown: Bool) -> Set<NoteID> {
        guard let notes = groups.first(where: { $0.document.id == documentID })?.notes else { return [] }
        if panelShown {
            let listed = listedIDs(for: documentID)
            return Set(notes.lazy.map(\.id).filter { !listed.contains($0) })
        }
        return showResolved ? [] : Set(notes.lazy.filter { !Self.isOpen($0) }.map(\.id))
    }

    /// Brings a note into the list when it's selected or revealed from elsewhere (Attention, the explorer, an
    /// agent's `open_in_viewer`) while the panel's filters hide it: the tab goes to All, resolved notes show if it's
    /// one, and a colour filter or search that still hides it is cleared.
    func makeListed(_ note: Note) {
        let needle = searchText.trimmingCharacters(in: .whitespaces)
        if !listed(in: filter, note) {
            filter = .all
            if !showResolved, !Self.isOpen(note) { showResolved = true }
        }
        if !colorFilter.isEmpty, !colorFilter.contains(note.color) { colorFilter = [] }
        let fileName = groups.first { group in group.notes.contains { $0.id == note.id } }?.document.fileName
        if !needle.isEmpty, !Self.contains(fileName, needle), !textMatches(note, needle) { searchText = "" }
    }

    private func matches(_ filter: Filter, _ note: Note) -> Bool {
        let state = note.state
        return switch filter {
        case .all: true
        case .drafts: Self.isUnsent(note)
        // Waiting on the agent: a question back, or a follow-up still to send, is the user's turn.
        case .sent: state == .sent && !note.waitingOnUser && !note.hasUnsentFollowUps
        case .resolved: state == .resolved
        case .attention: note.needsAttention
        }
    }

    private func ordering(_ a: Note, _ b: Note) -> Bool {
        switch sort {
        case .position: a.anchor.sortKey < b.anchor.sortKey
        case .newest: a.createdAt > b.createdAt
        case .oldest: a.createdAt < b.createdAt
        case .color: (Self.rank(a.color), a.anchor.sortKey) < (Self.rank(b.color), b.anchor.sortKey)
        case .state: (Self.rank(a.state), a.anchor.sortKey) < (Self.rank(b.state), b.anchor.sortKey)
        }
    }

    private static func rank(_ color: NoteColor) -> Int { NoteColor.allCases.firstIndex(of: color) ?? 0 }
    /// Drafts first: what still needs sending is what the panel is for.
    private static func rank(_ state: NoteState) -> Int { NoteState.allCases.firstIndex(of: state) ?? 0 }

    /// Drafts, and notes with a follow-up not yet sent: what Send would hand over.
    var draftCount: Int { groups.reduce(0) { $0 + $1.notes.filter(Self.isUnsent).count } }

    /// Something in the note hasn't left the app: it is a draft, or has a follow-up not yet sent.
    nonisolated static func isUnsent(_ note: Note) -> Bool { note.state == .draft || note.hasUnsentFollowUps }

    /// One line about a note's latest delivery for its card: where it went and when, or that it failed.
    /// Who a note was sent to, for naming the agent that answered it when the reply doesn't say. The clipboard is
    /// no agent: whoever answered a pasted packet is unknown.
    nonisolated static func agentName(_ send: SendSummary) -> String? {
        guard send.transport != TransportKind.clipboard.rawValue else { return nil }
        return send.targetJSON.data(using: .utf8).flatMap { try? JSONDecoder().decode(AgentTarget.self, from: $0) }?.label
    }

    nonisolated static func deliveryLine(_ send: SendSummary, now: Date = Date()) -> (text: String, failed: Bool) {
        let target = send.targetJSON.data(using: .utf8).flatMap { try? JSONDecoder().decode(AgentTarget.self, from: $0) }
        let name = target?.label ?? TransportKind(rawValue: send.transport)?.displayName ?? send.transport
        let formatter = RelativeDateTimeFormatter()   // re-evaluated each minute by the card's TimelineView
        formatter.unitsStyle = .abbreviated
        let when = now.timeIntervalSince(send.sentAt) < 60 ? "just now" : formatter.localizedString(for: send.sentAt, relativeTo: now)
        if send.outcome.hasPrefix("failed") {
            let reason = send.outcome.drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespaces)
            return ("Sending to \(name) failed \(when)\(reason.isEmpty ? "" : ": \(reason)")", true)
        }
        return ("Sent to \(name) · \(when)", false)
    }

    /// The selected note with its document, for revealing it.
    var selectedEntry: (note: Note, document: Document)? {
        guard let selectedNoteID else { return nil }
        for group in groups {
            if let note = group.notes.first(where: { $0.id == selectedNoteID }) { return (note, group.document) }
        }
        return nil
    }

    var selectedNote: Note? {
        guard let selectedNoteID else { return nil }
        return groups.lazy.flatMap(\.notes).first { $0.id == selectedNoteID }
    }

    /// The selected notes in the order the list shows them (by document, then the panel's sort). Selected notes the
    /// list no longer shows (filtered out since) are left out: what is acted on is what is seen.
    /// The selected notes shown, earlier iterations' too: what Copy as Packet copies.
    var selectedListedNotes: [Note] {
        guard !selection.isEmpty else { return [] }
        return visibleGroups.flatMap(\.notes).filter { selection.contains($0.id) }
    }

    var selectedNotes: [Note] {
        guard !selection.isEmpty else { return [] }
        // An earlier iteration's notes are only looked at: nothing acts on them in bulk.
        return visibleGroups.flatMap(\.notes).filter { selection.contains($0.id) && !isPast($0) }
    }

    /// The selected notes in runs of cards next to each other in the list, top to bottom (issue #19). A document's
    /// header, or the rule before resolved notes, stands between cards, so it ends a run, as an unselected card does.
    var selectionRuns: [[Note]] { Self.selectionRuns(selection, in: visibleGroups) }

    /// `selectionRuns` over groups already worked out, in the order shown.
    nonisolated static func selectionRuns(_ selection: Set<NoteID>, in groups: [DocumentNotes]) -> [[Note]] {
        guard !selection.isEmpty else { return [] }
        var runs: [[Note]] = []
        for group in groups {
            var run: [Note] = []
            for note in group.notes {
                if selection.contains(note.id) { run.append(note); continue }
                if !run.isEmpty { runs.append(run) }
                run = []
            }
            if !run.isEmpty { runs.append(run) }
        }
        return runs
    }

    /// What each bulk action would touch among `notes`: only notes the action makes sense for.
    /// Sendable: drafts and sent notes (sent again), and any note with a follow-up waiting, an orphan's too.
    nonisolated static func sendable(_ notes: [Note]) -> [Note] { notes.filter { $0.state == .draft || $0.state == .sent || $0.hasUnsentFollowUps } }
    nonisolated static func resolvable(_ notes: [Note]) -> [Note] { notes.filter { $0.state != .resolved } }
    /// Notes that can go back to drafts: resolved ones, and sent ones (#13).
    nonisolated static func reopenable(_ notes: [Note]) -> [Note] { notes.filter { $0.state == .resolved || $0.state == .sent } }

    /// Why the last action on notes failed, in a sentence, for the panel's alert; nil when none did.
    var lastError: String?

    /// Runs a store write, and on failure logs it and says so in `lastError`. False when it failed.
    @discardableResult
    private func attempt(_ what: String, _ write: () async throws -> Void) async -> Bool {
        do {
            try await write()
            return true
        } catch {
            Log.notes.error("\(what, privacy: .public) failed: \(error, privacy: .public)")
            lastError = "Couldn't \(what): \(Self.reason(error))"
            return false
        }
    }

    /// A failed note action's cause for the user. The store's own words are for agents and name note ids; a note
    /// gone meanwhile (deleted in another window, say) is said plainly.
    nonisolated static func reason(_ error: any Error) -> String {
        switch error as? NoteStoreError {
        case .noteNotFound?, .noteDeleted?: "it was deleted."
        default: error.userMessage
        }
    }

    func resolve(_ id: NoteID) async {
        await attempt("resolve the note") { try await noteStore.resolve(id) }
    }

    /// Resolves the unresolved notes among `ids` (drafts, sent and orphaned), by hand.
    func resolve(_ ids: [NoteID]) async {
        let notes = Self.resolvable(groups.flatMap(\.notes).filter { ids.contains($0.id) })
        for note in notes { await resolve(note.id) }
    }

    /// Puts the resolved and sent notes among `ids` back to drafts.
    func reopen(_ ids: [NoteID]) async {
        let notes = Self.reopenable(groups.flatMap(\.notes).filter { ids.contains($0.id) })
        for note in notes {
            if note.state == .sent { await unsend(note.id) } else { await reopen(note.id) }
        }
    }

    /// A sent note back to a draft (#13).
    func unsend(_ id: NoteID) async {
        await attempt("put the note back to a draft") { try await noteStore.unsend(id) }
    }

    /// Why an inline edit couldn't be saved; nil when it was.
    enum EditRefusal: Error, Equatable { case changedMeanwhile, failed }

    /// Saves an edit made in the card (#14). Refused when the comment changed since editing began (an agent's answer
    /// was added), so the person's typing is never laid over text they didn't see; the card keeps what they typed.
    func update(_ id: NoteID, body: String, color: NoteColor, editedFrom original: String) async -> EditRefusal? {
        do {
            guard let current = try await noteStore.note(id) else { return .failed }
            guard current.body == original else { return .changedMeanwhile }
            guard body != current.body || color != current.color else { return nil }
            // Compared and written together: an answer that lands between the read above and this write still wins.
            return try await noteStore.updateBody(id, body: body, color: color, ifBodyIs: original) ? nil : .changedMeanwhile
        } catch {
            Log.notes.error("edit failed: \(error, privacy: .public)")
            return .failed
        }
    }

    func setColor(_ ids: [NoteID], _ color: NoteColor) async {
        for id in ids {
            guard await attempt("change the note's color", { try await noteStore.updateColor(id, color: color) }) else { return }
        }
    }

    /// The notes deleted last, offered back together in the undo toast for a few seconds; empty when there is none.
    private(set) var lastDeleted: [Note] = []
    /// Why the last Undo could not bring the note back, in a sentence; the toast says so and offers Try Again.
    private(set) var undoFailure: String?
    @ObservationIgnored private var undoTokens: [NoteID: UndoToken] = [:]
    private final class UndoToken {}
    /// Called with the notes brought back from Recently Deleted, so their open documents re-anchor them.
    @ObservationIgnored var onRestored: ([Note]) -> Void = { _ in }

    /// Deletes at once (no confirmation) and makes it undoable: the toast's Undo, and Edit › Undo (⌘Z).
    func delete(_ id: NoteID) async {
        await delete([id])
    }

    /// Deletes several notes as one step: one toast, one Undo that brings them all back. A deleted note goes to
    /// Recently Deleted (issue #15), so Undo only takes it out again.
    func delete(_ ids: [NoteID]) async {
        var batch: [Note] = []
        for id in ids {
            if let note = try? await noteStore.note(id) { batch.append(note) }
        }
        guard !batch.isEmpty else { return }
        guard await attempt(batch.count == 1 ? "delete the note" : "delete \(batch.count) notes", { try await noteStore.trashNotes(batch.map(\.id)) }) else { return }
        if !lastDeleted.isEmpty, lastDeleted.map(\.id) != batch.map(\.id) {
            Log.notes.info("undo toast replaced: \(self.lastDeleted.count, privacy: .public) by \(batch.count, privacy: .public) notes")
        }
        lastDeleted = batch
        undoFailure = nil
        selection.subtract(batch.map(\.id))
        if let undo = NSApp.mainWindow?.undoManager ?? NSApp.keyWindow?.undoManager {
            // Each delete gets its own undo target, so undoing one from the toast leaves the others' entries.
            let token = UndoToken()
            for deleted in batch { undoTokens[deleted.id] = token }
            undo.registerUndo(withTarget: token) { [weak self] _ in
                _ = MainActor.assumeIsolated { Task { await self?.undoDelete(batch) } }
            }
            undo.setActionName(batch.count == 1 ? "Delete Note" : "Delete \(batch.count) Notes")
        }
    }

    /// Brings a deleted batch back from Recently Deleted and selects it. Notes that can't come back (deleted for good
    /// meanwhile) stay listed in the toast with Try Again.
    func undoDelete(_ batch: [Note]) async {
        // Undone from the toast: the Edit › Undo entry would now restore notes that are already back.
        var tokens: [UndoToken] = []
        for id in batch.map(\.id) {
            if let token = undoTokens.removeValue(forKey: id), !tokens.contains(where: { $0 === token }) { tokens.append(token) }
        }
        for token in tokens {
            for window in [NSApp.mainWindow, NSApp.keyWindow].compactMap({ $0 }) { window.undoManager?.removeAllActions(withTarget: token) }
        }
        var restored: Set<NoteID> = []
        do {
            restored = try await noteStore.untrashNotes(batch.map(\.id))
            Log.notes.info("undo toast: restored \(restored.count, privacy: .public) of \(batch.count, privacy: .public) notes")
        } catch {
            Log.notes.error("undo delete failed: \(error, privacy: .public)")
        }
        // A note already back (restored from Recently Deleted meanwhile) is not a failure.
        var failed: [Note] = []
        for note in batch where !restored.contains(note.id) {
            if (try? await noteStore.note(note.id)) == nil { failed.append(note) }
        }
        onRestored(batch.filter { restored.contains($0.id) })
        let wasShown = lastDeleted.map(\.id) == batch.map(\.id)
        if failed.isEmpty {
            if wasShown {
                lastDeleted = []
                undoFailure = nil
            }
        } else if wasShown {
            // The toast stays and says so: a silent failure looked exactly like a note that had come back.
            lastDeleted = failed
            undoFailure = failed.count == 1 ? "Couldn't bring the note back. It was deleted for good." : "Couldn't bring \(failed.count) notes back. They were deleted for good."
        }
        selection = Set(batch.map(\.id)).subtracting(failed.map(\.id))
    }

    // MARK: Recently Deleted

    /// The panel shows Recently Deleted instead of the notes (issue #15).
    var showsRecentlyDeleted = false
    /// The deleted notes under the folder in front, newest first, while Recently Deleted shows.
    private(set) var trashed: [TrashedNote] = []
    @ObservationIgnored private var trashObservation: Task<Void, Never>?
    @ObservationIgnored private var trashScope: RecentlyDeletedScope?

    /// Follows the deleted notes under `scope`; nil stops.
    func observeTrash(_ scope: RecentlyDeletedScope?) {
        guard scope != trashScope || trashObservation == nil else { return }
        trashObservation?.cancel()
        trashObservation = nil
        trashScope = scope
        trashed = []
        guard let scope else { return }
        let stream = noteStore.observeTrashedNotes(underRoot: scope.path, hostID: scope.hostID)
        trashObservation = Task { [weak self] in
            do {
                for try await trashed in stream { self?.trashed = trashed }
            } catch {
                Log.notes.error("Recently Deleted observation failed: \(error, privacy: .public)")
            }
        }
    }

    /// Puts notes back on their documents, re-anchored against the text there now.
    func restoreFromTrash(_ ids: [NoteID]) async {
        let wanted = Set(ids)
        let notes = trashed.map(\.note).filter { wanted.contains($0.id) }
        await attempt("restore from Recently Deleted") {
            let restored = try await noteStore.untrashNotes(ids)
            onRestored(notes.filter { restored.contains($0.id) })
        }
    }

    /// Deletes notes for good, from Recently Deleted.
    func deleteNow(_ ids: [NoteID]) async {
        await attempt("delete for good") { try await noteStore.deleteForever(ids) }
    }

    /// Deletes for good every note Recently Deleted lists (the folder in front's).
    func emptyRecentlyDeleted() async {
        await deleteNow(trashed.map(\.id))
    }

    func dismissUndo() {
        if !lastDeleted.isEmpty { Log.notes.info("undo toast dismissed: \(self.lastDeleted.count, privacy: .public) notes") }
        lastDeleted = []
        undoFailure = nil
    }

    /// Adds a follow-up to a note's thread, unsent until the note is sent: an answer to the agent's question, or
    /// anything more to say (on a resolved note it reopens the thread). Sending stays the person's choice; nothing
    /// goes to the agent from here. Returns false when it could not be added (the note is gone), so the card keeps
    /// what was typed.
    @discardableResult
    func addFollowUp(to id: NoteID, _ text: String) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        do {
            try await noteStore.addFollowUp(id, body: text)
            return true
        } catch {
            Log.notes.error("follow-up failed: \(error, privacy: .public)")
            return false
        }
    }

    /// Adds what is typed in a card's follow-up field and clears it; the text stays when it couldn't be added.
    @discardableResult
    func commitFollowUp(for id: NoteID) async -> Bool {
        // Taken out of the field before the write, so a second Return while it is in flight adds nothing twice.
        guard let text = followUpText.removeValue(forKey: id) else { return false }
        if await addFollowUp(to: id, text) { return true }
        // Not added: what was typed comes back, ahead of anything typed meanwhile.
        followUpText[id] = text + (followUpText[id].map { "\n" + $0 } ?? "")
        return false
    }

    /// Changes a follow-up not yet sent; a blank one is deleted. False when it was sent meanwhile.
    @discardableResult
    func updateFollowUp(_ id: MessageID, _ text: String) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if text.isEmpty { try await noteStore.deleteFollowUp(id) } else { try await noteStore.updateFollowUp(id, body: text) }
            if let question = messages.values.flatMap({ $0 }).first(where: { $0.id == id })?.inReplyTo { choiceSelections[question] = nil }
            return true
        } catch {
            Log.notes.error("follow-up edit failed: \(error, privacy: .public)")
            return false
        }
    }

    /// Deletes a follow-up not yet sent, with Edit › Undo (⌘Z) to bring it back, as a deleted note has: it can hold a
    /// long answer, and one click on a small trash icon took it for good.
    func deleteFollowUp(_ id: MessageID) async {
        let removed = messages.values.lazy.flatMap { $0 }.first { $0.id == id }
        guard await attempt("delete the follow-up", { try await noteStore.deleteFollowUp(id) }) else { return }
        if let question = removed?.inReplyTo { choiceSelections[question] = nil }
        if let removed { messages[removed.noteID]?.removeAll { $0.id == id } }
        guard let removed, let undo = NSApp?.mainWindow?.undoManager ?? NSApp?.keyWindow?.undoManager else { return }
        undo.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { _ = Task { await model.restoreFollowUp(removed) } }
        }
        undo.setActionName("Delete Follow-Up")
    }

    /// A deleted follow-up back on its note, at the end of its thread (with a new id: it was never sent).
    @discardableResult
    func restoreFollowUp(_ message: NoteMessage) async -> Bool {
        if message.customAnswer { return await attempt("restore the custom answer", { try await noteStore.restoreCustomAnswer(message) }) }
        if let question = message.inReplyTo, let selected = message.selectedOptions, !message.customAnswer {
            guard await attempt("restore the choice answer", { try await noteStore.setChoiceSelection(questionID: question, indexes: selected) }) else { return false }
            choiceSelections[question] = selected
            return true
        }
        return await addFollowUp(to: message.noteID, message.body)
    }

    /// Puts a moved note back where it was before its first move.
    func restoreOriginalPlace(_ id: NoteID) async {
        await attempt("put the note back where it was") { try await noteStore.restoreOriginalPlace(id) }
    }

    func reopen(_ id: NoteID) async {
        await attempt("reopen the note") { try await noteStore.reopen(id) }
    }

    func restoreDraft(_ note: Note) async {
        await attempt("restore the note") { try await noteStore.updateAnchor(note.id, anchor: note.anchor, state: .draft) }
    }
}
