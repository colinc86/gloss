import Core
import Foundation
import Testing
@testable import Gloss

/// Which agents the target picker marks as running in the explorer's folder.
struct AgentTargetDirectoryTests {
    private func target(_ transport: TransportKind, host: HostID = .local, directory: String?) -> AgentTarget {
        AgentTarget(transport: transport, hostID: host, label: "agent", detail: directory, identityJSON: "{}")
    }

    @Test func matchesTheFolderAndFoldersInsideIt() {
        let agent = target(.herdr, directory: "/Users/me/project")
        #expect(agent.runs(inHost: .local, path: "/Users/me/project"))
        #expect(agent.runs(inHost: .local, path: "/Users/me/project/"), "trailing slashes do not matter")
        #expect(target(.tmux, directory: "/Users/me/project/app").runs(inHost: .local, path: "/Users/me/project"))
        #expect(!target(.herdr, directory: "/Users/me").runs(inHost: .local, path: "/Users/me/project"), "an agent in a parent folder is not marked")
        #expect(!agent.runs(inHost: .local, path: "/Users/me/project-two"), "a shared prefix is not a parent")
        #expect(!agent.runs(inHost: .local, path: "/Users/me/other"))
    }

    @Test func requiresTheSameHostAndADirectory() {
        #expect(!target(.herdr, host: HostID(rawValue: "asus"), directory: "/home/me/p").runs(inHost: .local, path: "/home/me/p"))
        #expect(target(.herdr, host: HostID(rawValue: "asus"), directory: "/home/me/p").runs(inHost: HostID(rawValue: "asus"), path: "/home/me/p"))
        #expect(!target(.clipboard, directory: "/p").runs(inHost: .local, path: "/p"))
        #expect(!target(.opencode, directory: "http://127.0.0.1:4096").runs(inHost: .local, path: "/"), "a server URL is not a directory")
        #expect(!target(.herdr, directory: nil).runs(inHost: .local, path: "/p"))
    }

    @Test func localSymlinksResolve() throws {
        // The temporary directory lives under `/var`, a symlink to `/private/var`; shells report either spelling.
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "gloss-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let short = folder.path.hasPrefix("/private/") ? String(folder.path.dropFirst("/private".count)) : folder.path
        #expect(target(.herdr, directory: "/private" + short).runs(inHost: .local, path: short))
        #expect(target(.herdr, directory: short).runs(inHost: .local, path: "/private" + short))
    }
}
