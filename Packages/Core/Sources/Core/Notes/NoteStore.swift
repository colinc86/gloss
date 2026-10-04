import Foundation
import GRDB

public enum NoteStoreError: Error, Equatable, Sendable {
    case noteNotFound(NoteID)
    case documentNotFound(DocumentID)
    case illegalTransition(from: NoteState, to: NoteState)
}

/// All reads and writes of hosts, roots, documents, notes, sends, attachments, staged files,
/// targets, and settings. Every write runs in one transaction.
public struct NoteStore: Sendable {
    public let database: AppDatabase
    private var queue: DatabaseQueue { database.queue }

    public init(database: AppDatabase) {
        self.database = database
    }

    // MARK: Hosts

    public func hosts() async throws -> [Host] {
        try await queue.read { db in
            try HostRecord.order(Column("name")).fetchAll(db).map(Host.init(record:))
        }
    }

    /// Returns the host named `name`, creating it when missing. A name already taken by a host of another kind
    /// (an ssh alias called `github` next to the GitHub host) gets `-ssh` appended, so the two never merge.
    /// The host row for an ssh config alias. An alias whose name another kind of host already has (`github`)
    /// gets the first free `<name>-<kind>` name and remembers its real alias, which is what ssh is given.
    public func upsertHost(name: String, kind: HostKind, origin: HostOrigin = .sshConfig) async throws -> Host {
        try await queue.write { db in
            if let existing = try HostRecord.filter(Column("name") == name).fetchOne(db), existing.kind == kind.rawValue { return Host(record: existing) }
            guard try HostRecord.filter(Column("name") == name).fetchOne(db) != nil else {
                let record = HostRecord(id: HostID.new().rawValue, name: name, kind: kind.rawValue, lastConnectedAt: nil, origin: origin.rawValue, optionsJson: nil)
                try record.insert(db)
                return Host(record: try Self.refetch(record, db))
            }
            // Taken by another kind: reuse the row already standing in for this alias, else make one.
            let aliased = try HostRecord.filter(Column("kind") == kind.rawValue).fetchAll(db).first { record in
                record.optionsJson.flatMap { try? JSONDecoder().decode(HostOptions.self, from: Data($0.utf8)) }?.alias == name
            }
            if let aliased { return Host(record: aliased) }
            let free = try Self.freeName(for: name, suffix: kind.rawValue, db)
            let json = String(decoding: try JSONEncoder().encode(HostOptions(alias: name)), as: UTF8.self)
            let record = HostRecord(id: HostID.new().rawValue, name: free, kind: kind.rawValue, lastConnectedAt: nil, origin: origin.rawValue, optionsJson: json)
            try record.insert(db)
            return Host(record: try Self.refetch(record, db))
        }
    }

    /// `name-suffix`, or `name-suffix-2`, `-3`, … when that is taken too.
    static func freeName(for name: String, suffix: String, _ db: Database) throws -> String {
        var candidate = "\(name)-\(suffix)"
        var counter = 2
        while try HostRecord.filter(Column("name") == candidate).fetchCount(db) > 0 {
            candidate = "\(name)-\(suffix)-\(counter)"
            counter += 1
        }
        return candidate
    }

    /// Adds or updates an app-managed host. The name must be unique; notes keep following the host id.
    public func saveHost(id: HostID?, name: String, options: HostOptions) async throws -> Host {
        try await queue.write { db in
            let json = String(decoding: try JSONEncoder().encode(options), as: UTF8.self)
            if let id, var record = try HostRecord.fetchOne(db, key: id.rawValue) {
                record.name = name
                record.origin = HostOrigin.manual.rawValue
                record.optionsJson = json
                try record.update(db)
                return Host(record: try Self.refetch(record, db))
            }
            let record = HostRecord(id: HostID.new().rawValue, name: name, kind: HostKind.ssh.rawValue, lastConnectedAt: nil, origin: HostOrigin.manual.rawValue, optionsJson: json)
            try record.insert(db)
            return Host(record: try Self.refetch(record, db))
        }
    }

