import Foundation

public enum TransportKind: String, Codable, Sendable, CaseIterable {
    case herdr
    case mcp
    case claudeHook = "claude-hook"
    case codexHook = "codex-hook"
    case opencode
    case tmux
    case clipboard

    public var displayName: String {
        switch self {
        case .herdr: "Herdr"
        case .mcp: "MCP"
        case .claudeHook: "Claude Code hook"
        case .codexHook: "Codex hook"
        case .opencode: "OpenCode"
        case .tmux: "tmux"
        case .clipboard: "Clipboard"
        }
    }
}

/// One agent session a packet can be delivered to. `identityJSON` is what the transport needs to reach it
/// (a Herdr pane id, a tmux target, an OpenCode session); it is also the stable key in the `target` table.
public struct AgentTarget: Identifiable, Hashable, Codable, Sendable {
    public var transport: TransportKind
    public var hostID: HostID
    public var label: String
    public var detail: String?
    public var identityJSON: String
    /// Agent status when the transport can see it (`idle`, `working`, `blocked`, …).
    public var status: String?

    public init(transport: TransportKind, hostID: HostID, label: String, detail: String? = nil, identityJSON: String, status: String? = nil) {
        self.transport = transport
        self.hostID = hostID
        self.label = label
        self.detail = detail
        self.identityJSON = identityJSON
        self.status = status
    }

    public var id: String { "\(transport.rawValue):\(hostID.rawValue):\(identityJSON)" }
}

/// A crop or page render on this Mac, before staging.
public struct LocalAttachment: Hashable, Sendable {
    public var noteID: NoteID
    public var localPath: String

    public init(noteID: NoteID, localPath: String) {
        self.noteID = noteID
        self.localPath = localPath
    }

    public var fileName: String { PathUtilities.name(of: localPath) }
}

/// The same attachment at the path the agent will read it from.
public struct StagedAttachment: Hashable, Sendable {
    public var noteID: NoteID
    public var agentPath: String

    public init(noteID: NoteID, agentPath: String) {
        self.noteID = noteID
        self.agentPath = agentPath
    }
}

public struct DeliveryReceipt: Sendable, Equatable {
    /// Human-readable detail for the send history, e.g. the pane that received the packet.
    public var detail: String?

    public init(detail: String? = nil) {
        self.detail = detail
    }
}

public enum DeliveryError: Error, Sendable, Equatable {
    case targetUnavailable(String)
    case agentBlocked(String)
    case packetTooLarge(limit: Int)
    case failed(String)
}

/// Plain sentences, because these reach the notes panel and the send history verbatim through `"\(error)"`.
extension DeliveryError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case .targetUnavailable(let reason): reason.isEmpty ? "The agent is not reachable" : "The agent is not reachable (\(reason))"
        case .agentBlocked(let reason): reason.isEmpty ? "The agent is waiting on a permission prompt" : reason
        case .packetTooLarge(let limit): "The notes are too long for this transport (limit \(limit.formatted()) bytes); send fewer at once or use the clipboard"
        case .failed(let reason): reason.isEmpty ? "Delivery failed" : reason
        }
    }

    public var errorDescription: String? { description }
}

/// How a packet reaches an agent. Every transport emits the same packet text; only delivery differs.
public protocol Transport: Sendable {
    var kind: TransportKind { get }
    func discoverTargets() async throws -> [AgentTarget]
    func deliver(_ packet: Packet, attachments: [StagedAttachment], to target: AgentTarget) async throws -> DeliveryReceipt
}

public struct StagingResult: Sendable, Equatable {
    public var attachments: [StagedAttachment]
    /// Directories created on the target host, recorded for expiry once the send row exists.
    public var remoteDirectories: [String]

    public init(attachments: [StagedAttachment], remoteDirectories: [String] = []) {
        self.attachments = attachments
        self.remoteDirectories = remoteDirectories
    }

    public static let empty = StagingResult(attachments: [])
}

/// Puts attachments where the target's machine can read them and returns the paths to print in the packet.
public protocol AttachmentStager: Sendable {
    func stage(_ files: [LocalAttachment], for target: AgentTarget, sendID: SendID) async throws -> StagingResult
}
