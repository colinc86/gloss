import Foundation

public enum HostKind: String, Codable, Sendable, CaseIterable {
    case local
    case ssh
    /// Live web pages, addressed by URL.
    case web
    /// GitHub pull requests, read with the user's token.
    case github
    /// Jira issues and Confluence pages, read with the user's token.
    case atlassian

    /// Served by the app from an API or a web view rather than from a machine's file system; never written to.
    public var isVirtual: Bool {
        switch self {
        case .local, .ssh: false
        case .web, .github, .atlassian: true
        }
    }
}

/// Where a host entry came from.
public enum HostOrigin: String, Codable, Sendable {
    case local
    /// A `Host` alias read from `~/.ssh/config`; ssh resolves everything about it.
    case sshConfig = "ssh_config"
    /// Added in the app; `HostOptions` say how to reach it.
    case manual
}

/// Connection details for an app-added host, passed to ssh as `-o` options. Empty fields fall back to ssh's own
/// defaults and config, so an alias that also exists in `~/.ssh/config` keeps working.
public struct HostOptions: Codable, Sendable, Hashable {
    public var hostName: String = ""
    public var user: String = ""
    public var port: Int?
    public var identityFile: String = ""
    /// The `~/.ssh/config` alias, when the host's name had to differ from it: an alias called `github`, `atlassian`
    /// or `web` is listed as `github-ssh` (those names are the integration hosts'), and ssh is still given `github`.
    public var alias: String?
    /// The integration host's account, for the `atlassian` host: the site its documents' paths are about.
    public var site: String?

    public init(hostName: String = "", user: String = "", port: Int? = nil, identityFile: String = "", alias: String? = nil, site: String? = nil) {
        self.site = site
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.alias = alias
    }

    public var isEmpty: Bool { hostName.isEmpty && user.isEmpty && port == nil && identityFile.isEmpty }
}

public struct Host: Identifiable, Hashable, Codable, Sendable {
    public var id: HostID
    /// `local` or the ssh destination (an alias from `~/.ssh/config`, or whatever the user named it in the app).
    public var name: String
    public var kind: HostKind
    public var lastConnectedAt: Date?
    public var origin: HostOrigin = .sshConfig
    public var options: HostOptions?

    public init(id: HostID, name: String, kind: HostKind, lastConnectedAt: Date? = nil, origin: HostOrigin = .sshConfig, options: HostOptions? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.origin = origin
        self.options = options
        self.lastConnectedAt = lastConnectedAt
    }

    public var isLocal: Bool { kind == .local }
    public var isVirtual: Bool { kind.isVirtual }
}

/// A live page visited, for the explorer's Web section and Open Quickly: its document key, the host it was reached
/// on, and the page's title once it loaded.
public struct WebPage: Identifiable, Hashable, Codable, Sendable {
    public var url: String
    public var hostID: HostID
    public var title: String?
    public var lastVisitedAt: Date
    public var pinned: Bool

    public var id: String { hostID.rawValue + " " + url }

    public init(url: String, hostID: HostID, title: String? = nil, lastVisitedAt: Date, pinned: Bool = false) {
        self.url = url
        self.hostID = hostID
        self.title = title
        self.lastVisitedAt = lastVisitedAt
        self.pinned = pinned
    }
}

public struct Root: Identifiable, Hashable, Codable, Sendable {
    public var id: RootID
    public var hostID: HostID
    public var path: String
    public var lastOpenedAt: Date
    public var pinned: Bool

    public init(id: RootID, hostID: HostID, path: String, lastOpenedAt: Date, pinned: Bool) {
        self.id = id
        self.hostID = hostID
        self.path = path
        self.lastOpenedAt = lastOpenedAt
        self.pinned = pinned
    }
}

public enum DocumentKind: String, Codable, Sendable, CaseIterable {
    case text
    case code
    case markdown
    case image
    case pdf
    case csv
    /// Anything else: shown with QuickLook, only whole-file notes.
    case file
    /// A live web page; the path is its URL.
    case web

    /// The `Source:` value in a context packet.
    public var packetSource: String { rawValue }
}

/// The identity of a file as last seen: used to detect changes before a save and after a reload.
public struct Fingerprint: Hashable, Codable, Sendable {
    public var mtime: Date?
    public var size: Int64?
    /// SHA-256 of the bytes, lowercase hex. Optional because a stat alone does not provide it.
    public var hash: String?

    public init(mtime: Date? = nil, size: Int64? = nil, hash: String? = nil) {
        self.mtime = mtime
        self.size = size
        self.hash = hash
    }