    /// Removes a host and, through the foreign keys, its roots, documents, and notes.
    public func deleteHost(_ id: HostID) async throws {
        _ = try await queue.write { db in try HostRecord.deleteOne(db, key: id.rawValue) }
    }

    public func markHostConnected(_ id: HostID, at date: Date = Date()) async throws {
        let date = Self.rounded(date)
        return try await queue.write { db in
            try db.execute(sql: "UPDATE host SET last_connected_at = ? WHERE id = ?", arguments: [date, id.rawValue])
        }
    }

    // MARK: Roots

    public func roots(for hostID: HostID) async throws -> [Root] {
        try await queue.read { db in
            try RootRecord.filter(Column("host_id") == hostID.rawValue)
                .order(Column("pinned").desc, Column("last_opened_at").desc)
                .fetchAll(db).map(Root.init(record:))
        }
    }

    public func recordRootOpened(hostID: HostID, path: String, at date: Date = Date()) async throws -> Root {
        let date = Self.rounded(date)
        return try await queue.write { db in
            if var existing = try RootRecord.filter(Column("host_id") == hostID.rawValue && Column("path") == path).fetchOne(db) {
                existing.lastOpenedAt = date
                try existing.update(db)
                return Root(record: try Self.refetch(existing, db))
            }
            let record = RootRecord(id: RootID.new().rawValue, hostId: hostID.rawValue, path: path, lastOpenedAt: date, pinned: false)
            try record.insert(db)
            return Root(record: try Self.refetch(record, db))
        }
    }

    public func setRootPinned(_ id: RootID, _ pinned: Bool) async throws {
        try await queue.write { db in
            try db.execute(sql: "UPDATE root SET pinned = ? WHERE id = ?", arguments: [pinned, id.rawValue])
        }
    }

    public func deleteRoot(_ id: RootID) async throws {
        _ = try await queue.write { db in try RootRecord.deleteOne(db, key: id.rawValue) }
    }

    // MARK: Documents

    public func document(_ id: DocumentID) async throws -> Document? {
        try await queue.read { db in try DocumentRecord.fetchOne(db, key: id.rawValue).map(Document.init(record:)) }
    }

    public func document(hostID: HostID, path: String) async throws -> Document? {
        try await queue.read { db in
            try DocumentRecord.filter(Column("host_id") == hostID.rawValue && Column("path") == path)
                .fetchOne(db).map(Document.init(record:))
        }
    }

    /// Finds or creates the document row and refreshes its kind and fingerprint. `.file` is what the extension
    /// alone says; it never replaces a kind the viewer learned by reading the bytes.
    public func upsertDocument(hostID: HostID, path: String, kind: DocumentKind, fingerprint: Fingerprint) async throws -> Document {
        let fingerprint = Fingerprint(mtime: fingerprint.mtime.map(Self.rounded), size: fingerprint.size, hash: fingerprint.hash)
        return try await queue.write { db in
            if var existing = try DocumentRecord.filter(Column("host_id") == hostID.rawValue && Column("path") == path).fetchOne(db) {
                if kind != .file || existing.kind == DocumentKind.file.rawValue { existing.kind = kind.rawValue }
                existing.lastHash = fingerprint.hash
                existing.lastMtime = fingerprint.mtime
                existing.lastSize = fingerprint.size
                try existing.update(db)
                return Document(record: try Self.refetch(existing, db))
            }
            let record = DocumentRecord(
                id: DocumentID.new().rawValue, hostId: hostID.rawValue, path: path, kind: kind.rawValue,
                lastHash: fingerprint.hash, lastMtime: fingerprint.mtime, lastSize: fingerprint.size
            )
            try record.insert(db)
            return Document(record: try Self.refetch(record, db))
        }
    }

