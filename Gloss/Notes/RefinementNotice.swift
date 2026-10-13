import AppKit
import Core
import SwiftUI

struct RefinementCommands: View {
    let model: AppModel
    var body: some View {
        Button("Refine This Document") {
            guard let session = model.activeSession else { return }
            Task { await model.refinement.begin(session, review: model.settings.reviewsResults) }
        }
        .disabled(model.isShowingPastIteration || !model.refinement.canStart(model.activeSession))
        if model.isShowingPastIteration, let session = model.activeSession {
            Button("Back to Current") { model.iterations.backToCurrent(session) }
        }
        if let id = model.activeSession?.document?.id {
            if let state = model.refinement.state(for: id), state.emitsDirective {
                Button("End Refinement") { model.refinement.end(state) }
            } else if model.refinement.isPreparing(id) {
                Button("End Refinement") { model.refinement.cancelPreparation(id) }
            }
        }
    }
}

struct RefinementNotice: View {
    @Environment(AppModel.self) private var model
    let session: DocumentSession
    @State private var previewingAnswers = false
    var body: some View {
        if let id = session.document?.id, session.pastIteration == nil {
            if let state = model.refinement.state(for: id), state.status != .ended, !state.dismissed,
               !(model.refinement.isPreparing(id) && !state.emitsDirective) {
                let title = state.status == .completed ? "No more questions" : state.status == .starting ? "Starting Refinement…" : "Refining"
                let detail = model.refinement.detail(state)
                let target = model.refinement.target(for: state)
                let available = target.map(model.refinement.available) ?? false
                Notice(kind: .mode, symbol: "sparkles", title: title, detail: "\(session.fileName) · \(target?.label ?? "Agent") · " + detail + (state.emitsDirective && !available ? " · \(target?.label ?? "Agent") unavailable" : ""), expandsDetail: state.status == .completed, wrapsActions: true) {
                    if state.status == .completed {
                        Button("Done") { Task { await model.refinement.dismiss(state) } }.buttonStyle(.glassProminent)
                    } else {
                        if state.status == .starting, state.error != nil {
                            Button("Retry") { Task { await model.refinement.retry(state, review: model.settings.reviewsResults, session: session) } }
                                .buttonStyle(.glassProminent).disabled(!available || model.send.isSending)
                        } else if state.status == .active {
                            let ready = model.refinement.readyAnswers(in: id).count
                            if ready > 0 {
                                Button("Send \(ready) Answer\(ready == 1 ? "" : "s")") { Task { await model.refinement.sendAnswers(state, review: model.settings.reviewsResults) } }
                                    .buttonStyle(.glassProminent).disabled(!available || model.send.isSending || model.refinement.sendingAnswers.contains(id))
                                    .contextMenu { Button("Preview Answers…") { previewingAnswers = true } }
                                    .popover(isPresented: $previewingAnswers) { RefinementAnswerPreview(state: state, session: session) }
                            } else if !model.refinement.questions(in: id).isEmpty {
                                Button("Show Questions") { model.showRefinementQuestions(in: session) }.buttonStyle(.glassProminent)
                            }
                        }
                        Button("End Refinement") { model.refinement.end(state) }.buttonStyle(.glass)
                    }
                }
                .padding(DS.Space.s)
                .onChange(of: session.fileName + ". " + title + ". " + detail, initial: true) { _, text in
                    guard let window = NSApp?.mainWindow else { return }
                    NSAccessibility.post(element: window, notification: .announcementRequested,
                                         userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
                }
            }
            if model.refinement.isPreparing(id), model.refinement.state(for: id)?.emitsDirective != true {
                Notice(kind: .mode, symbol: "sparkles", title: "Starting Refinement…", detail: "Preparing the saved document.") {
                    Button("End Refinement") { model.refinement.cancelPreparation(id) }.buttonStyle(.glass)
                }.padding(DS.Space.s)
            }
            if model.refinement.saveFirst.contains(id), session.isDirty {
                Notice(kind: .warning, symbol: "square.and.arrow.down", title: "Save before Refinement", detail: "The agent needs the saved document.") {
                    Button("Save First") { Task { await session.save(); if !session.isDirty { model.refinement.saveFirst.remove(id) } } }.buttonStyle(.glassProminent)
                }.padding(DS.Space.s)
            }
            if let error = model.refinement.errors[id] {
                Notice(kind: .warning, symbol: "exclamationmark.triangle", title: "Refinement", detail: error) {
                    Button("Dismiss") { model.refinement.errors[id] = nil }.buttonStyle(.glass)
                }.padding(DS.Space.s)
            }
        }
    }
}

extension AppModel {
    func showRefinementQuestions(in session: DocumentSession) {
        guard let document = session.document else { return }
        iterations.backToCurrent(session)
        showNotesPanel = true
        notesPanel.searchText = ""; notesPanel.colorFilter = []; notesPanel.filter = .attention
        if let note = refinement.questions(in: document.id).first {
            notesPanel.makeListed(note)
            notesPanel.selectedNoteID = note.id
            reveal(note: note, in: document, select: false)
        }
    }
}

private struct RefinementAnswerPreview: View {
    @Environment(AppModel.self) private var model
    let state: Refinement
    let session: DocumentSession
    @State private var text = ""
    private var key: String {
        let panel = model.notesPanel
        return String(describing: model.refinement.state(for: state.documentID)) + String(describing: panel.followUpText) + String(describing: panel.followUpEdits)
            + model.refinement.readyAnswers(in: state.documentID).map { "\($0.id.rawValue):\($0.updatedAt)" }.joined()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text("\(session.fileName) · \(model.refinement.target(for: state)?.label ?? "Agent")").font(.headline)
            ScrollView { Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 280)
        }.padding(DS.Space.m).frame(width: 420)
        .task(id: key) {
            do {
                let packet = try await model.send.preview(noteIDs: model.refinement.readyAnswers(in: state.documentID).map(\.id), review: model.settings.reviewsResults,
                                                          composing: model.notesPanel.followUpText, edits: model.notesPanel.followUpEdits)
                guard !Task.isCancelled else { return }; text = packet.text
            } catch { text = error.userMessage }
        }
    }
}
