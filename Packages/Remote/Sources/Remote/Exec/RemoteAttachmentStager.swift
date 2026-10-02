import Core
import Foundation
import OSLog

/// Uploads attachments to `/tmp/gloss/<send-id>/` on the target host before delivery,
/// records them for expiry, and removes expired directories over the exec channel.
public struct RemoteAttachmentStager: AttachmentStager {
    private static let log = Logger(subsystem: "com.cnc.Gloss", category: "staging")
    public static let expiry: TimeInterval = 7 * 24 * 3600

    public let hostID: HostID
    public let connection: SSHConnection
    public let fileSystem: SFTPFileSystem
    public let noteStore: NoteStore

    public init(hostID: HostID, connection: SSHConnection, fileSystem: SFTPFileSystem, noteStore: NoteStore) {
        self.hostID = hostID
        self.connection = connection
        self.fileSystem = fileSystem
        self.noteStore = noteStore
    }

    /// `/tmp/gloss` unless it exists and is not ours, then `<tmpdir>/gloss-<uid>`.
    public func stagingRoot() async throws -> String {
        let tools = try await connection.tools()
        let shared = "/tmp/gloss"
        let check = try await connection.exec("if [ -e \(ShellQuote.single(shared)) ] && [ ! -w \(ShellQuote.single(shared)) ]; then echo busy; else echo ok; fi")
        if check.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) == "busy" {
            return PathUtilities.join(tools.tmpdir, "gloss-\(tools.uid)")
        }
        return shared
    }

    public func stage(_ files: [LocalAttachment], for target: AgentTarget, sendID: SendID) async throws -> StagingResult {
        guard !files.isEmpty else { return .empty }
        let root = try await stagingRoot()
        let directory = PathUtilities.join(root, sendID.rawValue)
        try await fileSystem.makeDirectory(directory)
        _ = try? await connection.exec("chmod 700 \(ShellQuote.single(directory))")
        var staged: [StagedAttachment] = []
        for (index, file) in files.enumerated() {
            let data = try Data(contentsOf: URL(fileURLWithPath: file.localPath))
            let remotePath = PathUtilities.join(directory, "\(index + 1)-\(file.fileName)")
            _ = try await fileSystem.writeAtomically(data, to: remotePath, preservingModeFrom: FileAttributes(kind: .file, size: 0, mtime: Date(), mode: 0o600))
            staged.append(StagedAttachment(noteID: file.noteID, agentPath: remotePath))
        }
        return StagingResult(attachments: staged, remoteDirectories: [directory])
    }

    /// Removes expired staging directories recorded for this host, plus any week-old leftovers from a lost database.
    public func cleanupExpired(now: Date = Date()) async {
        do {
            let expired = try await noteStore.expiredStagedFiles(now: now).filter { $0.hostID == hostID }
            if !expired.isEmpty {
                let paths = expired.map { ShellQuote.single($0.remotePath) }.joined(separator: " ")
                _ = try await connection.exec("rm -rf -- \(paths)")
                try await noteStore.deleteStagedFiles(expired.map(\.id))
            }
            let root = try await stagingRoot()
            _ = try await connection.exec("[ -d \(ShellQuote.single(root)) ] && find \(ShellQuote.single(root)) -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} + ; true")
        } catch {
            Self.log.error("staging cleanup failed: \(error, privacy: .public)")
        }
    }
}
