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
