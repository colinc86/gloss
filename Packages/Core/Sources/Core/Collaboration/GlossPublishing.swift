import Foundation

/// Who is writing: one author per Gloss install, with the name they chose.
public struct GlossIdentity: Sendable, Hashable {
    public var author: AuthorID
    public var name: String

    public init(author: AuthorID, name: String) {
        self.author = author
        self.name = name
    }
}

/// The document a new review is made from.
public struct GlossReviewSeed: Sendable {
    public var title: String
    public var kind: DocumentKind
    /// Portable identity only; refused if it names the owner's disk or carries a credential.
    public var source: GlossSource
    /// The saved bytes.
    public var content: GlossContent
    public var contentFacts: JSONValue?
    /// The document's current iteration.
    public var iteration: Int
    public var gitCommit: String?
    public var capturedAt: Date

    public init(title: String, kind: DocumentKind, source: GlossSource, content: GlossContent, contentFacts: JSONValue? = nil,
                iteration: Int, gitCommit: String? = nil, capturedAt: Date = Date()) {
        self.title = title
        self.kind = kind
        self.source = source
        self.content = content
        self.contentFacts = contentFacts
        self.iteration = iteration
        self.gitCommit = gitCommit
        self.capturedAt = capturedAt
    }
}

/// The bytes of an image a note refers to.
public struct GlossAttachmentData: Sendable, Hashable {
    public var data: Data
    public var ext: String?
    public var kind: AttachmentKind
    public var width: Int
    public var height: Int

    public init(data: Data, ext: String?, kind: AttachmentKind, width: Int, height: Int) {
        self.data = data
        self.ext = ext
        self.kind = kind
        self.width = width
        self.height = height
    }
}

/// One note with everything its author publishes about it.
public struct GlossNoteBundle: Sendable, Hashable {
    public var note: GlossNote
    public var messages: [GlossMessage]
    public var events: [GlossEvent]
    public var attachments: [GlossAttachmentData]

    public init(note: GlossNote, messages: [GlossMessage] = [], events: [GlossEvent] = [], attachments: [GlossAttachmentData] = []) {
        self.note = note
        self.messages = messages
        self.events = events
        self.attachments = attachments
    }

    /// A bundle from the local store, holding only what the user sent: unsent follow-ups (`sentAt == nil`) and
    /// Gloss's own turns (`.app`) are left out.
    /// - The owner publishes agent turns as their own messages `via` the agent, and the note's state as events: `sent`
    ///   at `sentAt` (the first send, from the sends table), `resolved` at the note's `updatedAt` (with the agent
    ///   that resolved it), `accepted` at `acceptedAt`.
    /// - A participant publishes their comment and their own sent follow-ups, and no events.
    /// - Turns another contributor wrote (imported rows with someone else's `contributorID`) are never published as
    ///   this author's.
    /// Event identifiers are derived from the transition and stable times, so building the same bundle again after
    /// unrelated local edits publishes nothing new. The resolve time is `resolvedAt` when the caller knows it, else
    /// the agent's last turn, else the send; never `updatedAt`, which moves on every edit.
    public init(note: Note, messages: [NoteMessage], attachments: [(Attachment, Data)], identity: GlossIdentity, isOwner: Bool,
                sentAt: Date?, reviewRequested: Bool = false, agent: String? = nil, resolvedAt: Date? = nil) {
        let me = identity.author
        let files = attachments.map { attachment, data in
            GlossAttachmentData(data: data, ext: (attachment.localPath as NSString).pathExtension.nilIfEmpty ?? "png",
                                kind: attachment.kind, width: attachment.width, height: attachment.height)
        }
        let refs = files.map { GlossAttachmentRef(path: GlossLayout.attachment(hash: $0.data.sha256Hex, ext: $0.ext, by: me), kind: $0.kind, width: $0.width, height: $0.height) }
        self.note = GlossNote(
            id: note.id, author: me, via: isOwner ? note.author.map(GlossVia.init(agent:)) : nil, createdAt: note.createdAt,
            updatedAt: note.updatedAt, iteration: note.iteration, anchor: note.anchor, body: note.body, color: note.color,
            attachments: refs.isEmpty ? nil : refs)
        self.attachments = files
        self.messages = messages.compactMap { message in
            if let contributor = message.contributorID, contributor != me.rawValue { return nil }
            switch message.author {
            case .user:
                guard message.isSent else { return nil }
                return GlossMessage(message, author: me, via: nil)
            case .agent(let name):
                return isOwner ? GlossMessage(message, author: me, via: GlossVia(agent: name)) : nil
            case .app:
                return nil
            }
        }
        var events: [GlossEvent] = []
        if isOwner {
            if let sentAt {
                var sent = GlossEvent.sent(note.id, by: me, to: agent, review: reviewRequested, at: sentAt)
                sent.id = .derived(note: note.id, type: .sent, author: me, at: sentAt)
                events.append(sent)
            }
            if note.state == .resolved {
                let lastAgentTurn = messages.filter { if case .agent = $0.author { true } else { false } }.map(\.createdAt).max()
                let resolvedAt = resolvedAt ?? lastAgentTurn ?? sentAt ?? note.createdAt
                var resolved = GlossEvent.resolved(note.id, by: me, via: note.resolveAgent.map(GlossVia.init(agent:)),
                                                   outcome: note.resolveOutcome ?? .done, message: note.resolveMessage, at: resolvedAt)
                resolved.id = .derived(note: note.id, type: .resolved, author: me, at: resolvedAt)
                events.append(resolved)
                if let acceptedAt = note.acceptedAt {
                    // Strictly after the resolve, so the fold (identifier order) never reads the acceptance first.
                    let at = max(acceptedAt, resolvedAt.addingTimeInterval(0.001))
                    events.append(GlossEvent(id: .derived(note: note.id, type: .accepted, author: me, at: at),
                                             note: note.id, author: me, type: .accepted, at: at))
                }
            }
        }
        self.events = events
    }
}

