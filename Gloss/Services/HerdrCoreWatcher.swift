import Core
import Foundation
import Transports

/// Keeps the agent list current from herdr-core's event stream: a status change patches the listed agent in place
/// (the chip's dot moves as the agent works), and a terminal appearing or ending looks for agents again. Waits
/// quietly while herdr-core isn't running and reconnects with a backoff when its stream ends.
@MainActor
final class HerdrCoreWatcher {
    private let client: HerdrCoreClient
    private let send: SendCoordinator
    private var task: Task<Void, Never>?
    private var refresh: Task<Void, Never>?
    /// Every status change, for whoever shows one agent (the follow card).
    var onStatus: (String, String?) -> Void = { _, _ in }
    /// Whether an address could be listed at all: on this Mac, or on a machine that is one of the app's hosts.
    /// Agents on other machines report every turn; their status must not set off a discovery each time.
    var canList: (String) -> Bool = { _ in true }

    init(client: HerdrCoreClient, send: SendCoordinator) {
        self.client = client
        self.send = send
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
        refresh?.cancel()
        refresh = nil
    }

    private func run() async {
        var backoff: Duration = .seconds(1)
        while !Task.isCancelled {
            guard FileManager.default.fileExists(atPath: client.socketPath) else {
                try? await Task.sleep(for: .seconds(15))
                continue
            }
            do {
                for try await event in client.subscribe() {
                    backoff = .seconds(1)
                    apply(event)
                }
            } catch is CancellationError {
                return
            } catch {
                // The core restarted or the line dropped; the next subscription starts from a fresh listing.
            }
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: backoff)
            backoff = min(backoff * 2, .seconds(15))
            refreshSoon()
        }
    }

    func apply(_ event: HCEvent) {
        switch event {
        case .changed(type: "status", let address, let status):
            send.updateStatus(of: .herdrCore, where: { HerdrCoreWatcher.address(of: $0) == address }, to: status?.state)
            onStatus(address, status?.state)
            // A program that starts reporting may be an agent not listed yet; one that stops may no longer be one.
            let listed = send.targets.contains { $0.transport == .herdrCore && Self.address(of: $0) == address }
            if listed ? status == nil : (status?.app != nil && canList(address)) { refreshSoon() }
        case .changed:
            break
        case .lifecycle, .missed:
            refreshSoon()
        case .heartbeat:
            break
        }
    }

    /// One discovery for a burst of events (a tab of agents closing at once).
    private func refreshSoon() {
        guard refresh == nil else { return }
        refresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.refresh = nil
            await self.send.refreshTargets()
        }
    }

    nonisolated static func address(of target: AgentTarget) -> String? {
        guard target.transport == .herdrCore else { return nil }
        return (try? JSONDecoder().decode(HCTargetIdentity.self, from: Data(target.identityJSON.utf8)))?.address
    }
}

extension AppModel {
    /// The Gloss host a herdr-core machine is: the ssh host whose alias is the machine's ssh target, else its name.
    static func host(for machine: HCMachine, in entries: [HostsModel.Entry]) -> HostID? {
        let ssh = entries.filter { $0.kind == .ssh }
        if let target = machine.target, let entry = ssh.first(where: { $0.alias == target }) ?? ssh.first(where: { $0.name == target }) { return entry.id }
        return (ssh.first { $0.alias == machine.name } ?? ssh.first { $0.name == machine.name })?.id
    }
}

