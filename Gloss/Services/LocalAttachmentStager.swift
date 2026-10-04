import Core
import Foundation

/// Attachments for local agents: copied into the app's cache under the send id so they outlive the note's crop file.
struct LocalAttachmentStager: AttachmentStager {
    let cacheRoot: URL

    init(cacheRoot: URL = AttachmentCache.root) {
        self.cacheRoot = cacheRoot
    }

    func stage(_ files: [LocalAttachment], for target: AgentTarget, sendID: SendID) async throws -> StagingResult {
        guard !files.isEmpty else { return .empty }
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
        return StagingResult(attachments: staged)
    }
}

enum AttachmentCache {
    /// Staged copies per send: `~/Library/Application Support/Gloss/attachments/<send-id>/`. Safe to clear.
    nonisolated static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gloss/attachments", isDirectory: true)
    }

    /// Crops and page renders that notes reference: `.../Gloss/note-attachments/`. Kept until the note goes.
    nonisolated static var notesRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gloss/note-attachments", isDirectory: true)
    }

    /// Removes crops and page renders no note references any more (deleting a note dropped its rows but left the
    /// PNGs forever) and per-send staged copies older than `stagedExpiry`, the same rule remote hosts follow.
    /// Files younger than `minimumAge` stay: a crop is written before its row, so a brand-new file may not be
    /// referenced yet. Returns how many note files and send folders went.
    @discardableResult
    nonisolated static func sweep(
        notesRoot: URL = notesRoot, stagedRoot: URL = root, referenced: Set<String>,
        stagedExpiry: TimeInterval, minimumAge: TimeInterval = 3_600, now: Date = Date()
    ) -> (noteFiles: Int, sendFolders: Int) {
        let manager = FileManager.default
        var noteFiles = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        if let files = manager.enumerator(at: notesRoot, includingPropertiesForKeys: keys) {
            for case let url as URL in files {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                let age = now.timeIntervalSince(values.contentModificationDate ?? now)
                let path = url.resolvingSymlinksInPath().path
                guard age >= minimumAge, !referenced.contains(url.path), !referenced.contains(path) else { continue }
                if (try? manager.removeItem(at: url)) != nil { noteFiles += 1 }
            }
        }
        var sendFolders = 0
        for folder in (try? manager.contentsOfDirectory(at: stagedRoot, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            if now.timeIntervalSince(modified) >= stagedExpiry, (try? manager.removeItem(at: folder)) != nil { sendFolders += 1 }
        }
        return (noteFiles, sendFolders)
    }
}
