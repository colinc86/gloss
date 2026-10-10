import Core
import Foundation
import Observation
import OSLog
import Remote
import Transports

/// Install state of the agents' MCP registrations and the Herdr plugin, locally and on connected hosts, for Settings.
@MainActor
@Observable
final class HooksModel {
    struct Key: Hashable {
        var hostID: HostID
        var agent: HookAgent
    }

    private(set) var status: [Key: HookStatus] = [:]
    private(set) var busy: Set<Key> = []
    private(set) var lastReport: String?
    private(set) var lastError: String?

    @ObservationIgnored var installerProvider: (HostID) async -> HookInstaller? = { _ in nil }
    /// The last operation queued per host. Agents share files on a host (the port file, and the old hook script
    /// while it is being removed), so one operation must not run while another is half done.
    @ObservationIgnored private var queues: [HostID: Task<Void, Never>] = [:]

    func refresh(hosts: [HostID], agents: [HookAgent] = HookAgent.allCases) async {
        for hostID in hosts {
            guard let installer = await installerProvider(hostID) else { continue }
            for agent in agents {
                status[Key(hostID: hostID, agent: agent)] = await installer.status(agent)
            }
        }
    }

    /// The agents checked at launch and when a host connects, for the update toast (#10). The Herdr plugin is left
    /// to Settings: its check runs `herdr`, and "not reachable" only means Herdr isn't running.
    static let launchCheckedAgents: [HookAgent] = [.claude, .codex, .opencode]

    /// Installed agents whose set-up is out of date (an old prompt hook, a stale MCP url), with why, in a stable order.
    var needsUpdate: [(key: Key, reason: String)] {
        status.compactMap { key, status -> (key: Key, reason: String)? in
            guard Self.launchCheckedAgents.contains(key.agent), case .outdated(let reason) = status else { return nil }
            return (key, reason)
        }
        .sorted { ($0.key.hostID.rawValue, $0.key.agent.rawValue) < ($1.key.hostID.rawValue, $1.key.agent.rawValue) }
    }

    /// What the toast is about, so dismissing it holds only until something else needs updating.
    var needsUpdateSignature: String {
        needsUpdate.map { "\($0.key.hostID.rawValue)/\($0.key.agent.rawValue): \($0.reason)" }.joined(separator: "\n")
    }

    /// The signature the person dismissed the toast at.
    var dismissedSignature: String? = UserDefaults.standard.string(forKey: "agents.updateNoticeDismissed") {
        didSet { UserDefaults.standard.set(dismissedSignature, forKey: "agents.updateNoticeDismissed") }
    }

    var showsUpdateNotice: Bool { !needsUpdate.isEmpty && needsUpdateSignature != dismissedSignature }

    func dismissUpdateNotice() { dismissedSignature = needsUpdateSignature }

    func install(_ agent: HookAgent, on hostID: HostID) async {
        await perform(agent, on: hostID) { try await $0.install(agent) }
    }

    func uninstall(_ agent: HookAgent, on hostID: HostID) async {
        await perform(agent, on: hostID) { try await $0.uninstall(agent) }
    }

    private func perform(_ agent: HookAgent, on hostID: HostID, _ action: @escaping @MainActor (HookInstaller) async throws -> HookInstallReport) async {
        let key = Key(hostID: hostID, agent: agent)
        guard !busy.contains(key) else { return }
        busy.insert(key)
        let previous = queues[hostID]
        let task = Task { @MainActor in
            await previous?.value
            await self.run(agent, on: hostID, key: key, action)
        }
        queues[hostID] = task
        await task.value
        if queues[hostID] == task { queues[hostID] = nil }
    }

    private func run(_ agent: HookAgent, on hostID: HostID, key: Key, _ action: @MainActor (HookInstaller) async throws -> HookInstallReport) async {
        defer { busy.remove(key) }
        guard let installer = await installerProvider(hostID) else {
            lastError = "\(agent.displayName): the host is still being probed; try again in a moment"
            return
        }
        lastError = nil
        do {
            let report = try await action(installer)
            var lines = report.changedFiles.isEmpty ? ["Nothing to change."] : ["Updated " + report.changedFiles.map { PathUtilities.name(of: $0) }.joined(separator: ", ") + "."]
            if !report.backups.isEmpty { lines.append("Backups: " + report.backups.map { PathUtilities.name(of: $0) }.joined(separator: ", ")) }
            lines.append(contentsOf: report.notices)
            lastReport = lines.joined(separator: "\n")
            status[key] = await installer.status(agent)
        } catch {
            lastError = "\(agent.displayName): \(error.userMessage)"
            Log.transport.error("hook install failed: \(error, privacy: .public)")
        }
    }
}
