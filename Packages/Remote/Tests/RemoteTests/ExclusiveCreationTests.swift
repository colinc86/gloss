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
}
