import Core
import Foundation
import Observation
import OSLog
import Remote

/// Iterations (issue #18): numbered rounds of notes on one document, from 0, backed by Gloss's own snapshots. Starts
/// them (asking about open notes as Settings › Notes says), shows an earlier one read-only from its snapshot, tints
/// what changed since one, and brings an earlier note forward.
@MainActor
@Observable
final class IterationsModel {
    /// Asking what to do with the notes still open when an iteration starts.
    struct OpenNotesPrompt: Identifiable {
        let document: Core.Document
        let openCount: Int
        var id: DocumentID { document.id }
    }

    /// An earlier iteration shown in place of the document: its snapshot's session, nil when the snapshot was not
    /// kept (its notes are listed alone).
    struct PastView {
        let iteration: Iteration
        let session: DocumentSession?
    }

    private let noteStore: NoteStore
    private let settings: SettingsStore
    /// The host's file system, for reading the content an iteration ends on.
    @ObservationIgnored var fileSystem: (HostID) -> (any FileSystemProvider)? = { _ in nil }
    /// The open session of a document, if any.
    @ObservationIgnored var liveSession: (DocumentID) -> DocumentSession? = { _ in nil }
    /// Tells the notes panel which iteration of a document to list (nil: the current one).
    @ObservationIgnored var onViewedIterationChange: (Core.Document, Int?) -> Void = { _, _ in }
    /// Why something the user asked for failed, in a sentence, for the notes panel's alert.
    @ObservationIgnored var onFailure: (String) -> Void = { _ in }

    /// The earlier iteration shown for a live session, by session id.
    private(set) var past: [String: PastView] = [:]
    var prompt: OpenNotesPrompt?

    init(noteStore: NoteStore, settings: SettingsStore) {
        self.noteStore = noteStore
        self.settings = settings
    }

    /// The session the viewer shows for `session`: an earlier iteration's, while one is shown.
    func shownSession(for session: DocumentSession) -> DocumentSession {
        past[session.id]?.session ?? session
    }

    // MARK: Starting

    /// Ends every observation and closes the snapshots on screen, when the app quits.
    func stop() {
        for view in past.values { view.session?.close() }
        past = [:]
        viewGeneration += 1
    }

    /// New Iteration: asks about open notes when there are any and Settings says to ask, else starts at once. An
    /// iteration with no notes yet has nothing to end.
    func requestNewIteration(for document: Core.Document) async {
        let notes = (try? await noteStore.notes(for: document.id)) ?? []
        guard !notes.isEmpty else { return }
        let open = notes.filter { $0.state != .resolved }.count
        switch (open, settings.iterationOpenNotes) {
        case (0, _): await start(document, openNotes: .carry)
        case (_, .ask): prompt = OpenNotesPrompt(document: document, openCount: open)
        case (_, .carry): await start(document, openNotes: .carry)
        case (_, .leave): await start(document, openNotes: .leave)
        }
    }

    /// The prompt's answer; "Don't ask again" makes it the setting.
    func answer(_ prompt: OpenNotesPrompt, _ choice: OpenNotesChoice, remember: Bool) async {
        self.prompt = nil
        if remember { settings.iterationOpenNotes = choice == .carry ? .carry : .leave }
        await start(prompt.document, openNotes: choice)
    }

    /// Ends the current iteration on the content as it is now (and the commit it is at), and opens the next.
    /// `byHand`: the user asked for it, so a failure is said, not only logged (one started on its own stays quiet).
    func start(_ document: Core.Document, openNotes: OpenNotesChoice, byHand: Bool = true) async {
        let snapshot = await currentContent(of: document)
        let commit = await gitCommit(of: document)
        do {
            try await noteStore.startIteration(documentID: document.id, openNotes: openNotes, snapshot: snapshot, gitCommit: commit)
        } catch {
            Log.notes.error("starting an iteration failed: \(error, privacy: .public)")
            if byHand { onFailure("Couldn't start a new iteration: \(error.userMessage)") }
            return
        }
        // The iteration began; old snapshots that stay are only disk space.
        if settings.snapshotsKept > 0 {
            do { try await noteStore.pruneSnapshots(keepingLast: settings.snapshotsKept) } catch {
                Log.notes.error("pruning snapshots failed: \(error, privacy: .public)")
            }
        }
    }

    /// The first note added after every note of the iteration was resolved starts the next one, when Settings says
    /// so. Resolving never does: the panel stays as it is while replies are read.
    func startIfAllResolved(_ documentID: DocumentID) async {
        guard settings.iteratesAfterResolved, let document = try? await noteStore.document(documentID),
              let notes = try? await noteStore.notes(for: documentID), Self.allResolved(notes) else { return }
        await start(document, openNotes: .leave, byHand: false)
    }

