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
}

public struct NoteRecord: SnakeCaseRecord, Identifiable {
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
