import Foundation
import GRDB

/// Local review index. Source links and private edits never enter the package.
public struct IndexedReview: Sendable, Hashable {
    public var instance: InstanceID
    public var url: URL
    public var documentID: DocumentID
    public var title: String
    public var ownerAuthor: AuthorID
    public var isOwner: Bool
    public var isCopy: Bool
}

extension NoteStore {
    public func indexedReviews() async throws -> [IndexedReview] {
        try await queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM collaboration_review ORDER BY title").map { row in
                IndexedReview(instance: InstanceID(rawValue: row["instance"]), url: URL(fileURLWithPath: row["url"]),
                              documentID: DocumentID(rawValue: row["document_id"]), title: row["title"],
                              ownerAuthor: AuthorID(rawValue: row["owner_author"]), isOwner: row["is_owner"], isCopy: row["is_copy"])
            }
        }
    }

    public func reviewDocumentID(_ instance: InstanceID) async throws -> DocumentID? {
        try await queue.read { db in
            try String.fetchOne(db,sql: "SELECT document_id FROM collaboration_document WHERE instance=?",arguments: [instance.rawValue]).map(DocumentID.init(rawValue:))
        }
    }

    public func indexReview(_ info: GlossInfo, url: URL, documentID: DocumentID, isOwner: Bool) async throws {
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO collaboration_document(instance,document_id) VALUES (?,?) ON CONFLICT(instance) DO UPDATE SET document_id=excluded.document_id",arguments: [info.instance.rawValue,documentID.rawValue])
            try db.execute(sql: """
                INSERT INTO collaboration_review(instance,url,document_id,title,owner_author,is_owner,is_copy)
                VALUES (?,?,?,?,?,?,?) ON CONFLICT(instance) DO UPDATE SET url=excluded.url,title=excluded.title,
                owner_author=excluded.owner_author,is_owner=excluded.is_owner
                """, arguments: [info.instance.rawValue, url.path, documentID.rawValue, info.title, info.ownerAuthor.rawValue, isOwner, info.origin != nil])
        }
    }

    /// Removing a stale location must not delete the notes kept on this Mac.
    public func removeReview(_ instance: InstanceID) async throws {
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM collaboration_review WHERE instance=?", arguments: [instance.rawValue])
        }
    }

    public func agentDeliveryAllowed(_ ids: [NoteID]) async throws -> Bool {
        try await queue.read { db in
            for id in ids {
                if try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM note JOIN document d ON d.id=note.document_id LEFT JOIN collaboration_review c ON c.document_id=d.id WHERE note.id=? AND (c.is_owner=0 OR d.host_id='h_gloss'))", arguments: [id.rawValue]) == true { return false }
            }
            return true
        }
    }

    public func seenReviewRecords(_ instance: InstanceID) async throws -> Set<String> {
        try await queue.read { db in Set(try String.fetchAll(db, sql: "SELECT record_id FROM collaboration_seen WHERE instance = ?", arguments: [instance.rawValue])) }
    }

    public func markReviewRecordsSeen(_ records: Set<String>, instance: InstanceID) async throws {
        try await queue.write { db in
            for id in records { try db.execute(sql: "INSERT OR IGNORE INTO collaboration_seen(instance,record_id) VALUES (?,?)", arguments: [instance.rawValue, id]) }
        }
    }

    /// Detached copies and live reviews can contain the same remote ids. Each instance gets its own local notes.
    public func reviewNoteMap(_ instance: InstanceID) async throws -> [NoteID: NoteID] {
        try await queue.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT remote_id,local_id FROM collaboration_note_map WHERE instance = ?", arguments: [instance.rawValue]).map { row in
                (NoteID(rawValue: row["remote_id"]), NoteID(rawValue: row["local_id"]))
            })
        }
    }

    /// Imports complete published records while preserving this Mac's unpublished comment edits and answers.
    /// Agent delivery is deliberately NOT synthesized in send/send_note.
    public func importReview(_ snapshot: GlossSnapshot, documentID: DocumentID, identity: AuthorID, isOwner: Bool) async throws {
        try await queue.write { db in
            let instance = snapshot.info.instance.rawValue
            let encoder = JSONEncoder.sorted
            func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
            for folded in snapshot.folded() {
                let remote = folded.note
                let mapped = try String.fetchOne(db, sql: "SELECT local_id FROM collaboration_note_map WHERE instance=? AND remote_id=?", arguments: [instance, remote.id.rawValue])
                let localID = mapped ?? (isOwner ? remote.id.rawValue : NoteID.new().rawValue)
                var record = try NoteRecord.fetchOne(db, key: localID)
                if let record, record.documentId != documentID.rawValue { throw GlossPackageError.notAllowed("A note belongs to another review") }
                let previous = record
                let becameOwner = isOwner && record?.postedToOwner == true
                let new = record == nil
                let keepEdit = record?.publishedAt != nil && (record?.body != record?.publishedBody || record?.color != record?.publishedColor)
                if record == nil {
                    record = NoteRecord(id: localID, documentId: documentID.rawValue, anchorJson: try remote.anchor.encodedJSON(), anchorType: remote.anchor.type.rawValue,
                                        body: remote.body, state: NoteState.draft.rawValue, createdAt: remote.createdAt, updatedAt: remote.updatedAt,
                                        color: remote.color, resolveOutcome: nil, resolveMessage: nil)
                }
                guard var record else { continue }
                if !keepEdit { record.body = remote.body; record.color = remote.color }
                record.publishedBody = remote.body; record.publishedColor = remote.color
                record.publishedAt = record.publishedAt ?? remote.createdAt
                record.postedToOwner = !isOwner
                record.contributorId = remote.author.rawValue
                record.contributorName = snapshot.author(remote.author)?.name
                let events = snapshot.events.filter { $0.note == remote.id && !folded.refused.contains($0.id) }
                let latestEvent = events.max { ($0.at,$0.id.rawValue) < ($1.at,$1.id.rawValue) }
                let eventID = latestEvent?.id.rawValue
                // MCP writes are outside the package queue. An older sent echo must not undo their result.
                let newerLocalState = isOwner && record.localStateAt.map {
                    $0 > (latestEvent?.at ?? .distantPast) || ($0 == latestEvent?.at && latestEvent?.author == identity)
                } == true
                let latestMove = try Self.messages(NoteID(rawValue: localID),db).last { $0.kind == .moved }?.createdAt
                let foreignMove = events.filter { $0.eventType == .moved && $0.author != identity }
                    .max { ($0.at,$0.id.rawValue) < ($1.at,$1.id.rawValue) }
                if !isOwner {
                    record.anchorJson = try folded.anchor.encodedJSON(); record.anchorType = folded.anchor.type.rawValue
                } else if let foreignMove,
                          (foreignMove.at,foreignMove.id.rawValue) > (record.collaborationMoveAt ?? .distantPast,record.collaborationMoveId ?? ""),
                          foreignMove.at > (latestMove ?? previous?.createdAt ?? .distantPast), let anchor = foreignMove.movedAnchor {
                    record.anchorJson = try anchor.encodedJSON(); record.anchorType = anchor.type.rawValue
                }
                if let foreignMove, (foreignMove.at,foreignMove.id.rawValue) > (record.collaborationMoveAt ?? .distantPast,record.collaborationMoveId ?? "") {
                    record.collaborationMoveId = foreignMove.id.rawValue; record.collaborationMoveAt = foreignMove.at
                }
                if !newerLocalState && (new || !isOwner || becameOwner || record.collaborationEventId != eventID) {
                record.state = folded.status == .resolved ? "resolved" : (folded.isAgentVisible ? "sent" : "draft")
                record.resolveOutcome = folded.resolution?.outcome; record.resolveMessage = folded.resolution?.message
                record.resolveAgent = folded.resolution?.via?.agent
                record.resolvedAt = folded.resolution?.at
                }
                if becameOwner || !newerLocalState {
                    record.reviewRequested = isOwner && folded.reviewRequested; record.acceptedAt = isOwner ? folded.acceptedAt : nil
                }
                record.collaborationEventId = eventID
                record.author = remote.via?.agent
                let hasNewTurn = try folded.thread.contains { turn in
                    if isOwner { return try NoteMessageRecord.fetchOne(db,key: turn.id.rawValue) == nil }
                    return try String.fetchOne(db,sql: "SELECT local_id FROM collaboration_message_map WHERE instance=? AND remote_id=?",arguments: [instance,turn.id.rawValue]) == nil
                }
                if !newerLocalState && (new || becameOwner || hasNewTurn || previous?.collaborationEventId != eventID) { record.waitingOnUser = folded.waitingOnUser }
                if new || !isOwner || remote.iteration > record.iteration { record.iteration = remote.iteration }
                if !newerLocalState { record.deletedAt = folded.trashed ? (events.filter { $0.eventType == .deleted }.max { ($0.at,$0.id.rawValue) < ($1.at,$1.id.rawValue) }?.at ?? remote.updatedAt) : nil }
                record.updatedAt = max(record.updatedAt, remote.updatedAt)
                if new { try record.insert(db) } else if previous != record { try record.update(db) }
                try db.execute(sql: "INSERT OR IGNORE INTO collaboration_note_map(instance,remote_id,local_id) VALUES (?,?,?)", arguments: [instance, remote.id.rawValue, localID])
                for turn in folded.thread {
                    // Participant/copy message ids are namespaced locally too. Existing own unsent turns retain their id.
                    let ownExisting = try NoteMessageRecord.fetchOne(db, key: turn.id.rawValue)
                    let mappedMessage = try String.fetchOne(db,sql: "SELECT local_id FROM collaboration_message_map WHERE instance=? AND remote_id=?",arguments: [instance,turn.id.rawValue])
                    let id = mappedMessage ?? (isOwner || (turn.author == identity && ownExisting?.noteId == localID) ? turn.id.rawValue : MessageID.new().rawValue)
                    if var existing = try NoteMessageRecord.fetchOne(db,key: id) {
                        guard existing.noteId == localID else { throw GlossPackageError.notAllowed("A message belongs to another review") }
                        if isOwner {
                            let delivered = snapshot.info.isOwner(turn.author) || turn.via != nil
                            let sentAt = delivered ? turn.createdAt : existing.agentSentAt
                            if existing.sentAt != sentAt || (delivered && existing.agentSentAt != turn.createdAt) {
                                existing.sentAt = sentAt
                                if delivered { existing.agentSentAt = turn.createdAt }
                                try existing.update(db)
                            }
                        }
                        try db.execute(sql: "INSERT OR IGNORE INTO collaboration_message_map(instance,remote_id,local_id) VALUES (?,?,?)",arguments: [instance,turn.id.rawValue,id])
                        continue
                    }
                    let choices = turn.meta?["choices"]
                    let selected = turn.meta?["selectedOptions"]
                    let replyTo = try turn.inReplyTo.flatMap { try String.fetchOne(db,sql: "SELECT local_id FROM collaboration_message_map WHERE instance=? AND remote_id=?",arguments: [instance,$0.rawValue]) }
                    var message = NoteMessageRecord(id: id, noteId: localID, author: turn.via?.agent ?? MessageAuthor.userValue,
                                                   kind: turn.kind, body: turn.body, metaJson: turn.messageKind == .moved ? try turn.meta?["move"].map(json) : nil,
                                                   createdAt: turn.createdAt, sentAt: !isOwner || turn.via != nil || snapshot.info.isOwner(turn.author) ? turn.createdAt : nil,
                                                   choicesJson: try choices.map(json), inReplyTo: replyTo,
                                                   selectedOptionsJson: try selected.map(json), customAnswer: turn.meta?["customAnswer"]?.boolValue ?? false)
                    if isOwner && (turn.via != nil || snapshot.info.isOwner(turn.author)) { message.agentSentAt = turn.createdAt }
                    message.contributorId = turn.author.rawValue; message.contributorName = snapshot.author(turn.author)?.name
                    try message.insert(db)
                    try db.execute(sql: "INSERT OR IGNORE INTO collaboration_message_map(instance,remote_id,local_id) VALUES (?,?,?)",arguments: [instance,turn.id.rawValue,id])
                }
            }
            let captureDocument = try String.fetchOne(db,sql: "SELECT host_id FROM document WHERE id=?",arguments: [documentID.rawValue]) == HostID.gloss.rawValue
            if (!isOwner || captureDocument), snapshot.hasCurrentContent {
                try db.execute(sql: "UPDATE document SET current_iteration = ? WHERE id = ?", arguments: [snapshot.info.current.iteration, documentID.rawValue])
                for round in snapshot.iterations {
                    let existing = try IterationRecord.filter(Column("document_id") == documentID.rawValue && Column("number") == round.number).fetchOne(db)
                    let record = IterationRecord(documentId: documentID.rawValue, number: round.number, name: round.name, startedAt: round.startedAt,
                                                 endedAt: round.endedAt, snapshotHash: existing?.snapshotHash, gitCommit: round.gitCommit)
                    try record.save(db)
                }
            }
        }
    }

    /// Only the exact sent snapshot is stamped; an edit made during the coordinated write stays private.
    public func recordReviewPublication(_ notes: [Note], messages: [NoteMessage], instance: InstanceID, identity: GlossIdentity, at date: Date) async throws {
        try await queue.write { db in
            for note in notes {
                guard var record = try NoteRecord.fetchOne(db, key: note.id.rawValue) else { continue }
                record.postedToOwner = try Bool.fetchOne(db,sql: "SELECT is_owner=0 FROM collaboration_review WHERE instance=?",arguments: [instance.rawValue]) ?? false
                record.publishedAt = date; record.publishedBody = note.body; record.publishedColor = note.color.rawValue
                record.contributorId = record.contributorId ?? identity.author.rawValue
                record.contributorName = identity.name
                try record.update(db)
                try db.execute(sql: "INSERT OR IGNORE INTO collaboration_note_map(instance,remote_id,local_id) VALUES (?,?,?)", arguments: [instance.rawValue, note.id.rawValue, note.id.rawValue])
            }
            for message in messages {
                guard var published = try NoteMessageRecord.fetchOne(db,key: message.id.rawValue), published.sentAt == nil else { continue }
                let selected = try message.selectedOptions.map { String(decoding: try JSONEncoder.sorted.encode($0),as: UTF8.self) }
                if published.body != message.body || published.selectedOptionsJson != selected || published.customAnswer != message.customAnswer {
                    // Shared turns are immutable. Keep an edit made during publication as a new private turn,
                    // while the old id continues to describe exactly the bytes other people received.
                    var pending = published
                    pending.id = MessageID.new().rawValue; pending.createdAt = max(date,published.createdAt)
                    pending.contributorId = nil; pending.contributorName = nil
                    try pending.insert(db)
                }
                published.body = message.body
                published.selectedOptionsJson = selected
                published.customAnswer = message.customAnswer
                published.inReplyTo = message.inReplyTo?.rawValue
                published.sentAt = date; published.contributorId = identity.author.rawValue; published.contributorName = identity.name
                try published.update(db)
                try db.execute(sql: "INSERT OR IGNORE INTO collaboration_message_map(instance,remote_id,local_id) VALUES (?,?,?)",arguments: [instance.rawValue,message.id.rawValue,message.id.rawValue])
            }
        }
    }
}

