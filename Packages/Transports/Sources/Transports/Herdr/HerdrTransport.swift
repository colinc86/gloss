import Core
import Foundation
import Remote

/// Delivers packets to Herdr agent panes: the local socket, a remote socket forwarded over our ssh master, the
/// `herdr` CLI over the exec channel, or a local `herdr --machine <profile>` as the last resort.
public actor HerdrTransport: Transport {
    public nonisolated let kind = TransportKind.herdr

    private let registry: ConnectionRegistry
    private let localSocketPath: String
    private let forwardDirectory: String
    private let herdrPath: String?
    private var forwards: [HostID: SSHForward] = [:]
    /// The route that last worked per host, so delivery does not re-probe.
    private var routes: [HostID: HerdrRoute] = [:]

    public init(registry: ConnectionRegistry, localSocketPath: String = HerdrEndpoint.localSocketPath(), forwardDirectory: String = SSHConnectionManager.defaultControlDirectory, herdrPath: String? = HerdrTransport.locateHerdr()) {
        self.registry = registry
        self.localSocketPath = localSocketPath
        self.forwardDirectory = forwardDirectory
        self.herdrPath = herdrPath
    }

    public static func locateHerdr() -> String? {
        let candidates = ["/opt/homebrew/bin/herdr", "/usr/local/bin/herdr", (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/herdr")]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/herdr" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The socket path that reaches `hostID`'s Herdr, forwarding it first when needed. Nil when the host has no
    /// socket route (CLI fallbacks cannot stream events).
    public func socketPath(for hostID: HostID) async -> String? {
        if hostID == .local { return FileManager.default.fileExists(atPath: localSocketPath) ? localSocketPath : nil }
        // Always re-check the forward: a reconnected master starts with none, and the cached route would be stale.
        guard let entry = await registry.all().first(where: { $0.hostID == hostID }) else { return nil }
        return await forwardedSocket(for: entry)
    }

    /// Drops cached routes and forwards for a host that disconnected.
    public func forget(_ hostID: HostID) {
        routes[hostID] = nil
        forwards[hostID] = nil
    }

    // MARK: Discovery

    public func discoverTargets() async throws -> [AgentTarget] {
        var targets: [AgentTarget] = []
        if FileManager.default.fileExists(atPath: localSocketPath),
           let agents = try? await HerdrClient(socketPath: localSocketPath).agentList() {
            routes[.local] = .socket(path: localSocketPath)
            targets += agents.compactMap { Self.target(for: $0, hostID: .local, hostLabel: nil) }
        }
        for entry in await registry.all() {
            guard let (route, agents) = await discover(on: entry) else { continue }
            routes[entry.hostID] = route
            targets += agents.compactMap { Self.target(for: $0, hostID: entry.hostID, hostLabel: entry.alias) }
        }
        return targets
    }

    /// Tries the forwarded socket, then the CLI over exec, then a local machine profile.
    private func discover(on entry: ConnectionRegistry.Entry) async -> (HerdrRoute, [HerdrAgentInfo])? {
        if let path = await forwardedSocket(for: entry), let agents = try? await HerdrClient(socketPath: path).agentList() {
            return (.socket(path: path), agents)
        }
        if let tools = try? await entry.connection.tools(), tools.herdr,
           let result = try? await entry.connection.exec("herdr agent list", timeout: .seconds(10)), result.exitStatus == 0,
           let agents = try? Self.agents(fromCLIOutput: result.stdout) {
            return (.exec, agents)
        }
        if let profile = await machineProfile(matching: entry.alias),
           let output = try? await runLocalHerdr(["--machine", profile, "agent", "list"]),
           let agents = try? Self.agents(fromCLIOutput: output) {
            return (.machine(profile: profile), agents)
        }
        return nil
    }

    /// Forwards the host's Herdr socket to `<forwardDirectory>/<short host id>-herdr.sock` once per connection.
    private func forwardedSocket(for entry: ConnectionRegistry.Entry) async -> String? {
        guard let tools = try? await entry.connection.tools(), !tools.home.isEmpty else { return nil }
        let local = (forwardDirectory as NSString).appendingPathComponent("\(String(entry.hostID.rawValue.suffix(10)).lowercased())-herdr.sock")
        let remote = PathUtilities.join(tools.home, ".config/herdr/herdr.sock")
        if let existing = forwards[entry.hostID], await entry.connection.activeForwards.contains(existing) { return local }
        guard let forward = try? await entry.connection.forwardLocalSocket(local: local, remote: remote) else { return nil }
        forwards[entry.hostID] = forward
        return local
    }

    nonisolated static func agents(fromCLIOutput data: Data) throws -> [HerdrAgentInfo] {
        // The CLI prints the same envelope the socket does: {"id":"cli:agent:list","result":{"type":"agent_list","agents":[...]}}
        guard let line = data.split(separator: 0x0A).first(where: { !$0.isEmpty }) else { return [] }
        let result = try HerdrClient.result(from: Data(line))
        return try HerdrClient.decode([HerdrAgentInfo].self, from: result["agents"] ?? [])
    }

    private func machineProfile(matching alias: String) async -> String? {
        guard let output = try? await runLocalHerdr(["machine", "list", "--json"]),
              let list = try? JSONSerialization.jsonObject(with: output) as? [[String: Any]] else { return nil }
        return list.first { ($0["target"] as? String) == alias || ($0["label"] as? String) == alias }.flatMap { $0["label"] as? String ?? $0["target"] as? String }
    }

    private func runLocalHerdr(_ arguments: [String]) async throws -> Data {
        guard let herdrPath else { throw DeliveryError.targetUnavailable("herdr is not installed") }
        let process = try ChildProcess.launch(ChildProcessSpec(executable: herdrPath, arguments: arguments))
        async let out = process.collectStdout()
        async let err = process.collectStderr()
        let code = try await process.exitCode
        guard code == 0 else { throw DeliveryError.failed(String(decoding: await err, as: UTF8.self)) }
        return await out
    }

    nonisolated static func target(for agent: HerdrAgentInfo, hostID: HostID, hostLabel: String?) -> AgentTarget? {
        guard let kind = agent.agent, !kind.isEmpty else { return nil }
        let identity = HerdrTargetIdentity(paneID: agent.paneID, agent: kind, name: agent.name)
        let json = (try? JSONEncoder().encode(identity)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let title = agent.name ?? agent.terminalTitleStripped ?? agent.currentDirectory.map { PathUtilities.name(of: $0) } ?? ""
        let prefix = hostLabel.map { "\($0): " } ?? ""
        let label = "\(prefix)\(kind) · \(title.isEmpty ? agent.paneID : "\(title) (\(agent.paneID))")"
        return AgentTarget(transport: .herdr, hostID: hostID, label: label, detail: agent.currentDirectory, identityJSON: json, status: agent.agentStatus)
    }

    nonisolated static func identity(from target: AgentTarget) -> HerdrTargetIdentity? {
        guard let data = target.identityJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(HerdrTargetIdentity.self, from: data)
    }

    // MARK: Delivery

    public func deliver(_ packet: Packet, attachments: [StagedAttachment], to target: AgentTarget) async throws -> DeliveryReceipt {
        guard let identity = Self.identity(from: target) else { throw DeliveryError.targetUnavailable("not a Herdr pane") }
        if target.hostID == .local { routes[.local] = .socket(path: localSocketPath) }
        guard let route = routes[target.hostID] else { throw DeliveryError.targetUnavailable("host has no Herdr route; refresh targets") }
        do {
            switch route {
            case .socket(let path):
                _ = try await HerdrClient(socketPath: path).prompt(target: identity.paneID, text: packet.text)
            case .exec:
                guard let connection = await registry.connection(for: target.hostID) else { throw DeliveryError.targetUnavailable("host is not connected") }
                let result = try await connection.exec("herdr agent prompt \(ShellQuote.single(identity.paneID)) \(ShellQuote.single(packet.text))", timeout: .seconds(30))
                guard result.exitStatus == 0 else { throw Self.map(cliOutput: result.stdout, stderr: result.stderrText) }
            case .machine(let profile):
                _ = try await runLocalHerdr(["--machine", profile, "agent", "prompt", identity.paneID, packet.text])
            }
        } catch let error as HerdrError {
            throw Self.map(error)
        }
        return DeliveryReceipt(detail: "prompted \(identity.paneID)")
    }

    nonisolated static func map(_ error: HerdrError) -> DeliveryError {
        switch error {
        case .server(let code, let message):
            switch code {
            case "agent_blocked": return .agentBlocked("The agent is waiting on a permission prompt")
            case "agent_not_found", "not_found": return .targetUnavailable(message)
            default: return .failed("\(code): \(message)")
            }
        case .requestTooLarge: return .packetTooLarge(limit: HerdrError.lineLimit)
        case .connection(let message): return .targetUnavailable(message)
        default: return .failed("\(error)")
        }
    }

    nonisolated static func map(cliOutput: Data, stderr: String) -> DeliveryError {
        if let line = cliOutput.split(separator: 0x0A).first, (try? HerdrClient.result(from: Data(line))) == nil {
            do { _ = try HerdrClient.result(from: Data(line)) } catch let error as HerdrError { return map(error) } catch {}
        }
        return .failed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
