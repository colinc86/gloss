import Core
import Foundation

/// Complete validated captures only. Package coordination runs in Core, away from the UI actor.
actor ReviewFileSystem: FileSystemProvider {
    nonisolated let hostID = HostID.gloss
    struct Capture: Sendable { var data: Data; var date: Date }
    private var captures: [String: Capture] = [:]
    private var pictures: [String: [Int: [String: Data]]] = [:]
    private var currentRounds: [String: Int] = [:]
    private var watchers: [UUID: AsyncStream<FileSystemEvent>.Continuation] = [:]

    func adopt(_ data: Data, path: String, at date: Date, iteration: Int? = nil, images: [String: Data] = [:]) {
        let picturesChanged = iteration.map { currentRounds[path] != $0 || pictures[path]?[$0] != images } ?? false
        let changed = captures[path]?.data != data || picturesChanged
        if let iteration { currentRounds[path] = iteration; pictures[path,default: [:]][iteration] = images }
        captures[path] = Capture(data: data, date: date)
        if changed { for watcher in watchers.values { watcher.yield(.changed([path])) } }
    }
    func image(_ source: String, path: String, iteration: Int?) -> Data? {
        guard let round = iteration ?? currentRounds[path] else { return nil }
        return pictures[path]?[round]?[source]
    }
    func retainImages(_ images: [String: Data],path: String,iteration: Int) { pictures[path,default: [:]][iteration] = images }
    func read(_ path: String) async throws -> Data {
        guard let capture = captures[path] else { throw FileSystemError.notFound(path) }
        return capture.data
    }
    func stat(_ path: String) async throws -> FileAttributes {
        guard let capture = captures[path] else { throw FileSystemError.notFound(path) }
        return FileAttributes(kind: .file, size: Int64(capture.data.count), mtime: capture.date, mode: 0o444)
    }
    func list(_ directory: String) async throws -> [DirectoryEntry] { [] }
    func writeAtomically(_ data: Data, to path: String, preservingModeFrom original: FileAttributes?) async throws -> FileAttributes { throw FileSystemError.permissionDenied(path) }
    func makeDirectory(_ path: String) async throws { throw FileSystemError.permissionDenied(path) }
    func rename(_ path: String, to newPath: String) async throws { throw FileSystemError.permissionDenied(path) }
    func delete(_ path: String) async throws { throw FileSystemError.permissionDenied(path) }
    nonisolated func watch(_ path: String) -> AsyncStream<FileSystemEvent> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.add(continuation, id: id) }
            continuation.onTermination = { _ in Task { await self.remove(id) } }
        }
    }
    private func add(_ continuation: AsyncStream<FileSystemEvent>.Continuation, id: UUID) { watchers[id] = continuation }
    private func remove(_ id: UUID) { watchers[id] = nil }
}
