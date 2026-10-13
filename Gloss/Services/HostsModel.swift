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

        /// What ssh is given: the config alias, which differs from the name for an alias called like an
        /// integration host (`github` listed as `github-ssh`).
        var alias: String { options?.alias ?? name }

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
    private(set) var entries: [Entry] = [Entry(id: .local, name: "local", kind: .local, origin: .local), HostsModel.web, Entry(id: .gloss, name: "gloss", kind: .gloss, origin: .local)]
    /// The open web: always listed after this Mac, for the explorer's Web section (pages, not files).
    static let web = Entry(id: .web, name: "web", kind: .web, origin: .local)
    /// Hosts the app serves itself (a pull request tree, a Jira project) while their key is saved; they need no
    /// connection and appear after this Mac and the web in the host menu.
    private(set) var virtualHosts: [Entry] = []
    private(set) var status: [HostID: Status] = [:]
    /// The latest stage ssh reported while connecting, e.g. "Authenticating as colin…".
    private(set) var progress: [HostID: String] = [:]

    /// What ssh is doing for this host, for the Details popover: the resolved destination, the agent socket in
    /// use, and the last lines ssh wrote. Readable at any time, including mid-connect.
    func diagnostics(for hostID: HostID) async -> String {
        guard let entry = entry(for: hostID), entry.kind == .ssh else { return "" }
        var lines: [String] = ["Host: \(entry.name)" + (entry.origin == .manual ? " (added in Settings)" : " (from ~/.ssh/config)")]
        // The caption the design asks for: an alias listed under another name says what ssh calls it.
        if entry.alias != entry.name { lines.append("ssh alias: \(entry.alias)") }
        if let resolved = await SSHConfig.resolve(entry.alias, options: entry.sshArguments) {
            lines.append("Destination: \(resolved.user.map { $0 + "@" } ?? "")\(resolved.hostName):\(resolved.port)")
            lines.append("Key agent: \(resolved.identityAgent ?? (ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] ?? "none"))")
        }
        if let options = entry.options, !options.isEmpty { lines.append("Options: \(entry.sshArguments.joined(separator: " "))") }
        lines.append("Status: \(status(for: hostID))")
        if let connection = await manager.existingConnection(for: hostID) {
            let stderr = await connection.capturedStderr.split(whereSeparator: \.isNewline).suffix(25)
            if !stderr.isEmpty {
                lines.append("")
                lines.append("ssh output (last \(stderr.count.counted("line"))):")
                lines.append(contentsOf: stderr.map(String.init))
            }
        }
        return lines.joined(separator: "\n")
    }
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
    /// Forwards a reconnect could not set up again.
    @ObservationIgnored var onForwardsLost: (HostID, [SSHForward]) -> Void = { _, _ in }
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
        // Notes in Recently Deleted count: the host stays until they are purged.
        let documents = (try? await noteStore.documentsWithAnyNotes()) ?? []
        for host in (try? await noteStore.hosts()) ?? [] where host.kind == .ssh {
            switch host.origin {
            case .manual:
                list.append(Entry(id: host.id, name: host.name, kind: .ssh, origin: .manual, options: host.options))
            case .sshConfig:
                // The config says `Host github-ssh` and not `Host github`: the row is that alias, not a renamed one.
                if let alias = host.options?.alias, alias != host.name, importsSSHConfigStored, aliases.contains(host.name), !aliases.contains(alias) {
                    try? await noteStore.clearHostAlias(host.id)
                    var cleared = host.options
                    cleared?.alias = nil
                    list.append(Entry(id: host.id, name: host.name, kind: .ssh, origin: .sshConfig, options: cleared))
                    continue
                }
                let stillListed = importsSSHConfigStored && aliases.contains(host.options?.alias ?? host.name)
                let hasNotes = documents.contains { $0.hostID == host.id }
                if stillListed || hasNotes { list.append(Entry(id: host.id, name: host.name, kind: .ssh, origin: .sshConfig, options: host.options)) }
            case .local:
                continue
            }
        }
        let ssh = list.dropFirst().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        entries = [list[0], Self.web, Entry(id: .gloss,name: "gloss",kind: .gloss,origin: .local)] + virtualHosts.filter { $0.id != .gloss }.sorted { $0.name < $1.name } + ssh
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

    /// The notes removing `hostID` deletes, from every document's notes: the panel's own list holds only the
    /// location in front, so a host's notes elsewhere went uncounted and the warning said nothing of them.
    nonisolated static func notesOnHost(_ hostID: HostID, in groups: [DocumentNotes]) -> Int {
        groups.filter { $0.document.hostID == hostID }.reduce(0) { $0 + $1.notes.count }
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
        hostID == .local || hostID.isVirtual ? .connected : (status[hostID] ?? .idle)
    }

    /// Shows or hides a virtual host (GitHub while a token is saved).
    func setVirtualHost(_ hostID: HostID, name: String, kind: HostKind, enabled: Bool) async {
        virtualHosts.removeAll { $0.id == hostID }
        if enabled { virtualHosts.append(Entry(id: hostID, name: name, kind: kind, origin: .local)) }
        await refresh()
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
            let connection = try await manager.connection(for: hostID, alias: entry.alias, options: entry.sshArguments)
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
            status[hostID] = .failed("\(error.userMessage)")
            return nil
        }
    }

    /// Retries with `StrictHostKeyChecking=accept-new` for this host only, after the user agreed.
    func acceptNewHostKey(_ hostID: HostID) async -> String? {
        pendingHostKey = nil
        guard let entry = entry(for: hostID) else { return nil }
        if let connection = try? await manager.connection(for: hostID, alias: entry.alias, connect: false) {
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
        case .forwardsLost(let host, let forwards): onForwardsLost(host, forwards)
        }
    }

    /// SSHError says itself (`LocalizedError` in Remote), wherever it surfaces.
    private func describe(_ error: SSHError) -> String { error.userMessage }
}

/// What the Add Host form accepts. ssh is given the name as its destination and the port as `-o Port=`, so a name with
/// a space or a leading hyphen (which ssh would read as an option) can't work, and a name taken by another host
/// (Gloss's own `local`, `web`, `github`, `atlassian` included) would fail to save.
enum HostForm {
    nonisolated static let reservedNames: Set<String> = Set(HostKind.allCases.filter { $0 != .ssh }.map(\.rawValue))

    /// Why the form can't be saved, for the line under it; nil when it can (an empty name just leaves Save off).
    nonisolated static func problem(name rawName: String, port rawPort: String, taken: Set<String>, hostName: String = "", user: String = "",
                                    identityFile: String = "") -> String? {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        let port = rawPort.trimmingCharacters(in: .whitespaces)
        if name.contains(where: \.isWhitespace) { return "A name can't contain spaces." }
        if name.hasPrefix("-") { return "A name can't start with a hyphen." }
        if reservedNames.contains(name.lowercased()) { return "“\(name)” is a name Gloss uses for itself." }
        if taken.contains(name) { return "Another host is already called “\(name)”." }
        if !port.isEmpty, !(Int(port).map { (1...65535).contains($0) } ?? false) { return "The port is a number from 1 to 65535." }
        // ssh reads each option as a config line: a space ends the value there.
        if hostName.trimmingCharacters(in: .whitespaces).contains(where: \.isWhitespace) { return "A host name can't contain spaces." }
        if user.trimmingCharacters(in: .whitespaces).contains(where: \.isWhitespace) { return "A user name can't contain spaces." }
        if identityFile.contains("\"") { return "An identity file's path can't contain a double quote." }
        return nil
    }
}
