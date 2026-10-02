import Core
import Foundation
import Remote
import Testing
@testable import Transports

struct RemoteTmuxTests {
    /// `GLOSS_REMOTE_HOST=<alias>`: pastes into a pane on a private tmux server on that host, over the exec channel.
    @Test(.enabled(if: TestGates.remoteHost != nil))
    func pastesIntoAPaneOnTheRemoteHost() async throws {
        let alias = try #require(TestGates.remoteHost)
        let control = (NSTemporaryDirectory() as NSString).appendingPathComponent("gloss-test-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: control, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: control) }
        let manager = SSHConnectionManager(controlDirectory: control)
        let hostID = HostID.new()
        let connection = try await manager.connection(for: hostID, alias: alias)
        do {
            let tools = try await connection.tools()
            guard tools.tmux else { await manager.disconnectAll(); return }
            let socket = "gloss-test-\(UUID().uuidString.prefix(6))"
            let started = try await connection.exec("tmux -L \(socket) new-session -d -s gloss-verify -x 120 -y 30 cat")
            #expect(started.exitStatus == 0, "\(started.stderrText)")
            try await Task.sleep(for: .milliseconds(300))

            let registry = ConnectionRegistry()
            await registry.register(connection, alias: alias, for: hostID)
            let transport = TmuxTransport(registry: registry, localTmuxPath: nil, socketName: socket)
            let targets = try await transport.discoverTargets()
            let target = try #require(targets.first { $0.hostID == hostID && TmuxTransport.pane(from: $0)?.target.hasPrefix("gloss-verify:") == true })
            let pane = try #require(TmuxTransport.pane(from: target))
            #expect(target.label.hasPrefix("\(alias): "))

            let packet = PacketBuilder.build([PacketNote(noteID: NoteID.new(), agentPath: "/tmp/demo/main.go", source: .code, anchor: .wholeFile, comment: "remote line one\nremote line two")])
            _ = try await transport.deliver(packet, attachments: [], to: target)
            var screen = ""
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(200))
                screen = try await connection.exec("tmux -L \(socket) capture-pane -p -t \(ShellQuote.single(pane.target))").stdoutText
                if screen.contains("remote line two") { break }
            }
            #expect(screen.contains("File: /tmp/demo/main.go") && screen.contains("remote line two"), "\(screen)")
            let killed = try await connection.exec("tmux -L \(socket) kill-server")
            #expect(killed.exitStatus == 0)
        } catch {
            // Awaited before the master goes away, so a failing run cannot leave the private server on the host.
            _ = try? await connection.exec("tmux -L 'gloss-test-*' kill-server 2>/dev/null; for s in /tmp/tmux-$(id -u)/gloss-test-*; do [ -S \"$s\" ] && tmux -S \"$s\" kill-server; done; true")
            await manager.disconnectAll()
            throw error
        }
        await manager.disconnectAll()
    }
}
