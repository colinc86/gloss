import Core
import Foundation
import Testing
@testable import Gloss

/// Holds discovery back until the test opens it.
actor DiscoveryGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrived = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        arrived = true
        arrivalWaiters.forEach { $0.resume() }
        arrivalWaiters = []
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Returns once discovery has reached the gate.
    func reached() async {
        if arrived { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Lists whatever agents it is given, once its gate (if any) opens, as a transport does while discovering.
final class ListedTransport: Transport, @unchecked Sendable {
    let kind: TransportKind
    var targets: [AgentTarget]
    let gate: DiscoveryGate?

    init(_ kind: TransportKind, _ targets: [AgentTarget], gate: DiscoveryGate? = nil) {
        self.kind = kind
        self.targets = targets
        self.gate = gate
    }

    func discoverTargets() async throws -> [AgentTarget] {
        let listed = targets
        await gate?.wait()
        return listed
    }

    func deliver(_ packet: Packet, attachments: [StagedAttachment], to target: AgentTarget) async throws -> DeliveryReceipt {
        DeliveryReceipt()
    }
}

/// Which agent a folder picks: the one chosen there, else the one working in it.
@MainActor
struct FolderTargetTests {
    private static let box = HostID(rawValue: "h_box")

    private func agent(_ transport: TransportKind, _ name: String, in directory: String?, host: HostID = .local) -> AgentTarget {
        AgentTarget(transport: transport, hostID: host, label: name, detail: directory, identityJSON: "{\"name\":\"\(name)\",\"path\":\"\(directory ?? "")\"}")
    }

    private func coordinator(_ targets: [AgentTarget], store: NoteStore? = nil) async throws -> SendCoordinator {
        let store = try store ?? NoteStore(database: try AppDatabase.inMemory())
        let kinds = Array(Set(targets.map(\.transport)))
        let transports = kinds.map { kind in ListedTransport(kind, targets.filter { $0.transport == kind }) }
        let coordinator = SendCoordinator(noteStore: store, transports: transports, stagers: [:])
        await coordinator.refreshTargets()
        return coordinator
    }

    @Test func theAgentChosenInTheFolderWins() async throws {
        let herdr = agent(.herdr, "herdr", in: "/work/p")
        let tmux = agent(.tmux, "tmux", in: "/work/p/app")
        let send = try await coordinator([herdr, tmux])
        await send.remember(tmux, forFolder: SendCoordinator.folderKey(hostID: .local, path: "/work/p"))
        #expect(await send.preferredTarget(hostID: .local, path: "/work/p")?.id == tmux.id, "chosen beats the agent in the folder itself")
    }

    @Test func aChosenTmuxPaneThatMovedStillMatches() async throws {
        let chosen = AgentTarget(transport: .tmux, hostID: .local, label: "main:0.1 · claude", detail: "/work/p", identityJSON: "{\"target\":\"main:0.1\",\"command\":\"claude\",\"path\":\"/work/p\"}")
        let moved = AgentTarget(transport: .tmux, hostID: .local, label: "main:0.1 · node", detail: "/work/p/app", identityJSON: "{\"target\":\"main:0.1\",\"command\":\"node\",\"path\":\"/work/p/app\"}")
        let herdr = agent(.herdr, "herdr", in: "/work/p")
        let send = try await coordinator([moved, herdr])
        await send.remember(chosen, forFolder: SendCoordinator.folderKey(hostID: .local, path: "/work/p"))
        #expect(await send.preferredTarget(hostID: .local, path: "/work/p")?.id == moved.id, "the chosen agent's transport beats the folder match")
    }

    @Test func withoutAChoiceTheAgentWorkingInTheFolderIsPicked() async throws {
        let parent = agent(.herdr, "parent", in: "/work")
        let inside = agent(.herdr, "inside", in: "/work/p/app")
        let exact = agent(.opencode, "exact", in: "/work/p")
        let elsewhere = agent(.herdr, "elsewhere", in: "/other")
        let send = try await coordinator([parent, inside, exact, elsewhere])
        #expect(await send.preferredTarget(hostID: .local, path: "/work/p")?.id == exact.id, "the folder itself beats delivery priority")
        #expect(await send.preferredTarget(hostID: .local, path: "/work/p/app")?.id == inside.id)
        #expect(await send.preferredTarget(hostID: .local, path: "/work/q") == nil, "an agent in a parent folder is not picked")

        let subfolders = try await coordinator([agent(.opencode, "opencode", in: "/work/p/a"), agent(.tmux, "tmux", in: "/work/p/b"), elsewhere])
        #expect(await subfolders.preferredTarget(hostID: .local, path: "/work/p")?.label == "opencode", "then delivery priority")
    }

    @Test func spellingsOfTheFolderMatch() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "gloss-folder-\(UUID().uuidString)")
        let real = base.appending(path: "real")
        let link = base.appending(path: "link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(SendCoordinator.folderKey(hostID: .local, path: link.path + "/") == SendCoordinator.folderKey(hostID: .local, path: real.path))
        #expect(SendCoordinator.folderKey(hostID: .local, path: real.path + "/./") == SendCoordinator.folderKey(hostID: .local, path: real.path))
        #expect(SendCoordinator.folderKey(hostID: Self.box, path: "/home/me/p/") == SendCoordinator.folderKey(hostID: Self.box, path: "/home/me/p"))

        let exact = agent(.tmux, "exact", in: real.path)
        let inside = agent(.herdr, "inside", in: real.path + "/app")
        let chosen = agent(.opencode, "chosen", in: real.path + "/docs")
        let send = try await coordinator([exact, inside, chosen])
        #expect(await send.preferredTarget(hostID: .local, path: link.path + "/")?.id == exact.id, "the folder itself, through the symlink")
        await send.remember(chosen, forFolder: SendCoordinator.folderKey(hostID: .local, path: link.path + "/"))
        #expect(await send.preferredTarget(hostID: .local, path: real.path)?.id == chosen.id)
    }

    @Test func remoteFoldersPickAgentsOnTheirHost() async throws {
        let local = agent(.herdr, "local", in: "/home/me/p")
        let remote = agent(.tmux, "remote", in: "/home/me/p/app", host: Self.box)
        let send = try await coordinator([local, remote])
        #expect(await send.preferredTarget(hostID: Self.box, path: "/home/me/p")?.id == remote.id)
        #expect(await send.preferredTarget(hostID: .local, path: "/home/me/p")?.id == local.id)
        #expect(await send.preferredTarget(hostID: HostID(rawValue: "h_other"), path: "/home/me/p") == nil)
    }

    @Test func theClipboardAndNewSessionsAreNeverPicked() async throws {
        let newSession = agent(.opencode, "New session", in: "http://127.0.0.1:4096")
        let send = try await coordinator([ClipboardTransport.target, newSession])
        #expect(await send.preferredTarget(hostID: .local, path: "/") == nil)
        #expect(await send.preferredTarget(hostID: .local, path: "/work/p") == nil)
    }

    /// At launch the folder opens while discovery is still under way; the agents it finds still pick the folder's
    /// agent, over the one used last in another folder.
    @Test func agentsFoundAfterTheFolderOpensPickItsAgent() async throws {
        let store = try NoteStore(database: try AppDatabase.inMemory())
        let last = agent(.herdr, "last", in: "/other")
        let here = agent(.tmux, "here", in: "/work/p")
        let json = try #require(String(data: try JSONEncoder().encode(last), encoding: .utf8))
        try await store.setSetting("send.lastTarget", json)
        let gate = DiscoveryGate()
        let send = SendCoordinator(noteStore: store, transports: [ListedTransport(.herdr, [last]), ListedTransport(.tmux, [here], gate: gate)], stagers: [:])
        let discovery = Task { await send.refreshTargets() }
        await gate.reached()
        send.currentFolder = { (.local, "/work/p") }
        await send.folderBecameCurrent()
        #expect(send.lastTarget == nil, "nothing to pick from yet")
        await gate.open()
        await discovery.value
        #expect(send.lastTarget?.id == here.id)
    }

    /// Only a folder coming forward picks: a later refresh keeps a target set meanwhile, as follow mode or a choice
    /// whose folder didn't open sets it.
    @Test func aRefreshKeepsATargetSetSinceThePick() async throws {
        let elsewhere = agent(.herdr, "elsewhere", in: "/other")
        let here = agent(.tmux, "here", in: "/work/p")
        let send = try await coordinator([elsewhere, here])
        send.currentFolder = { (.local, "/work/p") }
        await send.folderBecameCurrent()
        #expect(send.lastTarget?.id == here.id)
        send.rememberTarget(elsewhere)
        await send.refreshTargets()
        #expect(send.lastTarget?.id == elsewhere.id)
        await send.folderBecameCurrent()
        #expect(send.lastTarget?.id == here.id, "coming back to the folder picks its agent again")
    }

    /// A refresh asked for while one runs looks again, so an agent that appeared meanwhile is listed.
    @Test func aRefreshDuringDiscoveryLooksAgain() async throws {
        let store = try NoteStore(database: try AppDatabase.inMemory())
        let gate = DiscoveryGate()
        let transport = ListedTransport(.tmux, [], gate: gate)
        let send = SendCoordinator(noteStore: store, transports: [transport], stagers: [:])
        let first = Task { await send.refreshTargets() }
        await gate.reached()
        transport.targets = [agent(.tmux, "new", in: "/work/p")]
        let second = Task { await send.refreshTargets() }
        await Task.yield()
        await gate.open()
        await first.value
        await second.value
        #expect(send.targets.map(\.label) == ["new"])
    }

    @Test func folderKeysSavedBeforeNormalizingAreRewritten() async throws {
        let store = try NoteStore(database: try AppDatabase.inMemory())
        let chosen = agent(.herdr, "chosen", in: "/elsewhere")
        let json = try #require(String(data: try JSONEncoder().encode(["h_local:/work/p/": chosen]), encoding: .utf8))
        try await store.setSetting("send.folderTargets", json)
        let send = try await coordinator([chosen, agent(.tmux, "here", in: "/work/p")], store: store)
        #expect(await send.preferredTarget(hostID: .local, path: "/work/p")?.id == chosen.id)
        let saved = try #require(try await store.setting("send.folderTargets")?.data(using: .utf8))
        #expect(try JSONDecoder().decode([String: AgentTarget].self, from: saved).keys.sorted() == ["h_local:/work/p"])
    }
}

@MainActor struct RecipientSafetyTests {
    @Test func unrelatedAgentsNeverBecomeTheDefaultAndExplicitClipboardIsRemembered() async throws {
        let store = NoteStore(database: try AppDatabase.inMemory())
        let elsewhere = AgentTarget(transport: .tmux, hostID: .local, label: "elsewhere", detail: "/other", identityJSON: "{}")
        let send = SendCoordinator(noteStore: store, transports: [ListedTransport(.tmux, [elsewhere])], stagers: [:])
        var folder = "/review"
        send.currentFolder = { (.local, folder) }
        await send.folderBecameCurrent()
        await send.refreshTargets()
        #expect(send.lastTarget == nil && !send.isTargetAvailable)
        await send.remember(ClipboardTransport.target, forFolder: SendCoordinator.folderKey(hostID: .local, path: folder))
        await send.folderBecameCurrent()
        #expect(send.lastTarget?.transport == .clipboard && send.isTargetAvailable)
        folder = "/another"
        await send.folderBecameCurrent()
        #expect(send.lastTarget == nil)
    }
}
