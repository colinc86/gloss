import Core
import Foundation

/// One file as an earlier iteration saw it (issue #18): serves the snapshot's bytes at the document's path and
/// refuses every write, so any viewer opens it read-only, unchanged. Other paths go to the host's own file system
/// (a Markdown file's pictures), read-only too.
struct SnapshotFileSystem: FileSystemProvider {
    let base: any FileSystemProvider
    let path: String
    let data: Data
    /// When the iteration ended: the file's time as the snapshot shows it.
    let date: Date

    var hostID: HostID { base.hostID }

    func list(_ directory: String) async throws -> [DirectoryEntry] { try await base.list(directory) }

    func stat(_ path: String) async throws -> FileAttributes {
        guard path == self.path else { return try await base.stat(path) }
        return FileAttributes(kind: .file, size: Int64(data.count), mtime: date, mode: 0o444)
    }

    func read(_ path: String) async throws -> Data {
        guard path == self.path else { return try await base.read(path) }
        return data
    }

    func writeAtomically(_ data: Data, to path: String, preservingModeFrom original: FileAttributes?) async throws -> FileAttributes {
        throw FileSystemError.permissionDenied("An earlier iteration is read-only.")
    }

    func makeDirectory(_ path: String) async throws { throw FileSystemError.permissionDenied("An earlier iteration is read-only.") }
    func rename(_ path: String, to newPath: String) async throws { throw FileSystemError.permissionDenied("An earlier iteration is read-only.") }
    func delete(_ path: String) async throws { throw FileSystemError.permissionDenied("An earlier iteration is read-only.") }

    /// A snapshot never changes.
    func watch(_ path: String) -> AsyncStream<FileSystemEvent> { AsyncStream { $0.finish() } }
}
