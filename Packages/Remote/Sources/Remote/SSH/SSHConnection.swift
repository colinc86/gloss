import Core
import Foundation
import OSLog

public enum SSHError: Error, Sendable, Equatable {
    case hostKeyProblem(fingerprint: String?, offerAcceptNew: Bool)
    case hostKeyChanged(String)
    case authenticationFailed(String)
    case unreachable(String)
    case timedOut
    case notConnected
    case commandFailed(status: Int32, stderr: String)
    case forwardFailed(String)
    case other(String)
}

public enum SSHConnectionEvent: Sendable, Equatable {
    case connecting(HostID)
    case connected(HostID)
    case waitingForAgent(HostID)
    case reconnecting(HostID, attempt: Int)
    case disconnected(HostID, reason: String)
    case failed(HostID, SSHError)
}

public struct ExecResult: Sendable, Equatable {
    public var exitStatus: Int32
    public var stdout: Data
    public var stderr: Data

    public init(exitStatus: Int32, stdout: Data, stderr: Data) {
        self.exitStatus = exitStatus
        self.stdout = stdout
        self.stderr = stderr
    }

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// Tools present on the remote host, probed once per connection.
public struct RemoteTools: Sendable, Equatable {
    public var rg = false
    public var git = false
    public var herdr = false
    public var tmux = false
    public var grep = true
    public var os = ""
    public var home = ""
    public var tmpdir = "/tmp"
    public var uid = ""

    public init() {}
}

/// A forward added to the control connection; cancel it with `SSHConnection.cancel(_:)`.
public struct SSHForward: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case localSocket(local: String, remote: String)
        case remotePort(port: UInt16)
    }

    public var kind: Kind

    var arguments: [String] {
        switch kind {
        case .localSocket(let local, let remote): ["-L", "\(local):\(remote)"]
        case .remotePort(let port): ["-R", "\(port):127.0.0.1:\(port)"]
        }
    }
}

