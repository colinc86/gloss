import Foundation

/// `Info.json`: what the review is and which content is current. Written by the owner only.
public struct GlossInfo: GlossRecord, Hashable {
    public var format: Int
    public var minReader: Int
    public var id: ReviewID
    public var instance: InstanceID
    /// The package this one was copied from; nil for an original.
    public var origin: GlossOrigin?
    public var createdAt: Date
    /// The review's creator, named as its owner; see `owners` for rights.
    public var ownerAuthor: AuthorID
    /// Every install of the owner's Apple Account that adopted the review (`ownerAuthor` among them), sorted. Nil
    /// until a second install adopts it; read as just `ownerAuthor`.
    public var ownerAuthors: [AuthorID]?
    /// A `DocumentKind` raw value; kept as a string so a newer kind doesn't make the package unreadable.
    public var kind: String
    public var title: String
    public var source: GlossSource
    public var current: GlossCurrent
    /// Facts about the current content, per kind (encoding, pixel size, page count, changed lines…).
    public var content: JSONValue?
    /// A ULID minted on every write; the higher wins when two owner writes meet.
    public var rev: String
    public var original = GlossOriginal()

    enum CodingKeys: String, CodingKey, CaseIterable {
        case format, minReader, id, instance, origin, createdAt, ownerAuthor, ownerAuthors, kind, title, source, current, content, rev
    }

    public static var knownPaths: Set<String> { Set(CodingKeys.allCases.map(\.rawValue)).union(nestedPaths) }

    static let nestedPaths: Set<String> = Set(
        ["current.hash", "current.iteration", "current.capturedAt",
         "origin.review", "origin.instance", "origin.iteration", "origin.copiedAt",
         "source.git.origin", "source.git.path", "source.git.commit"]
        + GlossSource.knownKeys.map { "source." + $0 })

    public init(id: ReviewID, instance: InstanceID, origin: GlossOrigin? = nil, createdAt: Date, ownerAuthor: AuthorID,
                kind: DocumentKind, title: String, source: GlossSource,
                current: GlossCurrent, content: JSONValue? = nil) {
        self.format = GlossFormat.version
        self.minReader = GlossFormat.version
        self.id = id
        self.instance = instance
        self.origin = origin
        self.createdAt = createdAt
        self.ownerAuthor = ownerAuthor
        self.kind = kind.rawValue
        self.title = title
        self.source = source
        self.current = current
        self.content = content
        self.rev = ULID.generate()
    }

    public var documentKind: DocumentKind? { DocumentKind(rawValue: kind) }

    /// Why an identifier isn't canonical, if one isn't. Identifiers name folders and index rows.
    var identifierProblem: String? {
        if GlossPath.canonical(id.rawValue, as: ReviewID.self) == nil { return "The review id isn't valid" }
        if GlossPath.canonical(instance.rawValue, as: InstanceID.self) == nil { return "The instance id isn't valid" }
        if !([ownerAuthor] + (ownerAuthors ?? [])).allSatisfy({ GlossPath.canonical($0.rawValue, as: AuthorID.self) != nil }) {
            return "An owner id isn't valid"
        }
        if let origin, GlossPath.canonical(origin.review.rawValue, as: ReviewID.self) == nil
            || GlossPath.canonical(origin.instance.rawValue, as: InstanceID.self) == nil { return "The origin isn't valid" }
        if !GlossPath.isHash(current.hash) { return "The current content hash isn't valid" }
        return nil
    }

    /// The authors with the owner's rights now: `ownerAuthor` and the installs that adopted the review.
    public var owners: Set<AuthorID> { Set(ownerAuthors ?? []).union([ownerAuthor]) }

    /// True when `author` is one of the owners. Owners only join, never leave, so this holds for any time.
    public func isOwner(_ author: AuthorID) -> Bool { owners.contains(author) }

    /// Adds `author` to the owners; false when it already is one.
    @discardableResult
    public mutating func addOwner(_ author: AuthorID) -> Bool {
        guard !isOwner(author) else { return false }
        ownerAuthors = owners.union([author]).sorted { $0.rawValue < $1.rawValue }
        return true
    }

}

public struct GlossCurrent: Codable, Hashable, Sendable {
    /// SHA-256 of the current snapshot (`content/<hash>…`).
    public var hash: String
    public var iteration: Int
    public var capturedAt: Date