extension NoteStore {
    public func linkReviewOriginal(_ instance: InstanceID, to documentID: DocumentID, baseline: Data) async throws {
        try await queue.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT document_id,is_owner FROM collaboration_review WHERE instance=?",arguments: [instance.rawValue]), row["is_owner"] as Bool else { throw GlossPackageError.notOwner }
            let old: String = row["document_id"]
            if old == documentID.rawValue { return }
            if try Int.fetchOne(db,sql: "SELECT COUNT(*) FROM note WHERE document_id=?",arguments: [documentID.rawValue]) != 0 { throw GlossPackageError.notAllowed("The original already has notes. Choose a matching original without a separate review history.") }
            try db.execute(sql: "DELETE FROM iteration WHERE document_id=?",arguments: [documentID.rawValue])
            try db.execute(sql: "INSERT INTO iteration SELECT ?,number,name,started_at,ended_at,snapshot_hash,git_commit,start_hash,completion_generation,handled_generation,completed_at FROM iteration WHERE document_id=?",arguments: [documentID.rawValue,old])
            try db.execute(sql: "UPDATE document SET current_iteration=(SELECT current_iteration FROM document WHERE id=?) WHERE id=?",arguments: [old,documentID.rawValue])
            try db.execute(sql: "UPDATE note SET document_id=? WHERE document_id=?",arguments: [documentID.rawValue,old])
            try db.execute(sql: "UPDATE iteration SET start_hash=COALESCE(start_hash,?) WHERE document_id=? AND number=(SELECT current_iteration FROM document WHERE id=?)",arguments: [baseline.sha256Hex,documentID.rawValue,documentID.rawValue])
            try db.execute(sql: "UPDATE collaboration_review SET document_id=? WHERE instance=?",arguments: [documentID.rawValue,instance.rawValue])
            try db.execute(sql: "UPDATE collaboration_document SET document_id=? WHERE instance=?",arguments: [documentID.rawValue,instance.rawValue])
        }
    }
}