    /// True when `other` may describe different bytes: size or mtime differ, or hashes differ when both known.
    public func mayDiffer(from other: Fingerprint) -> Bool {
        if let hash, let otherHash = other.hash { return hash != otherHash }
        return size != other.size || mtime != other.mtime
    }
}

public struct Document: Identifiable, Hashable, Codable, Sendable {
    public var id: DocumentID
    public var hostID: HostID
    public var path: String
    public var kind: DocumentKind
    public var fingerprint: Fingerprint

    public init(id: DocumentID, hostID: HostID, path: String, kind: DocumentKind, fingerprint: Fingerprint) {
        self.id = id
        self.hostID = hostID
        self.path = path
        self.kind = kind
        self.fingerprint = fingerprint
    }

    public var fileName: String { Self.displayName(of: path) }

    /// The last path component of a file, or host and path of a web page (`localhost:3000/dashboard`).
    public static func displayName(of path: String) -> String {
        guard DocumentKindDetector.isWebURL(path), let url = URL(string: path) else { return (path as NSString).lastPathComponent }
        let host = (url.host() ?? "") + (url.port.map { ":\($0)" } ?? "")
        let trimmed = url.path == "/" ? "" : url.path
        return host + trimmed + (url.query.map { "?" + $0 } ?? "")
    }
}

public enum NoteState: String, Codable, Sendable, CaseIterable {
    case draft
    case sent
    case resolved
    case orphaned
}

/// Palette key, themed by the UI.
public enum NoteColor: String, Codable, Sendable, CaseIterable {
    case yellow
    case green
    case blue
    case pink
    case purple
    case orange
}

public struct Note: Identifiable, Hashable, Codable, Sendable {
    public var id: NoteID
    public var documentID: DocumentID
    public var anchor: Anchor
    public var body: String
    public var state: NoteState
    public var color: NoteColor
    public var createdAt: Date
    public var updatedAt: Date
    /// What the agent reported through `resolve_note`, when it did.
    public var resolveOutcome: ResolveOutcome?
    public var resolveMessage: String?
    /// The agent that wrote the note to ask the user something (`ask_user`); nil for the user's own notes.
    public var author: String?
    /// The agent that resolved the note through MCP (its client's name); nil when the user resolved it.
    public var resolveAgent: String?
    /// An agent asked the user something (`reply_to_note` asking, or `ask_user`) and no answer has been sent yet.
    public var waitingOnUser: Bool
    /// The user wrote a follow-up that hasn't been sent; read from the note's messages by the store's queries.
    public var hasUnsentFollowUps: Bool
    /// Where the note was before it first moved, for Restore Original Place; nil for a note that never moved.
    public var originalAnchor: Anchor?

    public init(
        id: NoteID, documentID: DocumentID, anchor: Anchor, body: String, state: NoteState,
        color: NoteColor, createdAt: Date, updatedAt: Date, resolveOutcome: ResolveOutcome? = nil, resolveMessage: String? = nil,
        author: String? = nil, resolveAgent: String? = nil, waitingOnUser: Bool = false, hasUnsentFollowUps: Bool = false,
        originalAnchor: Anchor? = nil
    ) {
        self.id = id
        self.documentID = documentID
        self.anchor = anchor
        self.body = body
        self.state = state
        self.color = color
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.resolveOutcome = resolveOutcome
        self.resolveMessage = resolveMessage
        self.author = author
        self.resolveAgent = resolveAgent
        self.waitingOnUser = waitingOnUser
        self.hasUnsentFollowUps = hasUnsentFollowUps
        self.originalAnchor = originalAnchor
    }

    /// Notes an agent still has to act on.
    public var isPending: Bool { state == .draft || state == .sent }

    /// The user has to look: an agent asked something, or the note lost its place.
    public var needsAttention: Bool { waitingOnUser || state == .orphaned }
}

/// One turn of a note's thread, after the comment in `Note.body`.
public enum MessageKind: String, Codable, Sendable, CaseIterable {
    /// The user's follow-up.
    case comment
    /// An agent asks the user something; the note waits on the user.
    case question
    /// An agent's answer or report.
    case reply
    /// The note's anchor moved, or its text was removed.
    case moved
}

/// Who wrote a message.
public enum MessageAuthor: Hashable, Sendable {
    case user
    /// An agent, by the name its MCP client gave (`agent` when it gave none).
    case agent(String)
    /// Gloss itself: a removal it found while re-anchoring.
    case app

