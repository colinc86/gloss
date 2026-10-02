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

    private func perform(_ agent: HookAgent, on hostID: HostID, _ action: (HookInstaller) async throws -> HookInstallReport) async {
        let key = Key(hostID: hostID, agent: agent)
        guard !busy.contains(key), let installer = await installerProvider(hostID) else { return }
        busy.insert(key)
        defer { busy.remove(key) }
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
