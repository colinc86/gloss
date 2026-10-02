import Core
import Foundation

public enum HerdrError: Error, Sendable, Equatable {
    /// The request line would exceed Herdr's 1 MiB cap; the server would drop the connection silently.
    case requestTooLarge(Int)
    /// The server closed the connection without a reply line.
    case emptyReply
    case server(code: String, message: String)
    case decoding(String)
    /// The subscription fell behind; the consumer must resnapshot and resubscribe.
    case eventsLost
    case connection(String)
    case subscriptionRefused(String)

    public static let lineLimit = 1_048_576
}

/// An agent-managed pane as `agent.list`, `pane.get`, and `agent.prompt` describe it. Every field but the pane id is
/// optional so a newer Herdr adding or dropping keys never breaks decoding.
public struct HerdrAgentInfo: Codable, Sendable, Hashable, Identifiable {
    public var paneID: String
    public var workspaceID: String?
    public var tabID: String?
    public var terminalID: String?
    public var name: String?
    public var agent: String?
    public var agentStatus: String?
    public var cwd: String?
    public var foregroundCwd: String?
    public var focused: Bool?
    public var interactiveReady: Bool?
    public var launchPending: Bool?
    public var terminalTitle: String?
    public var terminalTitleStripped: String?
    public var agentSession: HerdrAgentSession?

    public var id: String { paneID }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id", workspaceID = "workspace_id", tabID = "tab_id", terminalID = "terminal_id"
        case name, agent, agentStatus = "agent_status", cwd, foregroundCwd = "foreground_cwd", focused
        case interactiveReady = "interactive_ready", launchPending = "launch_pending"
        case terminalTitle = "terminal_title", terminalTitleStripped = "terminal_title_stripped", agentSession = "agent_session"
    }

    public init(paneID: String, workspaceID: String? = nil, tabID: String? = nil, agent: String? = nil, agentStatus: String? = nil, cwd: String? = nil, foregroundCwd: String? = nil, name: String? = nil, terminalTitleStripped: String? = nil) {
        self.paneID = paneID
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.agent = agent
        self.agentStatus = agentStatus
        self.cwd = cwd
        self.foregroundCwd = foregroundCwd
        self.name = name
        self.terminalTitleStripped = terminalTitleStripped
    }

    /// The directory the pane's foreground process is in, else the shell's.
    public var currentDirectory: String? { foregroundCwd ?? cwd }
}

public struct HerdrAgentSession: Codable, Sendable, Hashable {
    public var source: String?
    public var agent: String?
    public var kind: String?
    public var value: String?
}

public struct HerdrPong: Codable, Sendable, Equatable {
    public var version: String?
    public var `protocol`: Int?
}

/// One streamed frame from `events.subscribe`: `{"event":"pane_focused","data":{...}}`.
public struct HerdrEvent: Sendable, Equatable {
    public var event: String
    public var paneID: String?
    public var workspaceID: String?
    public var agent: String?
    public var agentStatus: String?

    public init(event: String, paneID: String? = nil, workspaceID: String? = nil, agent: String? = nil, agentStatus: String? = nil) {
        self.event = event
        self.paneID = paneID
        self.workspaceID = workspaceID
        self.agent = agent
        self.agentStatus = agentStatus
    }
}

/// The part of `agent.list` / `pane.get` the transport keys targets by.
public struct HerdrTargetIdentity: Codable, Sendable, Hashable {
    public var paneID: String
    public var agent: String?
    public var name: String?

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id", agent, name
    }

    public init(paneID: String, agent: String?, name: String?) {
        self.paneID = paneID
        self.agent = agent
        self.name = name
    }
}

/// How an endpoint is reached: the local socket, a socket forwarded over our ssh master, or the CLI over exec.
public enum HerdrRoute: Sendable, Hashable {
    case socket(path: String)
    case exec
    case machine(profile: String)
}

public struct HerdrEndpoint: Sendable, Hashable {
    public var hostID: HostID
    public var route: HerdrRoute

    public init(hostID: HostID, route: HerdrRoute) {
        self.hostID = hostID
        self.route = route
    }

    public static func localSocketPath() -> String {
        if let explicit = ProcessInfo.processInfo.environment["HERDR_SOCKET_PATH"], !explicit.isEmpty { return explicit }
        if let session = ProcessInfo.processInfo.environment["HERDR_SESSION"], !session.isEmpty {
            return (NSHomeDirectory() as NSString).appendingPathComponent(".config/herdr/sessions/\(session)/herdr.sock")
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent(".config/herdr/herdr.sock")
    }
}
