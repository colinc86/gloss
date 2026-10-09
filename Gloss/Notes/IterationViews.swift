import Core
import SwiftUI

/// The notes panel's "Iteration 3" menu for the document in front (issue #18): every iteration with its date and
/// note count, then New Iteration, Show Changes Since, and Rename.
struct IterationMenu: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: Iteration?
    @State private var newName = ""

    var body: some View {
        let iterations = model.iterations
        if let session = model.activeSession, let document = session.document, !iterations.iterations.isEmpty,
           document.kind != .web {
            let viewed = iterations.viewedIteration(for: session)
            // Iterations only grow: the last is the current one (the session's document row may predate it).
            let current = iterations.iterations.last
            let shown = viewed ?? current
            Menu {
                ForEach(iterations.iterations.reversed()) { iteration in
                    Toggle(isOn: Binding(get: { shown?.number == iteration.number },
                                         set: { if $0 { Task { await iterations.view(iteration.number, for: session) } } })) {
                        Text(iteration.label)
                        Text(Self.detail(iteration, current: iteration.number == current?.number))
                    }
                }
                Divider()
                Button("New Iteration", systemImage: "plus") { model.newIteration() }
                    .disabled(viewed != nil || current?.noteCount == 0)
                let earlier = iterations.iterations.filter { $0.snapshotHash != nil }
                if session.textController != nil, !earlier.isEmpty {
                    Menu("Show Changes Since") {
                        ForEach(earlier.reversed()) { iteration in
                            Button(iteration.label) { Task { await iterations.showChanges(since: iteration.number, in: session) } }
                        }
                    }
                    if session.changesSinceIteration != nil {
                        Button("Hide Changes") { Task { await iterations.showChanges(since: nil, in: session) } }
                    }
                }
                if let shown {
                    Button("Rename…") {
                        newName = shown.name ?? ""
                        renaming = shown
                    }
                }
            } label: {
                Label(shown.map { "Iteration \($0.number)" } ?? "Iteration", systemImage: "square.stack.3d.up")
                    .font(.caption.weight(.medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Iterations of \(document.fileName)")
            .alert("Rename Iteration", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Rename") {
                    if let renaming { Task { await iterations.rename(renaming, to: newName) } }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            } message: {
                Text("Leave it empty for the date it started.")
            }
        }
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
