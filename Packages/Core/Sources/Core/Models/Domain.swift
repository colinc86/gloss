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

    public init(hostName: String = "", user: String = "", port: Int? = nil, identityFile: String = "") {
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFile = identityFile
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

    public init(
        id: NoteID, documentID: DocumentID, anchor: Anchor, body: String, state: NoteState,
        color: NoteColor, createdAt: Date, updatedAt: Date, resolveOutcome: ResolveOutcome? = nil, resolveMessage: String? = nil
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
    }

    /// Notes an agent still has to act on.
    public var isPending: Bool { state == .draft || state == .sent }
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
