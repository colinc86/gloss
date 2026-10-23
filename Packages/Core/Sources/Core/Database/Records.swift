import Foundation
import GRDB

/// Row types, one per table. Column names are snake_case in SQLite and camelCase here.
/// Domain types in `Models/` are what the rest of the app sees; `NoteStore` converts.
public protocol SnakeCaseRecord: Codable, FetchableRecord, PersistableRecord, Sendable {}

extension SnakeCaseRecord {
    public static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy { .convertFromSnakeCase }
    public static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy { .convertToSnakeCase }
}

public struct HostRecord: SnakeCaseRecord, Identifiable {
    public static let databaseTableName = "host"
    public var id: String
    public var name: String
    public var kind: String
    public var lastConnectedAt: Date?
    public var origin: String = "ssh_config"
    public var optionsJson: String?
}

public struct RootRecord: SnakeCaseRecord, Identifiable {
    public static let databaseTableName = "root"
    public var id: String
    public var hostId: String
    public var path: String
    public var lastOpenedAt: Date
    public var pinned: Bool
}

public struct WebPageRecord: SnakeCaseRecord {
    public static let databaseTableName = "web_page"
    public var url: String
    public var hostId: String
    public var title: String?
    public var lastVisitedAt: Date
    public var pinned: Bool
}

public struct DocumentRecord: SnakeCaseRecord, Identifiable {
    public static let databaseTableName = "document"
    public static let notes = hasMany(NoteRecord.self)
    public var id: String
    public var hostId: String
    public var path: String
    public var kind: String
    public var lastHash: String?
    public var lastMtime: Date?
    public var lastSize: Int64?
    /// The iteration new notes go into (issue #18).
    public var currentIteration: Int = 0
}

public struct NoteRecord: SnakeCaseRecord, Identifiable, Equatable {
    public static let databaseTableName = "note"
    public static let document = belongsTo(DocumentRecord.self)
    public var id: String
    public var documentId: String
    public var anchorJson: String
    public var anchorType: String
    public var body: String
    public var state: String
    public var createdAt: Date
    public var updatedAt: Date
    public var color: String
    public var resolveOutcome: String?
    public var resolveMessage: String?
    /// The state before the note was orphaned; nil otherwise.
    public var previousState: String? = nil
    /// Nil for the user; an agent's name for a question it asked.
    public var author: String? = nil
    /// The agent that resolved the note through MCP; nil when resolved by hand or not resolved.
    public var resolveAgent: String? = nil
    /// An agent asked the user something and the user hasn't sent an answer yet.
    public var waitingOnUser: Bool = false
    /// Where the note was before its first move, for Restore Original; nil until it moves.
    public var originalAnchorJson: String? = nil
    public var originalAnchorType: String? = nil
    /// The anchor as it was when the note last went to an agent, so review can show the lines as sent; nil until
    /// a send is delivered.
    public var sentAnchorJson: String? = nil
    public var sentAnchorType: String? = nil
    /// When the user deleted the note, which put it in Recently Deleted; nil for a note that isn't deleted.
    public var deletedAt: Date? = nil
    /// The document's iteration the note was taken in (issue #18).
    public var iteration: Int = 0
    /// A send that carried the note asked the user to review the result.
    public var reviewRequested: Bool = false
    /// When the user accepted the agent's result; nil until then, and again after the note is sent anew.
    public var acceptedAt: Date? = nil
    public var resolvedAt: Date? = nil
    public var localStateAt: Date? = nil
    public var contributorId: String? = nil
    public var contributorName: String? = nil
    public var publishedAt: Date? = nil
    public var postedToOwner = false
    public var publishedBody: String? = nil
    public var publishedColor: String? = nil
    public var collaborationEventId: String? = nil
    public var collaborationMoveId: String? = nil
    public var collaborationMoveAt: Date? = nil
}

/// One round of notes on a document (issue #18). Keyed by document and number.
public struct IterationRecord: SnakeCaseRecord {
    public static let databaseTableName = "iteration"
    public var documentId: String
    public var number: Int
    public var name: String?
    public var startedAt: Date
    public var endedAt: Date?
    /// The content the iteration's notes were taken on, saved when it ended; nil while it is current, and once pruned.
    public var snapshotHash: String?
    public var gitCommit: String?
}

/// File content kept for an ended iteration, shared by every iteration with the same bytes.
public struct SnapshotRecord: SnakeCaseRecord {
    public static let databaseTableName = "snapshot"
    public var hash: String
    /// zlib-compressed.
    public var data: Data
    /// The uncompressed size.
    public var size: Int64
    public var createdAt: Date
}

public struct NoteMessageRecord: SnakeCaseRecord, Identifiable {
    public static let databaseTableName = "note_message"
    public var id: String
    public var noteId: String
    /// `user`, the agent's name, or nil for Gloss itself (a removal it found on its own).
    public var author: String?
    public var kind: String
    public var body: String
    /// For `moved`: the `NoteMove` as JSON.
    public var metaJson: String?
    public var createdAt: Date
    /// Nil for a user's follow-up until it is sent; set on write for everything else.
    public var sentAt: Date?
    public var agentSentAt: Date? = nil
    public var choicesJson: String? = nil
    public var inReplyTo: String? = nil
    public var selectedOptionsJson: String? = nil
    public var customAnswer: Bool = false
    public var contributorId: String? = nil
    public var contributorName: String? = nil
}

public struct AttachmentRecord: SnakeCaseRecord, Identifiable {
    public static let databaseTableName = "attachment"
    public var id: String
    public var noteId: String
    public var kind: String
    public var localPath: String
    public var width: Int
    public var height: Int
}

public struct SendRecord: SnakeCaseRecord, Identifiable {
    public static let databaseTableName = "send"
    public var id: String
    public var targetJson: String
    public var transport: String
    public var packetText: String
    public var sentAt: Date
    public var outcome: String
    /// The send asked the user to review what the agent did.
    public var review: Bool = false
}

public struct SendNoteRecord: SnakeCaseRecord {
    public static let databaseTableName = "send_note"
    public var sendId: String
    public var noteId: String
}

public struct StagedFileRecord: SnakeCaseRecord, Identifiable {
    public static let databaseTableName = "staged_file"
    public var id: String
    public var sendId: String
    public var hostId: String
    public var remotePath: String
    public var expiresAt: Date
}

public struct TargetRecord: SnakeCaseRecord, Identifiable {
    public static let databaseTableName = "target"
    public var id: String
    public var hostId: String
    public var transport: String
    public var identityJson: String
    public var label: String
    public var lastUsedAt: Date?
}

public struct SettingRecord: SnakeCaseRecord {
    public static let databaseTableName = "setting"
    public var key: String
    public var value: String
}
