import Core
import Foundation

/// Delivers packets to agents running in herdr-core terminals, on this Mac and on every machine the core reaches
/// over its own ssh lines. One socket call lists them all; Gloss needs no connection of its own to a machine to
/// find or prompt its agents (only to stage a packet's images there).
public actor HerdrCoreTransport: Transport {
    public nonisolated let kind = TransportKind.herdrCore

    /// The Gloss host a core machine is, by its ssh target or name; nil when Gloss doesn't know it.
    public typealias HostResolver = @Sendable (HCMachine) async -> HostID?

    private let client: HerdrCoreClient
    private let resolveHost: HostResolver
    private var lastMachines: [HCMachine] = []
    /// Every host this transport has listed agents for, so one whose machine leaves the core drops them too.
    private var everAnswered: Set<HostID> = [.local]

    public init(client: HerdrCoreClient = HerdrCoreClient(), resolveHost: @escaping HostResolver) {
        self.client = client
        self.resolveHost = resolveHost
    }

    public nonisolated var socketPath: String { client.socketPath }

    /// Whether the core's socket is there (the core may still not answer).
    public nonisolated var isInstalled: Bool { FileManager.default.fileExists(atPath: client.socketPath) }

    /// The machines the last listing named, with their line state.
    public var machines: [HCMachine] { lastMachines }

    // MARK: Discovery

    public func discoverTargets() async throws -> [AgentTarget] {
        await discover(within: .seconds(15)).targets
    }

    public func discover(within deadline: Duration) async -> TargetDiscovery {
        // No socket is a definite answer: herdr-core isn't running, so it has no agents anywhere.
        guard isInstalled else {
            lastMachines = []
            return TargetDiscovery(targets: [], answered: nil)
        }
        // A socket that doesn't answer in time says nothing; what it listed before stands.
        guard let list = await withDeadline(deadline, { try? await self.client.list() }) else {
            return TargetDiscovery(targets: [], answered: [])
        }
        lastMachines = list.machines
        var hosts: [String: HostID] = [:]
        for machine in list.machines {
            if let hostID = await resolveHost(machine) { hosts[machine.name] = hostID }
        }
        // This Mac always answers; a machine only while its line is up, so a dropped line keeps its agents listed.
        var answered: Set<HostID> = [.local]
        for machine in list.machines where machine.isConnected {
            if let hostID = hosts[machine.name] { answered.insert(hostID) }
        }
        // A host listed before whose machine the core no longer names (removed, or no longer one of the app's
        // hosts) has no agents here now.
        let named = Set(list.machines.compactMap { hosts[$0.name] })
        answered.formUnion(everAnswered.subtracting(named))
        everAnswered = answered.union(named)
        let targets = list.terminals.compactMap { terminal -> AgentTarget? in
            guard let machine = terminal.machine else { return Self.target(for: terminal, hostID: .local) }
            guard let hostID = hosts[machine] else { return nil }
            return Self.target(for: terminal, hostID: hostID)
        }
        return TargetDiscovery(targets: targets, answered: answered)
    }

    /// The target a terminal is, or nil when it isn't running an agent.
    public nonisolated static func target(for terminal: HCTerminal, hostID: HostID) -> AgentTarget? {
        guard terminal.isLive, let agent = terminal.agent else { return nil }
        let identity = HCTargetIdentity(address: terminal.address, app: agent, name: terminal.name)
        let json = (try? Self.identityEncoder.encode(identity)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let machine = terminal.machine.map { "\($0): " } ?? ""
        let place = terminal.place ?? terminal.currentDirectory.map { PathUtilities.name(of: $0) } ?? ""
        // An agent's title is usually its session's name, which tells two agents in one tab apart.
        let title = terminal.title.flatMap { $0.isEmpty || $0 == place || $0.contains("@") ? nil : $0 }
        let name = [place.isEmpty ? nil : place, title].compactMap { $0 }.joined(separator: " · ")
        let label = "\(machine)\(agent) · \(name.isEmpty ? terminal.address : "\(name) (\(terminal.address))")"
        return AgentTarget(transport: .herdrCore, hostID: hostID, label: label, detail: terminal.currentDirectory, identityJSON: json, status: terminal.status?.state)
    }

    nonisolated static func identity(from target: AgentTarget) -> HCTargetIdentity? {
        try? JSONDecoder().decode(HCTargetIdentity.self, from: Data(target.identityJSON.utf8))
    }

    // MARK: Delivery

    public func deliver(_ packet: Packet, attachments: [StagedAttachment], to target: AgentTarget) async throws -> DeliveryReceipt {
        guard let identity = Self.identity(from: target) else { throw DeliveryError.targetUnavailable("not a herdr-core terminal") }
        guard isInstalled else { throw DeliveryError.targetUnavailable("herdr-core is not running") }
        do {
            try await client.send(identity.address, text: packet.text)
        } catch let error as HerdrCoreError {
            throw Self.map(error)
        } catch HerdrError.requestTooLarge {
            throw DeliveryError.packetTooLarge(limit: HerdrError.lineLimit)
        } catch HerdrError.timedOut {
            throw DeliveryError.failed("herdr-core did not finish typing the notes in time; check the terminal before sending again")
        } catch let error as HerdrError {
            throw DeliveryError.targetUnavailable(error.localizedDescription)
        }
        return DeliveryReceipt(detail: "typed into \(identity.address)")
    }

    nonisolated static func map(_ error: HerdrCoreError) -> DeliveryError {
        switch error {
        case .server(let kind, let message):
            switch kind {
            case "blocked": .agentBlocked("The agent is waiting on a prompt of its own; answer it, then send again")
            case "not_found", "finished", "unavailable", "needs_target": .targetUnavailable(message)
            default: .failed(message.isEmpty ? kind : message)
            }
        default: .failed(error.localizedDescription)
        }
    }
}
