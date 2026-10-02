import AppKit
import Core
import Foundation
import Observation
import OSLog
import Remote

/// The hosts the explorer can show: `local`, hosts added in Settings, and (when enabled) every concrete alias in
/// `~/.ssh/config`. Connects on demand and registers an SFTP file system with the app when a host comes up.
@MainActor
@Observable
final class HostsModel {
    struct Entry: Identifiable, Hashable {
        var id: HostID
        var name: String
        var kind: HostKind
        var origin: HostOrigin = .sshConfig
        var options: HostOptions?

        var sshArguments: [String] {
            guard let options else { return [] }
            return SSHConnection.arguments(hostName: options.hostName, user: options.user, port: options.port, identityFile: options.identityFile)
        }
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
    private(set) var entries: [Entry] = [Entry(id: .local, name: "local", kind: .local, origin: .local)]
    private(set) var status: [HostID: Status] = [:]
    /// The latest stage ssh reported while connecting, e.g. "Authenticating as colin…".
    private(set) var progress: [HostID: String] = [:]
    /// Whether `~/.ssh/config` aliases are listed (Settings → Hosts).
    var importsSSHConfig = true {
        didSet {
            importsSSHConfigStored = importsSSHConfig
            Task {
                try? await noteStore.setSetting("hosts.importSSHConfig", importsSSHConfig ? "1" : "0")
                await refresh()
            }
        }
    }
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

    /// Rebuilds the list: app-added hosts always, `~/.ssh/config` aliases when imports are on (each alias becomes a
    /// host row once so notes can refer to it), and config-origin rows that have dropped out of the config only
    /// while they still hold documents.
    func refresh() async {
        var aliases: Set<String> = []
        if importsSSHConfigStored {
            for alias in SSHConfig.hostAliases() {
                aliases.insert(alias.alias)
                _ = try? await noteStore.upsertHost(name: alias.alias, kind: .ssh, origin: .sshConfig)
            }
        }
        var list = [Entry(id: .local, name: "local", kind: .local, origin: .local)]
        let documents = (try? await noteStore.documentsWithNotes()) ?? []
        for host in (try? await noteStore.hosts()) ?? [] where host.kind == .ssh {
            switch host.origin {
            case .manual:
                list.append(Entry(id: host.id, name: host.name, kind: .ssh, origin: .manual, options: host.options))
            case .sshConfig:
                let stillListed = importsSSHConfigStored && aliases.contains(host.name)
                let hasNotes = documents.contains { $0.document.hostID == host.id }
                if stillListed || hasNotes { list.append(Entry(id: host.id, name: host.name, kind: .ssh, origin: .sshConfig)) }
            case .local:
                continue
            }
        }
        entries = list.sorted { lhs, rhs in lhs.kind == .local ? true : rhs.kind == .local ? false : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }
    }

    /// Mirror of the setting that `refresh` reads, so the didSet above does not loop.
    @ObservationIgnored private var importsSSHConfigStored = true

    func load() async {
        if let stored = try? await noteStore.setting("hosts.importSSHConfig") {
            importsSSHConfigStored = stored != "0"
            if importsSSHConfig != importsSSHConfigStored { importsSSHConfig = importsSSHConfigStored }
        }
        await refresh()
    }

    /// Adds or edits an app-managed host.
    func save(id: HostID?, name: String, options: HostOptions) async throws {
        _ = try await noteStore.saveHost(id: id, name: name, options: options)
        await refresh()
    }

    /// Removes an app-managed host, its notes included, after disconnecting it.
    func remove(_ hostID: HostID) async throws {
        await disconnect(hostID)
        try await noteStore.deleteHost(hostID)
        await refresh()
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
            let connection = try await manager.connection(for: hostID, alias: entry.name, options: entry.sshArguments)
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
        case .connecting(let host): status[host] = .connecting; progress[host] = nil
        case .progress(let host, let stage): progress[host] = stage
        case .waitingForAgent(let host): status[host] = .waitingForAgent
        case .connected(let host): status[host] = .connected; progress[host] = nil
        case .reconnecting(let host, let attempt): status[host] = .reconnecting(attempt)
        case .disconnected(let host, _): status[host] = .idle
        case .failed(let host, let error): status[host] = .failed(describe(error))
        }
    }

    private func describe(_ error: SSHError) -> String {
        switch error {
        case .hostKeyProblem: "Host key not known"
        case .hostKeyChanged: "Host key changed; check known_hosts"
        case .authenticationFailed: "Authentication failed: no key was accepted. Check the key, your agent, or the user name."
        case .unreachable: "Host unreachable"
        case .timedOut: "Timed out waiting for ssh"
        case .notConnected: "Not connected"
        case .commandFailed(_, let stderr): stderr
        case .forwardFailed(let message): "Forward failed: \(message)"
        case .other(let message): message
        }
    }
}
