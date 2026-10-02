import Core
import Foundation
import Remote
import Testing
@testable import Transports

struct RemoteHerdrTests {
    /// `GLOSS_REMOTE_HOST=<alias>`: discovers agent panes on the host through the forwarded socket and streams one
    /// subscription ack over it. Never prompts a real agent.
    @Test(.enabled(if: TestGates.remoteHost != nil))
    func discoversAgentsThroughTheForwardedSocket() async throws {
        let alias = try #require(TestGates.remoteHost)
        let control = (NSTemporaryDirectory() as NSString).appendingPathComponent("gloss-test-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: control, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: control) }
        let manager = SSHConnectionManager(controlDirectory: control)
        let hostID = HostID.new()
        let connection = try await manager.connection(for: hostID, alias: alias)
        do {
            let registry = ConnectionRegistry()
            await registry.register(connection, alias: alias, for: hostID)
            let transport = HerdrTransport(registry: registry, localSocketPath: "/nonexistent/herdr.sock", forwardDirectory: control)
            let targets = try await transport.discoverTargets()
            let remote = targets.filter { $0.hostID == hostID }
            let tools = try await connection.tools()
            if tools.herdr {
                #expect(!remote.isEmpty, "the host runs Herdr with agent panes")
                #expect(remote.allSatisfy { $0.label.hasPrefix("\(alias): ") })
                let socket = try #require(await transport.socketPath(for: hostID))
                #expect(FileManager.default.fileExists(atPath: socket), "forwarded socket exists locally")
                let pong = try await HerdrClient(socketPath: socket).ping()
                #expect(pong.protocol == 22)
                let service = HerdrFollowService(hostID: hostID, socketPath: socket)
                await service.start()
                let first = await withDeadline(.seconds(10)) { () -> FollowEvent? in
                    for await event in service.events { return event }
                    return nil
                } ?? nil
                await service.stop()
                #expect(first?.hostID == hostID && first?.path != nil, "the initial agent list seeds a follow event")
            }
        } catch {
            await manager.disconnectAll()
            throw error
        }
        await manager.disconnectAll()
        #expect(!(await connection.check()))
    }
}