    public init(hash: String, iteration: Int, capturedAt: Date) {
        self.hash = hash
        self.iteration = iteration
        self.capturedAt = capturedAt
    }
}

/// Where a copy came from: the review, the instance it was copied from and the iteration it showed.
public struct GlossOrigin: Codable, Hashable, Sendable {
    public var review: ReviewID
    public var instance: InstanceID
    public var iteration: Int
    public var copiedAt: Date

    public init(review: ReviewID, instance: InstanceID, iteration: Int, copiedAt: Date) {
        self.review = review
        self.instance = instance
        self.iteration = iteration
        self.copiedAt = copiedAt
    }
}

/// A file's place in a git work tree: portable, unlike the owner's path on disk.
public struct GlossGitLocation: Codable, Hashable, Sendable {
    /// The remote without scheme or user, such as `github.com/o/r`.
    public var origin: String
    /// The path inside the work tree, such as `docs/README.md`.
    public var path: String
    public var commit: String?

    public init(origin: String, path: String, commit: String? = nil) {
        self.origin = origin
        self.path = path
        self.commit = commit
    }
}

/// Where the captured content came from, by portable identity only: never an absolute path or an ssh alias.
public enum GlossSource: Hashable, Sendable {
    case file(name: String, git: GlossGitLocation?)
    /// A live page; `reachable` is false for localhost and tunneled pages other people can't open.
    case web(url: String, reachable: Bool)
    case github(repo: String, pull: Int, path: String, head: String?, base: String?)
    case jira(site: String, key: String)
    case confluence(site: String, pageID: String, version: Int?)
    /// A source type this Gloss doesn't know, kept as written.
    case other(JSONValue)

    /// Why this source would leak something private to the owner's Mac or a credential, or nil when it's portable.
    public var privacyProblem: String? {
        switch self {
        case .file(let name, let git):
            if name.isEmpty || name.contains("/") || name.hasPrefix("~") || name == ".." { return "The source name must be a file name, not a path" }
            if let git {
                if !Self.isRelative(git.path) { return "The git path must be relative to the work tree" }
                if !Self.isBareRemote(git.origin) { return "The git origin must be a host and path, without a scheme, user or credential" }
            }
            return nil
        case .web(let url, _):
            guard let components = URLComponents(string: url), let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                return "Only http and https pages are portable sources"
            }
            return components.user != nil || components.password != nil ? "The page address carries a user or password" : nil
        case .github(_, _, let path, _, _):
            return Self.isRelative(path) ? nil : "The pull request path must be relative to the repository"
        case .jira, .confluence, .other:
            return nil
        }
    }

    /// No leading `/` or `~`, and no `..` component.
    static func isRelative(_ path: String) -> Bool {
        !path.hasPrefix("/") && !path.hasPrefix("~") && !path.split(separator: "/").contains("..")
    }

    /// `github.com/o/r`: no scheme, no `user@`, no `host:path` ssh form, no local path.
    static func isBareRemote(_ origin: String) -> Bool {
        guard !origin.isEmpty, !origin.contains("@"), !origin.contains("://"), isRelative(origin) else { return false }
        let host = origin.split(separator: "/", maxSplits: 1).first ?? ""
        return !host.contains(":")
    }
}

extension GlossSource: Codable {
    /// Every key a known source type has, for keeping a newer Gloss's extra keys on rewrite.
    static let knownKeys = ["type", "name", "git", "url", "reachable", "repo", "pull", "path", "head", "base", "site", "key", "pageId", "version"]

    public init(from decoder: any Decoder) throws {
        let value = try JSONValue(from: decoder)
        self = Self(value) ?? .other(value)
    }