    /// The `author` column: `user`, the agent's name, or NULL for Gloss.
    public init(stored: String?) {
        switch stored {
        case nil: self = .app
        case Self.userValue?: self = .user
        case let name?: self = .agent(name)
        }
    }

    public var stored: String? {
        switch self {
        case .user: Self.userValue
        case .agent(let name): name
        case .app: nil
        }
    }

    static let userValue = "user"
    /// The name an agent is stored under when its client gave none.
    public static let unnamedAgent = "agent"
}

/// Where a moved note was and is: `meta_json` of a `moved` message.
public struct NoteMove: Codable, Hashable, Sendable {
    public var from: Anchor
    public var to: Anchor
    /// The text was removed; `to` is a point where it was.
    public var removed: Bool

    public init(from: Anchor, to: Anchor, removed: Bool) {
        self.from = from
        self.to = to
        self.removed = removed
    }
}

public struct NoteMessage: Identifiable, Hashable, Sendable {
    public var id: MessageID
    public var noteID: NoteID
    public var author: MessageAuthor
    public var kind: MessageKind
    public var body: String
    public var createdAt: Date
    /// Nil for a follow-up the user hasn't sent yet.
    public var sentAt: Date?
    /// For `moved` messages.
    public var move: NoteMove?

    public init(id: MessageID, noteID: NoteID, author: MessageAuthor, kind: MessageKind, body: String, createdAt: Date, sentAt: Date?, move: NoteMove? = nil) {
        self.id = id
        self.noteID = noteID
        self.author = author
        self.kind = kind
        self.body = body
        self.createdAt = createdAt
        self.sentAt = sentAt
        self.move = move
    }

    public var isSent: Bool { sentAt != nil }
}

/// A new place for a note, worked out by `AnchorRelocator` from the document's current text.
public struct NoteRelocation: Hashable, Sendable {
    public var anchor: Anchor
    /// The text was removed and `anchor` is a point where it was.
    public var removed: Bool

    public init(anchor: Anchor, removed: Bool) {
        self.anchor = anchor
        self.removed = removed
    }
}

public enum AttachmentKind: String, Codable, Sendable {
    case crop
    case pageRender = "page_render"
}

public struct Attachment: Identifiable, Hashable, Codable, Sendable {
    public var id: AttachmentID
    public var noteID: NoteID
    public var kind: AttachmentKind
    public var localPath: String
    public var width: Int
    public var height: Int

    public init(id: AttachmentID, noteID: NoteID, kind: AttachmentKind, localPath: String, width: Int, height: Int) {
        self.id = id
        self.noteID = noteID
        self.kind = kind
        self.localPath = localPath
        self.width = width
        self.height = height
    }
}

/// Outcome an agent reports through `resolve_note`.
public enum ResolveOutcome: String, Codable, Sendable {
    case done
    case skipped
    /// Accepted from agents with older instructions, and stored as a question (`NoteStore.agentReply` asking):
    /// a note is never resolved with it.
    case needsInput = "needs_input"
}

public struct SendSummary: Identifiable, Hashable, Codable, Sendable {
    public var id: SendID
    public var transport: String
    public var targetJSON: String
    public var sentAt: Date
    public var outcome: String

    public init(id: SendID, transport: String, targetJSON: String, sentAt: Date, outcome: String) {
        self.id = id
        self.transport = transport
        self.targetJSON = targetJSON
        self.sentAt = sentAt
        self.outcome = outcome
    }
}

public struct StagedFile: Identifiable, Hashable, Codable, Sendable {
    public var id: StagedFileID
    public var sendID: SendID
    public var hostID: HostID
    public var remotePath: String
    public var expiresAt: Date

    public init(id: StagedFileID, sendID: SendID, hostID: HostID, remotePath: String, expiresAt: Date) {
        self.id = id
        self.sendID = sendID
        self.hostID = hostID
        self.remotePath = remotePath
        self.expiresAt = expiresAt
    }
}

/// A remembered agent target: how to reach one agent session through one transport on one host.
public struct KnownTarget: Identifiable, Hashable, Codable, Sendable {
    public var id: TargetID
    public var hostID: HostID
    public var transport: String
    public var identityJSON: String
    public var label: String
    public var lastUsedAt: Date?

    public init(id: TargetID, hostID: HostID, transport: String, identityJSON: String, label: String, lastUsedAt: Date? = nil) {
        self.id = id
        self.hostID = hostID
        self.transport = transport
        self.identityJSON = identityJSON
        self.label = label
        self.lastUsedAt = lastUsedAt
    }
}
