import Core
import Foundation
import Testing
@testable import Remote

/// Runs against `GLOSS_REMOTE_HOST=<alias>` (for example `asus`). The master may need the 1Password prompt, so this
/// is for the phase gate, not CI. Everything it creates lives under the host's temp directory and is removed.
struct RemoteHostTests {
    @Test(.enabled(if: TestGates.remoteHost != nil))
    func sftpAndExecAgainstTheRemoteHost() async throws {
        let alias = try #require(TestGates.remoteHost)
        try await TestGates.withManager(serialized: false) { manager, _ in
            let host = HostID.new()
            let connection = try await manager.connection(for: host, alias: alias)
            let tools = try await connection.tools()
            #expect(!tools.home.isEmpty)
            let fs = SFTPFileSystem(hostID: host, connection: connection)
            let client = try await fs.channel.client()
            #expect(await client.homeDirectory == tools.home)
            let directory = PathUtilities.join(tools.tmpdir, "gloss-remote-\(UUID().uuidString.prefix(8))")
            try await fs.makeDirectory(directory)
            do {
                let path = PathUtilities.join(directory, "note.md")
                let payload = Data((0..<200_000).map { UInt8($0 % 253) })
                let written = try await fs.writeAtomically(payload, to: path, preservingModeFrom: nil)
                #expect(written.size == 200_000)
                #expect(try await fs.read(path) == payload)
                #expect(try await fs.list(directory).map(\.name) == ["note.md"])
                let (_, fingerprint) = try await fs.readWithFingerprint(path)
                _ = try await connection.exec("printf 'agent edit' > \(ShellQuote.single(path))")
                guard case .changed = try await fs.checkForChanges(at: path, since: fingerprint) else { Issue.record("expected change"); return }
                try await fs.rename(path, to: PathUtilities.join(directory, "renamed.md"))
                #expect(try await fs.list(directory).map(\.name) == ["renamed.md"])
                var hits: [RemoteSearchHit] = []
                for try await hit in RemoteSearch.run(pattern: "agent edit", root: directory, over: connection) { hits.append(hit) }
                #expect(hits.map(\.line) == [1])
        }
        try await fs.delete(directory)
        #expect((try? await fs.stat(directory)) == nil)
        await fs.channel.close()
        await manager.disconnectAll()
        #expect(!(await connection.check()))
        }
    }
}
