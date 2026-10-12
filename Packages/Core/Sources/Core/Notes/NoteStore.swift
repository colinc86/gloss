import Foundation
import GRDB

public enum NoteStoreError: Error, Equatable, Sendable {
    case noteNotFound(NoteID)
    case documentNotFound(DocumentID)
    case illegalTransition(from: NoteState, to: NoteState)
    /// A document already holds this many open questions from agents.
    case tooManyQuestions(Int)
    case messageNotFound(MessageID)
    /// Only a follow-up the user hasn't sent can be changed or deleted.
    case messageAlreadySent(MessageID)
    /// The note is resolved: an agent can't add to it until the user reopens it with a follow-up.
    case noteClosed
    /// The user wrote a follow-up that hasn't been sent: the agent hasn't seen what they said since.
    case unsentFollowUp
    /// The note never moved, so it has no original place to go back to.
    case noOriginalPlace(NoteID)
    /// The user deleted the note: it is in Recently Deleted, where an agent can't reach it.
    case noteDeleted(NoteID)
}

extension NoteStoreError: LocalizedError {
    /// Plain words, since an agent reads these through MCP.
    public var errorDescription: String? {
        switch self {
        case .noteNotFound(let id): "No note with id \(id.rawValue)."
        case .documentNotFound(let id): "No document with id \(id.rawValue)."
        case .illegalTransition(from: .draft, to: _): "The note is a draft: the user hasn't sent it."
        case .illegalTransition(from: .resolved, to: .resolved): "The note is already resolved."
        case .illegalTransition(let from, let to): "A \(from.rawValue) note can't become \(to.rawValue)."
        case .tooManyQuestions(let limit): "This file already has \(limit) open questions; wait for the user to answer some."
        case .messageNotFound(let id): "No message with id \(id.rawValue)."
        case .messageAlreadySent: "That follow-up was already sent."
        case .noteClosed: "The note is resolved; the user reopens it with a follow-up."
        case .unsentFollowUp: "The user has written a follow-up they haven't sent yet; wait for it before resolving."
        case .noOriginalPlace: "The note hasn't moved."
        case .noteDeleted(let id): "Note \(id.rawValue) was deleted by the user."
        }
    }
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
            let named = try HostRecord.filter(Column("name") == name).fetchOne(db)
            // A row by this name is this alias's, unless it stands in for another alias (`github-ssh` for `github`).
            if let named, named.kind == kind.rawValue, Self.alias(of: named) == nil || Self.alias(of: named) == name { return Host(record: named) }
            guard named != nil else {
                let record = HostRecord(id: HostID.new().rawValue, name: name, kind: kind.rawValue, lastConnectedAt: nil, origin: origin.rawValue, optionsJson: nil)
                try record.insert(db)
                return Host(record: try Self.refetch(record, db))
            }
            // Taken by another kind: reuse the row already standing in for this alias, else make one.
            let aliased = try HostRecord.filter(Column("kind") == kind.rawValue).fetchAll(db).first { Self.alias(of: $0) == name }
            if let aliased { return Host(record: aliased) }
            // Taken by another kind (`github`, the integration host): `github-ssh`. Taken by a row standing in for
            // another alias: `github-ssh-2`.
            let free = try named?.kind == kind.rawValue ? Self.freeNumbered(name, db) : Self.freeName(for: name, suffix: kind.rawValue, db)
            let json = String(decoding: try JSONEncoder().encode(HostOptions(alias: name)), as: UTF8.self)
            let record = HostRecord(id: HostID.new().rawValue, name: free, kind: kind.rawValue, lastConnectedAt: nil, origin: origin.rawValue, optionsJson: json)
            try record.insert(db)
            return Host(record: try Self.refetch(record, db))
        }
    }

    static func alias(of record: HostRecord) -> String? {
        record.optionsJson.flatMap { try? JSONDecoder().decode(HostOptions.self, from: Data($0.utf8)) }?.alias
    }

    /// Forgets a row's alias: its name is what ssh knows it by after all (a config alias really called
    /// `github-ssh` that an earlier migration took for a renamed `github`).
    public func clearHostAlias(_ id: HostID) async throws {
        try await queue.write { db in
            guard var record = try HostRecord.fetchOne(db, key: id.rawValue),
                  var options = record.optionsJson.flatMap({ try? JSONDecoder().decode(HostOptions.self, from: Data($0.utf8)) }) else { return }
            options.alias = nil
            record.optionsJson = options.isEmpty ? nil : String(decoding: try JSONEncoder().encode(options), as: UTF8.self)
            try record.update(db)
        }
    }

    /// `name-2`, `name-3`, … whichever is free first.
    static func freeNumbered(_ name: String, _ db: Database) throws -> String {
        var counter = 2
        while try HostRecord.filter(Column("name") == "\(name)-\(counter)").fetchCount(db) > 0 { counter += 1 }
        return "\(name)-\(counter)"
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
                // The editor knows nothing of an alias the row keeps for ssh; it stays.
                var merged = options
                if merged.alias == nil { merged.alias = Self.alias(of: record) }
                record.optionsJson = String(decoding: try JSONEncoder().encode(merged), as: UTF8.self)
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

    /// Every pinned root on every host, the most recently opened first: the switcher's Favorites.
    public func pinnedRoots() async throws -> [Root] {
        try await queue.read { db in
            try RootRecord.filter(Column("pinned") == true)
                .order(Column("last_opened_at").desc)
                .fetchAll(db).map(Root.init(record:))
        }
    }

    /// Unpinned folders kept beyond this many are forgotten, oldest first, as recent web pages are: every folder an
    /// agent or a typed path opened otherwise stayed forever, though only a handful are ever offered.
    public static let maximumRecentRoots = 200

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
            try db.execute(sql: """
                DELETE FROM root WHERE pinned = 0 AND rowid NOT IN
                    (SELECT rowid FROM root WHERE pinned = 0 ORDER BY last_opened_at DESC LIMIT ?)
                """, arguments: [Self.maximumRecentRoots])
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

    // MARK: Web pages

    /// Unpinned pages kept beyond this many are forgotten, oldest first.
    public static let maximumRecentWebPages = 200

    /// Pinned first, then the most recently visited.
    public func webPages() async throws -> [WebPage] {
        try await queue.read { db in
            try WebPageRecord.order(Column("pinned").desc, Column("last_visited_at").desc).fetchAll(db).map(WebPage.init(record:))
        }
    }

    /// A visit to `url` on `hostID`: moves it to the top of the recent pages, keeping its title and pin unless a
    /// title is given, and forgets the oldest unpinned pages past `maximumRecentWebPages`.
    @discardableResult
    public func recordWebPageVisit(url: String, hostID: HostID, title: String? = nil, at date: Date = Date()) async throws -> WebPage {
        let date = Self.rounded(date)
        return try await queue.write { db in
            var record = try WebPageRecord.filter(Column("url") == url && Column("host_id") == hostID.rawValue).fetchOne(db)
                ?? WebPageRecord(url: url, hostId: hostID.rawValue, title: nil, lastVisitedAt: date, pinned: false)
            record.lastVisitedAt = date
            if let title, !title.isEmpty { record.title = title }
            try record.save(db)
            try db.execute(sql: """
                DELETE FROM web_page WHERE pinned = 0 AND rowid NOT IN
                    (SELECT rowid FROM web_page WHERE pinned = 0 ORDER BY last_visited_at DESC LIMIT ?)
                """, arguments: [Self.maximumRecentWebPages])
            return WebPage(record: record)
        }
    }

    /// The page's title once it is known; a page never visited is not added.
    public func setWebPageTitle(url: String, hostID: HostID, title: String) async throws {
        guard !title.isEmpty else { return }
        try await queue.write { db in
            try db.execute(sql: "UPDATE web_page SET title = ? WHERE url = ? AND host_id = ?", arguments: [title, url, hostID.rawValue])
        }
    }

    public func setWebPagePinned(url: String, hostID: HostID, _ pinned: Bool) async throws {
        try await queue.write { db in
            try db.execute(sql: "UPDATE web_page SET pinned = ? WHERE url = ? AND host_id = ?", arguments: [pinned, url, hostID.rawValue])
        }
    }

    public func removeWebPage(url: String, hostID: HostID) async throws {
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM web_page WHERE url = ? AND host_id = ?", arguments: [url, hostID.rawValue])
        }
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

    /// Moves a document's notes to another path on the same host (the thing it names was renamed or moved): the
    /// row takes the new path, or, when the new path already has a row, its notes join that row and the old one
    /// goes. One transaction.
    public func relocateDocument(hostID: HostID, from oldPath: String, to newPath: String) async throws {
        guard oldPath != newPath else { return }
        try await queue.write { db in
            guard var old = try DocumentRecord.filter(Column("host_id") == hostID.rawValue && Column("path") == oldPath).fetchOne(db) else { return }
            if let target = try DocumentRecord.filter(Column("host_id") == hostID.rawValue && Column("path") == newPath).fetchOne(db) {
                try Self.moveNotes(from: old.id, to: target, db)
                _ = try old.delete(db)
            } else {
                old.path = newPath
                try old.update(db)
            }
        }
    }

    /// Sets a host row's options as they are (the integration hosts keep their site here).
    public func setHostOptions(_ id: HostID, _ options: HostOptions?) async throws {
        try await queue.write { db in
            guard var record = try HostRecord.fetchOne(db, key: id.rawValue) else { return }
            record.optionsJson = try options.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
            try record.update(db)
        }
    }

    /// Moves every document of a host under `prefix` (one transaction) and forgets the host's recent roots: an
    /// integration host's account changed, and its documents' paths now mean something else. Their notes stay,
    /// readable, under the prefix. Documents already under a `/previous-sites/` prefix stay where they are.
    public func archiveDocuments(hostID: HostID, under prefix: String) async throws {
        try await queue.write { db in
            for var record in try DocumentRecord.filter(Column("host_id") == hostID.rawValue).fetchAll(db) where !record.path.hasPrefix("/previous-sites/") {
                let archived = prefix + record.path
                if let existing = try DocumentRecord.filter(Column("host_id") == hostID.rawValue && Column("path") == archived).fetchOne(db) {
                    // Archived before (A → B → A → B): the notes join that row, so none stays on the live path.
                    try Self.moveNotes(from: record.id, to: existing, db)
                    _ = try record.delete(db)
                } else {
                    record.path = archived
                    try record.update(db)
                }
            }
            try db.execute(sql: "DELETE FROM root WHERE host_id = ?", arguments: [hostID.rawValue])
        }
    }

    /// Documents that have at least one note, with their notes in reading order.
    public func documentsWithNotes() async throws -> [(document: Document, notes: [Note])] {
        try await queue.read { db in
            let documents = try DocumentRecord
                .filter(sql: "EXISTS (SELECT 1 FROM note WHERE note.document_id = document.id AND note.deleted_at IS NULL)")
                .order(Column("host_id"), Column("path"))
                .fetchAll(db)
            let unsent = try Self.unsentNoteIDs(db)
            return try documents.map { record in
                let notes = try NoteRecord.live.filter(Column("document_id") == record.id).fetchAll(db).map { try Note(record: $0, unsent: unsent) }
                return (Document(record: record), Self.sorted(notes))
            }
        }
    }

    // MARK: Notes

    public func note(_ id: NoteID) async throws -> Note? {
        try await queue.read { db in try NoteRecord.live.filter(key: id.rawValue).fetchOne(db).map { try Note(record: $0, db) } }
    }

    /// A document's notes in one iteration (issue #18): the current one when `iteration` is nil.
    public func notes(for documentID: DocumentID, iteration: Int? = nil) async throws -> [Note] {
        try await queue.read { db in try Self.notes(documentID, iteration: iteration, db) }
    }

    static func notes(_ documentID: DocumentID, iteration: Int?, _ db: Database) throws -> [Note] {
        let unsent = try Self.unsentNoteIDs(db)
        var request = NoteRecord.live.filter(Column("document_id") == documentID.rawValue)
        if let iteration {
            request = request.filter(Column("iteration") == iteration)
        } else {
            request = request.filter(sql: "iteration = (SELECT current_iteration FROM document WHERE id = ?)", arguments: [documentID.rawValue])
        }
        return Self.sorted(try request.fetchAll(db).map { try Note(record: $0, unsent: unsent) })
    }

    /// A document's notes in every iteration: the newest iteration first, each in the panel's order.
    static func notesInEveryIteration(_ documentID: DocumentID, _ db: Database) throws -> [Note] {
        let unsent = try Self.unsentNoteIDs(db)
        let notes = try NoteRecord.live.filter(Column("document_id") == documentID.rawValue).fetchAll(db)
            .map { try Note(record: $0, unsent: unsent) }
        return Dictionary(grouping: notes, by: \.iteration).sorted { $0.key > $1.key }.flatMap { Self.sorted($0.value) }
    }

    /// Open notes (draft and sent by default), optionally limited to one host and a path prefix (a file or a
    /// directory). What agents see through MCP passes `[.sent]`: a draft stays the user's until they press Send.
    public func pendingNotes(hostID: HostID? = nil, pathPrefix: String? = nil, states: Set<NoteState> = [.draft, .sent], currentIterationOnly: Bool = false) async throws -> [(note: Note, document: Document)] {
        let stateValues = states.map(\.rawValue)
        return try await queue.read { db in
            var request = NoteRecord.live
                .filter(stateValues.contains(Column("state")))
                .including(required: NoteRecord.document)
            if currentIterationOnly { request = request.filter(sql: "note.iteration = document.current_iteration") }
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
            let unsent = try Self.unsentNoteIDs(db)
            return try rows
                .map { (note: try Note(record: $0.note, unsent: unsent), document: Document(record: $0.document)) }
                .sorted { lhs, rhs in
                    if lhs.document.path != rhs.document.path { return lhs.document.path < rhs.document.path }
                    return lhs.note.anchor.sortKey < rhs.note.anchor.sortKey
                }
        }
    }

    public func createNote(documentID: DocumentID, anchor: Anchor, body: String, color: NoteColor, at date: Date = Date()) async throws -> Note {
        let date = Self.rounded(date)
        return try await queue.write { db in
            let iteration = try Self.openIteration(documentID, at: date, db)
            let record = NoteRecord(
                id: NoteID.new().rawValue, documentId: documentID.rawValue,
                anchorJson: try anchor.encodedJSON(), anchorType: anchor.type.rawValue,
                body: Self.cleanBody(body), state: NoteState.draft.rawValue, createdAt: date, updatedAt: date, color: color.rawValue,
                resolveOutcome: nil, resolveMessage: nil, iteration: iteration
            )
            try record.insert(db)
            return try Note(record: try Self.refetch(record, db), db)
        }
    }

    /// Notes an agent may see: ones delivered to an agent at least once, and agents' own questions. A draft, an
    /// orphaned draft or a note resolved by hand without being sent stays the user's.
    public func sharedNoteIDs() async throws -> Set<NoteID> {
        try await queue.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT note.id FROM note WHERE note.deleted_at IS NULL AND (note.author IS NOT NULL OR EXISTS (
                    SELECT 1 FROM send_note JOIN send ON send.id = send_note.send_id
                    WHERE send_note.note_id = note.id AND send.outcome = 'delivered'))
                """).map(NoteID.init(rawValue:)))
        }
    }

    /// Orphans that were sent when their text went missing: still the agent's to resolve, since deleting the text
    /// is often what the note asked for.
    public func sentOrphanIDs() async throws -> Set<NoteID> {
        try await queue.read { db in
            Set(try String.fetchAll(db, sql: "SELECT id FROM note WHERE state = 'orphaned' AND previous_state = 'sent' AND deleted_at IS NULL")
                .map(NoteID.init(rawValue:)))
        }
    }

    /// Open questions one document may hold from agents, so a looping agent can't bury the user's own notes.
    public static let agentQuestionLimit = 20

    /// A question an agent asks the user about a place in a file (`ask_user`): a sent note by the agent, with no
    /// comment, whose thread opens with the question. It waits on the user, so it shows under Attention and counts on
    /// the Dock; the user's answer is a follow-up that goes back only when they send it.
    public func askUser(documentID: DocumentID, anchor: Anchor, question: String, author: String, color: NoteColor = .orange, at date: Date = Date()) async throws -> Note {
        let date = Self.rounded(date)
        return try await queue.write { db in
            let iteration = try Self.openIteration(documentID, at: date, db)
            let open = try NoteRecord
                .filter(Column("document_id") == documentID.rawValue && Column("author") != nil && Column("waiting_on_user") == true && Column("deleted_at") == nil)
                .fetchCount(db)
            guard open < Self.agentQuestionLimit else { throw NoteStoreError.tooManyQuestions(Self.agentQuestionLimit) }
            let record = NoteRecord(
                id: NoteID.new().rawValue, documentId: documentID.rawValue,
                anchorJson: try anchor.encodedJSON(), anchorType: anchor.type.rawValue,
                body: "", state: NoteState.sent.rawValue, createdAt: date, updatedAt: date, color: color.rawValue,
                resolveOutcome: nil, resolveMessage: nil, author: author, waitingOnUser: true, iteration: iteration
            )
            try record.insert(db)
            try Self.insertMessage(note: record.id, author: .agent(author), kind: .question, body: question, at: date, sent: true, db)
            return try Note(record: try Self.refetch(record, db), db)
        }
    }

    public func updateBody(_ id: NoteID, body: String, at date: Date = Date()) async throws {
        let date = Self.rounded(date)
        return try await queue.write { db in
            try db.execute(sql: "UPDATE note SET body = ?, updated_at = ? WHERE id = ?", arguments: [Self.cleanBody(body), date, id.rawValue])
        }
    }

    /// A comment as kept and sent: without the blank lines and spaces typed around it, which the packet would carry
    /// as escaped `\n`s. Editing a note in its card trimmed already; the composer didn't.
    static func cleanBody(_ body: String) -> String {
        body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Saves an edit only if the comment is still `expected`, in one write, so an answer added meanwhile is never
    /// overwritten. False when the note is gone or its comment changed.
    public func updateBody(_ id: NoteID, body: String, color: NoteColor, ifBodyIs expected: String, at date: Date = Date()) async throws -> Bool {
        let date = Self.rounded(date)
        return try await queue.write { db in
            try db.execute(sql: "UPDATE note SET body = ?, color = ?, updated_at = ? WHERE id = ? AND body = ?",
                           arguments: [Self.cleanBody(body), color.rawValue, date, id.rawValue, expected])
            return db.changesCount > 0
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

    /// Deletes a note and returns everything the delete removed (the note, its attachment rows, its send links, its thread),
    /// so `restore` can put it back exactly. Attachment files stay on disk; the sweep keeps young files.
    public func deleteNoteForUndo(_ id: NoteID) async throws -> DeletedNote? {
        try await queue.write { db in
            guard let note = try NoteRecord.fetchOne(db, key: id.rawValue) else { return nil }
            let attachments = try AttachmentRecord.filter(Column("note_id") == id.rawValue).fetchAll(db)
            let sends = try SendNoteRecord.filter(Column("note_id") == id.rawValue).fetchAll(db)
            let messages = try Self.messageRecords(id, db)
            _ = try NoteRecord.deleteOne(db, key: id.rawValue)
            return DeletedNote(note: note, attachments: attachments, sends: sends, messages: messages)
        }
    }

    /// Puts a deleted note back with its id, attachments, thread, and send history (sends that still exist).
    public func restore(_ deleted: DeletedNote) async throws {
        try await queue.write { db in
            guard try DocumentRecord.exists(db, key: deleted.note.documentId) else {
                throw NoteStoreError.documentNotFound(DocumentID(rawValue: deleted.note.documentId))
            }
            try deleted.note.insert(db)
            for attachment in deleted.attachments { try attachment.insert(db) }
            for link in deleted.sends where try SendRecord.exists(db, key: link.sendId) { try link.insert(db) }
            for message in deleted.messages { try message.insert(db) }
        }
    }

    // MARK: Iterations

    /// Moves a document's notes onto another row (the same thing under a new path) into that row's current iteration:
    /// the old row's iterations go with it, and notes kept in an iteration the new row doesn't have would be lost.
    static func moveNotes(from oldID: String, to target: DocumentRecord, _ db: Database) throws {
        guard try NoteRecord.filter(Column("document_id") == oldID).fetchCount(db) > 0 else { return }
        _ = try openIteration(DocumentID(rawValue: target.id), at: rounded(Date()), db)
        try db.execute(sql: "UPDATE note SET document_id = ?, iteration = ? WHERE document_id = ?",
                       arguments: [target.id, target.currentIteration, oldID])
    }

    /// The document's current iteration, its row made when the document gets its first note.
    static func openIteration(_ documentID: DocumentID, at date: Date, _ db: Database) throws -> Int {
        guard let document = try DocumentRecord.fetchOne(db, key: documentID.rawValue) else { throw NoteStoreError.documentNotFound(documentID) }
        try db.execute(sql: "INSERT OR IGNORE INTO iteration (document_id, number, started_at) VALUES (?, ?, ?)",
                       arguments: [documentID.rawValue, document.currentIteration, date])
        return document.currentIteration
    }

    /// A document's iterations, oldest first, each with how many notes it holds (Recently Deleted's left out).
    public func iterations(for documentID: DocumentID) async throws -> [Iteration] {
        try await queue.read { db in try Self.iterations(documentID, db) }
    }

    /// The same, observed: the notes panel's iteration menu follows new notes, renames and new iterations.
    public func observeIterations(for documentID: DocumentID) -> AsyncThrowingStream<[Iteration], any Error> {
        Self.stream(ValueObservation.tracking { db in try Self.iterations(documentID, db) }, in: queue)
    }

    static func iterations(_ documentID: DocumentID, _ db: Database) throws -> [Iteration] {
        let counts = Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: """
            SELECT iteration, COUNT(*) AS count FROM note WHERE document_id = ? AND deleted_at IS NULL GROUP BY iteration
            """, arguments: [documentID.rawValue]).map { ($0["iteration"] as Int, $0["count"] as Int) })
        return try IterationRecord.filter(Column("document_id") == documentID.rawValue).order(Column("number")).fetchAll(db)
            .map { Iteration(record: $0, noteCount: counts[$0.number] ?? 0) }
    }

    /// Ends the document's current iteration and opens the next, in one write (issue #18). The iteration that ends
    /// keeps `snapshot`, the content its notes were taken on, and `gitCommit`, the commit the file was at. Open notes
    /// (anything not resolved) move to the new iteration with `.carry` and stay with `.leave`; resolved notes always
    /// stay. Returns the new iteration's number.
    @discardableResult
    public func startIteration(documentID: DocumentID, openNotes: OpenNotesChoice, snapshot: Data?, gitCommit: String? = nil, at date: Date = Date()) async throws -> Int {
        let date = Self.rounded(date)
        return try await queue.write { db in
            let current = try Self.openIteration(documentID, at: date, db)
            let hash = try snapshot.map { try Self.storeSnapshot($0, at: date, db) }
            try db.execute(sql: """
                UPDATE iteration SET ended_at = ?, snapshot_hash = ?, git_commit = COALESCE(?, git_commit)
                WHERE document_id = ? AND number = ?
                """, arguments: [date, hash, gitCommit, documentID.rawValue, current])
            let next = current + 1
            try db.execute(sql: "UPDATE document SET current_iteration = ? WHERE id = ?", arguments: [next, documentID.rawValue])
            // The next iteration starts at the commit this one ends on: the first commit after it is a change.
            try db.execute(sql: "INSERT INTO iteration (document_id, number, started_at, git_commit) VALUES (?, ?, ?, ?)",
                           arguments: [documentID.rawValue, next, date, gitCommit])
            // A result waiting for review is the user's open work whatever was chosen: it comes along.
            try db.execute(sql: """
                UPDATE note SET iteration = ? WHERE document_id = ? AND iteration = ? AND state = 'resolved'
                    AND review_requested = 1 AND accepted_at IS NULL AND deleted_at IS NULL
                """, arguments: [next, documentID.rawValue, current])
            if openNotes == .carry {
                try db.execute(sql: """
                    UPDATE note SET iteration = ? WHERE document_id = ? AND iteration = ? AND state != 'resolved' AND deleted_at IS NULL
                    """, arguments: [next, documentID.rawValue, current])
            }
            return next
        }
    }

    /// Names an iteration; nil or blank goes back to the default label.
    public func renameIteration(documentID: DocumentID, number: Int, name: String?) async throws {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        try await queue.write { db in
            try db.execute(sql: "UPDATE iteration SET name = ? WHERE document_id = ? AND number = ?",
                           arguments: [name?.isEmpty == false ? name : nil, documentID.rawValue, number])
        }
    }

    /// Sets an iteration's git commit: the commit its file was at when it began, so a later commit is noticed as a
    /// change, until it ends on the commit it ends on.
    public func setIterationCommit(documentID: DocumentID, number: Int, commit: String?) async throws {
        try await queue.write { db in
            try db.execute(sql: "UPDATE iteration SET git_commit = ? WHERE document_id = ? AND number = ?", arguments: [commit, documentID.rawValue, number])
        }
    }

    /// An iteration's snapshot, uncompressed; nil when it has none (current, or pruned).
    public func snapshot(hash: String) async throws -> Data? {
        try await queue.read { db in
            guard let record = try SnapshotRecord.fetchOne(db, key: hash) else { return nil }
            return try Self.decompress(record.data)
        }
    }

    /// Keeps the snapshots of each document's last `count` ended iterations; older ones keep their notes and lose
    /// their snapshot. A snapshot no iteration uses any more is deleted.
    public func pruneSnapshots(keepingLast count: Int) async throws {
        try await queue.write { db in
            try db.execute(sql: """
                UPDATE iteration SET snapshot_hash = NULL WHERE snapshot_hash IS NOT NULL AND number < (
                    SELECT document.current_iteration FROM document WHERE document.id = iteration.document_id) - ?
                """, arguments: [count])
            try db.execute(sql: "DELETE FROM snapshot WHERE hash NOT IN (SELECT snapshot_hash FROM iteration WHERE snapshot_hash IS NOT NULL)")
        }
    }

    /// Copies a note from an earlier iteration into the current one as a new draft at `anchor` (worked out against
    /// the content now), with a line in its thread saying where it came from. `found` false makes it an orphan (that
    /// was a draft): its text isn't in the file any more, and it waits to be placed again.
    public func bringForward(_ id: NoteID, anchor: Anchor, found: Bool = true, origin: String, at date: Date = Date()) async throws -> Note {
        let date = Self.rounded(date)
        return try await queue.write { db in
            guard let source = try NoteRecord.live.filter(key: id.rawValue).fetchOne(db) else { throw NoteStoreError.noteNotFound(id) }
            let documentID = DocumentID(rawValue: source.documentId)
            let iteration = try Self.openIteration(documentID, at: date, db)
            let body = source.body.isEmpty ? (try Self.messageRecords(id, db).first?.body ?? "") : source.body
            let record = NoteRecord(
                id: NoteID.new().rawValue, documentId: source.documentId,
                anchorJson: try anchor.encodedJSON(), anchorType: anchor.type.rawValue,
                body: body, state: (found ? NoteState.draft : .orphaned).rawValue, createdAt: date, updatedAt: date, color: source.color,
                resolveOutcome: nil, resolveMessage: nil, previousState: found ? nil : NoteState.draft.rawValue, iteration: iteration
            )
            try record.insert(db)
            for var attachment in try AttachmentRecord.filter(Column("note_id") == source.id).fetchAll(db) {
                attachment.id = AttachmentID.new().rawValue
                attachment.noteId = record.id
                try attachment.insert(db)
            }
            try Self.insertMessage(note: record.id, author: .app, kind: .comment, body: origin, at: date, sent: true, db)
            return try Note(record: try Self.refetch(record, db), db)
        }
    }

    /// Stores content once by its SHA-256, zlib-compressed; returns the hash.
    static func storeSnapshot(_ data: Data, at date: Date, _ db: Database) throws -> String {
        let hash = data.sha256Hex
        if try !SnapshotRecord.exists(db, key: hash) {
            try SnapshotRecord(hash: hash, data: try compress(data), size: Int64(data.count), createdAt: date).insert(db)
        }
        return hash
    }

    static func compress(_ data: Data) throws -> Data {
        try (data as NSData).compressed(using: .zlib) as Data
    }

    static func decompress(_ data: Data) throws -> Data {
        try (data as NSData).decompressed(using: .zlib) as Data
    }

    // MARK: Recently Deleted

    /// Puts notes in Recently Deleted (issue #15): every read leaves them out, and they draw nothing, but the row,
    /// its thread, attachments and sends stay until `untrashNotes`, `deleteForever` or `purgeTrash`.
    public func trashNotes(_ ids: [NoteID], at date: Date = Date()) async throws {
        guard !ids.isEmpty else { return }
        let date = Self.rounded(date)
        try await queue.write { db in
            try db.execute(sql: "UPDATE note SET deleted_at = ? WHERE id IN (\(Self.placeholders(ids.count))) AND deleted_at IS NULL",
                           arguments: StatementArguments([date] + ids.map(\.rawValue)))
        }
    }

    /// Brings notes back from Recently Deleted to their documents, as they were. Returns the ones that came back: a
    /// note deleted for good meanwhile, or never deleted, is not among them.
    @discardableResult
    public func untrashNotes(_ ids: [NoteID]) async throws -> Set<NoteID> {
        guard !ids.isEmpty else { return [] }
        return try await queue.write { db in
            let arguments = StatementArguments(ids.map(\.rawValue))
            let trashed = try String.fetchAll(db, sql: "SELECT id FROM note WHERE id IN (\(Self.placeholders(ids.count))) AND deleted_at IS NOT NULL", arguments: arguments)
            try db.execute(sql: "UPDATE note SET deleted_at = NULL WHERE id IN (\(Self.placeholders(ids.count)))", arguments: arguments)
            return Set(trashed.map(NoteID.init(rawValue:)))
        }
    }

    /// Whether the user deleted this note (it is in Recently Deleted), so an agent asking for it is told so.
    public func isTrashed(_ id: NoteID) async throws -> Bool {
        try await queue.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM note WHERE id = ? AND deleted_at IS NOT NULL)", arguments: [id.rawValue]) ?? false
        }
    }

    /// Whether an agent was ever given this note (delivered, or its own question), deleted or not: only such a
    /// note is named to an agent as deleted.
    public func wasShared(_ id: NoteID) async throws -> Bool {
        try await queue.read { db in
            guard let record = try NoteRecord.fetchOne(db, key: id.rawValue) else { return false }
            return try Self.wasShared(record, db)
        }
    }

    /// Every document with a note, Recently Deleted's included: what still needs its host row and path kept until
    /// those notes are purged.
    public func documentsWithAnyNotes() async throws -> [Document] {
        try await queue.read { db in
            try DocumentRecord.filter(sql: "EXISTS (SELECT 1 FROM note WHERE note.document_id = document.id)")
                .order(Column("host_id"), Column("path")).fetchAll(db).map(Document.init(record:))
        }
    }

    /// Recently Deleted for one location: the deleted notes of documents at or under `path` on `hostID`, the most
    /// recently deleted first.
    public func trashedNotes(underRoot path: String, hostID: HostID) async throws -> [TrashedNote] {
        try await queue.read { db in try Self.trashedNotes(underRoot: path, hostID: hostID, db) }
    }

    /// The same, observed: the Recently Deleted view follows deletes, restores and purges.
    public func observeTrashedNotes(underRoot path: String, hostID: HostID) -> AsyncThrowingStream<[TrashedNote], any Error> {
        Self.stream(ValueObservation.tracking { db in try Self.trashedNotes(underRoot: path, hostID: hostID, db) }, in: queue)
    }

    static func trashedNotes(underRoot path: String, hostID: HostID, _ db: Database) throws -> [TrashedNote] {
        let directory = path.hasSuffix("/") ? path : path + "/"
        let rows = try NoteRecord
            .filter(Column("deleted_at") != nil)
            .including(required: NoteRecord.document)
            .filter(sql: "document.host_id = ? AND (document.path = ? OR substr(document.path, 1, ?) = ?)",
                    arguments: [hostID.rawValue, path, directory.unicodeScalars.count, directory])
            .asRequest(of: NoteWithDocument.self).fetchAll(db)
        let unsent = try Self.unsentNoteIDs(db)
        return try rows.compactMap { row in
            guard let deletedAt = row.note.deletedAt else { return nil }
            return TrashedNote(note: try Note(record: row.note, unsent: unsent), document: Document(record: row.document), deletedAt: deletedAt)
        }
        .sorted { $0.deletedAt != $1.deletedAt ? $0.deletedAt > $1.deletedAt : $0.note.id.rawValue > $1.note.id.rawValue }
    }

    /// Deletes notes for good, with their threads, attachment rows, send links, and sends left carrying no note.
    /// Attachment files stay on disk for the attachment sweep.
    public func deleteForever(_ ids: [NoteID]) async throws {
        guard !ids.isEmpty else { return }
        try await queue.write { db in
            _ = try NoteRecord.deleteAll(db, keys: ids.map(\.rawValue))
            try Self.deleteEmptySends(db)
        }
    }

    /// A send keeps the packet as sent, the notes' words and excerpts of the files: once none of its notes is left
    /// it goes too, or a note deleted for good lived on in it. One still owning staged files waits for their sweep.
    static func deleteEmptySends(_ db: Database) throws {
        try db.execute(sql: """
            DELETE FROM send WHERE NOT EXISTS (SELECT 1 FROM send_note WHERE send_note.send_id = send.id)
                AND NOT EXISTS (SELECT 1 FROM staged_file WHERE staged_file.send_id = send.id)
            """)
    }

    /// Deletes for good every note deleted at or before `date`; returns how many went.
    @discardableResult
    public func purgeTrash(olderThan date: Date) async throws -> Int {
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM note WHERE deleted_at IS NOT NULL AND deleted_at <= ?", arguments: [Self.rounded(date)])
            let purged = db.changesCount
            // Also sends emptied by earlier deletes (a document's notes went with it, or an older build's purge).
            try Self.deleteEmptySends(db)
            return purged
        }
    }

    /// `sent` → `resolved`, `draft` → `resolved` when the user resolves by hand, or `orphaned` → `resolved` when the
    /// text is gone because acting on the note removed it. An outcome of `needsInput` is a question, never a
    /// resolution (see `agentReply`).
    public func resolve(_ id: NoteID, outcome: ResolveOutcome = .done, message: String? = nil, at date: Date = Date()) async throws {
        try await resolve(id, outcome: outcome, message: message, agent: nil, relocation: nil, at: date, onlySent: false)
    }

    /// An agent resolves a note it was given: a sent one, or one sent before its text went. Checked in the same write,
    /// so a note the user takes back meanwhile is never resolved behind their back, and refused while the user has a
    /// follow-up they haven't sent, since the agent hasn't heard what they said since.
    /// `agent` is the resolving client's name, which the card's reply is headed with; `message` is also added to the
    /// thread as the agent's reply, and `relocation`, worked out by `AnchorRelocator`, moves the note in the same write.
    public func resolveSent(_ id: NoteID, outcome: ResolveOutcome = .done, message: String? = nil, agent: String? = nil,
                            relocation: NoteRelocation? = nil, at date: Date = Date()) async throws {
        try await resolve(id, outcome: outcome, message: message, agent: agent, relocation: relocation, at: date, onlySent: true)
    }

    private func resolve(_ id: NoteID, outcome: ResolveOutcome, message: String?, agent: String?, relocation: NoteRelocation?, at date: Date, onlySent: Bool) async throws {
        if outcome == .needsInput {
            // Agents with older instructions ask by resolving with needs_input; the note stays open, waiting on the user.
            try await agentReply(id, body: message ?? "", asks: true, agent: agent, relocation: relocation, at: date, onlySent: onlySent)
            return
        }
        let date = Self.rounded(date)
        try await queue.write { db in
            guard var record = try NoteRecord.fetchOne(db, key: id.rawValue) else { throw NoteStoreError.noteNotFound(id) }
            let current = NoteState(rawValue: record.state) ?? .draft
            if onlySent {
                try Self.checkAgentMayWrite(record)
                if try Self.hasUnsentFollowUp(record.id, db) { throw NoteStoreError.unsentFollowUp }
            }
            try Self.checkTransition(from: current, to: .resolved)
            if let relocation {
                try Self.relocate(&record, to: relocation.anchor, removed: relocation.removed, author: .agent(agent ?? MessageAuthor.unnamedAgent), at: date, db)
            }
            // Relocating may have found an orphan its place again.
            let state = NoteState(rawValue: record.state) ?? current
            record.state = NoteState.resolved.rawValue
            record.resolveOutcome = outcome.rawValue
            record.resolveMessage = message
            record.resolveAgent = agent
            record.waitingOnUser = false
            if onlySent {
                // An agent's resolve is new work to review, in the round the user is on: it waits in the current
                // iteration, where the panel and review find it.
                record.acceptedAt = nil
                if record.reviewRequested, let current = try Int.fetchOne(db, sql: "SELECT current_iteration FROM document WHERE id = ?", arguments: [record.documentId]) {
                    record.iteration = current
                }
            } else if record.reviewRequested {
                // Resolving by hand is the user's own verdict: nothing is left for them to review.
                record.acceptedAt = date
            }
            // A resolved orphan remembers its text is gone, so taking it back makes an orphan, not a draft drawn on
            // whatever text sits where its anchor points.
            record.previousState = state == .orphaned ? NoteState.orphaned.rawValue : nil
            record.updatedAt = date
            try record.update(db)
            if onlySent, let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try Self.insertMessage(note: record.id, author: .agent(agent ?? MessageAuthor.unnamedAgent), kind: .reply, body: message, at: date, sent: true, db)
            }
        }
    }

    /// The user accepts what the agent did on notes awaiting review; any other note is left as it is.
    public func accept(_ ids: [NoteID], at date: Date = Date()) async throws {
        let date = Self.rounded(date)
        try await queue.write { db in
            for id in ids {
                guard var record = try NoteRecord.fetchOne(db, key: id.rawValue), record.deletedAt == nil,
                      record.state == NoteState.resolved.rawValue, record.reviewRequested, record.acceptedAt == nil else { continue }
                record.acceptedAt = date
                record.updatedAt = date
                try record.update(db)
            }
        }
    }

    /// An agent answers on a sent note (`reply_to_note`): a reply, or a question when `asks`, which leaves the note
    /// waiting on the user until they send a follow-up (a later reply that doesn't ask leaves it waiting). It never
    /// resolves the note. Refused for drafts (the user
    /// hasn't sent them) and resolved notes (the user reopens those with a follow-up). A follow-up the user hasn't
    /// sent yet stays as it is. `relocation` moves the note in the same write.
    public func agentReply(_ id: NoteID, body: String, asks: Bool, agent: String?, relocation: NoteRelocation? = nil, at date: Date = Date()) async throws {
        try await agentReply(id, body: body, asks: asks, agent: agent, relocation: relocation, at: date, onlySent: true)
    }

    private func agentReply(_ id: NoteID, body: String, asks: Bool, agent: String?, relocation: NoteRelocation?, at date: Date, onlySent: Bool) async throws {
        let date = Self.rounded(date)
        try await queue.write { db in
            guard var record = try NoteRecord.fetchOne(db, key: id.rawValue) else { throw NoteStoreError.noteNotFound(id) }
            if onlySent { try Self.checkAgentMayWrite(record) }
            if record.state == NoteState.resolved.rawValue { throw NoteStoreError.noteClosed }
            let author = MessageAuthor.agent(agent ?? MessageAuthor.unnamedAgent)
            if let relocation {
                try Self.relocate(&record, to: relocation.anchor, removed: relocation.removed, author: author, at: date, db)
            }
            // A status reply doesn't answer the agent's own open question; only the user's sent follow-up or a resolve does.
            record.waitingOnUser = record.waitingOnUser || asks
            record.updatedAt = date
            try record.update(db)
            let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty || asks {
                try Self.insertMessage(note: record.id, author: author, kind: asks ? .question : .reply, body: text, at: date, sent: true, db)
            }
        }
    }

    /// An agent may write only to a note it was given: not a draft, nor an orphan that was a draft when its text went.
    private static func checkAgentMayWrite(_ record: NoteRecord) throws {
        if record.deletedAt != nil { throw NoteStoreError.noteDeleted(NoteID(rawValue: record.id)) }
        let current = NoteState(rawValue: record.state) ?? .draft
        if current == .draft || (current == .orphaned && record.previousState != NoteState.sent.rawValue) {
            throw NoteStoreError.illegalTransition(from: .draft, to: .resolved)
        }
    }

    /// Where a resolved note goes when it is taken back: a draft, or an orphan (that was a draft) if its text had gone.
    private static func reopened(_ record: inout NoteRecord) {
        if record.previousState == NoteState.orphaned.rawValue {
            record.state = NoteState.orphaned.rawValue
            record.previousState = NoteState.draft.rawValue
        } else {
            record.state = NoteState.draft.rawValue
        }
    }

    /// The note's text is gone. Remembers the state it had, so `recoverOrphan` can put it back. A resolved note
    /// stays resolved: its work is done, and the agent rewriting the text it pointed at is the expected outcome,
    /// not something to look at again.
    public func markOrphaned(_ id: NoteID, ifAnchorIs expected: Anchor? = nil, at date: Date = Date()) async throws {
        let date = Self.rounded(date)
        try await queue.write { db in
            guard var record = try NoteRecord.fetchOne(db, key: id.rawValue) else { throw NoteStoreError.noteNotFound(id) }
            guard try Self.anchor(of: record, is: expected) else { return }
            let current = NoteState(rawValue: record.state) ?? .draft
            guard current != .resolved else { return }
            try Self.checkTransition(from: current, to: .orphaned)
            record.previousState = current.rawValue
            record.state = NoteState.orphaned.rawValue
            record.updatedAt = date
            try record.update(db)
        }
    }

    /// An orphan found again (by re-anchoring, or placed by the user): it takes `anchor` and returns to the state
    /// it had before it was orphaned, draft or sent, never silently becoming a draft that could be sent twice.
    public func recoverOrphan(_ id: NoteID, anchor: Anchor, ifAnchorIs expected: Anchor? = nil, at date: Date = Date()) async throws {
        let date = Self.rounded(date)
        try await queue.write { db in
            guard var record = try NoteRecord.fetchOne(db, key: id.rawValue) else { throw NoteStoreError.noteNotFound(id) }
            guard try Self.anchor(of: record, is: expected) else { return }
            record.anchorJson = try anchor.encodedJSON()
            record.anchorType = anchor.type.rawValue
            if record.state == NoteState.orphaned.rawValue {
                let previous = record.previousState.flatMap(NoteState.init(rawValue:)) ?? .draft
                record.state = (previous == .sent ? NoteState.sent : .draft).rawValue
                record.previousState = nil
            }
            record.updatedAt = date
            try record.update(db)
        }
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
            Self.reopened(&record)
            record.resolveOutcome = nil
            record.resolveMessage = nil
            record.resolveAgent = nil
            record.updatedAt = date
            try record.update(db)
        }
    }

    /// A sent note back to a draft (#13), to change and send again. Its send history stays: it was sent. The agent may
    /// already have read it, but `resolve_note` refuses drafts, so it can't be resolved until it is sent again.
    public func unsend(_ id: NoteID, at date: Date = Date()) async throws {
        try await transition(id, to: .draft, at: date)
    }

    // MARK: Threads

    public func messages(for noteID: NoteID) async throws -> [NoteMessage] {
        try await queue.read { db in try Self.messages(noteID, db) }
    }

    /// The same, read on the caller's thread: for a view's first frame, before an observation delivers. One
    /// indexed query; nothing else should need it.
    public func messagesNow(for noteID: NoteID) -> [NoteMessage] {
        (try? queue.read { db in try Self.messages(noteID, db) }) ?? []
    }

    /// The threads of several notes in one read, keyed by note; a note with no messages has no entry.
    public func messages(for noteIDs: [NoteID]) async throws -> [NoteID: [NoteMessage]] {
        guard !noteIDs.isEmpty else { return [:] }
        return try await queue.read { db in
            let records = try NoteMessageRecord.filter(noteIDs.map(\.rawValue).contains(Column("note_id")))
                .order(Column("created_at"), Column("id")).fetchAll(db)
            return Dictionary(grouping: records.map(NoteMessage.init(record:)), by: \.noteID)
        }
    }

    /// The user adds a follow-up, unsent until the note is next sent. On a resolved note it reopens the thread: the
    /// note is sent again if an agent ever had it, a draft if not (an orphan stays an orphan, remembering which), and
    /// the agent's outcome is cleared. On a note waiting on the user, it stays waiting until the follow-up is sent.
    @discardableResult
    public func addFollowUp(_ noteID: NoteID, body: String, at date: Date = Date()) async throws -> NoteMessage {
        let date = Self.rounded(date)
        return try await queue.write { db in
            guard var record = try NoteRecord.fetchOne(db, key: noteID.rawValue) else { throw NoteStoreError.noteNotFound(noteID) }
            if record.state == NoteState.resolved.rawValue {
                // A draft resolved by hand was never an agent's: reopening it must not hand it to one.
                let open = try Self.wasShared(record, db) ? NoteState.sent : .draft
                if record.previousState == NoteState.orphaned.rawValue {
                    record.state = NoteState.orphaned.rawValue
                    record.previousState = open.rawValue
                } else {
                    record.state = open.rawValue
                    record.previousState = nil
                }
                record.resolveOutcome = nil
                record.resolveMessage = nil
                record.resolveAgent = nil
            }
            record.updatedAt = date
            try record.update(db)
            let message = try Self.insertMessage(note: record.id, author: .user, kind: .comment, body: body, at: date, sent: false, db)
            return NoteMessage(record: message)
        }
    }

    /// Changes a follow-up the user hasn't sent.
    public func updateFollowUp(_ id: MessageID, body: String, at date: Date = Date()) async throws {
        let date = Self.rounded(date)
        try await queue.write { db in
            var message = try Self.unsentFollowUp(id, db)
            message.body = body
            try message.update(db)
            try db.execute(sql: "UPDATE note SET updated_at = ? WHERE id = ?", arguments: [date, message.noteId])
        }
    }

    /// Deletes a follow-up the user hasn't sent.
    public func deleteFollowUp(_ id: MessageID, at date: Date = Date()) async throws {
        let date = Self.rounded(date)
        try await queue.write { db in
            let message = try Self.unsentFollowUp(id, db)
            _ = try message.delete(db)
            try db.execute(sql: "UPDATE note SET updated_at = ? WHERE id = ?", arguments: [date, message.noteId])
        }
    }

    private static func unsentFollowUp(_ id: MessageID, _ db: Database) throws -> NoteMessageRecord {
        guard let message = try NoteMessageRecord.fetchOne(db, key: id.rawValue) else { throw NoteStoreError.messageNotFound(id) }
        guard message.sentAt == nil else { throw NoteStoreError.messageAlreadySent(id) }
        return message
    }

    /// Moves a note to `anchor`, worked out from the document's current text: by an agent saying where its change is
    /// (`author` its name), or by Gloss finding the text removed (`author` nil). The first move remembers where the
    /// note was, for `restoreOriginalPlace`; every move adds a `moved` message; an orphan finds its place again as
    /// `recoverOrphan` does. Moving to where the note already is changes nothing.
    /// False when `expected` was given and the note had moved from it, so nothing was written.
    @discardableResult
    public func applyRelocation(_ noteID: NoteID, to anchor: Anchor, removed: Bool, author: String?, ifAnchorIs expected: Anchor? = nil,
                                at date: Date = Date()) async throws -> Bool {
        let date = Self.rounded(date)
        return try await queue.write { db in
            guard var record = try NoteRecord.fetchOne(db, key: noteID.rawValue) else { throw NoteStoreError.noteNotFound(noteID) }
            guard try Self.anchor(of: record, is: expected) else { return false }
            try Self.relocate(&record, to: anchor, removed: removed, author: author.map(MessageAuthor.agent) ?? .app, at: date, db)
            try record.update(db)
            return true
        }
    }

    /// Gloss found a note again after its file changed (a reload, a page that settled, a packet built from a closed
    /// file). Found on the same words, it only follows them: the anchor is updated and an orphan has its place back.
    /// Found on changed words (someone rewrote them), it is a move Gloss records as its own, so the thread says so and
    /// Restore Original can return to the words the note was made on. An agent saying where its change is soon
    /// after takes that move over (`relocate`).
    /// `expected`: the anchor the new place was worked out from. When the note has moved since (an agent's move landed
    /// while the file was being read), that place is stale and nothing is written: the move stands.
    @discardableResult
    public func applyReanchor(_ noteID: NoteID, to anchor: Anchor, ifAnchorIs expected: Anchor? = nil, at date: Date = Date()) async throws -> Bool {
        let date = Self.rounded(date)
        return try await queue.write { db in
            guard var record = try NoteRecord.fetchOne(db, key: noteID.rawValue) else { throw NoteStoreError.noteNotFound(noteID) }
            guard try Self.anchor(of: record, is: expected) else { return false }
            let current = try Anchor(type: AnchorType(rawValue: record.anchorType) ?? .file, json: record.anchorJson)
            // CRLF files: the stored text and the text found may end their lines differently and still be the same words.
            if case .text(let was) = current, case .text(let now) = anchor,
               ReAnchorer.normalizeNewlines(was.text) != ReAnchorer.normalizeNewlines(now.text) {
                try Self.relocate(&record, to: anchor, removed: false, author: .app, at: date, db)
            } else {
                guard anchor != current || record.state == NoteState.orphaned.rawValue else { return true }
                record.anchorJson = try anchor.encodedJSON()
                record.anchorType = anchor.type.rawValue
                if record.state == NoteState.orphaned.rawValue {
                    let previous = record.previousState.flatMap(NoteState.init(rawValue:)) ?? .draft
                    record.state = (previous == .sent ? NoteState.sent : .draft).rawValue
                    record.previousState = nil
                }
                record.updatedAt = date
            }
            try record.update(db)
            return true
        }
    }

    /// Whether the stored anchor is still `expected` (always, when there is none to check).
    static func anchor(of record: NoteRecord, is expected: Anchor?) throws -> Bool {
        guard let expected else { return true }
        return try Anchor(type: AnchorType(rawValue: record.anchorType) ?? .file, json: record.anchorJson) == expected
    }

    /// Puts a moved note back where it was before its first move, and says so in the thread.
    public func restoreOriginalPlace(_ noteID: NoteID, at date: Date = Date()) async throws {
        let date = Self.rounded(date)
        try await queue.write { db in
            guard var record = try NoteRecord.fetchOne(db, key: noteID.rawValue) else { throw NoteStoreError.noteNotFound(noteID) }
            guard let json = record.originalAnchorJson, let rawType = record.originalAnchorType, let type = AnchorType(rawValue: rawType) else {
                throw NoteStoreError.noOriginalPlace(noteID)
            }
            let original = try Anchor(type: type, json: json)
            try Self.relocate(&record, to: original, removed: false, author: .user, at: date, db)
            record.originalAnchorJson = nil
            record.originalAnchorType = nil
            try record.update(db)
        }
    }

    /// `relocate` inside a write: the record is changed but not saved; the `moved` message is inserted.
    /// A move Gloss recorded on its own that is still the thread's last word is taken over rather than followed by a
    /// second line: by Gloss's next move (two reloads, a page that keeps settling), which updates where it went; and by
    /// an agent's move, when Gloss's came after the note was last sent (the agent's edit reached the file before it
    /// said where its change is), which makes it one move, the agent's, from where the note was before either. A move
    /// that ends where the taken-over one began is no move: it goes, and with it the original place if it was the only
    /// one.
    private static func relocate(_ record: inout NoteRecord, to anchor: Anchor, removed: Bool, author: MessageAuthor, at date: Date, _ db: Database) throws {
        let current = try Anchor(type: AnchorType(rawValue: record.anchorType) ?? .file, json: record.anchorJson)
        let orphaned = record.state == NoteState.orphaned.rawValue
        let noteID = NoteID(rawValue: record.id)
        if var last = try messageRecords(noteID, db).last, last.kind == MessageKind.moved.rawValue, last.author == nil,
           let earlier = last.metaJson.flatMap({ try? JSONDecoder().decode(NoteMove.self, from: Data($0.utf8)) }) {
            let takesOver: Bool
            switch author {
            case .app: takesOver = true
            case .agent: takesOver = try appMove(last, followsLatestSendOf: record, db)
            case .user: takesOver = false
            }
            if takesOver {
                try place(&record, at: anchor, orphaned: orphaned, at: date)
                if anchor == earlier.from {
                    _ = try last.delete(db)
                    let moves = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_message WHERE note_id = ? AND kind = 'moved'", arguments: [record.id]) ?? 0
                    if moves == 0 {
                        record.originalAnchorJson = nil
                        record.originalAnchorType = nil
                    }
                } else {
                    last.author = author.stored
                    last.metaJson = String(decoding: try JSONEncoder.sorted.encode(NoteMove(from: earlier.from, to: anchor, removed: removed)), as: UTF8.self)
                    try last.update(db)
                }
                return
            }
        }
        guard anchor != current || orphaned else { return }
        if record.originalAnchorJson == nil {
            record.originalAnchorJson = record.anchorJson
            record.originalAnchorType = record.anchorType
        }
        try place(&record, at: anchor, orphaned: orphaned, at: date)
        let meta = String(decoding: try JSONEncoder.sorted.encode(NoteMove(from: current, to: anchor, removed: removed)), as: UTF8.self)
        try insertMessage(note: record.id, author: author, kind: .moved, body: "", meta: meta, at: date, sent: true, db)
    }

    /// Writes the anchor; an orphan has its place back, in the state it had before.
    private static func place(_ record: inout NoteRecord, at anchor: Anchor, orphaned: Bool, at date: Date) throws {
        record.anchorJson = try anchor.encodedJSON()
        record.anchorType = anchor.type.rawValue
        if orphaned {
            let previous = record.previousState.flatMap(NoteState.init(rawValue:)) ?? .draft
            record.state = (previous == .sent ? NoteState.sent : .draft).rawValue
            record.previousState = nil
        }
        record.updatedAt = date
    }

    /// Gloss's move came after the agent last had the note: since its latest delivered send, or, for an agent's own
    /// question (never sent), since it was asked. A move from before then (the user's own edit, an earlier reload)
    /// is not the agent's to take over.
    private static func appMove(_ move: NoteMessageRecord, followsLatestSendOf record: NoteRecord, _ db: Database) throws -> Bool {
        let sent = try Date.fetchOne(db, sql: """
            SELECT MAX(send.sent_at) FROM send JOIN send_note ON send_note.send_id = send.id
            WHERE send_note.note_id = ? AND send.outcome = 'delivered'
            """, arguments: [record.id])
        guard let since = sent ?? (record.author != nil ? record.createdAt : nil) else { return false }
        return move.createdAt >= since
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

    /// The lifecycle: draft → sent → resolved; any → orphaned; orphaned → draft or resolved; draft → resolved by hand;
    /// sent → draft when unsent.
    static func checkTransition(from: NoteState, to: NoteState) throws {
        let allowed: Bool
        switch (from, to) {
        case (.draft, .sent), (.sent, .resolved), (.draft, .resolved), (.orphaned, .draft), (.orphaned, .resolved), (.sent, .draft):
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

    /// Observes the notes of one document in one iteration (the current one when nil, following it as it changes),
    /// emitting the full sorted list on every change.
    public func observeNotes(for documentID: DocumentID, iteration: Int? = nil) -> AsyncThrowingStream<[Note], any Error> {
        Self.stream(ValueObservation.tracking { db in try Self.notes(documentID, iteration: iteration, db) }, in: queue)
    }

    /// Observes the notes of one document in every iteration, newest iteration first (All Iterations).
    public func observeNotesInEveryIteration(for documentID: DocumentID) -> AsyncThrowingStream<[Note], any Error> {
        Self.stream(ValueObservation.tracking { db in try Self.notesInEveryIteration(documentID, db) }, in: queue)
    }

    /// Observes one note's messages, oldest first.
    public func observeMessages(for noteID: NoteID) -> AsyncThrowingStream<[NoteMessage], any Error> {
        Self.stream(ValueObservation.tracking { db in try Self.messages(noteID, db) }, in: queue)
    }

    /// Observes every note's messages, by note and oldest first: one observation for the notes panel, rather than one
    /// per card. Notes without messages are absent.
    public func observeAllMessages() -> AsyncThrowingStream<[NoteID: [NoteMessage]], any Error> {
        Self.stream(ValueObservation.tracking { db in try Self.allMessages(db) }, in: queue)
    }

    /// The same, read on the caller's thread: the panel's first frame, before the observation delivers.
    public func allMessagesNow() -> [NoteID: [NoteMessage]] {
        (try? queue.read { db in try Self.allMessages(db) }) ?? [:]
    }

    static func allMessages(_ db: Database) throws -> [NoteID: [NoteMessage]] {
        let records = try NoteMessageRecord.order(Column("note_id"), Column("created_at"), Column("id")).fetchAll(db)
        return Dictionary(grouping: records.map(NoteMessage.init(record:)), by: \.noteID)
    }

    /// Observes every document with review history, for the notes panel: a note not deleted, in any iteration, or
    /// an iteration past the first, so an emptied current iteration keeps its header (and its menu of earlier ones).
    /// Each document's notes in its current iteration (issue #18): earlier iterations are looked at one at a time.
    public func observeDocumentsWithNotes() -> AsyncThrowingStream<[DocumentNotes], any Error> {
        Self.stream(ValueObservation.tracking { db in
            let documents = try DocumentRecord
                .filter(sql: """
                    EXISTS (SELECT 1 FROM note WHERE note.document_id = document.id AND note.deleted_at IS NULL)
                    OR EXISTS (SELECT 1 FROM iteration WHERE iteration.document_id = document.id AND iteration.number > 0)
                    """)
                .order(Column("host_id"), Column("path"))
                .fetchAll(db)
            let unsent = try Self.unsentNoteIDs(db)
            return try documents.map { record in
                let notes = try NoteRecord.live.filter(Column("document_id") == record.id && Column("iteration") == record.currentIteration)
                    .fetchAll(db).map { try Note(record: $0, unsent: unsent) }
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

    /// Records one delivery and, when it succeeded, flips every draft note in it to `sent`, stamps the follow-ups it
    /// carried as sent, and leaves no note waiting on the user. A resolved note with a follow-up is reopened by it.
    /// `outcome` is `delivered` or `failed: <message>`. `carried` holds the follow-ups the packet held, with the text
    /// it held for each; one written, or changed, while the delivery was under way stays unsent. Nil stamps every
    /// unsent follow-up of the notes.
    /// `review`: the send asked the user to review what the agent does; a note it carries out keeps asking (a later
    /// follow-up included) and loses any earlier acceptance, since it is new work.
    public func recordSend(
        transport: String, targetJSON: String, packetText: String, noteIDs: [NoteID],
        outcome: SendOutcome, carried: [MessageID: String]? = nil, review: Bool = false, at date: Date = Date()
    ) async throws -> SendID {
        try await queue.write { db in
            let sendID = SendID.new()
            try SendRecord(
                id: sendID.rawValue, targetJson: targetJSON, transport: transport,
                packetText: packetText, sentAt: date, outcome: outcome.stored, review: review
            ).insert(db)
            for noteID in noteIDs {
                try SendNoteRecord(sendId: sendID.rawValue, noteId: noteID.rawValue).insert(db)
                if outcome == .delivered {
                    guard var record = try NoteRecord.fetchOne(db, key: noteID.rawValue) else { throw NoteStoreError.noteNotFound(noteID) }
                    let current = NoteState(rawValue: record.state) ?? .draft
                    var stampedAny = false
                    for message in try NoteMessageRecord.filter(Column("note_id") == noteID.rawValue && Column("sent_at") == nil).fetchAll(db)
                    where carried.map({ $0[MessageID(rawValue: message.id)] == message.body }) ?? true {
                        var stamped = message
                        stamped.sentAt = date
                        try stamped.update(db)
                        stampedAny = true
                    }
                    if current == .draft || current == .sent {
                        record.state = NoteState.sent.rawValue
                    } else if current == .resolved, stampedAny {
                        if record.previousState == NoteState.orphaned.rawValue {
                            record.state = NoteState.orphaned.rawValue
                            record.previousState = NoteState.sent.rawValue
                        } else {
                            record.state = NoteState.sent.rawValue
                            record.previousState = nil
                        }
                        record.resolveOutcome = nil
                        record.resolveMessage = nil
                        record.resolveAgent = nil
                    }
                    let reviewBefore = (record.reviewRequested, record.acceptedAt)
                    if record.state != NoteState.resolved.rawValue {
                        record.reviewRequested = record.reviewRequested || review
                        record.acceptedAt = nil
                    }
                    if record.state != current.rawValue || record.waitingOnUser || stampedAny
                        || (record.reviewRequested, record.acceptedAt) != reviewBefore {
                        record.waitingOnUser = false
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
        try await queue.write { db in
            _ = try StagedFileRecord.deleteAll(db, keys: ids.map(\.rawValue))
            try Self.deleteEmptySends(db)
        }
    }

    // MARK: Targets

    /// One row per agent, found by what identifies it (`AgentTarget.id`'s key), not by the JSON's text: a Herdr
    /// agent's name or a tmux pane's command changes while it is the same agent, and each change used to add a row.
    /// The row keeps the newest JSON; rows an older build added for the same agent are folded into it.
    public func upsertTarget(hostID: HostID, transport: String, identityJSON: String, label: String, usedAt: Date? = nil) async throws -> KnownTarget {
        // An unknown transport falls back to the whole identity, keys sorted, as any transport without a key does.
        let kind = TransportKind(rawValue: transport) ?? .clipboard
        let key = AgentTarget.identityKey(transport: kind, json: identityJSON)
        return try await queue.write { db in
            let same = try TargetRecord
                .filter(Column("host_id") == hostID.rawValue && Column("transport") == transport)
                .order(Column("last_used_at").desc)
                .fetchAll(db)
                .filter { AgentTarget.identityKey(transport: kind, json: $0.identityJson) == key }
            if var existing = same.first {
                for duplicate in same.dropFirst() { try duplicate.delete(db) }
                existing.identityJson = identityJSON
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

    /// The note was given to an agent: delivered at least once, or an agent's own question (as `sharedNoteIDs`).
    static func wasShared(_ record: NoteRecord, _ db: Database) throws -> Bool {
        if record.author != nil { return true }
        return try Bool.fetchOne(db, sql: """
            SELECT EXISTS (SELECT 1 FROM send_note JOIN send ON send.id = send_note.send_id
                           WHERE send_note.note_id = ? AND send.outcome = 'delivered')
            """, arguments: [record.id]) ?? false
    }

    /// Notes with a follow-up the user hasn't sent; there are only ever a few.
    static func unsentNoteIDs(_ db: Database) throws -> Set<String> {
        Set(try String.fetchAll(db, sql: "SELECT DISTINCT note_id FROM note_message WHERE sent_at IS NULL"))
    }

    /// `?, ?, ?` for an `IN` list of `count` values.
    static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ", ")
    }

    static func hasUnsentFollowUp(_ noteID: String, _ db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM note_message WHERE note_id = ? AND sent_at IS NULL)", arguments: [noteID]) ?? false
    }

    static func messageRecords(_ noteID: NoteID, _ db: Database) throws -> [NoteMessageRecord] {
        try NoteMessageRecord.filter(Column("note_id") == noteID.rawValue).order(Column("created_at"), Column("id")).fetchAll(db)
    }

    static func messages(_ noteID: NoteID, _ db: Database) throws -> [NoteMessage] {
        try messageRecords(noteID, db).map(NoteMessage.init(record:))
    }

    @discardableResult
    static func insertMessage(note noteID: String, author: MessageAuthor, kind: MessageKind, body: String, meta: String? = nil, at date: Date, sent: Bool, _ db: Database) throws -> NoteMessageRecord {
        let record = NoteMessageRecord(id: MessageID.new().rawValue, noteId: noteID, author: author.stored, kind: kind.rawValue, body: body,
                                       metaJson: meta, createdAt: date, sentAt: sent ? date : nil)
        try record.insert(db)
        return record
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

/// What happens to a document's open notes when it starts a new iteration (issue #18).
public enum OpenNotesChoice: String, Sendable, CaseIterable {
    /// They move to the new iteration.
    case carry
    /// They stay in the iteration that ends.
    case leave
}

extension Iteration {
    init(record: IterationRecord, noteCount: Int) {
        self.init(documentID: DocumentID(rawValue: record.documentId), number: record.number, name: record.name,
                  startedAt: record.startedAt, endedAt: record.endedAt, snapshotHash: record.snapshotHash,
                  gitCommit: record.gitCommit, noteCount: noteCount)
    }
}

/// A note in Recently Deleted, with its document and when it was deleted.
public struct TrashedNote: Hashable, Sendable, Identifiable {
    public var note: Note
    public var document: Document
    public var deletedAt: Date
    public var id: NoteID { note.id }

    public init(note: Note, document: Document, deletedAt: Date) {
        self.note = note
        self.document = document
        self.deletedAt = deletedAt
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

extension JSONEncoder {
    /// Sorted keys, so stored JSON is diffable.
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private struct NoteWithDocument: Decodable, FetchableRecord {
    var note: NoteRecord
    var document: DocumentRecord
}

extension NoteRecord {
    /// Notes not in Recently Deleted: what every read and observation of notes starts from.
    static var live: QueryInterfaceRequest<NoteRecord> { NoteRecord.filter(Column("deleted_at") == nil) }
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

extension WebPage {
    init(record: WebPageRecord) {
        self.init(url: record.url, hostID: HostID(rawValue: record.hostId), title: record.title, lastVisitedAt: record.lastVisitedAt, pinned: record.pinned)
    }
}

extension Document {
    init(record: DocumentRecord) {
        self.init(
            id: DocumentID(rawValue: record.id), hostID: HostID(rawValue: record.hostId), path: record.path,
            kind: DocumentKind(rawValue: record.kind) ?? .file,
            fingerprint: Fingerprint(mtime: record.lastMtime, size: record.lastSize, hash: record.lastHash),
            currentIteration: record.currentIteration
        )
    }
}

extension Note {
    /// `unsent` holds the ids of notes with a follow-up not sent yet (`NoteStore.unsentNoteIDs`).
    init(record: NoteRecord, unsent: Set<String>) throws {
        let type = AnchorType(rawValue: record.anchorType) ?? .file
        var original: Anchor?
        if let json = record.originalAnchorJson, let rawType = record.originalAnchorType, let originalType = AnchorType(rawValue: rawType) {
            original = try? Anchor(type: originalType, json: json)
        }
        self.init(
            id: NoteID(rawValue: record.id), documentID: DocumentID(rawValue: record.documentId),
            anchor: try Anchor(type: type, json: record.anchorJson), body: record.body,
            state: NoteState(rawValue: record.state) ?? .draft, color: NoteColor(rawValue: record.color) ?? .yellow,
            createdAt: record.createdAt, updatedAt: record.updatedAt,
            resolveOutcome: record.resolveOutcome.flatMap(ResolveOutcome.init(rawValue:)), resolveMessage: record.resolveMessage,
            author: record.author, resolveAgent: record.resolveAgent, waitingOnUser: record.waitingOnUser,
            hasUnsentFollowUps: unsent.contains(record.id), originalAnchor: original, iteration: record.iteration,
            reviewRequested: record.reviewRequested, acceptedAt: record.acceptedAt
        )
    }

    /// One note, asking the database whether it has an unsent follow-up.
    init(record: NoteRecord, _ db: Database) throws {
        let unsent = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM note_message WHERE note_id = ? AND sent_at IS NULL)", arguments: [record.id]) ?? false
        try self.init(record: record, unsent: unsent ? [record.id] : [])
    }
}

extension NoteMessage {
    init(record: NoteMessageRecord) {
        self.init(
            id: MessageID(rawValue: record.id), noteID: NoteID(rawValue: record.noteId), author: MessageAuthor(stored: record.author),
            kind: MessageKind(rawValue: record.kind) ?? .comment, body: record.body, createdAt: record.createdAt, sentAt: record.sentAt,
            move: record.metaJson.flatMap { try? JSONDecoder().decode(NoteMove.self, from: Data($0.utf8)) }
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
    public let messages: [NoteMessageRecord]
    public var id: NoteID { NoteID(rawValue: note.id) }

    public static func == (lhs: DeletedNote, rhs: DeletedNote) -> Bool { lhs.note.id == rhs.note.id }
}
