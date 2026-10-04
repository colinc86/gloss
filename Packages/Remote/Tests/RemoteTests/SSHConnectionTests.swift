import Core
import Foundation
import Testing
@testable import Remote

struct SSHConnectionTests {
    @Test(.enabled(if: TestGates.loopback))
    func masterConnectsExecsAndExitsCleanly() async throws {
        try await TestGates.withManager { manager, _ in
            let host = HostID.new()
            let connection = try await manager.connection(for: host, alias: "localhost")
            #expect(await connection.state == .connected)
            #expect(await connection.check())

            let echo = try await connection.exec("printf 'hi %s' \"$(uname -s)\"")
            #expect(echo.exitStatus == 0)
            #expect(echo.stdoutText == "hi Darwin")

            let quoted = try await connection.exec("printf '%s' " + ShellQuote.single("it's \"quoted\" $HOME"))
            #expect(quoted.stdoutText == "it's \"quoted\" $HOME")

            let piped = try await connection.exec("cat", stdin: Data("stdin bytes".utf8))
            #expect(piped.stdoutText == "stdin bytes")

            let failing = try await connection.exec("exit 7")
            #expect(failing.exitStatus == 7)

            let tools = try await connection.tools()
            #expect(tools.os == "Darwin")
            #expect(tools.home == NSHomeDirectory())
            #expect(tools.git)

            await manager.disconnectAll()
            #expect(await connection.state == .disconnected)
            #expect(!(await connection.check()), "the master must be gone after disconnect")
        }
    }

    @Test(.enabled(if: TestGates.loopback))
    func forwardsAUnixSocketAndCancelsIt() async throws {
        try await TestGates.withManager { manager, control in
            let connection = try await manager.connection(for: HostID.new(), alias: "localhost")
            let remoteSocket = "\(control)/remote.sock"
            let localSocket = "\(control)/local.sock"
            // A tiny echo server on the "remote" side (this Mac).
            let server = try ChildProcess.launch(ChildProcessSpec(executable: "/usr/bin/nc", arguments: ["-lU", remoteSocket]))
            try await Task.sleep(for: .milliseconds(400))
            let forward = try await connection.forwardLocalSocket(local: localSocket, remote: remoteSocket)
            #expect(await connection.activeForwards.contains(forward))
            #expect(FileManager.default.fileExists(atPath: localSocket))
            await connection.cancel(forward)
            #expect(await connection.activeForwards.isEmpty)
            server.terminate()
            _ = try? await server.exitCode
        }
    }

    @Test(.enabled(if: TestGates.loopback))
    func forwardsALocalPortToARemoteLoopbackServer() async throws {
        try await TestGates.withManager { manager, control in
            let connection = try await manager.connection(for: HostID.new(), alias: "localhost")
            // A dev server on the "remote" side (this Mac), on a port only it knows.
            let remotePort = try PortAllocator.freeLoopbackPort()
            try "hello through the tunnel".write(toFile: "\(control)/hello.txt", atomically: true, encoding: .utf8)
            let server = try ChildProcess.launch(ChildProcessSpec(
                executable: "/usr/bin/python3", arguments: ["-m", "http.server", String(remotePort), "--bind", "127.0.0.1", "--directory", control]
            ))
            // Python takes a moment to listen; forwarding before that makes ssh drop the first connection.
            let direct = URL(string: "http://127.0.0.1:\(remotePort)/hello.txt")!
            var up = false
            for _ in 0..<50 where !up {
                if let (_, response) = try? await URLSession.shared.data(from: direct), (response as? HTTPURLResponse)?.statusCode == 200 { up = true } else { try await Task.sleep(for: .milliseconds(100)) }
            }
            #expect(up, "the test server is listening")

            let forward = try await connection.forwardLocalPort(toRemotePort: remotePort)
            guard case .localPort(let local, let remote) = forward.kind else { Issue.record("expected a local port forward"); return }
            #expect(remote == remotePort)
            #expect(await connection.localPort(forRemotePort: remotePort) == local)
            #expect(try await connection.forwardLocalPort(toRemotePort: remotePort) == forward, "a second request reuses the forward")
            // Two requests at once for a new port share one forward.
            let other = try PortAllocator.freeLoopbackPort()
            async let first = connection.forwardLocalPort(toRemotePort: other)
            async let second = connection.forwardLocalPort(toRemotePort: other)
            let (a, b) = try await (first, second)
            #expect(a == b)
            #expect(await connection.activeForwards.filter { if case .localPort(_, let remote) = $0.kind { remote == other } else { false } }.count == 1)
            await connection.cancelLocalPort(remotePort: other)
            #expect(await connection.localPort(forRemotePort: other) == nil)

            let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(local)/hello.txt")!)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(String(decoding: data, as: UTF8.self) == "hello through the tunnel")

            await connection.cancel(forward)
            #expect(await connection.localPort(forRemotePort: remotePort) == nil)
            server.terminate()
            _ = try? await server.exitCode
        }
    }

