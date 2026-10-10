import Core
import Foundation
import Remote

/// One tmux pane, locally or on a host.
public struct TmuxPane: Sendable, Hashable, Codable {
    /// `session:window.pane`, the form every tmux `-t` accepts, as the pane is named to the user.
    public var target: String
    public var command: String
    public var path: String
    /// tmux's own id for the pane (`%12`): it stays the pane's while the server runs, where `session:window.pane`
    /// moves on to another pane when windows or panes are closed and renumbered. Nil for a pane remembered by an
    /// older build.
    public var paneID: String?

    public init(target: String, command: String, path: String, paneID: String? = nil) {
        self.target = target
        self.command = command
        self.path = path
        self.paneID = paneID
    }

    enum CodingKeys: String, CodingKey {
        case target, command, path
        case paneID = "pane_id"
    }

    /// What a packet is sent to: the pane's id when known, so it never lands in whatever pane took this one's number.
    public var sendTarget: String { paneID ?? target }

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

    public static let listFormat = "#{pane_id}\t#{session_name}:#{window_index}.#{pane_index}\t#{pane_current_command}\t#{pane_current_path}"

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
    ///
    /// The pane is asked what it runs at the moment of sending, and a shell is refused: a pane remembered while an
    /// agent ran in it may now be a bare shell, where the paste and its Enter would run the packet's lines (file
    /// excerpts from any repository among them) as commands.
    nonisolated static func deliverScript(tmux: String, target: String) -> String {
        let quoted = ShellQuote.single(target)
        let shells = shellCommands.sorted().joined(separator: "|")
        let guardShell = "c=$(\(tmux) display-message -p -t \(quoted) '#{pane_current_command}') || exit 1; case \"${c#-}\" in \(shells)) echo \"the pane runs $c, not an agent\" >&2; exit 3 ;; esac; "
        return guardShell + "b=\"cc-$$\"; \(tmux) load-buffer -b \"$b\" - && { \(tmux) paste-buffer -p -d -b \"$b\" -t \(quoted) || { \(tmux) delete-buffer -b \"$b\" 2>/dev/null; false; }; } && \(tmux) send-keys -t \(quoted) Enter"
    }

    /// Commands that are shells: a packet is never typed into one.
    nonisolated static let shellCommands: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "mksh", "tcsh", "csh", "nu", "xonsh", "elvish", "pwsh", "login"]

    nonisolated static func parsePanes(_ text: String) -> [TmuxPane] {
        text.split(separator: "\n").compactMap { line in
            // The path last: it may hold a tab of its own.
            let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4, parts[0].hasPrefix("%"), !parts[1].isEmpty else { return nil }
            return TmuxPane(target: parts[1], command: parts[2], path: parts[3], paneID: parts[0])
        }
    }

    // MARK: Transport

    public func discoverTargets() async throws -> [AgentTarget] {
        await discover(within: .seconds(15)).targets
    }

    /// This Mac and every connected host at once, each with its own deadline, so one slow host holds up only its
    /// own panes. A local listing that fails answers for nothing, keeping what was listed before.
    public func discover(within deadline: Duration) async -> TargetDiscovery {
        let entries = await registry.all()
        let found = await withTaskGroup(of: (HostID, [AgentTarget])?.self) { group in
            group.addTask { await withDeadline(deadline) { await self.localPanes() }.map { (.local, $0) } }
            for entry in entries {
                group.addTask { await withDeadline(deadline) { await self.panes(on: entry) }.map { (entry.hostID, $0) } }
            }
            var found = TargetDiscovery(targets: [], answered: [])
            for await case let (hostID, targets)? in group {
                found.targets += targets
                found.answered?.insert(hostID)
            }
            return found
        }
        return TargetDiscovery(targets: Self.sorted(found.targets), answered: found.answered)
    }

    private func localPanes() async -> [AgentTarget]? {
        guard localTmuxPath != nil else { return [] }
        guard let output = try? await runLocal(Self.listScript(tmux: tmuxInvocation), stdin: nil) else { return nil }
        return Self.parsePanes(output.stdoutText).map { Self.target(for: $0, hostID: .local, hostLabel: nil) }
    }

    private func panes(on entry: ConnectionRegistry.Entry) async -> [AgentTarget] {
        guard let tools = try? await entry.connection.tools(), tools.tmux,
              let result = try? await entry.connection.exec(Self.listScript(tmux: tmuxInvocation), timeout: .seconds(10)), result.exitStatus == 0
        else { return [] }
        return Self.parsePanes(result.stdoutText).map { Self.target(for: $0, hostID: entry.hostID, hostLabel: entry.alias) }
    }

    private static func sorted(_ targets: [AgentTarget]) -> [AgentTarget] {
        targets.sorted { lhs, rhs in
            let lhsAgent = Self.pane(from: lhs)?.looksLikeAgent ?? false
            let rhsAgent = Self.pane(from: rhs)?.looksLikeAgent ?? false
            if lhsAgent != rhsAgent { return lhsAgent }
            return lhs.label < rhs.label
        }
    }

    public func deliver(_ packet: Packet, attachments: [StagedAttachment], to target: AgentTarget) async throws -> DeliveryReceipt {
        guard let pane = Self.pane(from: target) else { throw DeliveryError.targetUnavailable("not a tmux pane") }
        let script = Self.deliverScript(tmux: tmuxInvocation, target: pane.sendTarget)
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
            if text.contains("can't find") || text.contains("no server") || result.exitStatus == 3 { throw DeliveryError.targetUnavailable(text) }
            throw DeliveryError.failed(text.isEmpty ? "tmux exited \(result.exitStatus)" : text)
        }
        return DeliveryReceipt(detail: "pasted into \(pane.target)")
    }

    // MARK: Helpers

    static func target(for pane: TmuxPane, hostID: HostID, hostLabel: String?) -> AgentTarget {
        let identity = (try? Self.identityEncoder.encode(pane)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
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
