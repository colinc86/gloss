import Core
import Foundation
import Remote

/// One tmux pane, locally or on a host.
public struct TmuxPane: Sendable, Hashable, Codable {
    /// `session:window.pane`, the form every tmux `-t` accepts.
    public var target: String
    public var command: String
    public var path: String

    public init(target: String, command: String, path: String) {
        self.target = target
        self.command = command
        self.path = path
    }

    /// Commands that usually mean an agent is running in the pane; those targets sort first.
    public static let agentCommands: Set<String> = ["claude", "node", "codex", "opencode", "gemini", "pi", "amp", "aider"]

    public var looksLikeAgent: Bool { Self.agentCommands.contains(command) }
}

/// Pastes the packet into a tmux pane with bracketed paste, then presses Enter. Works on this Mac through the tmux
/// binary and on a host through the exec channel; the script is the same in both places.
public actor TmuxTransport: Transport {
    public nonisolated let kind = TransportKind.tmux

    private let registry: ConnectionRegistry
    private let localTmuxPath: String?
    /// `-L <name>`: a private server, used by the tests so no user session or buffer is ever touched.
    private let socketName: String?

    public static let listFormat = "#{session_name}:#{window_index}.#{pane_index}\t#{pane_current_command}\t#{pane_current_path}"

    public init(registry: ConnectionRegistry, localTmuxPath: String? = TmuxTransport.locateTmux(), socketName: String? = nil) {
        self.registry = registry
        self.localTmuxPath = localTmuxPath
        self.socketName = socketName
    }

    public static func locateTmux() -> String? {
        let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/tmux" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: Scripts

    private var tmuxInvocation: String {
        "tmux" + (socketName.map { " -L \(ShellQuote.single($0))" } ?? "")
    }

    nonisolated static func listScript(tmux: String) -> String {
        "\(tmux) list-panes -a -F \(ShellQuote.single(listFormat)) 2>/dev/null"
    }

    /// `-d` deletes the buffer as part of the paste; when the paste itself fails (wrong target) the buffer is
    /// deleted explicitly, so nothing is ever left on the user's tmux server.
    nonisolated static func deliverScript(tmux: String, target: String) -> String {
        let quoted = ShellQuote.single(target)
        return "b=\"cc-$$\"; \(tmux) load-buffer -b \"$b\" - && { \(tmux) paste-buffer -p -d -b \"$b\" -t \(quoted) || { \(tmux) delete-buffer -b \"$b\" 2>/dev/null; false; }; } && \(tmux) send-keys -t \(quoted) Enter"
    }

    nonisolated static func parsePanes(_ text: String) -> [TmuxPane] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, !parts[0].isEmpty else { return nil }
            return TmuxPane(target: parts[0], command: parts[1], path: parts[2])
        }
    }

    // MARK: Transport

    public func discoverTargets() async throws -> [AgentTarget] {
        var targets: [AgentTarget] = []
        if localTmuxPath != nil {
            let output = try await runLocal(Self.listScript(tmux: tmuxInvocation), stdin: nil)
            targets += Self.parsePanes(output.stdoutText).map { Self.target(for: $0, hostID: .local, hostLabel: nil) }
        }
        for entry in await registry.all() {
            guard let tools = try? await entry.connection.tools(), tools.tmux else { continue }
            guard let result = try? await entry.connection.exec(Self.listScript(tmux: tmuxInvocation), timeout: .seconds(10)), result.exitStatus == 0 else { continue }
            targets += Self.parsePanes(result.stdoutText).map { Self.target(for: $0, hostID: entry.hostID, hostLabel: entry.alias) }
        }
        return targets.sorted { lhs, rhs in
            let lhsAgent = Self.pane(from: lhs)?.looksLikeAgent ?? false
            let rhsAgent = Self.pane(from: rhs)?.looksLikeAgent ?? false
            if lhsAgent != rhsAgent { return lhsAgent }
            return lhs.label < rhs.label
        }
    }

    public func deliver(_ packet: Packet, attachments: [StagedAttachment], to target: AgentTarget) async throws -> DeliveryReceipt {
        guard let pane = Self.pane(from: target) else { throw DeliveryError.targetUnavailable("not a tmux pane") }
        let script = Self.deliverScript(tmux: tmuxInvocation, target: pane.target)
        let stdin = Data(packet.text.utf8)
        let result: ExecResult
        if target.hostID == .local {
            result = try await runLocal(script, stdin: stdin)
        } else {
            guard let connection = await registry.connection(for: target.hostID) else { throw DeliveryError.targetUnavailable("host is not connected") }
            result = try await connection.exec(script, stdin: stdin, timeout: .seconds(20))
        }
        guard result.exitStatus == 0 else {
            let text = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.contains("can't find") || text.contains("no server") { throw DeliveryError.targetUnavailable(text) }
            throw DeliveryError.failed(text.isEmpty ? "tmux exited \(result.exitStatus)" : text)
        }
        return DeliveryReceipt(detail: "pasted into \(pane.target)")
    }

    // MARK: Helpers

    static func target(for pane: TmuxPane, hostID: HostID, hostLabel: String?) -> AgentTarget {
        let identity = (try? JSONEncoder().encode(pane)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let where_ = hostLabel.map { "\($0): " } ?? ""
        return AgentTarget(transport: .tmux, hostID: hostID, label: "\(where_)\(pane.target) · \(pane.command)", detail: pane.path, identityJSON: identity)
    }

    static func pane(from target: AgentTarget) -> TmuxPane? {
        guard let data = target.identityJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TmuxPane.self, from: data)
    }

    private func runLocal(_ script: String, stdin: Data?) async throws -> ExecResult {
        guard let localTmuxPath else { throw DeliveryError.targetUnavailable("tmux is not installed") }
        // The script says `tmux`; a PATH entry for its directory makes that resolve to the located binary.
        let directory = (localTmuxPath as NSString).deletingLastPathComponent
        let path = directory + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
        let process = try ChildProcess.launch(ChildProcessSpec(executable: "/bin/sh", arguments: ["-c", script], extraEnvironment: ["PATH": path], stdin: stdin == nil ? .null : .pipe))
        if let stdin {
            try await process.write(stdin)
            process.closeStdin()
        }
        async let out = process.collectStdout()
        async let err = process.collectStderr()
        let code = try await process.exitCode
        return ExecResult(exitStatus: code, stdout: await out, stderr: await err)
    }
}
