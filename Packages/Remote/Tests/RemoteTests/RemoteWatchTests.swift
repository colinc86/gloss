import Core
import Foundation
import Testing
@testable import Remote

/// A remote file is watched by size and mtime, which has one-second granularity over SFTP v3. One at a time: the
/// app-in-front flag is global.
@Suite(.serialized)
struct RemoteWatchTests {
    actor Count {
        var value = 0
        func add() { value += 1 }
    }

    @Test func aSameSecondSameSizeRewriteAfterAChangeIsSeen() async throws {
        let server = FakeSFTPServer()
        server.put("/home/test/config.txt", "poll 60", mtime: 1_700_000_000)
        let client = try await SFTPClient.connect(transport: server)
        var fs = SFTPFileSystem(hostID: HostID(rawValue: "test"), channel: SFTPChannel(client: client))
        fs.focusedInterval = .milliseconds(50)
        let changes = Count()
        let stream = fs.watch("/home/test/config.txt")
        let watching = Task { for await _ in stream { await changes.add() } }
        defer { watching.cancel() }
        func waitFor(_ wanted: Int) async -> Bool {
            for _ in 0..<60 { if await changes.value >= wanted { return true }; try? await Task.sleep(for: .milliseconds(25)) }
            return false
        }
        try await Task.sleep(for: .milliseconds(120))   // the first tick takes the baseline

        server.put("/home/test/config.txt", "poll 120", mtime: 1_700_000_100)   // a change of size and second
        #expect(await waitFor(1))
        try await Task.sleep(for: .milliseconds(20))   // past the change's own read, inside the 50 ms tick
        // The agent's next edit lands in that same second, the same length: size and mtime say nothing.
        server.put("/home/test/config.txt", "poll 900", mtime: 1_700_000_100)
        #expect(await waitFor(2), "the rewrite within the same second is reported")
        await client.close()
    }

    /// While the app isn't in front, a remote file is looked at every `backgroundInterval`, not every few seconds.
    @Test func aWatchSlowsWhileTheAppIsInTheBackground() async throws {
        let server = FakeSFTPServer()
        server.put("/home/test/notes.md", "one", mtime: 1_700_000_000)
        let client = try await SFTPClient.connect(transport: server)
        var fs = SFTPFileSystem(hostID: HostID(rawValue: "test"), channel: SFTPChannel(client: client))
        fs.focusedInterval = .milliseconds(50)
        fs.backgroundInterval = .seconds(30)
        RemotePolling.isAppActive = false
        defer { RemotePolling.isAppActive = true }
        let changes = Count()
        let stream = fs.watch("/home/test/notes.md")
        let watching = Task { for await _ in stream { await changes.add() } }
        defer { watching.cancel() }
        try await Task.sleep(for: .milliseconds(150))   // the first tick, then the long background sleep
        server.put("/home/test/notes.md", "two words", mtime: 1_700_000_100)
        try await Task.sleep(for: .milliseconds(400))
        #expect(await changes.value == 0, "not looked at again within the focused interval's many ticks")
        await client.close()
    }
}