    private init?(_ value: JSONValue) {
        switch value["type"]?.stringValue {
        case "file":
            guard let name = value["name"]?.stringValue else { return nil }
            var git: GlossGitLocation?
            if let object = value["git"] {
                guard let decoded = try? object.decode(GlossGitLocation.self) else { return nil }
                git = decoded
            }
            self = .file(name: name, git: git)
        case "web":
            guard let url = value["url"]?.stringValue else { return nil }
            self = .web(url: url, reachable: value["reachable"]?.boolValue ?? true)
        case "github":
            guard let repo = value["repo"]?.stringValue, let pull = value["pull"]?.intValue, let path = value["path"]?.stringValue else { return nil }
            self = .github(repo: repo, pull: pull, path: path, head: value["head"]?.stringValue, base: value["base"]?.stringValue)
        case "jira":
            guard let site = value["site"]?.stringValue, let key = value["key"]?.stringValue else { return nil }
            self = .jira(site: site, key: key)
        case "confluence":
            guard let site = value["site"]?.stringValue, let page = value["pageId"]?.stringValue else { return nil }
            self = .confluence(site: site, pageID: page, version: value["version"]?.intValue)
        default:
            return nil
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var object: [String: JSONValue]
        switch self {
        case .file(let name, let git):
            object = ["type": .string("file"), "name": .string(name)]
            if let git { object["git"] = try JSONValue(encoding: git) }
        case .web(let url, let reachable):
            object = ["type": .string("web"), "url": .string(url)]
            if !reachable { object["reachable"] = .bool(false) }
        case .github(let repo, let pull, let path, let head, let base):
            object = ["type": .string("github"), "repo": .string(repo), "pull": .int(pull), "path": .string(path)]
            if let head { object["head"] = .string(head) }
            if let base { object["base"] = .string(base) }
        case .jira(let site, let key):
            object = ["type": .string("jira"), "site": .string(site), "key": .string(key)]
        case .confluence(let site, let page, let version):
            object = ["type": .string("confluence"), "site": .string(site), "pageId": .string(page)]
            if let version { object["version"] = .int(version) }
        case .other(let value):
            try value.encode(to: encoder)
            return
        }
        try JSONValue.object(object).encode(to: encoder)
    }
}

/// `iterations/<n>.json`: one numbered round, and the snapshot its notes were taken on. Owner only.
public struct GlossIteration: GlossRecord, Hashable {
    public var v: Int
    public var number: Int
    public var name: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var snapshot: String
    public var gitCommit: String?
    public var rev: String
    public var original = GlossOriginal()

    enum CodingKeys: String, CodingKey, CaseIterable {
        case v, number, name, startedAt, endedAt, snapshot, gitCommit, rev
    }

    public static var knownPaths: Set<String> { Set(CodingKeys.allCases.map(\.rawValue)).union(nestedPaths) }
    static let nestedPaths: Set<String> = []

    public init(number: Int, name: String? = nil, startedAt: Date, endedAt: Date? = nil, snapshot: String, gitCommit: String? = nil) {
        self.v = 1
        self.number = number
        self.name = name
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.snapshot = snapshot
        self.gitCommit = gitCommit
        self.rev = ULID.generate()
    }
}

/// `authors/<id>/author.json`: the name a person chose, rewritten when they change it.
public struct GlossAuthor: GlossRecord, Hashable {
    public var v: Int
    public var id: AuthorID
    public var name: String
    /// A tint key for the avatar; never the note's color.
    public var color: String?
    public var joinedAt: Date
    public var rev: String
    public var original = GlossOriginal()

    enum CodingKeys: String, CodingKey, CaseIterable {
        case v, id, name, color, joinedAt, rev
    }

    public static var knownPaths: Set<String> { Set(CodingKeys.allCases.map(\.rawValue)).union(nestedPaths) }
    static let nestedPaths: Set<String> = []

    public init(id: AuthorID, name: String, color: String? = nil, joinedAt: Date) {
        self.v = 1
        self.id = id
        self.name = name
        self.color = color
        self.joinedAt = joinedAt
        self.rev = ULID.generate()
    }
}

/// An agent that acted through the owner's Gloss: its turns and events are written into the owner's folder.
public struct GlossVia: Codable, Hashable, Sendable {
    public var agent: String

    public init(agent: String) { self.agent = agent }
}

/// `authors/<id>/notes/<noteID>.json`: a published note. Only its author writes it, so comment edits are
/// author-only by construction. It has no state: state is folded from events.
public struct GlossNote: GlossRecord, Hashable {
    public var v: Int
    public var id: NoteID
    public var author: AuthorID
    /// Set when an agent wrote the note through the owner (`ask_user`).
    public var via: GlossVia?
    public var createdAt: Date
    public var updatedAt: Date
    public var iteration: Int
    /// Today's `Anchor`, stored as `anchorType` and an `anchor` object.
    public var anchor: Anchor
    public var body: String
    /// A `NoteColor` raw value.
    public var color: String
    /// The images the note refers to, in the author's `attachments/` folder.
    public var attachments: [GlossAttachmentRef]?
    public var rev: String
    public var original = GlossOriginal()

