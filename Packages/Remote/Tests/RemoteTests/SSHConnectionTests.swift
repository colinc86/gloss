import Core
import Foundation
import Testing
@testable import Remote

struct SSHConnectionTests {
    @Test(.enabled(if: TestGates.loopback))
    func masterConnectsExecsAndExitsCleanly() async throws {
        try await TestGates.serialized {
            let control = TestGates.temporaryControlDirectory()
            defer { try? FileManager.default.removeItem(atPath: control) }
            let manager = SSHConnectionManager(controlDirectory: control)
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
        try await TestGates.serialized {
            let control = TestGates.temporaryControlDirectory()
            defer { try? FileManager.default.removeItem(atPath: control) }
            let manager = SSHConnectionManager(controlDirectory: control)
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
            _ = await server.exitCode
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
