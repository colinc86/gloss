import AppKit
import Core
import Foundation
import Observation
import OSLog
import Remote

/// The hosts the explorer can show: `local` plus every concrete alias in ssh config. Connects on demand and
/// registers an SFTP file system with the app when a host comes up.
@MainActor
@Observable
final class HostsModel {
    struct Entry: Identifiable, Hashable {
        var id: HostID
        var name: String
        var kind: HostKind
    }

    enum Status: Equatable {
        case idle
        case connecting
        case waitingForAgent
        case connected
        case reconnecting(Int)
        case failed(String)
    }

    private let noteStore: NoteStore
    let manager: SSHConnectionManager
    private(set) var entries: [Entry] = [Entry(id: .local, name: "local", kind: .local)]
    private(set) var status: [HostID: Status] = [:]
    private(set) var pendingHostKey: (hostID: HostID, fingerprint: String?)?
    @ObservationIgnored var onFileSystemReady: (HostID, SFTPFileSystem, SSHConnection) -> Void = { _, _, _ in }
    /// Called when the user disconnects a host, so the app drops its file system and transports forget the host.
    @ObservationIgnored var onDisconnected: (HostID) -> Void = { _ in }
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var fileSystems: [HostID: SFTPFileSystem] = [:]

    init(noteStore: NoteStore, manager: SSHConnectionManager = SSHConnectionManager()) {
        self.noteStore = noteStore
        self.manager = manager
        eventTask = Task { [weak self] in
            for await event in manager.events {
                guard let self else { return }
                self.apply(event)
            }
        }
        // Workspace notifications are posted on the workspace's own center, not the default one.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wake() }
        }
    }

    /// Merges ssh config aliases into the host table and the picker.
    func refresh() async {
        let aliases = SSHConfig.hostAliases()
        var list = [Entry(id: .local, name: "local", kind: .local)]
        for alias in aliases {
            if let host = try? await noteStore.upsertHost(name: alias.alias, kind: .ssh) {
                list.append(Entry(id: host.id, name: host.name, kind: .ssh))
            }
        }
        entries = list
    }

    func entry(for hostID: HostID) -> Entry? {
        entries.first { $0.id == hostID }
    }

    func status(for hostID: HostID) -> Status {
        hostID == .local ? .connected : (status[hostID] ?? .idle)
    }

    /// One-line warnings per host shown under the picker (e.g. a non-atomic save fallback).
    private(set) var warnings: [HostID: String] = [:]

    func noteWarning(_ message: String, for hostID: HostID) {
        warnings[hostID] = message
    }

    /// Connects (reusing a live master) and hands the file system to the app. Returns the remote home directory.
    func connect(_ hostID: HostID) async -> String? {
        guard let entry = entry(for: hostID), entry.kind == .ssh else { return nil }
        do {
            let connection = try await manager.connection(for: hostID, alias: entry.name)
            let fileSystem = fileSystems[hostID] ?? SFTPFileSystem(hostID: hostID, connection: connection)
            fileSystems[hostID] = fileSystem
            try? await noteStore.markHostConnected(hostID)
            onFileSystemReady(hostID, fileSystem, connection)
            return try? await fileSystem.homeDirectory()
        } catch let error as SSHError {
            if case .hostKeyProblem(let fingerprint, true) = error { pendingHostKey = (hostID, fingerprint) }
            status[hostID] = .failed(describe(error))
            Log.transport.error("connect \(entry.name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        } catch {
            status[hostID] = .failed("\(error)")
            return nil
        }
    }

    /// Retries with `StrictHostKeyChecking=accept-new` for this host only, after the user agreed.
    func acceptNewHostKey(_ hostID: HostID) async -> String? {
        pendingHostKey = nil
        guard let entry = entry(for: hostID) else { return nil }
        if let connection = try? await manager.connection(for: hostID, alias: entry.name, connect: false) {
            await connection.setAcceptNewHostKey(true)
        }
        return await connect(hostID)
    }

    func disconnect(_ hostID: HostID) async {
        await fileSystems[hostID]?.channel.close()
        fileSystems[hostID] = nil
        await manager.disconnect(hostID)
        status[hostID] = .idle
        onDisconnected(hostID)
    }

    func disconnectAll() async {
        for hostID in fileSystems.keys { await fileSystems[hostID]?.channel.close() }
        fileSystems = [:]
        await manager.disconnectAll()
    }

    /// Synchronous teardown for process exit; see `AppModel.shutDownSynchronously`.
    func killMasters() {
        manager.killMasters()
    }

    private func wake() {
        Task { await manager.recheckAll() }
    }

    private func apply(_ event: SSHConnectionEvent) {
        switch event {
        case .connecting(let host): status[host] = .connecting
        case .waitingForAgent(let host): status[host] = .waitingForAgent
        case .connected(let host): status[host] = .connected
        case .reconnecting(let host, let attempt): status[host] = .reconnecting(attempt)
        case .disconnected(let host, _): status[host] = .idle
        case .failed(let host, let error): status[host] = .failed(describe(error))
        }
    }

    private func describe(_ error: SSHError) -> String {
        switch error {
        case .hostKeyProblem: "Host key not known"
        case .hostKeyChanged: "Host key changed; check known_hosts"
        case .authenticationFailed: "Authentication failed (is the key in your agent?)"
        case .unreachable: "Host unreachable"
        case .timedOut: "Timed out waiting for ssh"
        case .notConnected: "Not connected"
        case .commandFailed(_, let stderr): stderr
        case .forwardFailed(let message): "Forward failed: \(message)"
        case .other(let message): message
        }
    }
}
