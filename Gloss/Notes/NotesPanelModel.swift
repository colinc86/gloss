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
    /// Notes that just appeared (made, or brought back by Undo); their cards glow briefly so the eye finds them.
    private(set) var arrivedIDs: Set<NoteID> = []
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var arrivalReset: Task<Void, Never>?

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
    /// Matched against note text, file name, and resolve message, case-insensitively.
    var searchText = ""
    /// Bumped by Notes › Search Notes to put the caret in the search field.
    var searchFocusRequest = 0
    /// Set with a request; consumed by the field, including one that only appears once the panel opens.
    @ObservationIgnored var searchFocusPending = false
    /// Empty means every color.
    var colorFilter: Set<NoteColor> = []
    /// The selected cards: one by a click, several by ⌘-click, ⇧-click or ⌘A (issue #8).
    var selection: Set<NoteID> = []
    /// The one selected note; nil when none or several are selected. Setting it selects just that note.
    var selectedNoteID: NoteID? {
        get { selection.count == 1 ? selection.first : nil }
        set { selection = newValue.map { [$0] } ?? [] }
    }
    @ObservationIgnored private var observation: Task<Void, Never>?

    init(noteStore: NoteStore) {
        self.noteStore = noteStore
    }

    func start() {
        observation?.cancel()
        let initial = sort
        Task { [weak self] in
            guard let self, let stored = try? await noteStore.setting("notes.sort"), let restored = Sort(rawValue: stored) else { return }
            // A pick made while the read was in flight wins over the stored value.
            guard sort == initial else { return }
            isRestoringSort = true
            sort = restored
            isRestoringSort = false
        }
        let stream = noteStore.observeDocumentsWithNotes()
        observation = Task { [weak self] in
            do {
                for try await groups in stream {
                    guard let self else { return }
                    let arrived = Self.arrivals(from: self.groups, to: groups, loaded: self.hasLoaded)
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
                    self.groups = groups
                    self.onGroupsChange(groups)
                }
            } catch {
                Log.notes.error("notes panel observation failed: \(error, privacy: .public)")
            }
        }
    }

    func stop() {
        observation?.cancel()
    }

    var isFiltering: Bool { filter != .all || !colorFilter.isEmpty || !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    /// What an empty list says, by what made it empty: a search names the words, a colour names the colour, and each tab
    /// says what belongs there and how notes arrive. An empty Attention list is good news and says so.
    struct EmptyCopy: Hashable {
        var symbol: String
        var title: String
        var message: String
        var action: String
        var goodNews = false
    }

    nonisolated static func emptyCopy(filter: Filter, colors: Set<NoteColor>, search: String) -> EmptyCopy {
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            return EmptyCopy(symbol: "magnifyingglass", title: "No notes match “\(query)”",
                             message: "Search looks through comments, file names, and agents' replies.", action: "Clear Search")
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

    /// Groups after the state, color, and text filters, with notes sorted by `sort` and documents ordered by
    /// their first note under that sort (so "newest" lists the document with the newest note first).
    var visibleGroups: [DocumentNotes] {
        let needle = searchText.trimmingCharacters(in: .whitespaces)
        func contains(_ text: String?) -> Bool { text?.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        let filtered = groups.compactMap { group -> DocumentNotes? in
            let fileMatches = !needle.isEmpty && contains(group.document.fileName)
            let notes = group.notes.filter { note in
                matches(filter, note)
                    && (colorFilter.isEmpty || colorFilter.contains(note.color))
                    && (needle.isEmpty || fileMatches || contains(note.body) || contains(note.resolveMessage))
            }
            return notes.isEmpty ? nil : DocumentNotes(document: group.document, notes: notes.sorted(by: ordering))
        }
        if sort == .position {
            // Open work leads: documents with anything still open come first, finished ones after, each in path order.
            let open = filtered.filter { $0.notes.contains(where: Self.isOpen) }
            let settled = filtered.filter { !$0.notes.contains(where: Self.isOpen) }
            return open + settled
        }
        return filtered.sorted { lhs, rhs in
            guard let a = lhs.notes.first, let b = rhs.notes.first else { return false }
            return ordering(a, b)
        }
    }

    /// Open work: anything not resolved, plus resolved notes where the agent asked a question back.
    nonisolated static func isOpen(_ note: Note) -> Bool {
        note.state != .resolved || note.resolveOutcome == .needsInput
    }

    /// Notes in each state across every document, for the filter bar's counts (before search and color filters,
    /// so a count says how much work exists, not how much is on screen).
    func count(for filter: Filter) -> Int {
        groups.reduce(0) { total, group in total + group.notes.filter { matches(filter, $0) }.count }
    }

    private func matches(_ filter: Filter, _ note: Note) -> Bool {
        let state = note.state
        return switch filter {
        case .all: true
        case .drafts: state == .draft
        case .sent: state == .sent
        case .resolved: state == .resolved
        case .attention: state == .orphaned || (state == .resolved && note.resolveOutcome == .needsInput)
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

    var draftCount: Int { groups.reduce(0) { $0 + $1.notes.filter { $0.state == .draft }.count } }

    /// One line about a note's latest delivery for its card: where it went and when, or that it failed.
    /// Who a note was sent to, for naming the agent that answered it.
    nonisolated static func agentName(_ send: SendSummary) -> String? {
        send.targetJSON.data(using: .utf8).flatMap { try? JSONDecoder().decode(AgentTarget.self, from: $0) }?.label
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
    var selectedNotes: [Note] {
        guard !selection.isEmpty else { return [] }
        return visibleGroups.flatMap(\.notes).filter { selection.contains($0.id) }
    }

    /// What each bulk action would touch among `notes`: only notes the action makes sense for.
    nonisolated static func sendable(_ notes: [Note]) -> [Note] { notes.filter { $0.state == .draft || $0.state == .sent } }
    nonisolated static func resolvable(_ notes: [Note]) -> [Note] { notes.filter { $0.state != .resolved } }
    /// Notes that can go back to drafts: resolved ones, and sent ones (#13).
    nonisolated static func reopenable(_ notes: [Note]) -> [Note] { notes.filter { $0.state == .resolved || $0.state == .sent } }

    func resolve(_ id: NoteID) async {
        do { try await noteStore.resolve(id) } catch { Log.notes.error("resolve failed: \(error, privacy: .public)") }
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
        do { try await noteStore.unsend(id) } catch { Log.notes.error("unsend failed: \(error, privacy: .public)") }
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
            do { try await noteStore.updateColor(id, color: color) } catch { Log.notes.error("colour change failed: \(error, privacy: .public)") }
        }
    }

    /// The notes deleted last, offered back together in the undo toast for a few seconds; empty when there is none.
    private(set) var lastDeleted: [DeletedNote] = []
    /// Why the last Undo could not bring the note back, in a sentence; the toast says so and offers Try Again.
    private(set) var undoFailure: String?
    @ObservationIgnored private var undoTokens: [NoteID: UndoToken] = [:]
    private final class UndoToken {}

    /// Deletes at once (no confirmation) and makes it undoable: the toast's Undo, and Edit › Undo (⌘Z).
    func delete(_ id: NoteID) async {
        await delete([id])
    }

    /// Deletes several notes as one step: one toast, one Undo that brings them all back.
    func delete(_ ids: [NoteID]) async {
        var batch: [DeletedNote] = []
        for id in ids {
            do {
                if let deleted = try await noteStore.deleteNoteForUndo(id) { batch.append(deleted) }
            } catch {
                Log.notes.error("delete failed: \(error, privacy: .public)")
            }
        }
        guard !batch.isEmpty else { return }
        if !lastDeleted.isEmpty, lastDeleted != batch {
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

    func undoDelete(_ deleted: DeletedNote) async {
        await undoDelete([deleted])
    }

    /// Brings a deleted batch back and selects it. Notes that can't come back stay listed in the toast with Try Again.
    func undoDelete(_ batch: [DeletedNote]) async {
        // Undone from the toast: the Edit › Undo entry would now restore notes that are already back.
        var tokens: [UndoToken] = []
        for id in batch.map(\.id) {
            if let token = undoTokens.removeValue(forKey: id), !tokens.contains(where: { $0 === token }) { tokens.append(token) }
        }
        for token in tokens {
            for window in [NSApp.mainWindow, NSApp.keyWindow].compactMap({ $0 }) { window.undoManager?.removeAllActions(withTarget: token) }
        }
        var failed: [DeletedNote] = []
        for deleted in batch {
            do {
                try await noteStore.restore(deleted)
                Log.notes.info("undo toast: restored \(deleted.id.rawValue, privacy: .public)")
            } catch {
                Log.notes.error("undo delete failed: \(error, privacy: .public)")
                failed.append(deleted)
            }
        }
        let wasShown = lastDeleted == batch
        if failed.isEmpty {
            if wasShown {
                lastDeleted = []
                undoFailure = nil
            }
        } else if wasShown {
            // The toast stays and says so: a silent failure looked exactly like a note that had come back.
            lastDeleted = failed
            undoFailure = failed.count == 1 ? "Couldn't bring the note back. It may have changed elsewhere." : "Couldn't bring \(failed.count) notes back. They may have changed elsewhere."
        }
        selection = Set(batch.map(\.id)).subtracting(failed.map(\.id))
    }

    func dismissUndo() {
        if !lastDeleted.isEmpty { Log.notes.info("undo toast dismissed: \(self.lastDeleted.count, privacy: .public) notes") }
        lastDeleted = []
        undoFailure = nil
    }

    /// Answers an agent's question: the exchange is added to the note, which becomes a draft again, ready to send.
    /// Sending stays the person's choice; nothing goes to the agent from here. Returns false when the answer could
    /// not be added (the note changed meanwhile), so the card can keep what was typed.
    @discardableResult
    func reply(to id: NoteID, with answer: String) async -> Bool {
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return false }
        do {
            try await noteStore.answer(id, with: answer)
            return true
        } catch {
            Log.notes.error("reply failed: \(error, privacy: .public)")
            return false
        }
    }

    func reopen(_ id: NoteID) async {
        do { try await noteStore.reopen(id) } catch { Log.notes.error("reopen failed: \(error, privacy: .public)") }
    }

    func restoreDraft(_ note: Note) async {
        do { try await noteStore.updateAnchor(note.id, anchor: note.anchor, state: .draft) } catch { Log.notes.error("restore failed: \(error, privacy: .public)") }
    }
}
