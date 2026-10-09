import Core
import SwiftUI

/// "Iteration 3" at the trailing edge of a document's header in the notes panel (issue #18): every iteration of that
/// document with its date and note count, then New Iteration, Show Changes Since, and Rename. Shown once the document
/// has a note; while an earlier iteration is shown it names that one, in the accent of a mode, not the current one.
struct IterationMenu: View {
    @Environment(AppModel.self) private var model
    let document: Core.Document
    @State private var state: DocumentIterations
    @State private var renaming: Iteration?
    @State private var newName = ""

    /// `state` is given only by tests, to see what the header knows.
    init(document: Core.Document, state: DocumentIterations = DocumentIterations()) {
        self.document = document
        _state = State(initialValue: state)
    }

    var body: some View {
        let viewed = model.notesPanel.viewedIteration.flatMap { $0.document.id == document.id ? $0.number : nil }
        // Never empty: an empty view never starts its task, so a document whose first note came later never showed
        // the menu. The clear spacer holds the observation until there is something to show.
        ZStack(alignment: .trailing) {
            Color.clear.frame(width: 0, height: 0)
            if document.kind != .web, let shown = state.shown(viewing: viewed) {
                menu(shown: shown, viewed: viewed)
            }
        }
        .task(id: document.id) { await state.observe(document.id, in: model.noteStore) }
    }

    private func menu(shown: Iteration, viewed: Int?) -> some View {
        let iterations = state.iterations
        let current = iterations.last
        let shown: Iteration? = shown
        let live = model.session(hostID: document.hostID, path: document.path)
        return Menu {
            ForEach(iterations.reversed()) { iteration in
                Toggle(isOn: Binding(get: { shown?.number == iteration.number },
                                     set: { if $0 { model.showIteration(iteration.number, of: document) } })) {
                    Text(iteration.label)
                    Text(Self.detail(iteration, current: iteration.number == current?.number))
                }
            }
            Divider()
            Button("New Iteration", systemImage: "plus") { model.newIteration(for: document) }
                .disabled(viewed != nil || current?.noteCount == 0)
            let earlier = iterations.filter { $0.snapshotHash != nil }
            if Self.showsChanges(document.kind), !earlier.isEmpty {
                Menu("Show Changes Since") {
                    ForEach(earlier.reversed()) { iteration in
                        Button(iteration.label) { model.showChanges(since: iteration.number, of: document) }
                    }
                }
                if live?.changesSinceIteration != nil {
                    Button("Hide Changes") { model.showChanges(since: nil, of: document) }
                }
            }
            if let shown {
                Button("Rename…") {
                    newName = shown.name ?? ""
                    renaming = shown
                }
            }
        } label: {
            HStack(spacing: DS.Space.xxs) {
                if viewed != nil { Image(systemName: "clock.arrow.circlepath") }
                Text(shown.map { "Iteration \($0.number)" } ?? "Iteration")
                    .monospacedDigit()
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(viewed != nil ? Color.accentColor : Color.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .help(viewed != nil ? "Showing an earlier iteration of \(document.fileName)" : "Iterations of \(document.fileName)")
        .accessibilityLabel(viewed != nil ? "Iterations of \(document.fileName), showing earlier iteration \(viewed ?? 0)"
                            : "Iterations of \(document.fileName), iteration \(current?.number ?? 0)")
        .alert("Rename Iteration", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let renaming { Task { await model.iterations.rename(renaming, to: newName) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Leave it empty for the date it started.")
        }
    }

    /// Text documents tint changed lines; images, PDFs and pages don't.
    static func showsChanges(_ kind: DocumentKind) -> Bool {
        kind == .text || kind == .code || kind == .markdown
    }

    /// "Current · 4 notes" or "Oct 8 · 3 notes · a1b2c3d".
    static func detail(_ iteration: Iteration, current: Bool) -> String {
        var parts = [current ? "Current" : (iteration.endedAt ?? iteration.startedAt).formatted(.dateTime.month(.abbreviated).day())]
        parts.append(iteration.noteCount == 1 ? "1 note" : "\(iteration.noteCount) notes")
        if let commit = iteration.shortCommit { parts.append(commit) }
        if !current, iteration.snapshotHash == nil { parts.append("no snapshot") }
        return parts.joined(separator: " · ")
    }
}

/// One document's iterations for its header's menu, kept current by an observation of the database.
@MainActor
@Observable
final class DocumentIterations {
    private(set) var iterations: [Iteration] = []

    /// Follows `documentID`'s iterations until the task is cancelled; the first note's insert brings iteration 0.
    func observe(_ documentID: DocumentID, in store: NoteStore) async {
        iterations = []
        do {
            for try await iterations in store.observeIterations(for: documentID) { self.iterations = iterations }
        } catch {}
    }

    /// The iteration the header names: `viewing`, an earlier one on screen, else the current one (iterations only
    /// grow, so the last). Nil before the document has a note, when the menu isn't shown.
    func shown(viewing: Int?) -> Iteration? {
        viewing.flatMap { number in iterations.first { $0.number == number } } ?? iterations.last
    }

    /// "Iteration 0", the header's words; nil while the menu isn't shown.
    func label(viewing: Int?) -> String? {
        shown(viewing: viewing).map { "Iteration \($0.number)" }
    }
}

/// Over the viewer while an earlier iteration is shown: which, that it is read-only, and the way back.
struct IterationBanner: View {
    @Environment(AppModel.self) private var model
    let session: DocumentSession
    let iteration: Iteration

    var body: some View {
        let detail = iteration.snapshotHash == nil
            ? "Its snapshot wasn't kept; its notes are listed in the notes panel."
            : "Read-only: the file as this iteration left it, with its notes."
        Notice(kind: .mode, symbol: "clock.arrow.circlepath", title: iteration.label, detail: detail) {
            if iteration.snapshotHash != nil, session.textController != nil {
                Button("Show Changes Since") { Task { await model.iterations.showChanges(since: iteration.number, in: session) } }
            }
            Button("Back to Current") { model.iterations.backToCurrent(session) }
                .buttonStyle(.glassProminent)
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.top, DS.Space.s)
        .padding(.bottom, DS.Space.xs)
    }
}

/// Asks what to do with the notes still open when an iteration starts, with "Don't ask again" (Settings › Notes
/// changes it back).
struct OpenNotesPromptSheet: View {
    @Environment(AppModel.self) private var model
    let prompt: IterationsModel.OpenNotesPrompt
    @State private var remember = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text("Start a new iteration of \(prompt.document.fileName)?")
                .font(.headline)
            Text(prompt.openCount == 1
                 ? "One note isn't resolved yet. Bring it along to the new iteration, or leave it behind with the one that ends?"
                 : "\(prompt.openCount) notes aren't resolved yet. Bring them along to the new iteration, or leave them behind with the one that ends?")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Don't ask again", isOn: $remember)
            HStack {
                Button("Cancel", role: .cancel) { model.iterations.prompt = nil }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Leave Them Behind") { Task { await model.iterations.answer(prompt, .leave, remember: remember) } }
                Button("Bring Them Along") { Task { await model.iterations.answer(prompt, .carry, remember: remember) } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Space.l)
        .frame(width: 420)
    }
}