/// One ControlMaster per host. The master runs without BatchMode so an agent prompt (1Password) can appear;
/// every mux client uses BatchMode and ControlMaster=no so it never blocks or spawns a stray master.
public actor SSHConnection {
    public enum State: Sendable, Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int)
        case failed(SSHError)
    }

    private static let log = Logger(subsystem: "com.cnc.Gloss", category: "ssh")
    public static let connectBudget: Duration = .seconds(90)

    public let hostID: HostID
    public let alias: String
    public nonisolated let controlPath: String
    private let sshPath: String
    private let events: AsyncStream<SSHConnectionEvent>.Continuation
    private var master: ChildProcess?
    private var masterStderr = ""
    public private(set) var state: State = .disconnected
    private var forwards: Set<SSHForward> = []
    private var supervisor: Task<Void, Never>?
    private var toolsCache: RemoteTools?
    private var homeCache: String?
    /// After the user accepts a new host key once, the master is launched with accept-new for this host.
    public private(set) var acceptNewHostKey = false

    public func setAcceptNewHostKey(_ accept: Bool) {
        acceptNewHostKey = accept
    }

    init(hostID: HostID, alias: String, controlDirectory: String, sshPath: String, events: AsyncStream<SSHConnectionEvent>.Continuation) {
        self.hostID = hostID
        self.alias = alias
        // ssh binds the socket through "<path>.<16 random chars>", so the whole name must stay well under 104 bytes;
        // a short per-host id does what %C (40 hex chars) cannot.
        self.controlPath = (controlDirectory as NSString).appendingPathComponent(String(hostID.rawValue.suffix(10)).lowercased())
        self.sshPath = sshPath
        self.events = events
    }

    // MARK: argv

    private var clientPrefix: [String] {
        ["-o", "ControlPath=\(controlPath)", "-o", "ControlMaster=no", "-o", "BatchMode=yes", "-o", "LogLevel=ERROR"]
    }

    nonisolated func masterArguments(acceptNew: Bool) -> [String] {
        [
            "-o", "ControlMaster=yes",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlPersist=no",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "StreamLocalBindUnlink=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "StrictHostKeyChecking=\(acceptNew ? "accept-new" : "yes")",
            "-o", "LogLevel=ERROR",
            "-N", "--", alias,
        ]
    }

    // MARK: Lifecycle

    /// Connects (or returns at once when already connected). Waits up to 90 s for the agent prompt.
    public func connect() async throws {
        if state == .connected, await check() { return }
        try await launchMaster()
        startSupervisor()
    }

    private func launchMaster() async throws {
        state = .connecting
        events.yield(.connecting(hostID))
        removeStaleControlSocket()
        let spec = ChildProcessSpec(
            executable: sshPath, arguments: masterArguments(acceptNew: acceptNewHostKey),
            extraEnvironment: ["SSH_ASKPASS_REQUIRE": "never"], stdin: .null
        )
        let process: ChildProcess
        do {
            process = try ChildProcess.launch(spec)
        } catch {
            let failure = SSHError.other("ssh could not start: \(error)")
            state = .failed(failure)
            events.yield(.failed(hostID, failure))
            throw failure
        }
        master = process
        masterStderr = ""
        let stderrTask = Task { [weak self] in
            for await chunk in process.stderr {
                await self?.appendStderr(String(decoding: chunk, as: UTF8.self))
            }
        }
        let deadline = ContinuousClock.now + Self.connectBudget
        var announcedAgentWait = false
        while ContinuousClock.now < deadline {
            if await check() {
                state = .connected
                events.yield(.connected(hostID))
                return
            }
            if !process.isRunning {
                let code = await process.exitCode
                stderrTask.cancel()
                let failure = classify(stderr: masterStderr, status: code)
                state = .failed(failure)
                master = nil
                events.yield(.failed(hostID, failure))
                throw failure
            }
            if !announcedAgentWait, ContinuousClock.now > deadline - Self.connectBudget + .seconds(3) {
                announcedAgentWait = true
                events.yield(.waitingForAgent(hostID))
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        process.terminate()
        state = .failed(.timedOut)
        master = nil
        events.yield(.failed(hostID, .timedOut))
        throw SSHError.timedOut
    }

    private func appendStderr(_ text: String) {
        masterStderr += text
        if masterStderr.count > 8192 { masterStderr = String(masterStderr.suffix(8192)) }
    }

    nonisolated func classify(stderr: String, status: Int32) -> SSHError {
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") { return .hostKeyChanged(text) }
        if text.contains("Host key verification failed") || text.contains("No ED25519 host key is known") || text.contains("host key is known") {
            let fingerprint = text.components(separatedBy: .newlines).first { $0.contains("SHA256:") }
            return .hostKeyProblem(fingerprint: fingerprint, offerAcceptNew: true)
        }
        if text.contains("Permission denied") || text.contains("communication with agent failed") { return .authenticationFailed(text) }
        if text.contains("Could not resolve hostname") || text.contains("Connection timed out") || text.contains("Connection refused") || text.contains("No route to host") {
            return .unreachable(text)
        }
        return .other(text.isEmpty ? "ssh exited with status \(status)" : text)
    }

    private func removeStaleControlSocket() {
        // The real socket path has %C expanded; let ssh tell us whether a master answers, else unlink nothing
        // (we cannot know the expanded name without ssh), and rely on StreamLocalBindUnlink for forwards.
    }

    /// `ssh -O check`: exit 0 when the master answers.
    public func check() async -> Bool {
        guard let process = try? ChildProcess.launch(ChildProcessSpec(executable: sshPath, arguments: clientPrefix + ["-O", "check", "--", alias])) else { return false }
        _ = await process.collectStdout()
        _ = await process.collectStderr()
        return await process.exitCode == 0
    }

    private func startSupervisor() {
        supervisor?.cancel()
        supervisor = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self else { return }
                let alive = await self.waitForMasterExitOrCheckFailure()
                if Task.isCancelled || alive { continue }
                attempt += 1
                await self.noteDisconnected(attempt: attempt)
                let delay = min(30.0, pow(2.0, Double(attempt - 1))) * Double.random(in: 0.8...1.2)
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { return }
                do {
                    try await self.launchMaster()
                    await self.restoreForwards()
                    attempt = 0
                } catch {
                    continue
                }
            }
        }
    }

    /// Returns true when still alive after the periodic check; false when the master is gone.
    private func waitForMasterExitOrCheckFailure() async -> Bool {
        guard let master else { return false }
        let exited = await withTaskGroup(of: Bool.self) { group in
            group.addTask { _ = await master.exitCode; return true }
            group.addTask { try? await Task.sleep(for: .seconds(20)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if exited { return false }
        return await check()
    }

    private func noteDisconnected(attempt: Int) {
        state = .reconnecting(attempt: attempt)
        events.yield(.reconnecting(hostID, attempt: attempt))
        master?.terminate()
        master = nil
        toolsCache = nil
    }

    /// Forces an immediate liveness check, for wake-from-sleep.
    public func recheck() async {
        if state == .connected, !(await check()) {
            master?.terminate()
        }
    }

    public func disconnect() async {
        supervisor?.cancel()
        supervisor = nil
        for forward in forwards { await cancel(forward) }
        _ = try? await runClient(["-O", "exit"], timeout: .seconds(5))
        master?.terminate()
        master = nil
        state = .disconnected
        events.yield(.disconnected(hostID, reason: "closed"))
    }

    // MARK: Exec

    /// Runs `sh -c '<script>'` on the host; stdin data is written then closed.
    public func exec(_ script: String, stdin: Data? = nil, timeout: Duration = .seconds(60)) async throws -> ExecResult {
        guard state == .connected else { throw SSHError.notConnected }
        let process = try ChildProcess.launch(ChildProcessSpec(
            executable: sshPath, arguments: clientPrefix + ["-T", "--", alias, "sh -c " + ShellQuote.single(script)],
            stdin: stdin == nil ? .null : .pipe
        ))
        if let stdin {
            try await process.write(stdin)
            process.closeStdin()
        }
        return try await collect(process, timeout: timeout)
    }

    /// Starts a command whose stdout the caller streams; the caller terminates it to cancel.
    public func execStreaming(_ script: String) throws -> ChildProcess {
        guard state == .connected else { throw SSHError.notConnected }
        return try ChildProcess.launch(ChildProcessSpec(executable: sshPath, arguments: clientPrefix + ["-T", "--", alias, "sh -c " + ShellQuote.single(script)]))
    }

    /// Opens the `sftp` subsystem on the control connection; the SFTP client speaks over its pipes.
    public func openSFTPSubsystem() throws -> ChildProcess {
        guard state == .connected else { throw SSHError.notConnected }
        return try ChildProcess.launch(ChildProcessSpec(executable: sshPath, arguments: clientPrefix + ["-T", "-s", "--", alias, "sftp"], stdin: .pipe))
    }

    private func runClient(_ arguments: [String], timeout: Duration) async throws -> ExecResult {
        let process = try ChildProcess.launch(ChildProcessSpec(executable: sshPath, arguments: clientPrefix + arguments + ["--", alias]))
        return try await collect(process, timeout: timeout)
    }

    private func collect(_ process: ChildProcess, timeout: Duration) async throws -> ExecResult {
        async let out = process.collectStdout()
        async let err = process.collectStderr()
        let code = await withTaskGroup(of: Int32?.self) { group in
            group.addTask { await process.exitCode }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let code else {
            process.terminate()
            throw SSHError.timedOut
        }
        return ExecResult(exitStatus: code, stdout: await out, stderr: await err)
    }

    // MARK: Forwards

    public func forwardLocalSocket(local: String, remote: String) async throws -> SSHForward {
        let forward = SSHForward(kind: .localSocket(local: local, remote: remote))
        try await add(forward)
        return forward
    }

    public func forwardRemotePort(_ port: UInt16) async throws -> SSHForward {
        let forward = SSHForward(kind: .remotePort(port: port))
        try await add(forward)
        return forward
    }

    private func add(_ forward: SSHForward) async throws {
        guard state == .connected else { throw SSHError.notConnected }
        let result = try await runClient(["-O", "forward"] + forward.arguments, timeout: .seconds(15))
        guard result.exitStatus == 0 else { throw SSHError.forwardFailed(result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)) }
        forwards.insert(forward)
    }

    public func cancel(_ forward: SSHForward) async {
        forwards.remove(forward)
        _ = try? await runClient(["-O", "cancel"] + forward.arguments, timeout: .seconds(15))
    }

    private func restoreForwards() async {
        let pending = forwards
        forwards = []
        for forward in pending {
            try? await add(forward)
        }
    }

    public var activeForwards: Set<SSHForward> { forwards }

    // MARK: Probe

    public static let probeScript = """
    for t in rg git herdr tmux grep; do if command -v "$t" >/dev/null 2>&1; then printf '%s=1\\n' "$t"; else printf '%s=0\\n' "$t"; fi; done
    printf 'os=%s\\n' "$(uname -s)"; printf 'home=%s\\n' "$HOME"; printf 'tmpdir=%s\\n' "${TMPDIR:-/tmp}"; printf 'uid=%s\\n' "$(id -u)"
    """

    public func tools() async throws -> RemoteTools {
        if let toolsCache { return toolsCache }
        let result = try await exec(Self.probeScript, timeout: .seconds(30))
        var tools = RemoteTools()
        for line in result.stdoutText.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "rg": tools.rg = parts[1] == "1"
            case "git": tools.git = parts[1] == "1"
            case "herdr": tools.herdr = parts[1] == "1"
            case "tmux": tools.tmux = parts[1] == "1"
            case "grep": tools.grep = parts[1] == "1"
            case "os": tools.os = parts[1]
            case "home": tools.home = parts[1]
            case "tmpdir": tools.tmpdir = parts[1]
            case "uid": tools.uid = parts[1]
            default: break
            }
        }
        toolsCache = tools
        return tools
    }
}