    @Test func allocatesFreeLoopbackPortsAndBuildsForwardArguments() throws {
        let port = try PortAllocator.freeLoopbackPort()
        #expect(port >= 1024)
        #expect(SSHForward(kind: .localPort(local: 50_123, remotePort: 3000)).arguments == ["-L", "127.0.0.1:50123:localhost:3000"])
    }

    @Test func buildsHostOptionArguments() {
        #expect(SSHConnection.arguments(hostName: "", user: "", port: nil, identityFile: "").isEmpty)
        #expect(SSHConnection.arguments(hostName: "10.0.0.5", user: "me", port: 2222, identityFile: "/k/id") ==
            ["-o", "HostName=10.0.0.5", "-o", "User=me", "-o", "Port=2222", "-o", "IdentityFile=/k/id", "-o", "IdentitiesOnly=yes"])
        // ssh terminates lines with CRLF, which Swift reads as one Character.
        let stderr = "debug1: Connecting to box [10.0.0.5] port 22.\r\ndebug1: Connection established.\r\ndebug1: Authenticating to box:22 as 'me'\r\ndebug1: Offering public key: /k/id ED25519 SHA256:abc agent\r\n"
        #expect(SSHConnection.stage(from: stderr) == "Offering key /k/id…")
        #expect(SSHConnection.stage(from: "debug1: Connecting to box [10.0.0.5] port 22.\n") == "Connecting to box…")
        let connection = SSHConnection(hostID: .local, alias: "x", controlDirectory: "/tmp", sshPath: "/usr/bin/ssh", events: AsyncStream<SSHConnectionEvent> { _ in }.makeContinuationForTest())
        #expect(connection.classify(stderr: stderr + "me@box: Permission denied (publickey).\r\n", status: 255) == .authenticationFailed("me@box: Permission denied (publickey)."), "verbose lines are dropped from the error text")
    }

    /// App-managed host options reach ssh, and the verbose stages come back as progress events.
    @Test(.enabled(if: TestGates.loopback))
    func honoursHostOptionsAndReportsStages() async throws {
        try await TestGates.withManager { manager, _ in
            let user = NSUserName()
            let collector = Task { () -> [SSHConnectionEvent] in
                var seen: [SSHConnectionEvent] = []
                for await event in manager.events {
                    seen.append(event)
                    if case .connected = event { break }
                }
                return seen
            }
            let options = SSHConnection.arguments(hostName: "localhost", user: user, port: 22, identityFile: "")   // localhost keeps the known_hosts entry valid
            let connection = try await manager.connection(for: HostID.new(), alias: "localhost", options: options)
            #expect(await connection.state == .connected)
            let who = try await connection.exec("id -un")
            #expect(who.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) == user)
            let events = await collector.value
            // Loopback usually connects before the first poll, so a progress event is not guaranteed here; the
            // stage parser is covered above and the real-host test sees the stages.
            #expect(events.contains { if case .connected = $0 { return true } else { return false } })
            #expect(!events.contains { if case .waitingForAgent = $0 { return true } else { return false } }, "a fast key exchange never claims an agent wait")
        }
    }

    /// A key agent that accepts the connection and never answers: the connect reports the agent wait and fails
    /// with the agent-specific error instead of spinning out the whole budget.
    @Test(.enabled(if: TestGates.loopback))
    func failsWhenTheKeyAgentStaysSilent() async throws {
        try await TestGates.serialized {
            let control = TestGates.temporaryControlDirectory()
            defer { try? FileManager.default.removeItem(atPath: control) }
            let socket = "\(control)/agent.sock"
            // -d: never read stdin, so nc keeps the accepted connection open without replying.
            let fakeAgent = try ChildProcess.launch(ChildProcessSpec(executable: "/usr/bin/nc", arguments: ["-dlU", socket]))
            defer { fakeAgent.terminate() }
            try await Task.sleep(for: .milliseconds(400))
            let manager = SSHConnectionManager(controlDirectory: control, agentBudget: .seconds(3))
            let collector = Task { () -> [SSHConnectionEvent] in
                var seen: [SSHConnectionEvent] = []
                for await event in manager.events {
                    seen.append(event)
                    if case .failed = event { break }
                }
                return seen
            }
            do {
                _ = try await manager.connection(for: HostID.new(), alias: "localhost", options: ["-o", "IdentityAgent=\(socket)", "-o", "IdentitiesOnly=no"])
                Issue.record("connected through a silent agent")
            } catch let error as SSHError {
                #expect(error == .agentUnresponsive, "\(error)")
            }
            let events = await collector.value
            #expect(events.contains { if case .waitingForAgent = $0 { return true } else { return false } }, "\(events)")
            #expect(events.contains { if case .failed(_, .agentUnresponsive) = $0 { return true } else { return false } })
            await manager.disconnectAll()
            // A master blocked in an agent request ignores SIGTERM; the SIGKILL follow-up comes two seconds later.
            var remaining = pgrepMasters()
            for _ in 0..<12 where remaining > 0 {
                try await Task.sleep(for: .milliseconds(250))
                remaining = pgrepMasters()
            }
            #expect(remaining == 0, "the stalled master was terminated")
        }
    }

    /// Quitting while a master waits on the agent must not orphan it: the synchronous kill is SIGKILL.
    @Test(.enabled(if: TestGates.loopback))
    func killMastersEndsAStalledMasterAtOnce() async throws {
        try await TestGates.serialized {
            let control = TestGates.temporaryControlDirectory()
            defer { try? FileManager.default.removeItem(atPath: control) }
            let socket = "\(control)/agent.sock"
            let fakeAgent = try ChildProcess.launch(ChildProcessSpec(executable: "/usr/bin/nc", arguments: ["-dlU", socket]))
            defer { fakeAgent.terminate() }
            try await Task.sleep(for: .milliseconds(400))
            let manager = SSHConnectionManager(controlDirectory: control, agentBudget: .seconds(30))
            let connect = Task { try await manager.connection(for: HostID.new(), alias: "localhost", options: ["-o", "IdentityAgent=\(socket)", "-o", "IdentitiesOnly=no"]) }
            try await Task.sleep(for: .seconds(2))
            #expect(pgrepMasters() == 1, "the master is stalled in the agent request")
            manager.killMasters()
            try await Task.sleep(for: .milliseconds(500))
            #expect(pgrepMasters() == 0, "SIGKILL ends it without waiting for the app's follow-up timer")
            _ = try? await connect.value
            await manager.disconnectAll()
        }
    }

    @Test func classifiesFailures() {
        let connection = SSHConnection(hostID: .local, alias: "x", controlDirectory: "/tmp", sshPath: "/usr/bin/ssh", events: AsyncStream<SSHConnectionEvent> { _ in }.makeContinuationForTest())
        #expect(connection.classify(stderr: "Host key verification failed.", status: 255) == .hostKeyProblem(fingerprint: nil, offerAcceptNew: true))
        if case .hostKeyChanged = connection.classify(stderr: "@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @", status: 255) {} else { Issue.record("expected hostKeyChanged") }
        if case .authenticationFailed = connection.classify(stderr: "colin@x: Permission denied (publickey).", status: 255) {} else { Issue.record("expected auth") }
        if case .unreachable = connection.classify(stderr: "ssh: Could not resolve hostname x: nodename nor servname provided", status: 255) {} else { Issue.record("expected unreachable") }
        #expect(connection.classify(stderr: "", status: 1) == .other("ssh exited with status 1"))
        let args = connection.masterArguments(acceptNew: false)
        #expect(args.contains("ControlMaster=yes") && args.contains("-N") && !args.joined(separator: " ").contains("BatchMode"))
    }
}

extension AsyncStream {
    /// A throwaway continuation for tests that never read events.
    func makeContinuationForTest() -> AsyncStream<Element>.Continuation {
        var continuation: AsyncStream<Element>.Continuation!
        _ = AsyncStream<Element> { continuation = $0 }
        return continuation
    }
}


/// Count of live ControlMaster processes, for teardown assertions.
func pgrepMasters() -> Int {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", "^/usr/bin/ssh -o ControlMaster=yes"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").count
}