extension NoteStore {
    public func reviewMessageMap(_ instance: InstanceID) async throws -> [MessageID: MessageID] {
        try await queue.read { db in
            Dictionary(uniqueKeysWithValues: try Row.fetchAll(db,sql: "SELECT remote_id,local_id FROM collaboration_message_map WHERE instance=?",arguments: [instance.rawValue]).map { row in
                (MessageID(rawValue: row["remote_id"]),MessageID(rawValue: row["local_id"]))
            })
        }
    }
    /// Legacy sends did not keep the comment snapshot. A later edit cannot be exported safely until another Send.
    public func deliveredReviewNote(_ id: NoteID) async throws -> Note? {
        try await queue.read { db in
            guard let record = try NoteRecord.fetchOne(db,key: id.rawValue) else { return nil }
            var note = try Note(record: record,db)
            if let saved = try String.fetchOne(db,sql: "SELECT note_json FROM agent_note_snapshot WHERE note_id=?",arguments: [id.rawValue]) {
                let delivered = try JSONDecoder().decode(Note.self,from: Data(saved.utf8))
                note.body = delivered.body; note.color = delivered.color; note.anchor = delivered.anchor
                return note
            }
            if record.author != nil && record.body.isEmpty { return note }
            let sent = try Date.fetchOne(db,sql: "SELECT MAX(send.sent_at) FROM send JOIN send_note ON send_note.send_id=send.id WHERE send_note.note_id=? AND send.outcome='delivered'",arguments: [id.rawValue])
            return sent.map { record.updatedAt <= $0 } == true ? note : nil
        }
    }
}

