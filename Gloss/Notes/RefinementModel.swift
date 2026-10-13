import Core
import Foundation
import Observation
import OSLog

/// Standing document directives are separate from ordinary note/review lifecycles.
@MainActor @Observable
final class RefinementModel {
    private let store: NoteStore
    private let sender: SendCoordinator
    private let panel: NotesPanelModel
    private(set) var states: [DocumentID: Refinement] = [:]
    private(set) var sendingAnswers: Set<DocumentID> = []
    private(set) var preparing: Set<DocumentID> = []
    private var preparationGenerations: [DocumentID: String] = [:]
    private var cancellableGenerations: Set<String> = []
    private var ending: Set<DocumentID> = []
    private var endedDocuments: Set<DocumentID> = []
    private var endedGenerations: Set<String> = []
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored var prepareDocument: (DocumentID) async -> Void = { _ in }
    private var cancelledPreparation: Set<DocumentID> = []
    var saveFirst: Set<DocumentID> = []
    var errors: [DocumentID: String] = [:]

    init(store: NoteStore, sender: SendCoordinator, panel: NotesPanelModel) {
        self.store = store; self.sender = sender; self.panel = panel
        sender.refinementAllowed = { [weak self] _, generation in !(self?.endedGenerations.contains(generation) ?? false) }
        sender.willDeliver = { [weak self] ids in
            guard let self else { return }
            for state in self.states.values where state.requestNoteID.map(ids.contains) == true {
                self.cancellableGenerations.remove(state.generation)
            }
        }
    }
    func startObserving() {
        guard observation == nil else { return }
        let stream = store.observeRefinements()
        observation = Task { [weak self] in
            do { for try await states in stream {
                guard let self else { return }
                self.states = Dictionary(uniqueKeysWithValues: states.filter { !self.endedGenerations.contains($0.generation) }.map { ($0.documentID, $0) })
            } } catch { Log.notes.error("Refinement observation failed: \(error, privacy: .public)") }
        }
    }
    func stop() { observation?.cancel(); observation = nil }
    func state(for id: DocumentID) -> Refinement? { states[id] }
    func target(for state: Refinement) -> AgentTarget? { try? JSONDecoder().decode(AgentTarget.self, from: Data(state.targetJSON.utf8)) }
    func available(_ target: AgentTarget) -> Bool { target.transport == .clipboard || sender.targets.contains { $0.id == target.id } }
    @ObservationIgnored var mayStart: (DocumentID) -> Bool = { _ in true }
    func canStart(_ session: DocumentSession?) -> Bool {
        guard let session, let document = session.document, session.hostID != .gloss, session.pastIteration == nil else { return false }
        return mayStart(document.id) && sender.isTargetAvailable && !sender.isSending && !preparing.contains(document.id) && !ending.contains(document.id) && states[document.id]?.emitsDirective != true
    }
    func begin(_ session: DocumentSession, review: Bool) async {
        guard canStart(session), let document = session.document, let target = sender.lastTarget else { return }
        guard !session.isDirty else { saveFirst.insert(document.id); return }
        errors[document.id] = nil
        let generation = "rf_" + UUID().uuidString
        preparing.insert(document.id)
        preparationGenerations[document.id] = generation
        cancellableGenerations.insert(generation)
        cancelledPreparation.remove(document.id)
        defer {
            if preparationGenerations[document.id] == generation {
                preparationGenerations[document.id] = nil
                preparing.remove(document.id)
            }
            cancellableGenerations.remove(generation)
        }
        do {
            await prepareDocument(document.id)
            guard !cancelledPreparation.contains(document.id) else { return }
            guard !session.isDirty else { saveFirst.insert(document.id); return }
            // Keep the saved-content requirement explicit; never silently save an editor.
            let state = try await store.beginRefinement(documentID: document.id, generation: generation,
                                                       targetJSON: String(decoding: try JSONEncoder().encode(target), as: UTF8.self))
            guard state.generation == generation else { await refresh(document.id); return }
            if cancelledPreparation.contains(document.id) { end(state); return }
            endedDocuments.remove(document.id)
            states[document.id] = state
            await deliverRequest(state, review: review, session: session)
        } catch { errors[document.id] = error.userMessage }
    }
    func retry(_ state: Refinement, review: Bool, session: DocumentSession) async {
        guard state.status == .starting, !sender.isSending else { return }
        await deliverRequest(state, review: review, session: session)
    }
    private func deliverRequest(_ state: Refinement, review: Bool, session: DocumentSession) async {
        guard let target = target(for: state), available(target), let request = state.requestNoteID else { errors[state.documentID] = "The chosen Refinement agent is unavailable."; return }
        if sender.isSending {
            try? await store.refinementDeliveryFailed(documentID: state.documentID, generation: state.generation, message: "Another send is in progress. Retry when it finishes.")
            await refresh(state.documentID)
            return
        }
        await sender.send(noteIDs: [request], to: target, review: review, validate: { [weak self, weak session] in
            guard let self, let session else { return "The document is no longer open." }
            if self.endedGenerations.contains(state.generation) { return "Refinement ended before delivery." }
            if session.isDirty { return "Save this document before starting Refinement." }
            guard let note = try? await self.store.note(request), let document = try? await self.store.document(state.documentID), note.iteration == document.currentIteration else { return "The request moved to an earlier iteration. End and start Refinement again to send a current request." }
            if self.endedGenerations.contains(state.generation) { return "Refinement ended before delivery." }
            return session.isDirty ? "Save this document before starting Refinement." : nil
        })
        if let error = sender.lastResult?.failure {
            try? await store.refinementDeliveryFailed(documentID: state.documentID, generation: state.generation, message: error)
        }
        await refresh(state.documentID)
    }
    func isPreparing(_ id: DocumentID) -> Bool { preparing.contains(id) && !cancelledPreparation.contains(id) }
    func cancelPreparation(_ id: DocumentID) { cancelledPreparation.insert(id) }

