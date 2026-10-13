import Foundation
import GRDB

extension NoteMessage {
    /// A status reply cannot hide the question. Only a sent user answer closes it.
    public static func unansweredQuestion(in messages: [NoteMessage]) -> NoteMessage? {
        guard let index = messages.lastIndex(where: { $0.kind == .question }) else { return nil }
        guard !messages.dropFirst(index + 1).contains(where: { $0.author == .user && $0.isSent }) else { return nil }
        return messages[index]
    }
}

extension NoteStore {
    /// Undo preserves question association and custom status without changing any sent message.
    public func restoreCustomAnswer(_ message: NoteMessage, at date: Date = Date()) async throws {
        guard !message.isSent, message.customAnswer else { throw RefinementError.questionClosed }
        try await database.queue.write { db in
            guard let note = try NoteRecord.fetchOne(db, key: message.noteID.rawValue), note.deletedAt == nil else { throw NoteStoreError.noteNotFound(message.noteID) }
            var record = try Self.insertFollowUp(message.noteID, body: message.body, at: Self.rounded(date), db)
            record.inReplyTo = message.inReplyTo?.rawValue
            record.customAnswer = true
            try record.update(db)
            try db.execute(sql: "UPDATE note SET updated_at = ? WHERE id = ?", arguments: [Self.rounded(date), note.id])
        }
    }
    /// Selection is a durable ordinary follow-up, never a send. Edited/custom answers are separate and protected.
    public func setChoiceSelection(questionID: MessageID, indexes: [Int], at date: Date = Date()) async throws {
        try await database.queue.write { db in
            guard let question = try NoteMessageRecord.fetchOne(db, key: questionID.rawValue),
                  let note = try NoteRecord.fetchOne(db, key: question.noteId), note.deletedAt == nil,
                  note.state != NoteState.resolved.rawValue, note.waitingOnUser,
                  let choices = NoteMessage(record: question).choices,
                  try NoteMessage.unansweredQuestion(in: Self.messages(NoteID(rawValue: note.id), db))?.id == questionID,
                  try Int.fetchOne(db, sql: "SELECT current_iteration FROM document WHERE id = ?", arguments: [note.documentId]) == note.iteration
            else { throw RefinementError.questionClosed }
            let selected = Array(Set(indexes)).sorted()
            guard selected.allSatisfy({ choices.options.indices.contains($0) }), choices.multi || selected.count <= 1 else { throw RefinementError.invalidSelection }
            var draft = try NoteMessageRecord.filter(Column("in_reply_to") == questionID.rawValue && Column("sent_at") == nil && Column("selected_options_json") != nil && Column("custom_answer") == false).fetchOne(db)
            if selected.isEmpty {
                if let draft { try draft.delete(db) }
            } else {
                if draft == nil {
                    draft = NoteMessageRecord(id: MessageID.new().rawValue, noteId: note.id, author: MessageAuthor.user.stored,
                                              kind: MessageKind.comment.rawValue, body: "", metaJson: nil, createdAt: Self.rounded(date), sentAt: nil)
                }
                draft!.body = selected.map { choices.options[$0] }.joined(separator: "\n")
                draft!.inReplyTo = questionID.rawValue
                draft!.selectedOptionsJson = String(decoding: try JSONEncoder().encode(selected), as: UTF8.self)
                try draft!.save(db)
            }
            try db.execute(sql: "UPDATE note SET updated_at = ? WHERE id = ?", arguments: [Self.rounded(date), note.id])
        }
    }
}
