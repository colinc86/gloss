import Core
import Foundation
import Remote
import Testing
@testable import Transports

struct RemoteMCPTests {
    /// `GLOSS_REMOTE_HOST=<alias>`: the MCP server's port is reverse-forwarded over the control connection and the
    /// host reaches `/health` through it with curl, which is what an agent on that host will do.
    @Test(.enabled(if: TestGates.remoteHost != nil))
    func hostReachesTheServerThroughTheReverseForward() async throws {
        let alias = try #require(TestGates.remoteHost)
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("gloss-test-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let store = NoteStore(database: try AppDatabase.inMemory())
        let server = MCPServer(dependencies: MCPServerTests.dependencies(store: store), port: 0, portFileURL: nil)
        try await server.start()
        let port = try #require(await server.port)
        let manager = SSHConnectionManager(controlDirectory: directory)
        let connection = try await manager.connection(for: HostID.new(), alias: alias)
        do {
            let forward = try await connection.forwardRemotePort(UInt16(port))
            let curl = try await connection.exec("curl -s --max-time 5 http://127.0.0.1:\(port)/health || wget -qO- http://127.0.0.1:\(port)/health", timeout: .seconds(15))
            #expect(curl.stdoutText == "ok\n", "stdout: \(curl.stdoutText) stderr: \(curl.stderrText)")
            await connection.cancel(forward)
        } catch {
            await manager.disconnectAll()
            await server.stop()
            throw error
        }
        await manager.disconnectAll()
        await server.stop()
        #expect(!(await connection.check()))
    }
}
