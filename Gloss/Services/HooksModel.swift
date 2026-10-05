import Core
import Foundation
import Observation
import OSLog
import Remote
import Transports

/// Install state of the agent hooks and MCP registrations, locally and on connected hosts, for Settings.
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
    /// The last operation queued per host. Agents share files on a host (the hook script, the port file), so an
    /// uninstall of one must not run while another is half installed: it would see no other hooks and delete the
    /// script the first is about to point at.
    @ObservationIgnored private var queues: [HostID: Task<Void, Never>] = [:]

    func refresh(hosts: [HostID]) async {
        for hostID in hosts {
            guard let installer = await installerProvider(hostID) else { continue }
            for agent in HookAgent.allCases {
                status[Key(hostID: hostID, agent: agent)] = await installer.status(agent)
            }
        }
    }

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
            lastError = "\(agent.displayName): \(error)"
            Log.transport.error("hook install failed: \(error, privacy: .public)")
        }
    }
}