/// Creates and caches one connection per host; publishes connection events for the UI.
public actor SSHConnectionManager {
    public nonisolated let events: AsyncStream<SSHConnectionEvent>
    private let continuation: AsyncStream<SSHConnectionEvent>.Continuation
    private var connections: [HostID: SSHConnection] = [:]
    private let controlDirectory: String
    private let sshPath: String

    /// `$TMPDIR/gl` keeps the socket path short: Application Support would exceed the 104-byte limit.
    /// Socket names are `<controlDirectory>/<10-char host id>`; ssh appends 17 characters while binding.
    public static var defaultControlDirectory: String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("gl")
    }

    public init(controlDirectory: String = SSHConnectionManager.defaultControlDirectory, sshPath: String = "/usr/bin/ssh") {
        self.controlDirectory = controlDirectory
        self.sshPath = sshPath
        var continuation: AsyncStream<SSHConnectionEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        self.continuation = continuation
        try? FileManager.default.createDirectory(atPath: controlDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// The connection object for a host, created on first use and connected when `connect` is true.
    public func connection(for hostID: HostID, alias: String, connect: Bool = true) async throws -> SSHConnection {
        let connection = connections[hostID] ?? SSHConnection(hostID: hostID, alias: alias, controlDirectory: controlDirectory, sshPath: sshPath, events: continuation)
        connections[hostID] = connection
        if connect { try await connection.connect() }
        return connection
    }

    public func existingConnection(for hostID: HostID) -> SSHConnection? {
        connections[hostID]
    }

    public func disconnect(_ hostID: HostID) async {
        await connections[hostID]?.disconnect()
        connections[hostID] = nil
    }

    public func disconnectAll() async {
        for connection in connections.values { await connection.disconnect() }
        connections = [:]
    }

    /// Called on wake: every connected host re-checks its master.
    public func recheckAll() async {
        for connection in connections.values { await connection.recheck() }
    }
}
