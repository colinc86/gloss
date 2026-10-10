import Foundation
import Synchronization

public enum TransportKind: String, Codable, Sendable, CaseIterable {
    case herdr
    case mcp
    case claudeHook = "claude-hook"
    case codexHook = "codex-hook"
    /// The prompt hooks of builds before 0.2, which drained drafts into a prompt's context. Nothing sends through
    /// them now; the cases stay so the send history those builds recorded still reads.
    case promptHook = "prompt-hook"
    case opencode
    case tmux
    case clipboard

    public var displayName: String {
        switch self {
        case .herdr: "Herdr"
        case .mcp: "MCP"
        case .claudeHook: "Claude Code hook"
        case .codexHook: "Codex hook"
        case .promptHook: "Prompt hook"
        case .opencode: "OpenCode"
        case .tmux: "tmux"
        case .clipboard: "Clipboard"
        }
    }
}

/// One agent session a packet can be delivered to. `identityJSON` is what the transport needs to reach it
/// (a Herdr pane id, a tmux target, an OpenCode session); `id` is which agent that is.
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

    /// Which agent this is, from the identity's decoded fields rather than its text: the same agent must match across
    /// launches and discoveries, and neither the JSON's key order nor the fields that change while an agent keeps
    /// running (a Herdr agent's name, a tmux pane's command and folder) say anything about which agent it is.
    public var id: String { "\(transport.rawValue):\(hostID.rawValue):\(Self.identityKey(transport: transport, json: identityJSON))" }

    static func identityKey(transport: TransportKind, json: String) -> String {
        let fields = ((try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]) ?? [:]
        func value(_ key: String) -> String { fields[key].map { "\($0)" } ?? "" }
        let key: String? = switch transport {
        case .herdr: fields["pane_id"] == nil ? nil : "\(value("pane_id")) \(value("agent"))"
        // A pane by tmux's id when it was listed with one: its `session:window.pane` can pass to another pane.
        case .tmux: fields["pane_id"] != nil ? value("pane_id") : fields["target"] == nil ? nil : value("target")
        case .opencode: fields["session_id"] == nil ? nil : "\(value("base_url")) \(value("session_id"))"
        default: nil
        }
        // Anything else is the whole identity, its keys in a fixed order.
        return key ?? fields.keys.sorted().map { "\($0)=\(value($0))" }.joined(separator: " ")
    }
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
    /// The agents on every host this transport reaches, each host given `deadline` of its own, so one slow host
    /// holds up only its own agents.
    func discover(within deadline: Duration) async -> TargetDiscovery
    func deliver(_ packet: Packet, attachments: [StagedAttachment], to target: AgentTarget) async throws -> DeliveryReceipt
}

/// What a discovery found, and which hosts answered in time. A host that didn't say nothing about its agents, so
/// whatever it listed before still stands.
public struct TargetDiscovery: Sendable {
    public var targets: [AgentTarget]
    /// Nil when every host the transport covers answered.
    public var answered: Set<HostID>?

    public init(targets: [AgentTarget], answered: Set<HostID>?) {
        self.targets = targets
        self.answered = answered
    }

    /// Whether this discovery speaks for `hostID`.
    public func answered(_ hostID: HostID) -> Bool { answered?.contains(hostID) ?? true }
}

extension Transport {
    /// One listing for all hosts: it answers for every host, or (failing or too slow) for none.
    public func discover(within deadline: Duration) async -> TargetDiscovery {
        let listed = await withDeadline(deadline) { try? await self.discoverTargets() }
        return listed.map { TargetDiscovery(targets: $0, answered: nil) } ?? TargetDiscovery(targets: [], answered: [])
    }
}

/// `operation`'s result, or nil once `deadline` passes. Returns at the deadline even when the operation ignores
/// cancellation (an ssh exec with its own longer timeout), which a task group would wait out; it carries on alone.
public func withDeadline<T: Sendable>(_ deadline: Duration, _ operation: @escaping @Sendable () async -> T?) async -> T? {
    let resumed = Mutex(false)
    return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let work = Task {
            let value = await operation()
            if resumed.withLock({ done in defer { done = true }; return !done }) { continuation.resume(returning: value) }
        }
        Task {
            try? await Task.sleep(for: deadline)
            if resumed.withLock({ done in defer { done = true }; return !done }) {
                work.cancel()
                continuation.resume(returning: nil)
            }
        }
    }
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
    /// Removes directories `stage` made for a send that was then called off, so nothing is left on the host.
    func discard(_ remoteDirectories: [String]) async
}

extension AttachmentStager {
    public func discard(_ remoteDirectories: [String]) async {}
}

extension Transport {
    /// Writes a target's identity with its keys in a fixed order (`JSONEncoder`'s own order is not fixed), so an
    /// identity that hasn't changed is the same text from one launch to the next.
    public static var identityEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
}