    /// The current iteration remembers the commit its file was at when it began (its first note, for iteration 0),
    /// whatever Settings says, so the first commit after it is noticed as a change. Iterations from before this
    /// have none, and the commit check takes its first look as their baseline.
    func recordStartingCommit(_ documentID: DocumentID) async {
        guard let document = try? await noteStore.document(documentID),
              let current = try? await noteStore.iterations(for: documentID).last, current.number == document.currentIteration,
              current.gitCommit == nil, let commit = await gitCommit(of: document) else { return }
        try? await noteStore.setIterationCommit(documentID: documentID, number: current.number, commit: commit)
    }

    nonisolated static func allResolved(_ notes: [Note]) -> Bool {
        !notes.isEmpty && notes.allSatisfy { $0.state == .resolved }
    }

    /// When Settings says so, a local file whose git commit changed since the iteration began starts the next one
    /// (asking about open notes as New Iteration does). The first check only remembers the commit.
    func checkCommit(_ session: DocumentSession) async {
        guard settings.iteratesOnCommit, session.pastIteration == nil, let opened = session.document,
              let document = try? await noteStore.document(opened.id), let head = await gitCommit(of: document),
              let current = try? await noteStore.iterations(for: document.id).last, current.number == document.currentIteration else { return }
        guard let known = current.gitCommit else {
            try? await noteStore.setIterationCommit(documentID: document.id, number: current.number, commit: head)
            return
        }
        guard known != head, prompt == nil else { return }
        await requestNewIteration(for: document)
    }

    /// The bytes the iteration's notes were taken on: the file as it is now. A live page has none.
    private func currentContent(of document: Core.Document) async -> Data? {
        guard document.kind != .web else { return nil }
        if let fileSystem = fileSystem(document.hostID), let data = try? await fileSystem.read(document.path) { return data }
        return liveSession(document.id)?.baseText.map { Data($0.utf8) }
    }

    private func gitCommit(of document: Core.Document) async -> String? {
        guard document.hostID == .local, document.kind != .web else { return nil }
        return await Self.lastCommit(of: document.path)
    }

    /// The last commit that touched the file (`git log -1 --format=%H -- <file>`); nil outside a repository, for a
    /// file never committed, or without git. Reads only.
    @concurrent nonisolated static func lastCommit(of path: String) async -> String? {
        guard let gitPath = GitIgnoreService.gitPath else { return nil }
        let directory = (path as NSString).deletingLastPathComponent
        // The name as written: git reads a path as a pattern, so `[draft].md` meant d.md, r.md… and `:memo.md` a pathspec
        // to parse, and the commit found could be another file's.
        let spec = ChildProcessSpec(executable: gitPath, arguments: ["--literal-pathspecs", "-C", directory, "log", "-1", "--format=%H", "--", (path as NSString).lastPathComponent])
        guard let process = try? ChildProcess.launch(spec) else { return nil }
        let output = await process.collectStdout()
        guard (try? await process.exitCode) == 0 else { return nil }
        let commit = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return commit.isEmpty ? nil : commit
    }

    // MARK: Looking back

    /// Shows `number` for `session`'s document: the current iteration goes back to the document as it is; an earlier
    /// one opens its snapshot read-only with its own notes.
    func view(_ number: Int, for session: DocumentSession) async {
        // Read again: the session's row was read when it opened, before any iteration started since.
        guard let opened = session.document, let document = try? await noteStore.document(opened.id) else { return }
        guard number != document.currentIteration,
              let iteration = try? await noteStore.iterations(for: document.id).first(where: { $0.number == number }) else {
            backToCurrent(session)
            return
        }
        if let shown = past[session.id] {
            if shown.iteration.number == number { return }
            shown.session?.close()
            past[session.id] = nil
        }
        session.showChanges(since: nil, snapshot: nil)
        viewGeneration += 1
        let generation = viewGeneration
        var snapshotSession: DocumentSession?
        let data = try? await iteration.snapshotHash.asyncMap { try await noteStore.snapshot(hash: $0) }
        // Another view, Back to Current, or quitting won while the snapshot was read.
        guard generation == viewGeneration else { return }
        if let data = data ?? nil, let base = fileSystem(document.hostID) {
            let snapshot = SnapshotFileSystem(base: base, path: document.path, data: data, date: iteration.endedAt ?? iteration.startedAt)
            snapshotSession = DocumentSession(hostID: document.hostID, path: document.path, fileSystem: snapshot, noteStore: noteStore,
                                              attachmentDirectory: session.attachmentDirectory, pastIteration: number)
        }
        past[session.id] = PastView(iteration: iteration, session: snapshotSession)
        onViewedIterationChange(document, number)
        await snapshotSession?.open()
    }

    /// Bumped by every change of view, so a view still reading its snapshot gives way to a later one.
    @ObservationIgnored private var viewGeneration = 0