    /// Suppress the directive and notice synchronously, before the database suspension.
    func end(_ state: Refinement) {
        guard !endedGenerations.contains(state.generation) else { return }
        if preparing.contains(state.documentID) { cancelledPreparation.insert(state.documentID) }
        let cancelRequest = preparationGenerations[state.documentID] == state.generation && cancellableGenerations.contains(state.generation) && state.status == .starting
        endedDocuments.insert(state.documentID)
        endedGenerations.insert(state.generation)
        states[state.documentID] = nil
        ending.insert(state.documentID)
        Task {
            defer { ending.remove(state.documentID) }
            do {
                if cancelRequest, try await store.cancelRefinement(documentID: state.documentID, generation: state.generation) { return }
                try await store.endRefinement(documentID: state.documentID, generation: state.generation)
            }
            catch { errors[state.documentID] = error.userMessage }
        }
    }
    func dismiss(_ state: Refinement) async { try? await store.dismissRefinement(documentID: state.documentID); await refresh(state.documentID) }
    func refresh(_ id: DocumentID) async {
        guard let state = try? await store.refinement(for: id), !endedGenerations.contains(state.generation) else { states[id] = nil; return }
        states[id] = state
    }
    func questions(in id: DocumentID) -> [Note] {
        panel.allGroups.filter { $0.document.id == id }.flatMap { group in group.notes.filter { $0.iteration == group.document.currentIteration && $0.waitingOnUser } }
    }
    func readyAnswers(in id: DocumentID) -> [Note] {
        panel.allGroups.filter { $0.document.id == id }.flatMap { group in group.notes.filter { note in
            note.iteration == group.document.currentIteration && panel.messages(for: note.id).contains { $0.kind == .question }
            && (note.hasUnsentFollowUps || !(panel.followUpText[note.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || panel.messages(for: note.id).contains { panel.followUpEdits[$0.id] != nil })
        } }
    }
    func validateFinish(_ id: DocumentID) throws {
        guard !endedDocuments.contains(id) else { throw RefinementError.inactive }
        let current = panel.allGroups.filter { $0.document.id == id }.flatMap { group in group.notes.filter { $0.iteration == group.document.currentIteration } }
        guard !current.contains(where: { note in
            !(panel.followUpText[note.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || panel.messages(for: note.id).contains { panel.followUpEdits[$0.id] != nil || panel.pendingChoiceWrites.contains($0.id) }
        }) else { throw RefinementError.pendingAnswers }
    }
    /// Stage fields across filters before the delivery snapshot. Any write failure preserves input and stops Send.
    func sendAnswers(_ state: Refinement, review: Bool) async {
        guard let target = target(for: state), available(target), !sendingAnswers.contains(state.documentID) else { return }
        guard !sender.isSending else {
            errors[state.documentID] = "Another send is in progress. Retry when it finishes."
            return
        }
        errors[state.documentID] = nil
        sendingAnswers.insert(state.documentID)
        defer { sendingAnswers.remove(state.documentID) }
        let answers = readyAnswers(in: state.documentID)
        guard !answers.isEmpty else { return }
        for note in answers {
            for message in panel.messages(for: note.id) {
                if let text = panel.followUpEdits[message.id] {
                    guard await panel.updateFollowUp(message.id, text) else { errors[state.documentID] = "Couldn't stage an edited answer. Nothing was sent."; return }
                    if panel.followUpEdits[message.id] == text { panel.followUpEdits[message.id] = nil }
                }
            }
            if !(panel.followUpText[note.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard await panel.commitFollowUp(for: note.id) else { errors[state.documentID] = "Couldn't stage an answer. Nothing was sent."; return }
            }
        }
        var ids: [NoteID] = []
        for answer in answers {
            if let fresh = try? await store.note(answer.id), fresh.hasUnsentFollowUps { ids.append(answer.id) }
        }
        guard !ids.isEmpty else { return }
        guard !sender.isSending else {
            errors[state.documentID] = "Another send is in progress. Retry when it finishes."
            return
        }
        await sender.send(noteIDs: ids, to: target, review: review, validate: { [store] in
            for id in ids {
                guard let note = try? await store.note(id), let document = try? await store.document(note.documentID), note.iteration == document.currentIteration else {
                    return "The answers moved to an earlier iteration. Nothing was sent."
                }
            }
            return nil
        })
        await refresh(state.documentID)
    }
    func detail(_ state: Refinement) -> String {
        if state.status == .completed { return state.summary ?? "" }
        if state.status == .starting { return state.error ?? "Sending the document request to \(target(for: state)?.label ?? "the chosen agent")." }
        let count = questions(in: state.documentID).count
        return "Round \(state.round) · " + (count > 0 ? "\(count) question\(count == 1 ? "" : "s") for you" : state.hasAnswers ? "The agent is reading your answers" : "The agent is reading the document")
    }
}
