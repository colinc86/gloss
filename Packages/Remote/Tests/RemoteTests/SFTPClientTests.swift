import Core
import CryptoKit
import Foundation
import Testing
@testable import Remote

struct SFTPClientTests {
    @Test func handshakeCapturesExtensionsLimitsAndHome() async throws {
        let server = FakeSFTPServer()
        let client = try await SFTPClient.connect(transport: server)
        #expect(await client.supportsPosixRename)
        #expect(await client.supportsFsync)
        #expect(await client.limits.maxRead == 4096, "the fake's 1000-byte limit is raised to the 4 KiB floor")
        #expect(await client.homeDirectory == "/home/test")
        await client.close()
    }

    @Test func pipelinedReadsReassembleOutOfOrderReplies() async throws {
        let server = FakeSFTPServer(shuffleReplies: true)
        let text = (0..<20000).map { String($0 % 10) }.joined()   // 20000 bytes, about five 4 KiB reads
        server.put("/home/test/big.txt", text)
        let client = try await SFTPClient.connect(transport: server)
        let data = try await client.readFile("/home/test/big.txt")
        #expect(String(decoding: data, as: UTF8.self) == text)
        #expect(server.openHandleCount() <= 1, "handles are closed after reads (the close may still be in flight)")
        let empty = try await client.readFile("/home/test/empty.txt".isEmpty ? "" : {
            server.put("/home/test/empty.txt", "")
            return "/home/test/empty.txt"
        }())
        #expect(empty.isEmpty)
        await client.close()
    }

    @Test func fileSystemListsStatsAndWritesAtomically() async throws {
        let server = FakeSFTPServer()
        server.put("/home/test/a.md", "hello", permissions: 0o600)
        server.put("/home/test/sub/x", "x")
        let client = try await SFTPClient.connect(transport: server)
        let fs = SFTPFileSystem(hostID: HostID.new(), channel: SFTPChannel(client: client))
        let entries = try await fs.list("/home/test")
        try #require(entries.map(\.name) == ["a.md", "sub"])
        #expect(entries[0].kind == .file && entries[0].size == 5 && entries[0].mode == 0o600)
        #expect(entries[1].kind == .directory)
        let attributes = try await fs.stat("/home/test/a.md")
        #expect(attributes.kind == .file && attributes.size == 5 && attributes.mode == 0o600)
        #expect(try await fs.read("/home/test/a.md") == Data("hello".utf8))

        let written = try await fs.writeAtomically(Data("replaced".utf8), to: "/home/test/a.md", preservingModeFrom: attributes)
        #expect(written.size == 8 && written.mode == 0o600)
        #expect(server.contents("/home/test/a.md") == "replaced")
        #expect(server.file("/home/test/a.md")?.permissions == 0o600)
        #expect(server.openHandleCount() == 0)
        let leftovers = try await fs.list("/home/test").map(\.name).filter { $0.hasPrefix(".cc-") }
        #expect(leftovers.isEmpty, "no temp file survives a save")

        try await fs.makeDirectory("/home/test/new/deep")
        #expect(server.hasDirectory("/home/test/new/deep"))
        try await fs.rename("/home/test/a.md", to: "/home/test/b.md")
        #expect(server.contents("/home/test/b.md") == "replaced")
        await #expect(throws: FileSystemError.alreadyExists("/home/test/b.md")) {
            try await fs.rename("/home/test/sub/x", to: "/home/test/b.md")
        }
        try await fs.delete("/home/test/sub")
        #expect(!server.hasDirectory("/home/test/sub"))
        #expect(server.contents("/home/test/sub/x") == nil)
        await #expect(throws: FileSystemError.notFound("/home/test/missing")) { _ = try await fs.stat("/home/test/missing") }
        await client.close()
    }

    @Test func conflictCheckWorksOverSFTP() async throws {
        let server = FakeSFTPServer()
        server.put("/home/test/doc.md", "version one")
        let client = try await SFTPClient.connect(transport: server)
        let fs = SFTPFileSystem(hostID: HostID.new(), channel: SFTPChannel(client: client))
        let (_, fingerprint) = try await fs.readWithFingerprint("/home/test/doc.md")
        #expect(try await fs.checkForChanges(at: "/home/test/doc.md", since: fingerprint) == .unchanged)
        server.put("/home/test/doc.md", "version two", mtime: 1_700_000_000)   // same length, same second: only the hash can tell
        guard case .changed(let current, _) = try await fs.checkForChanges(at: "/home/test/doc.md", since: fingerprint) else { Issue.record("expected change"); return }
        #expect(String(decoding: current, as: UTF8.self) == "version two")
        await client.close()
    }

    @Test func pendingRequestsFailWhenTheTransportEnds() async throws {
        let server = FakeSFTPServer()
        let client = try await SFTPClient.connect(transport: server)
        server.close()
        await #expect(throws: (any Error).self) { _ = try await client.stat("/home/test") }
        #expect(!(await client.isOpen))
    }

    @Test(.enabled(if: TestGates.loopback))
    func loopbackSFTPEndToEnd() async throws {
        let control = TestGates.temporaryControlDirectory()
        defer { try? FileManager.default.removeItem(atPath: control) }
        let manager = SSHConnectionManager(controlDirectory: control)
        let connection = try await manager.connection(for: HostID.new(), alias: "localhost")
        let fs = SFTPFileSystem(hostID: HostID.new(), connection: connection)
        let client = try await fs.channel.client()
        #expect(await client.supportsPosixRename, "OpenSSH advertises posix-rename")
        #expect(await client.homeDirectory == NSHomeDirectory())
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("gloss-sftp-\(UUID().uuidString.prefix(8))")
        try await fs.makeDirectory(directory)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let path = "\(directory)/note.md"
        let big = Data((0..<300_000).map { UInt8($0 % 251) })
        let written = try await fs.writeAtomically(big, to: path, preservingModeFrom: nil)
        #expect(written.size == 300_000)
        #expect(try await fs.read(path) == big)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == big)
        let listed = try await fs.list(directory)
        #expect(listed.map(\.name) == ["note.md"])
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path)
        let attributes = try await fs.stat(path)
        #expect(attributes.mode == 0o640)
        let (_, fingerprint) = try await fs.readWithFingerprint(path)
        try "agent edit".write(toFile: path, atomically: true, encoding: .utf8)
        guard case .changed = try await fs.checkForChanges(at: path, since: fingerprint) else { Issue.record("expected change"); return }
        let saved = try await fs.writeAtomically(Data("mine".utf8), to: path, preservingModeFrom: attributes)
        #expect(saved.mode == 0o640, "mode survives the temp-file rename")
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "mine")
        try await fs.rename(path, to: "\(directory)/renamed.md")
        try await fs.delete("\(directory)/renamed.md")
        #expect(try await fs.list(directory).isEmpty)
        await fs.channel.close()
        await manager.disconnectAll()
    }
}
