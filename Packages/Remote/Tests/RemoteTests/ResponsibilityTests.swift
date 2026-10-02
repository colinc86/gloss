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
}
