import Core
import Foundation
import Testing
import Transports
@testable import Gloss

/// Lists fixed herdr-core agents, as the core would.
final class StaticTransport: Transport, @unchecked Sendable {
    let kind: TransportKind
    let targets: [AgentTarget]
    init(kind: TransportKind, targets: [AgentTarget]) {
        self.kind = kind
        self.targets = targets
    }
    func discoverTargets() async throws -> [AgentTarget] { targets }
    func deliver(_ packet: Packet, attachments: [StagedAttachment], to target: AgentTarget) async throws -> DeliveryReceipt { DeliveryReceipt() }
}

/// herdr-core in the app: live status, folder matching, the agent menu's explanations, and machines as hosts.
@MainActor
struct HerdrCoreAppTests {
    static func agent(_ address: String, status: String?, cwd: String = "/Users/u/app") -> AgentTarget {
        HerdrCoreTransport.target(for: HCTerminal(address: address, status: HCStatus(state: status, app: "claude-code"), cwd: cwd), hostID: .local)!
    }

    @Test func aStatusEventMovesTheListedAgentAndTheChosenOne() async throws {
        let seven = Self.agent("t7", status: "working")
        let eight = Self.agent("t8", status: "idle")
        let send = SendCoordinator(noteStore: NoteStore(database: try AppDatabase.inMemory()), transports: [StaticTransport(kind: .herdrCore, targets: [seven, eight])], stagers: [:])
        await send.refreshTargets()
        send.rememberTarget(seven)
        let watcher = HerdrCoreWatcher(client: HerdrCoreClient(socketPath: "/nonexistent"), send: send)
        var heard: [(String, String?)] = []
        watcher.onStatus = { heard.append(($0, $1)) }
        watcher.apply(.changed(type: "status", address: "t7", status: HCStatus(state: "blocked", app: "claude-code", kind: "permission")))
        #expect(send.targets.first { $0.id == seven.id }?.status == "blocked")
        #expect(send.targets.first { $0.id == eight.id }?.status == "idle")
        #expect(send.lastTarget?.status == "blocked")
        #expect(heard.map(\.0) == ["t7"] && heard.first?.1 == "blocked")
        // A title change says nothing about status.
        watcher.apply(.changed(type: "title", address: "t7", status: nil))
        #expect(send.lastTarget?.status == "blocked")
    }

    @Test func aHerdrCoreAgentWorksInItsFolder() {
        let agent = Self.agent("t7", status: "idle", cwd: "/Users/u/app/Sources")
        #expect(agent.runs(inHost: .local, path: "/Users/u/app"))
        #expect(!agent.runs(inHost: .local, path: "/Users/u/other"))
    }

    @Test func machinesThatCantBeListedSayWhy() {
        let studio = HostID(rawValue: "h_01JSTD00000000000000000000")
        let state = AppModel.HerdrCoreState(running: true, machines: [
            (HCMachine(name: "studio", target: "studio", state: "connected"), studio),
            (HCMachine(name: "den", target: "den", state: "needs_login"), studio),
            (HCMachine(name: "office", target: "office", state: "unreachable"), studio),
            (HCMachine(name: "lab", target: "lab.example", state: "connected"), nil),
        ])
        #expect(TargetPicker.machineProblems(state) == [
            "den: needs login (hc machine login den)",
            "office: unreachable",
            "lab: add it in Settings › Hosts to list its agents",
        ])
    }

    @Test func aMachineIsTheHostItsSSHTargetNames() {
        let studio = HostID(rawValue: "h_01JSTD00000000000000000000")
        let gh = HostID(rawValue: "h_01JGHSSH000000000000000000")
        let entries = [
            HostsModel.Entry(id: .local, name: "local", kind: .local, origin: .local),
            HostsModel.Entry(id: studio, name: "studio", kind: .ssh),
            HostsModel.Entry(id: gh, name: "github-ssh", kind: .ssh, options: HostOptions(alias: "github")),
        ]
        #expect(AppModel.host(for: HCMachine(name: "box", target: "studio"), in: entries) == studio)
        #expect(AppModel.host(for: HCMachine(name: "studio", target: "studio.example.com"), in: entries) == studio)
        #expect(AppModel.host(for: HCMachine(name: "gh", target: "github"), in: entries) == gh)
        #expect(AppModel.host(for: HCMachine(name: "lab", target: "lab"), in: entries) == nil)
    }
}