    enum CodingKeys: String, CodingKey, CaseIterable {
        case v, id, author, via, createdAt, updatedAt, iteration, anchorType, anchor, body, color, attachments, rev
    }

    public static var knownPaths: Set<String> { Set(CodingKeys.allCases.map(\.rawValue)).union(nestedPaths) }
    static let nestedPaths: Set<String> = ["via.agent"]

    public init(id: NoteID, author: AuthorID, via: GlossVia? = nil, createdAt: Date, updatedAt: Date, iteration: Int,
                anchor: Anchor, body: String, color: NoteColor, attachments: [GlossAttachmentRef]? = nil) {
        self.v = 1
        self.id = id
        self.author = author
        self.via = via
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.iteration = iteration
        self.anchor = anchor
        self.body = body
        self.color = color.rawValue
        self.attachments = attachments
        self.rev = ULID.generate()
    }

    public var noteColor: NoteColor { NoteColor(rawValue: color) ?? .yellow }

    /// Writes back the anchor object as it was read (with any fields a newer Gloss added) when the anchor is the
    /// same one.
    public static func finish(original: JSONValue, encoded: JSONValue) -> JSONValue {
        guard case .object(var object) = encoded, let oldAnchor = original["anchor"], original["anchorType"] == encoded["anchorType"],
              let type = encoded["anchorType"]?.stringValue.flatMap(AnchorType.init(rawValue:)), let newAnchor = encoded["anchor"],
              let old = try? Anchor(type: type, json: String(decoding: GlossCoding.encoder.encode(oldAnchor), as: UTF8.self)),
              let new = try? Anchor(type: type, json: String(decoding: GlossCoding.encoder.encode(newAnchor), as: UTF8.self)),
              old == new else { return encoded }
        object["anchor"] = oldAnchor
        return .object(object)
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        v = try values.decode(Int.self, forKey: .v)
        id = try values.decode(NoteID.self, forKey: .id)
        author = try values.decode(AuthorID.self, forKey: .author)
        via = try values.decodeIfPresent(GlossVia.self, forKey: .via)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        iteration = try values.decode(Int.self, forKey: .iteration)
        let type = try values.decode(AnchorType.self, forKey: .anchorType)
        let object = try values.decode(JSONValue.self, forKey: .anchor)
        anchor = try Anchor(type: type, json: String(decoding: try GlossCoding.encoder.encode(object), as: UTF8.self))
        body = try values.decode(String.self, forKey: .body)
        color = try values.decode(String.self, forKey: .color)
        attachments = try values.decodeIfPresent([GlossAttachmentRef].self, forKey: .attachments)
        rev = try values.decode(String.self, forKey: .rev)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(v, forKey: .v)
        try values.encode(id, forKey: .id)
        try values.encode(author, forKey: .author)
        try values.encodeIfPresent(via, forKey: .via)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encode(iteration, forKey: .iteration)
        try values.encode(anchor.type, forKey: .anchorType)
        try values.encode(try GlossCoding.decoder.decode(JSONValue.self, from: Data(anchor.encodedJSON().utf8)), forKey: .anchor)
        try values.encode(body, forKey: .body)
        try values.encode(color, forKey: .color)
        try values.encodeIfPresent(attachments, forKey: .attachments)
        try values.encode(rev, forKey: .rev)
    }
}

/// An image a note refers to: its path in the package and what it is.
public struct GlossAttachmentRef: Codable, Hashable, Sendable {
    /// `authors/<id>/attachments/<sha256>.<ext>`.
    public var path: String
    /// An `AttachmentKind` raw value.
    public var kind: String
    public var width: Int
    public var height: Int

    public init(path: String, kind: AttachmentKind, width: Int, height: Int) {
        self.path = path
        self.kind = kind.rawValue
        self.width = width
        self.height = height
    }
}

/// `authors/<id>/messages/<messageID>.json`: one turn of a thread, on anyone's note. Write-once.
public struct GlossMessage: GlossRecord, Hashable {
    public var v: Int
    public var id: MessageID
    public var note: NoteID
    public var author: AuthorID
    public var via: GlossVia?
    /// A `MessageKind` raw value: comment, question, reply or moved.
    public var kind: String
    public var body: String
    public var inReplyTo: MessageID?
    /// Kind-specific detail: a question's choices, an answer's selected options, a move.
    public var meta: JSONValue?
    public var createdAt: Date
    public var original = GlossOriginal()

    enum CodingKeys: String, CodingKey, CaseIterable {
        case v, id, note, author, via, kind, body, inReplyTo, meta, createdAt
    }

