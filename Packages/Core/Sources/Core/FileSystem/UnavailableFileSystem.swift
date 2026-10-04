import Foundation

/// The file system of a host that has none to read: the web host, whose documents are pages the browser loads
/// itself. Every operation refuses and nothing ever changes.
public struct UnavailableFileSystem: FileSystemProvider {
    public let hostID: HostID

    public init(hostID: HostID) {
        self.hostID = hostID
    }

    public func list(_ directory: String) async throws -> [DirectoryEntry] { throw FileSystemError.permissionDenied(directory) }
    public func stat(_ path: String) async throws -> FileAttributes { throw FileSystemError.notFound(path) }
    public func read(_ path: String) async throws -> Data { throw FileSystemError.notFound(path) }
    public func writeAtomically(_ data: Data, to path: String, preservingModeFrom original: FileAttributes?) async throws -> FileAttributes { throw FileSystemError.permissionDenied(path) }
    public func makeDirectory(_ path: String) async throws { throw FileSystemError.permissionDenied(path) }
    public func rename(_ path: String, to newPath: String) async throws { throw FileSystemError.permissionDenied(path) }
    public func delete(_ path: String) async throws { throw FileSystemError.permissionDenied(path) }
    public func watch(_ path: String) -> AsyncStream<FileSystemEvent> { AsyncStream { $0.finish() } }
}
