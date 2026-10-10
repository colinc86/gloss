import Core
import Testing
@testable import Remote

struct ExclusiveCreationTests {
    @Test func collisionKeepsRemoteBytesAndHandlesClose() async throws {
        let server = FakeSFTPServer()
        server.put("/home/test/existing", "original")
        let client = try await SFTPClient.connect(transport: server)
        let fs = SFTPFileSystem(hostID: HostID(rawValue: "test"), channel: SFTPChannel(client: client))
        await #expect(throws: FileSystemError.alreadyExists("/home/test/existing")) {
            _ = try await fs.createFile(at: "/home/test/existing")
        }
        #expect(server.contents("/home/test/existing") == "original")
        _ = try await fs.createFile(at: "/home/test/new")
        #expect(server.contents("/home/test/new") == "")
        #expect(server.openHandleCount() == 0)
        await client.close()
    }

    /// A Mac at the other end finds `readme.md` at `README.md` too; changing only the case is still a rename.
    @Test func aCaseOnlyRenameOnACaseInsensitiveHostIsNotAClash() async throws {
        let server = FakeSFTPServer()
        server.caseInsensitive = true
        server.put("/home/test/readme.md", "keep")
        server.put("/home/test/other.md", "other")
        let client = try await SFTPClient.connect(transport: server)
        let fs = SFTPFileSystem(hostID: HostID(rawValue: "test"), channel: SFTPChannel(client: client))
        try await fs.rename("/home/test/readme.md", to: "/home/test/README.md")
        #expect(server.contents("/home/test/README.md") == "keep")
        #expect(server.contents("/home/test/readme.md") == nil)
        await #expect(throws: FileSystemError.alreadyExists("/home/test/Readme.md")) {
            try await fs.rename("/home/test/other.md", to: "/home/test/Readme.md")
        }
        #expect(server.contents("/home/test/other.md") == "other")
        await client.close()
    }
}
