import Foundation
import GRDB

extension NoteStore {
    static func refinement(_ id: DocumentID, _ db: Database) throws -> Refinement? {
        try Row.fetchOne(db, sql: "SELECT * FROM refinement WHERE document_id = ?", arguments: [id.rawValue]).map { row in
            Refinement(documentID: id, generation: row["generation"], status: RefinementStatus(rawValue: row["status"])!, round: row["round"],
                       requestNoteID: (row["request_note_id"] as String?).map(NoteID.init(rawValue:)), targetJSON: row["target_json"],
                       startedAt: row["started_at"], completedAt: row["completed_at"], summary: row["summary"], error: row["error"],
                       awaitingNextRound: row["awaiting_next_round"], hasAnswers: row["has_answers"], dismissed: row["dismissed"])
        }
    }
    public func refinement(for id: DocumentID) async throws -> Refinement? { try await database.queue.read { try Self.refinement(id, $0) } }
    public func refinements() async throws -> [Refinement] { try await database.queue.read { try Self.refinements($0) } }
    static func refinements(_ db: Database) throws -> [Refinement] {
        try String.fetchAll(db, sql: "SELECT document_id FROM refinement ORDER BY document_id").compactMap { try refinement(DocumentID(rawValue: $0), db) }
    }
    public func observeRefinements() -> AsyncThrowingStream<[Refinement], any Error> {
        Self.stream(ValueObservation.tracking { try Self.refinements($0) }, in: database.queue)
    }
    /// One visible ordinary request and its mode state are created together. Other documents are independent.
    public func beginRefinement(documentID: DocumentID, generation: String, targetJSON: String, at date: Date = Date()) async throws -> Refinement {
        try await database.queue.write { db in
            if let current = try Self.refinement(documentID, db), current.emitsDirective { return current }
            let iteration = try Self.openIteration(documentID, at: Self.rounded(date), db)
            let record = NoteRecord(id: NoteID.new().rawValue, documentId: documentID.rawValue, anchorJson: try Anchor.wholeFile.encodedJSON(),
                                    anchorType: Anchor.wholeFile.type.rawValue, body: Refinement.request, state: NoteState.draft.rawValue,
                                    createdAt: Self.rounded(date), updatedAt: Self.rounded(date), color: NoteColor.yellow.rawValue,
                                    resolveOutcome: nil, resolveMessage: nil, iteration: iteration)
            try record.insert(db)
            try db.execute(sql: """
                INSERT INTO refinement(document_id, generation, status, request_note_id, target_json, started_at)
                VALUES (?, ?, 'starting', ?, ?, ?) ON CONFLICT(document_id) DO UPDATE SET
                generation = excluded.generation, status = 'starting', round = 1, request_note_id = excluded.request_note_id,
                target_json = excluded.target_json, started_at = excluded.started_at, completed_at = NULL, summary = NULL,
                error = NULL, awaiting_next_round = 0, has_answers = 0, dismissed = 0
                """, arguments: [documentID.rawValue, generation, record.id, targetJSON, Self.rounded(date)])
            return try Self.refinement(documentID, db)!
        }
    }
    /// Preparation cancellation removes its generated request and control row together. Any delivery history survives.
    @discardableResult
    public func cancelRefinement(documentID: DocumentID, generation: String) async throws -> Bool {
        try await database.queue.write { db in
            guard let state = try Self.refinement(documentID, db), state.generation == generation, state.status == .starting,
                  let request = state.requestNoteID, let note = try NoteRecord.fetchOne(db, key: request.rawValue),
                  try !Self.wasShared(note, db),
                  try SendNoteRecord.filter(Column("note_id") == request.rawValue).fetchCount(db) == 0 else { return false }
            try db.execute(sql: "DELETE FROM refinement WHERE document_id = ? AND generation = ?", arguments: [documentID.rawValue, generation])
            try note.delete(db)
            return true
        }
    }
    public func endRefinement(documentID: DocumentID, generation: String? = nil) async throws {
        try await database.queue.write { try $0.execute(sql: "UPDATE refinement SET status = 'ended', error = NULL WHERE document_id = ? AND status IN ('starting', 'active') AND (? IS NULL OR generation = ?)", arguments: [documentID.rawValue, generation, generation]) }
    }
    public func refinementDeliveryFailed(documentID: DocumentID, generation: String, message: String) async throws {
        try await database.queue.write { try $0.execute(sql: "UPDATE refinement SET error = ? WHERE document_id = ? AND generation = ? AND status = 'starting'", arguments: [message, documentID.rawValue, generation]) }
    }
    public func dismissRefinement(documentID: DocumentID) async throws {
        try await database.queue.write { try $0.execute(sql: "UPDATE refinement SET dismissed = 1 WHERE document_id = ? AND status = 'completed'", arguments: [documentID.rawValue]) }
    }
    public func finishRefinement(documentID: DocumentID, generation: String, summary: String, at date: Date = Date()) async throws {
        let summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty, summary.count <= 500 else { throw RefinementError.invalidSummary }
        try await database.queue.write { db in
            guard let state = try Self.refinement(documentID, db), state.generation == generation else { throw RefinementError.staleGeneration }
            if state.status == .completed { return }
            guard state.status == .active else { throw RefinementError.inactive }
            let notes = try Self.notes(documentID, iteration: nil, db)
            guard !notes.contains(where: { $0.waitingOnUser || $0.hasUnsentFollowUps }) else { throw RefinementError.pendingAnswers }
            try db.execute(sql: "UPDATE refinement SET status = 'completed', summary = ?, completed_at = ?, error = NULL WHERE document_id = ? AND generation = ?",
                           arguments: [summary, Self.rounded(date), documentID.rawValue, generation])
        }
    }
}