    func relocate(_ move: DocumentRelocation) async throws {
        viewGeneration += 1
        let prefix = move.hostID.rawValue + ":"
        for (key, view) in Array(past) {
            guard key.hasPrefix(prefix), let path = move.destination(for: String(key.dropFirst(prefix.count))) else { continue }
            if let snapshot = view.session { try await snapshot.retarget(to: path) }
            past[key] = nil
            past[prefix + path] = view
        }
    }

    func backToCurrent(_ session: DocumentSession) {
        viewGeneration += 1
        guard let shown = past.removeValue(forKey: session.id) else { return }
        shown.session?.close()
        if let document = session.document { onViewedIterationChange(document, nil) }
    }

    /// The iteration shown for `session`, when it is an earlier one.
    func viewedIteration(for session: DocumentSession) -> Iteration? {
        past[session.id]?.iteration
    }

    /// Tints, in the document as it is, the lines changed since `number` ended; nil turns it off. Text only.
    func showChanges(since number: Int?, in shown: DocumentSession) async {
        backToCurrent(shown)
        // Tinted on the document as it is, even when asked from an earlier iteration's banner.
        let session = shown.document.flatMap { liveSession($0.id) } ?? shown
        guard let number, let document = session.document,
              let iteration = try? await noteStore.iterations(for: document.id).first(where: { $0.number == number }),
              let hash = iteration.snapshotHash, let data = try? await noteStore.snapshot(hash: hash) else {
            session.showChanges(since: nil, snapshot: nil)
            return
        }
        // Decoded as the document is: read as UTF-8, a Latin-1 snapshot's accents differed from the text on every line.
        session.showChanges(since: number, snapshot: TextEncoding.decode(data).text)
    }

    /// Copies an earlier iteration's note into the current one, found again in the content as it is now (where it
    /// was, when it can't be found), saying where it came from.
    func bringForward(_ note: Note, in document: Core.Document) async {
        var anchor = note.anchor
        var found = true
        if case .text(let old) = note.anchor, let text = await currentText(of: document) {
            if let moved = EarlierNotes.relocate(old, in: text, hash: Data(text.utf8).sha256Hex, fileName: PathUtilities.name(of: document.path)) {
                anchor = .text(moved)
            } else {
                // Not in the file any more: an orphan, to be placed again, rather than a highlight on other words.
                found = false
            }
        }
        let label = (try? await noteStore.iterations(for: document.id).first { $0.number == note.iteration })?.label ?? "Iteration \(note.iteration)"
        do {
            _ = try await noteStore.bringForward(note.id, anchor: anchor, found: found, origin: "Brought forward from \(label)")
        } catch {
            Log.notes.error("bring forward failed: \(error, privacy: .public)")
            onFailure("Couldn't bring the note forward: \(NotesPanelModel.reason(error))")
        }
    }

    private func currentText(of document: Core.Document) async -> String? {
        if let text = liveSession(document.id)?.baseText { return text }
        guard let fileSystem = fileSystem(document.hostID), let data = try? await fileSystem.read(document.path) else { return nil }
        return TextEncoding.decode(data).text
    }

    func rename(_ iteration: Iteration, to name: String) async {
        do { try await noteStore.renameIteration(documentID: iteration.documentID, number: iteration.number, name: name) } catch {
            Log.notes.error("rename iteration failed: \(error, privacy: .public)")
            onFailure("Couldn't rename the iteration: \(error.userMessage)")
        }
    }
}

/// What changed between an iteration's snapshot and the text now, as the lines a viewer tints.
enum IterationDiff {
    /// Past this many bytes on either side nothing is tinted: the diff would take too long to be worth it.
    nonisolated static let maximumSize = 4 * 1024 * 1024

    /// `lineChanges` off the main actor; nil for text too large to compare.
    @concurrent nonisolated static func computed(from old: String, to new: String) async -> LineChanges? {
        guard old.utf8.count <= maximumSize, new.utf8.count <= maximumSize else { return nil }
        return lineChanges(from: old, to: new)
    }

    nonisolated static func lineChanges(from old: String, to new: String) -> LineChanges {
        // Lines end at "\n" only, as git's do; `editorLines` maps them onto the editor's rows.
        let hunks = LineDiff.hunks(old: old.components(separatedBy: "\n"), new: new.components(separatedBy: "\n"))
        var added: [ClosedRange<Int>] = []
        var deletions: [Int] = []
        for hunk in hunks {
            if hunk.newRange.isEmpty {
                deletions.append(hunk.newRange.lowerBound + 1)
            } else {
                added.append((hunk.newRange.lowerBound + 1)...hunk.newRange.upperBound)
            }
        }
        return LineChanges(added: added, deletions: deletions)
    }
}

fileprivate extension Optional {
    /// `map` for an async transform.
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let self else { return nil }
        return try await transform(self)
    }
}