extension NoteStore {
    public func collaborationAuthorID() async throws -> AuthorID {
        try await queue.write { db in
            if let value = try String.fetchOne(db,sql: "SELECT value FROM setting WHERE key='collaboration.author'"), let id = AuthorID(validating: value) { return id }
            let id = AuthorID.new()
            try db.execute(sql: "INSERT OR REPLACE INTO setting(key,value) VALUES ('collaboration.author',?)",arguments: [id.rawValue])
            return id
        }
    }
}

extension NoteStore {
    public func reviewHistoryNotes(_ documentID: DocumentID) async throws -> [Note] {
        try await queue.read { db in try Self.notesInEveryIteration(documentID,db) }
    }
    public func importReviewSnapshots(_ captures: [Int: Data], documentID: DocumentID) async throws {
        try await queue.write { db in
            for (number,bytes) in captures {
                let hash = try Self.storeSnapshot(bytes,at: Date(),db)
                try db.execute(sql: "UPDATE iteration SET snapshot_hash=? WHERE document_id=? AND number=? AND ended_at IS NOT NULL",arguments: [hash,documentID.rawValue,number])
            }
        }
    }
}

extension NoteStore {
    public func agentNote(_ id: NoteID) async throws -> Note? {
        try await queue.read { db in
            guard let record = try NoteRecord.live.filter(key: id.rawValue).fetchOne(db) else { return nil }
            var note = try Note(record: record,db)
            let saved = try String.fetchOne(db,sql: "SELECT note_json FROM agent_note_snapshot WHERE note_id=?",arguments: [id.rawValue])
            if let saved {
                let delivered = try JSONDecoder().decode(Note.self,from: Data(saved.utf8))
                note.body = delivered.body; note.color = delivered.color; note.anchor = delivered.anchor
            } else if record.publishedAt != nil {
                note.body = record.author != nil ? "" : record.publishedBody ?? record.body
                note.color = record.publishedColor.flatMap(NoteColor.init(rawValue:)) ?? note.color
            }
            return note
        }
    }
}

