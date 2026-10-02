import Core
import Foundation

/// Attachments for local agents: copied into the app's cache under the send id so they outlive the note's crop file.
struct LocalAttachmentStager: AttachmentStager {
    let cacheRoot: URL

    init(cacheRoot: URL = AttachmentCache.root) {
        self.cacheRoot = cacheRoot
    }

    func stage(_ files: [LocalAttachment], for target: AgentTarget, sendID: SendID) async throws -> [StagedAttachment] {
        guard !files.isEmpty else { return [] }
        let directory = cacheRoot.appendingPathComponent(sendID.rawValue, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var staged: [StagedAttachment] = []
        for (index, file) in files.enumerated() {
            let name = "\(index + 1)-\(file.fileName)"
            let destination = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.copyItem(atPath: file.localPath, toPath: destination.path)
            staged.append(StagedAttachment(noteID: file.noteID, agentPath: destination.path))
        }
        return staged
    }
}

enum AttachmentCache {
    /// `~/Library/Application Support/Gloss/attachments/`
    nonisolated static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gloss/attachments", isDirectory: true)
    }
}