    public func updateFingerprint(_ id: DocumentID, _ fingerprint: Fingerprint) async throws {
        let fingerprint = Fingerprint(mtime: fingerprint.mtime.map(Self.rounded), size: fingerprint.size, hash: fingerprint.hash)
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE document SET last_hash = ?, last_mtime = ?, last_size = ? WHERE id = ?",
                arguments: [fingerprint.hash, fingerprint.mtime, fingerprint.size, id.rawValue]
            )
        }
    }

    /// Documents that have at least one note, with their notes in reading order.
    public func documentsWithNotes() async throws -> [(document: Document, notes: [Note])] {
        try await queue.read { db in
            let documents = try DocumentRecord
                .filter(sql: "EXISTS (SELECT 1 FROM note WHERE note.document_id = document.id)")
                .order(Column("host_id"), Column("path"))
                .fetchAll(db)
            return try documents.map { record in
                let notes = try NoteRecord.filter(Column("document_id") == record.id).fetchAll(db).map { try Note(record: $0) }
                return (Document(record: record), Self.sorted(notes))
            }
        }
    }

    // MARK: Notes

    public func note(_ id: NoteID) async throws -> Note? {
        try await queue.read { db in try NoteRecord.fetchOne(db, key: id.rawValue).map { try Note(record: $0) } }
    }

    public func notes(for documentID: DocumentID) async throws -> [Note] {
        try await queue.read { db in
            Self.sorted(try NoteRecord.filter(Column("document_id") == documentID.rawValue).fetchAll(db).map { try Note(record: $0) })
        }
    }

    /// Draft and sent notes, optionally limited to one host and a path prefix (a file or a directory).
    public func pendingNotes(hostID: HostID? = nil, pathPrefix: String? = nil) async throws -> [(note: Note, document: Document)] {
        try await queue.read { db in
            var request = NoteRecord
                .filter(["draft", "sent"].contains(Column("state")))
                .including(required: NoteRecord.document)
            if let hostID {
                request = request.filter(sql: "document.host_id = ?", arguments: [hostID.rawValue])
            }
            if let pathPrefix {
                // Exact file, or inside the directory. substr() keeps it case-sensitive and needs no escaping. It counts
                // characters (code points), not bytes, so the length must too or non-ASCII directories never match.
                let directory = pathPrefix.hasSuffix("/") ? pathPrefix : pathPrefix + "/"
                request = request.filter(sql: "document.path = ? OR substr(document.path, 1, ?) = ?", arguments: [pathPrefix, directory.unicodeScalars.count, directory])
            }
            let rows = try request.asRequest(of: NoteWithDocument.self).fetchAll(db)
            return try rows
                .map { (note: try Note(record: $0.note), document: Document(record: $0.document)) }
                .sorted { lhs, rhs in
                    if lhs.document.path != rhs.document.path { return lhs.document.path < rhs.document.path }
                    return lhs.note.anchor.sortKey < rhs.note.anchor.sortKey
                }
        }
    }

    public func createNote(documentID: DocumentID, anchor: Anchor, body: String, color: NoteColor, at date: Date = Date()) async throws -> Note {
        let date = Self.rounded(date)
        return try await queue.write { db in
            guard try DocumentRecord.exists(db, key: documentID.rawValue) else { throw NoteStoreError.documentNotFound(documentID) }
            let record = NoteRecord(
                id: NoteID.new().rawValue, documentId: documentID.rawValue,
                anchorJson: try anchor.encodedJSON(), anchorType: anchor.type.rawValue,
                body: body, state: NoteState.draft.rawValue, createdAt: date, updatedAt: date, color: color.rawValue,
                resolveOutcome: nil, resolveMessage: nil
            )
            try record.insert(db)
            return try Note(record: try Self.refetch(record, db))
        }
    }

    public func updateBody(_ id: NoteID, body: String, at date: Date = Date()) async throws {
        let date = Self.rounded(date)
        return try await queue.write { db in
            try db.execute(sql: "UPDATE note SET body = ?, updated_at = ? WHERE id = ?", arguments: [body, date, id.rawValue])
        }
    }

    public func updateColor(_ id: NoteID, color: NoteColor, at date: Date = Date()) async throws {
        let date = Self.rounded(date)
        return try await queue.write { db in
            try db.execute(sql: "UPDATE note SET color = ?, updated_at = ? WHERE id = ?", arguments: [color.rawValue, date, id.rawValue])
        }
    }

    /// Replaces the anchor after an edit or a re-anchoring pass, keeping the state unless one is given.
    public func updateAnchor(_ id: NoteID, anchor: Anchor, state: NoteState? = nil, at date: Date = Date()) async throws {
        let date = Self.rounded(date)
        return try await queue.write { db in
            guard var record = try NoteRecord.fetchOne(db, key: id.rawValue) else { throw NoteStoreError.noteNotFound(id) }
            record.anchorJson = try anchor.encodedJSON()
            record.anchorType = anchor.type.rawValue
            if let state {
                let current = NoteState(rawValue: record.state) ?? .draft
                try Self.checkTransition(from: current, to: state)
                record.state = state.rawValue
            }
            record.updatedAt = date
            try record.update(db)
        }
    }

    public func deleteNote(_ id: NoteID) async throws {
        _ = try await queue.write { db in try NoteRecord.deleteOne(db, key: id.rawValue) }
    }

    /// Deletes a note and returns everything the delete removed (the note, its attachment rows, its send links),
    /// so `restore` can put it back exactly. Attachment files stay on disk; the sweep keeps young files.
    public func deleteNoteForUndo(_ id: NoteID) async throws -> DeletedNote? {
        try await queue.write { db in
            guard let note = try NoteRecord.fetchOne(db, key: id.rawValue) else { return nil }
            let attachments = try AttachmentRecord.filter(Column("note_id") == id.rawValue).fetchAll(db)
            let sends = try SendNoteRecord.filter(Column("note_id") == id.rawValue).fetchAll(db)
            _ = try NoteRecord.deleteOne(db, key: id.rawValue)
            return DeletedNote(note: note, attachments: attachments, sends: sends)
        }
    }

    /// Puts a deleted note back with its id, attachments, and send history (sends that still exist).
    public func restore(_ deleted: DeletedNote) async throws {
        try await queue.write { db in
            guard try DocumentRecord.exists(db, key: deleted.note.documentId) else {
                throw NoteStoreError.documentNotFound(DocumentID(rawValue: deleted.note.documentId))
            }
            try deleted.note.insert(db)
            for attachment in deleted.attachments { try attachment.insert(db) }
            for link in deleted.sends where try SendRecord.exists(db, key: link.sendId) { try link.insert(db) }
        }
    }

    /// `sent` → `resolved`, or `draft` → `resolved` when the user resolves by hand.
    public func resolve(_ id: NoteID, outcome: ResolveOutcome = .done, message: String? = nil, at date: Date = Date()) async throws {
        let date = Self.rounded(date)
        try await queue.write { db in
            guard var record = try NoteRecord.fetchOne(db, key: id.rawValue) else { throw NoteStoreError.noteNotFound(id) }
            let current = NoteState(rawValue: record.state) ?? .draft
            try Self.checkTransition(from: current, to: .resolved)
            record.state = NoteState.resolved.rawValue
            record.resolveOutcome = outcome.rawValue
            record.resolveMessage = message
            record.updatedAt = date
            try record.update(db)
        }
    }

    public func markOrphaned(_ id: NoteID, at date: Date = Date()) async throws {
        try await transition(id, to: .orphaned, at: date)
    }

    /// `orphaned` → `draft` once the user has placed the anchor again.
    /// The user takes a resolved note back: it becomes a draft again and the agent's outcome is cleared. The only
    /// way out of `resolved`; `restoreDraft` stays limited to orphans.
    public func reopen(_ id: NoteID, at date: Date = Date()) async throws {
        let date = Self.rounded(date)
        try await queue.write { db in
            guard var record = try NoteRecord.fetchOne(db, key: id.rawValue) else { throw NoteStoreError.noteNotFound(id) }
            let current = NoteState(rawValue: record.state) ?? .draft
            guard current == .resolved else { throw NoteStoreError.illegalTransition(from: current, to: .draft) }
            record.state = NoteState.draft.rawValue
            record.resolveOutcome = nil
            record.resolveMessage = nil
            record.updatedAt = date
            try record.update(db)
        }
    }

    /// The labels an answered question is written with, so the app can show the exchange as a conversation.
    public static let askedLabel = "Agent asked:"
    public static let answerLabel = "Answer:"

    /// The comment with the agent's question and the person's answer added after a blank line.
    public static func body(_ body: String, answering question: String?, with answer: String) -> String {
        let question = question?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return body + "\n\n" + (question.isEmpty ? "" : "\(askedLabel) \(question)\n") + "\(answerLabel) \(answer)"
    }

    /// The person answers a question an agent resolved the note with: in one write, the question and answer are added
    /// to the comment as it is now (not as some view last saw it), and the note becomes a draft again. Throws
    /// `illegalTransition` if the note is no longer waiting for an answer, so nothing is half applied.
    public func answer(_ id: NoteID, with answer: String, at date: Date = Date()) async throws {
        let date = Self.rounded(date)
        try await queue.write { db in
            guard var record = try NoteRecord.fetchOne(db, key: id.rawValue) else { throw NoteStoreError.noteNotFound(id) }
            let current = NoteState(rawValue: record.state) ?? .draft
            guard current == .resolved, record.resolveOutcome == ResolveOutcome.needsInput.rawValue else {
                throw NoteStoreError.illegalTransition(from: current, to: .draft)
            }
            record.body = Self.body(record.body, answering: record.resolveMessage, with: answer)
            record.state = NoteState.draft.rawValue
            record.resolveOutcome = nil
            record.resolveMessage = nil
            record.updatedAt = date
            try record.update(db)
        }
    }

    public func restoreDraft(_ id: NoteID, anchor: Anchor, at date: Date = Date()) async throws {
        try await updateAnchor(id, anchor: anchor, state: .draft, at: date)
    }

    private func transition(_ id: NoteID, to state: NoteState, at date: Date) async throws {
        let date = Self.rounded(date)
        return try await queue.write { db in
            guard var record = try NoteRecord.fetchOne(db, key: id.rawValue) else { throw NoteStoreError.noteNotFound(id) }
            let current = NoteState(rawValue: record.state) ?? .draft
            try Self.checkTransition(from: current, to: state)
            record.state = state.rawValue
            record.updatedAt = date
            try record.update(db)
        }
    }

    /// The lifecycle: draft → sent → resolved; any → orphaned; orphaned → draft; draft → resolved by hand.
    static func checkTransition(from: NoteState, to: NoteState) throws {
        let allowed: Bool
        switch (from, to) {
        case (.draft, .sent), (.sent, .resolved), (.draft, .resolved), (.orphaned, .draft):
            allowed = true
        case (_, .orphaned):
            allowed = from != .orphaned
        case (.sent, .sent):
            allowed = true   // re-sending a sent note is fine
        default:
            allowed = false
        }
        guard allowed else { throw NoteStoreError.illegalTransition(from: from, to: to) }
    }

    /// Observes the notes of one document, emitting the full sorted list on every change.
    public func observeNotes(for documentID: DocumentID) -> AsyncThrowingStream<[Note], any Error> {
        Self.stream(ValueObservation.tracking { db in
            Self.sorted(try NoteRecord.filter(Column("document_id") == documentID.rawValue).fetchAll(db).map { try Note(record: $0) })
        }, in: queue)
    }

    /// Observes every document that has notes, for the notes panel.
    public func observeDocumentsWithNotes() -> AsyncThrowingStream<[DocumentNotes], any Error> {
        Self.stream(ValueObservation.tracking { db in
            let documents = try DocumentRecord
                .filter(sql: "EXISTS (SELECT 1 FROM note WHERE note.document_id = document.id)")
                .order(Column("host_id"), Column("path"))
                .fetchAll(db)
            return try documents.map { record in
                let notes = try NoteRecord.filter(Column("document_id") == record.id).fetchAll(db).map { try Note(record: $0) }
                return DocumentNotes(document: Document(record: record), notes: Self.sorted(notes))
            }
        }, in: queue)
    }

    /// Bridges a GRDB observation to a plain stream so callers need no GRDB import.
    private static func stream<T: Sendable>(_ observation: ValueObservation<ValueReducers.Fetch<T>>, in queue: DatabaseQueue) -> AsyncThrowingStream<T, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await value in observation.values(in: queue) {
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Attachments

    public func addAttachment(noteID: NoteID, kind: AttachmentKind, localPath: String, width: Int, height: Int, at date: Date = Date()) async throws -> Attachment {
        try await queue.write { db in
            let record = AttachmentRecord(
                id: AttachmentID.new().rawValue, noteId: noteID.rawValue, kind: kind.rawValue,
                localPath: localPath, width: width, height: height
            )
            try record.insert(db)
            // Touch the note so observers (the notes panel's thumbnails) see the attachment arrive.
            try db.execute(sql: "UPDATE note SET updated_at = ? WHERE id = ?", arguments: [Self.rounded(date), noteID.rawValue])
            return Attachment(record: try Self.refetch(record, db))
        }
    }

    /// Every file path an attachment row points at, for sweeping files whose note is gone.
    public func allAttachmentPaths() async throws -> Set<String> {
        try await queue.read { db in Set(try String.fetchAll(db, sql: "SELECT local_path FROM attachment")) }
    }

    public func attachments(for noteID: NoteID) async throws -> [Attachment] {
        try await queue.read { db in
            try AttachmentRecord.filter(Column("note_id") == noteID.rawValue).order(Column("id")).fetchAll(db).map(Attachment.init(record:))
        }
    }

    // MARK: Sends

    /// Records one delivery and, when it succeeded, flips every draft note in it to `sent`.
    /// `outcome` is `delivered` or `failed: <message>`.
    public func recordSend(
        transport: String, targetJSON: String, packetText: String, noteIDs: [NoteID],
        outcome: SendOutcome, at date: Date = Date()
    ) async throws -> SendID {
        try await queue.write { db in
            let sendID = SendID.new()
            try SendRecord(
                id: sendID.rawValue, targetJson: targetJSON, transport: transport,
                packetText: packetText, sentAt: date, outcome: outcome.stored
            ).insert(db)
            for noteID in noteIDs {
                try SendNoteRecord(sendId: sendID.rawValue, noteId: noteID.rawValue).insert(db)
                if outcome == .delivered {
                    guard var record = try NoteRecord.fetchOne(db, key: noteID.rawValue) else { throw NoteStoreError.noteNotFound(noteID) }
                    let current = NoteState(rawValue: record.state) ?? .draft
                    if current == .draft || current == .sent {
                        record.state = NoteState.sent.rawValue
                        record.updatedAt = date
                        try record.update(db)
                    }
                }
            }
            return sendID
        }
    }

    public func sends(for noteID: NoteID) async throws -> [SendSummary] {
        try await queue.read { db in
            try SendRecord
                .filter(sql: "id IN (SELECT send_id FROM send_note WHERE note_id = ?)", arguments: [noteID.rawValue])
                .order(Column("sent_at").desc)
                .fetchAll(db)
                .map { SendSummary(id: SendID(rawValue: $0.id), transport: $0.transport, targetJSON: $0.targetJson, sentAt: $0.sentAt, outcome: $0.outcome) }
        }
    }

    /// The newest send of a note, without reading packet texts.
    public func lastSend(for noteID: NoteID) async throws -> SendSummary? {
        try await queue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT send.id, send.transport, send.target_json, send.sent_at, send.outcome
                FROM send JOIN send_note ON send_note.send_id = send.id
                WHERE send_note.note_id = ? ORDER BY send.sent_at DESC LIMIT 1
                """, arguments: [noteID.rawValue]).map {
                SendSummary(id: SendID(rawValue: $0["id"]), transport: $0["transport"], targetJSON: $0["target_json"], sentAt: $0["sent_at"], outcome: $0["outcome"])
            }
        }
    }

    // MARK: Staged files

    public func recordStagedFiles(sendID: SendID, hostID: HostID, remotePaths: [String], expiresAt: Date) async throws {
        let expiresAt = Self.rounded(expiresAt)
        try await queue.write { db in
            for path in remotePaths {
                try StagedFileRecord(id: StagedFileID.new().rawValue, sendId: sendID.rawValue, hostId: hostID.rawValue, remotePath: path, expiresAt: expiresAt).insert(db)
            }
        }
    }

    public func expiredStagedFiles(now: Date = Date()) async throws -> [StagedFile] {
        try await queue.read { db in
            try StagedFileRecord.filter(Column("expires_at") <= now).fetchAll(db).map(StagedFile.init(record:))
        }
    }

    public func deleteStagedFiles(_ ids: [StagedFileID]) async throws {
        _ = try await queue.write { db in try StagedFileRecord.deleteAll(db, keys: ids.map(\.rawValue)) }
    }

    // MARK: Targets

    public func upsertTarget(hostID: HostID, transport: String, identityJSON: String, label: String, usedAt: Date? = nil) async throws -> KnownTarget {
        try await queue.write { db in
            if var existing = try TargetRecord
                .filter(Column("host_id") == hostID.rawValue && Column("transport") == transport && Column("identity_json") == identityJSON)
                .fetchOne(db) {
                existing.label = label
                if let usedAt { existing.lastUsedAt = Self.rounded(usedAt) }
                try existing.update(db)
                return KnownTarget(record: try Self.refetch(existing, db))
            }
            let record = TargetRecord(id: TargetID.new().rawValue, hostId: hostID.rawValue, transport: transport, identityJson: identityJSON, label: label, lastUsedAt: usedAt.map(Self.rounded))
            try record.insert(db)
            return KnownTarget(record: try Self.refetch(record, db))
        }
    }

    public func targets(hostID: HostID? = nil, transport: String? = nil) async throws -> [KnownTarget] {
        try await queue.read { db in
            var request = TargetRecord.all()
            if let hostID { request = request.filter(Column("host_id") == hostID.rawValue) }
            if let transport { request = request.filter(Column("transport") == transport) }
            return try request.order(Column("last_used_at").desc).fetchAll(db).map(KnownTarget.init(record:))
        }
    }

    // MARK: Settings

    public func setting(_ key: String) async throws -> String? {
        try await queue.read { db in try SettingRecord.fetchOne(db, key: key)?.value }
    }

    public func setSetting(_ key: String, _ value: String?) async throws {
        try await queue.write { db in
            if let value {
                try SettingRecord(key: key, value: value).save(db)
            } else {
                _ = try SettingRecord.deleteOne(db, key: key)
            }
        }
    }

    // MARK: Helpers

    /// SQLite rows keep milliseconds; rounding on the way in makes written and read values equal.
    static func rounded(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    static func sorted(_ notes: [Note]) -> [Note] {
        notes.sorted { lhs, rhs in
            if lhs.anchor.sortKey != rhs.anchor.sortKey { return lhs.anchor.sortKey < rhs.anchor.sortKey }
            return lhs.id.rawValue < rhs.id.rawValue
        }
    }

    /// Reads a row back after a write so returned values carry exactly what SQLite stored.
    static func refetch<R: FetchableRecord & PersistableRecord & Identifiable>(_ record: R, _ db: Database) throws -> R where R.ID == String {
        guard let fresh = try R.fetchOne(db, key: record.id) else { throw DatabaseError(message: "row vanished after write") }
        return fresh
    }
}

public struct DocumentNotes: Hashable, Sendable, Identifiable {
    public var document: Document
    public var notes: [Note]
    public var id: DocumentID { document.id }

    public init(document: Document, notes: [Note]) {
        self.document = document
        self.notes = notes
    }
}

public enum SendOutcome: Equatable, Sendable {
    case delivered
    case failed(String)

    var stored: String {
        switch self {
        case .delivered: "delivered"
        case .failed(let message): "failed: \(message)"
        }
    }
}

private struct NoteWithDocument: Decodable, FetchableRecord {
    var note: NoteRecord
    var document: DocumentRecord
}

// MARK: Record ↔ domain conversions

extension Host {
    init(record: HostRecord) {
        let options = record.optionsJson.flatMap { try? JSONDecoder().decode(HostOptions.self, from: Data($0.utf8)) }
        self.init(id: HostID(rawValue: record.id), name: record.name, kind: HostKind(rawValue: record.kind) ?? .ssh, lastConnectedAt: record.lastConnectedAt, origin: HostOrigin(rawValue: record.origin) ?? .sshConfig, options: options)
    }
}

extension Root {
    init(record: RootRecord) {
        self.init(id: RootID(rawValue: record.id), hostID: HostID(rawValue: record.hostId), path: record.path, lastOpenedAt: record.lastOpenedAt, pinned: record.pinned)
    }
}

extension Document {
    init(record: DocumentRecord) {
        self.init(
            id: DocumentID(rawValue: record.id), hostID: HostID(rawValue: record.hostId), path: record.path,
            kind: DocumentKind(rawValue: record.kind) ?? .file,
            fingerprint: Fingerprint(mtime: record.lastMtime, size: record.lastSize, hash: record.lastHash)
        )
    }
}

extension Note {
    init(record: NoteRecord) throws {
        let type = AnchorType(rawValue: record.anchorType) ?? .file
        self.init(
            id: NoteID(rawValue: record.id), documentID: DocumentID(rawValue: record.documentId),
            anchor: try Anchor(type: type, json: record.anchorJson), body: record.body,
            state: NoteState(rawValue: record.state) ?? .draft, color: NoteColor(rawValue: record.color) ?? .yellow,
            createdAt: record.createdAt, updatedAt: record.updatedAt,
            resolveOutcome: record.resolveOutcome.flatMap(ResolveOutcome.init(rawValue:)), resolveMessage: record.resolveMessage
        )
    }
}

extension Attachment {
    init(record: AttachmentRecord) {
        self.init(id: AttachmentID(rawValue: record.id), noteID: NoteID(rawValue: record.noteId), kind: AttachmentKind(rawValue: record.kind) ?? .crop, localPath: record.localPath, width: record.width, height: record.height)
    }
}

extension StagedFile {
    init(record: StagedFileRecord) {
        self.init(id: StagedFileID(rawValue: record.id), sendID: SendID(rawValue: record.sendId), hostID: HostID(rawValue: record.hostId), remotePath: record.remotePath, expiresAt: record.expiresAt)
    }
}

extension KnownTarget {
    init(record: TargetRecord) {
        self.init(id: TargetID(rawValue: record.id), hostID: HostID(rawValue: record.hostId), transport: record.transport, identityJSON: record.identityJson, label: record.label, lastUsedAt: record.lastUsedAt)
    }
}

/// What deleting a note removed, kept so the delete can be undone.
public struct DeletedNote: Sendable, Equatable {
    public let note: NoteRecord
    public let attachments: [AttachmentRecord]
    public let sends: [SendNoteRecord]
    public var id: NoteID { NoteID(rawValue: note.id) }

    public static func == (lhs: DeletedNote, rhs: DeletedNote) -> Bool { lhs.note.id == rhs.note.id }
}