private struct RetainedAgentAttachment: Codable {
    var hash: String
    var attachment: Attachment
}

extension NoteStore {
    static func saveAgentSnapshot(_ note: Note, attachments: [SentAttachment], root: URL, _ db: Database) throws {
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM collaboration_review WHERE document_id=? AND is_owner=1 AND is_copy=0)", arguments: [note.documentID.rawValue]) == true else { return }
        let retained = try attachments.map { sent in
            let hash = sent.data.sha256Hex
            let url = root.appendingPathComponent(hash + ".png")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) { try sent.data.write(to: url, options: .atomic) }
            var attachment = sent.attachment; attachment.localPath = url.path
            return RetainedAgentAttachment(hash: hash, attachment: attachment)
        }
        let encoder = JSONEncoder.sorted
        try db.execute(sql: "INSERT INTO agent_note_snapshot(note_id,note_json,attachments_json) VALUES (?,?,?) ON CONFLICT(note_id) DO UPDATE SET note_json=excluded.note_json,attachments_json=excluded.attachments_json",
                       arguments: [note.id.rawValue,String(decoding: try encoder.encode(note),as: UTF8.self),String(decoding: try encoder.encode(retained),as: UTF8.self)])
    }

    public func agentResourceAttachments(_ id: NoteID) async throws -> [SentAttachment] {
        try await queue.read { db in
            if let json = try String.fetchOne(db,sql: "SELECT attachments_json FROM agent_note_snapshot WHERE note_id=?",arguments: [id.rawValue]) {
                return try JSONDecoder().decode([RetainedAgentAttachment].self,from: Data(json.utf8)).compactMap { ref in
                    guard let data = FileManager.default.contents(atPath: ref.attachment.localPath), data.sha256Hex == ref.hash else { return nil }
                    return SentAttachment(attachment: ref.attachment,data: data)
                }
            }
            guard let note = try NoteRecord.fetchOne(db,key: id.rawValue), note.publishedAt == nil else { return [] }
            return try AttachmentRecord.filter(Column("note_id") == id.rawValue).order(Column("id")).fetchAll(db).compactMap { record in
                let attachment = Attachment(record: record)
                guard let data = FileManager.default.contents(atPath: attachment.localPath) else { return nil }
                return SentAttachment(attachment: attachment,data: data)
            }
        }
    }
}
