import Core
import Foundation

/// A terminal as herdr-core's `terminal.list`, `terminal.get` and event snapshots describe it. Every field but the
/// address is optional so a newer core adding or dropping keys never breaks decoding.
public struct HCTerminal: Codable, Sendable, Hashable, Identifiable {
    /// `t7` on this Mac, `studio/t3` on a machine the core reaches.
    public var address: String
    public var name: String?
    /// `live` or `finished`.
    public var state: String?
    public var status: HCStatus?
    public var foreground: HCForeground?
    /// The folder the terminal started in; `foreground.cwd` is where its program is now.
    public var cwd: String?
    public var title: String?
    public var labels: [String: String]?
    public var argv: [String]?

    public var id: String { address }

    public init(address: String, name: String? = nil, state: String? = "live", status: HCStatus? = nil, foreground: HCForeground? = nil, cwd: String? = nil, title: String? = nil, labels: [String: String]? = nil, argv: [String]? = nil) {
        self.address = address
        self.name = name
        self.state = state
        self.status = status
        self.foreground = foreground
        self.cwd = cwd
        self.title = title
        self.labels = labels
        self.argv = argv
    }

    /// The machine part of the address: nil on this Mac.
    public var machine: String? {
        guard let slash = address.firstIndex(of: "/") else { return nil }
        return String(address[..<slash])
    }

    /// The folder the program in front works in.
    public var currentDirectory: String? { foreground?.cwd ?? cwd }

    public var isLive: Bool { state == nil || state == "live" }

    /// Programs Gloss treats as coding agents when they don't report a status of their own.
    static let knownAgents: Set<String> = ["claude", "claude-code", "codex", "opencode", "gemini", "aider", "amp", "goose", "cursor-agent", "crush", "qwen", "droid"]

    /// The agent running in front, as the core reports it (`claude-code`, `codex`), else the foreground program when
    /// it is a known agent. Nil for a shell, a server, or anything else nobody could hand a prompt to.
    public var agent: String? {
        if let app = status?.app, !app.isEmpty { return Self.canonical(app) }
        let programs = [foreground?.argv?.first, foreground?.name].compactMap { $0 }.map { PathUtilities.name(of: $0) }
        return programs.first { Self.knownAgents.contains($0) }.map(Self.canonical)
    }

    /// One name per agent whether it reported itself or was recognized by its program, so the target's identity
    /// doesn't change when an agent starts or stops reporting (`claude` on the command line is `claude-code`).
    static func canonical(_ name: String) -> String {
        switch name {
        case "claude": "claude-code"
        default: name
        }
    }

    /// What the terminal is called where people see it: its own name, else Herdr's tab (`Gloss / 1`).
    public var place: String? {
        if let name, !name.isEmpty { return name }
        if let place = labels?["where"], !place.isEmpty { return place }
        return nil
    }
}

/// What a program says about itself (OSC 7501): `idle`, `working`, `done`, `blocked`, `error`.
public struct HCStatus: Codable, Sendable, Hashable {
    public var state: String?
    public var app: String?
    public var msg: String?
    /// Why it is blocked: `permission`, `question`, `auth`.
    public var kind: String?

    public init(state: String? = nil, app: String? = nil, msg: String? = nil, kind: String? = nil) {
        self.state = state
        self.app = app
        self.msg = msg
        self.kind = kind
    }
}

public struct HCForeground: Codable, Sendable, Hashable {
    public var name: String?
    public var cwd: String?
    public var argv: [String]?

    public init(name: String? = nil, cwd: String? = nil, argv: [String]? = nil) {
        self.name = name
        self.cwd = cwd
        self.argv = argv
    }
}

/// Another machine the core reaches over its own ssh line.
public struct HCMachine: Codable, Sendable, Hashable, Identifiable {
    /// What the core calls it: `studio` in `studio/t3`.
    public var name: String
    /// What ssh is given, usually an alias in `~/.ssh/config`.
    public var target: String?
    /// `connecting`, `connected`, `needs_login`, `unreachable`.
    public var state: String?
    public var version: String?

    public var id: String { name }

    public init(name: String, target: String? = nil, state: String? = nil, version: String? = nil) {
        self.name = name
        self.target = target
        self.state = state
        self.version = version
    }

    public var isConnected: Bool { state == "connected" }
}

public struct HCList: Sendable, Equatable {
    public var terminals: [HCTerminal]
    public var machines: [HCMachine]
}

/// One notification from `events.subscribe`.
public enum HCEvent: Sendable, Equatable {
    /// `status`, `title`, `labels` and the like: one terminal's facts changed. `status` is set for status events.
    case changed(type: String, address: String, status: HCStatus?)
    /// `created`, `lost`, `restarted`, `finished`, `removed`: the set of terminals changed.
    case lifecycle(type: String, address: String)
    case heartbeat
    /// The subscriber fell behind; what follows is a fresh snapshot.
    case missed
}

/// The target identity a herdr-core agent is reached by.
public struct HCTargetIdentity: Codable, Sendable, Hashable {
    public var address: String
    public var app: String?
    public var name: String?

    public init(address: String, app: String?, name: String?) {
        self.address = address
        self.app = app
        self.name = name
    }
}

public enum HerdrCoreEndpoint {
    /// The core's socket: `~/.local/state/herdr-core/<session>/<session>.sock`, the session `default` unless
    /// `HC_SESSION` names another (honoring `XDG_STATE_HOME`).
    public static func socketPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let session = environment["HC_SESSION"].flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        let state = environment["XDG_STATE_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".local/state")
        return (state as NSString).appendingPathComponent("herdr-core/\(session)/\(session).sock")
    }

    /// The `hc` binary, for the version Settings shows.
    public static func locateCLI() -> String? {
        let home = NSHomeDirectory() as NSString
        let candidates = [home.appendingPathComponent(".local/bin/herdr-core"), home.appendingPathComponent(".local/bin/hc"), "/opt/homebrew/bin/herdr-core", "/usr/local/bin/herdr-core"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

public enum HerdrCoreError: Error, Sendable, Equatable {
    /// An error reply: `kind` is the core's stable `data.kind` (`not_found`, `blocked`, …).
    case server(kind: String, message: String)
    case decoding(String)
    case emptyReply
}

extension HerdrCoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .server(_, let message): message
        case .decoding(let detail): "herdr-core answered in a way Gloss doesn't read (\(detail))"
        case .emptyReply: "herdr-core closed the connection without answering"
        }
    }
}