extension GlossMessage {
    /// A local thread turn as a package message, keeping its id; choices, answers and moves go into `meta`.
    init(_ message: NoteMessage, author: AuthorID, via: GlossVia?) {
        var meta: [String: JSONValue] = [:]
        if let choices = message.choices, let value = try? JSONValue(encoding: choices) { meta["choices"] = value }
        if let selected = message.selectedOptions { meta["selectedOptions"] = .array(selected.map(JSONValue.int)) }
        if message.customAnswer { meta["customAnswer"] = .bool(true) }
        if let move = message.move, let value = try? JSONValue(encoding: move) { meta["move"] = value }
        self.init(id: message.id, note: message.noteID, author: author, via: via, kind: message.kind, body: message.body,
                  inReplyTo: message.inReplyTo, meta: meta.isEmpty ? nil : .object(meta), createdAt: message.createdAt)
    }
}

/// What a publish wrote and what it found already there.
public struct GlossPublishReport: Sendable, Hashable {
    public var notesWritten: [NoteID] = []
    public var notesUnchanged: [NoteID] = []
    /// Notes not written: the id isn't a plain note id (an imported row's namespaced id), or another author's
    /// folder already holds it. Publishing it would make both copies unreadable.
    public var notesRefused: [NoteID] = []
    public var messagesWritten = 0
    public var eventsWritten = 0
    public var attachmentsWritten = 0

    public init() {}
}

extension GlossPackageWriter {
    /// Writes bundles into this author's folder, skipping what's already there: a note is rewritten only when its
    /// content changed, and messages, events and attachments that exist are left alone. Writes `author.json` first
    /// if it's missing.
    func publish(_ bundles: [GlossNoteBundle], name: String, at date: Date) throws -> GlossPublishReport {
        var report = GlossPublishReport()
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: package.fileURL(GlossLayout.author(author)).path) {
            try writeAuthor(name: name, joinedAt: date)
        }
        for bundle in bundles {
            let id = bundle.note.id
            let owner = package.author(ofNote: id)
            guard GlossPath.canonical(id.rawValue, as: NoteID.self) != nil, owner == nil || owner == author else {
                report.notesRefused.append(id)
                continue
            }
            for attachment in bundle.attachments {
                let path = GlossLayout.attachment(hash: attachment.data.sha256Hex, ext: attachment.ext, by: author)
                if fileManager.fileExists(atPath: package.fileURL(path).path) { continue }
                try addAttachment(attachment.data, ext: attachment.ext)
                report.attachmentsWritten += 1
            }
            if let data = package.readIfSafe(GlossLayout.note(bundle.note.id, by: author)), let existing = try? GlossCoding.decode(GlossNote.self, from: data),
               existing.sameContent(as: bundle.note) {
                report.notesUnchanged.append(bundle.note.id)
            } else {
                try writeNote(bundle.note)
                report.notesWritten.append(bundle.note.id)
            }
            for message in bundle.messages where GlossPath.canonical(message.id.rawValue, as: MessageID.self) != nil
                && !fileManager.fileExists(atPath: package.fileURL(GlossLayout.message(message.id, by: author)).path) {
                try writeMessage(message)
                report.messagesWritten += 1
            }
            for event in bundle.events where !fileManager.fileExists(atPath: package.fileURL(GlossLayout.event(event.id, by: author)).path) {
                try writeEvent(event)
                report.eventsWritten += 1
            }
        }
        return report
    }
}

extension GlossNote {
    /// Writes the same bytes apart from `rev`, the stamp of when it was written.
    func sameContent(as other: GlossNote) -> Bool {
        var mine = self, theirs = other
        mine.rev = ""
        theirs.rev = ""
        mine.original = GlossOriginal()
        theirs.original = GlossOriginal()
        return (try? GlossCoding.encode(mine)) == (try? GlossCoding.encode(theirs))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
