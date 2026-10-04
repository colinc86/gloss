import Foundation
import Testing
@testable import Remote

struct ResponsibilityTests {
    /// Children must be their own responsible process, so key-agent approvals attach to the tool, not the app.
    @Test func childDisclaimsResponsibility() async throws {
        typealias Lookup = @convention(c) (pid_t) -> pid_t
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            Issue.record("responsibility_get_pid_responsible_for_pid is not available")
            return
        }
        let responsibleFor = unsafeBitCast(symbol, to: Lookup.self)
        let process = try ChildProcess.launch(ChildProcessSpec(executable: "/bin/sleep", arguments: ["5"]))
        defer { process.terminate() }
        let responsible = responsibleFor(process.processIdentifier)
        let ours = responsibleFor(getpid())
        print("RESPONSIBILITY child=\(process.processIdentifier) responsible=\(responsible) self=\(getpid()) selfResponsible=\(ours)")
        #expect(responsible == process.processIdentifier, "child \(process.processIdentifier) is attributed to \(responsible)")
    }

    /// The app ignores SIGTERM to turn it into a clean quit; children must not inherit that, or `terminate()`
    /// would do nothing to ssh and every other tool.
    @Test func childrenGetDefaultTerminationSignals() async throws {
        let previous = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, previous) }
        let child = try ChildProcess.launch(ChildProcessSpec(executable: "/bin/sleep", arguments: ["30"]))
        try await Task.sleep(for: .milliseconds(100))
        let started = Date()
        child.terminate()
        let code = try await child.exitCode
        #expect(Date().timeIntervalSince(started) < 1.5, "SIGTERM ends the child at once instead of waiting for the SIGKILL follow-up")
        #expect(code != 0)
    }
}