    public static var knownPaths: Set<String> { Set(CodingKeys.allCases.map(\.rawValue)).union(nestedPaths) }
    static let nestedPaths: Set<String> = ["via.agent"]

    public init(id: MessageID = .new(), note: NoteID, author: AuthorID, via: GlossVia? = nil, kind: MessageKind, body: String,
                inReplyTo: MessageID? = nil, meta: JSONValue? = nil, createdAt: Date) {
        self.v = 1
        self.id = id
        self.note = note
        self.author = author
        self.via = via
        self.kind = kind.rawValue
        self.body = body
        self.inReplyTo = inReplyTo
        self.meta = meta
        self.createdAt = createdAt
    }

    public var messageKind: MessageKind? { MessageKind(rawValue: kind) }
}

/// What an event does to a note.
public enum GlossEventType: String, Codable, Sendable, CaseIterable {
    /// The owner delivered the note to an agent. Owner only.
    case sent
    /// Resolved, by anyone with write access or by an agent through the owner (`outcome`, `message`).
    case resolved
    /// The owner accepted the agent's result. Owner only; the fold ignores anyone else's.
    case accepted
    /// Opened again, by anyone with write access.
    case reopened
    /// Moved to Recently Deleted: the note's author, or the owner as moderator.
    case deleted
    case restored
    /// A new anchor (`anchorType`, `anchor`, `removed`), from re-anchoring on changed content.
    case moved
}

/// `authors/<id>/events/<eventID>.json`: a state change on anyone's note, attributed to who made it. Write-once.
public struct GlossEvent: GlossRecord, Hashable {
    public var v: Int
    public var id: EventID
    public var note: NoteID
    public var author: AuthorID
    public var via: GlossVia?
    /// A `GlossEventType` raw value.
    public var type: String
    public var at: Date
    public var data: JSONValue?
    public var original = GlossOriginal()

    enum CodingKeys: String, CodingKey, CaseIterable {
        case v, id, note, author, via, type, at, data
    }

    public static var knownPaths: Set<String> { Set(CodingKeys.allCases.map(\.rawValue)).union(nestedPaths) }
    static let nestedPaths: Set<String> = ["via.agent"]

    public init(id: EventID = .new(), note: NoteID, author: AuthorID, via: GlossVia? = nil, type: GlossEventType, at: Date, data: JSONValue? = nil) {
        self.v = 1
        self.id = id
        self.note = note
        self.author = author
        self.via = via
        self.type = type.rawValue
        self.at = at
        self.data = data
    }

    public var eventType: GlossEventType? { GlossEventType(rawValue: type) }

    /// The owner sent the note to an agent; `review` asks for the result to be reviewed.
    public static func sent(_ note: NoteID, by author: AuthorID, to agent: String? = nil, review: Bool = false, at: Date) -> GlossEvent {
        var data: [String: JSONValue] = ["review": .bool(review)]
        if let agent { data["to"] = .string(agent) }
        return GlossEvent(note: note, author: author, type: .sent, at: at, data: .object(data))
    }

    public static func resolved(_ note: NoteID, by author: AuthorID, via: GlossVia? = nil, outcome: ResolveOutcome = .done, message: String? = nil, at: Date) -> GlossEvent {
        var data: [String: JSONValue] = ["outcome": .string(outcome.rawValue)]
        if let message { data["message"] = .string(message) }
        return GlossEvent(note: note, author: author, via: via, type: .resolved, at: at, data: .object(data))
    }

    public static func moved(_ note: NoteID, by author: AuthorID, to anchor: Anchor, removed: Bool, at: Date) throws -> GlossEvent {
        let object = try GlossCoding.decoder.decode(JSONValue.self, from: Data(anchor.encodedJSON().utf8))
        let data: JSONValue = .object(["anchorType": .string(anchor.type.rawValue), "anchor": object, "removed": .bool(removed)])
        return GlossEvent(note: note, author: author, type: .moved, at: at, data: data)
    }

    /// The anchor a `moved` event carries.
    public var movedAnchor: Anchor? {
        guard let type = data?["anchorType"]?.stringValue.flatMap(AnchorType.init(rawValue:)), let object = data?["anchor"],
              let json = try? GlossCoding.encoder.encode(object) else { return nil }
        return try? Anchor(type: type, json: String(decoding: json, as: UTF8.self))
    }
}
