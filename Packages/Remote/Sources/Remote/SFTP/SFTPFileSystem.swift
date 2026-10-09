import Core
import Foundation
import OSLog

/// Keeps one SFTP client per connection and reopens it when the channel drops.
public actor SFTPChannel {
    private var sweptDirectories: Set<String> = []

    /// A connection drop mid-save leaves `.cc-<name>-<hex>.tmp` behind. Runs once per directory per channel, after
    /// a save (not before, so a huge directory listing never delays the write), and only removes files older than a
    /// week so a temp file kept as the sole copy after a failed fallback rename survives long enough to be noticed.
    func sweepStaleTemporariesOnce(in directory: String, client: SFTPClient) async {
        guard !sweptDirectories.contains(directory) else { return }
        sweptDirectories.insert(directory)
        guard let entries = try? await client.listDirectory(directory) else { return }
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        for entry in entries where entry.name.hasPrefix(".cc-") && entry.name.hasSuffix(".tmp") {
            if let seconds = entry.attributes.mtime, Date(timeIntervalSince1970: TimeInterval(seconds)) < cutoff {
                try? await client.remove(PathUtilities.join(directory, entry.name))
            }
        }
    }

    private let connection: SSHConnection?
    private var client: SFTPClient?
    private var opening: Task<SFTPClient, any Error>?

    public init(connection: SSHConnection) {
        self.connection = connection
    }

    /// A channel around an already connected client (tests, or a transport opened elsewhere).
    public init(client: SFTPClient) {
        connection = nil
        self.client = client
    }

    public func client() async throws -> SFTPClient {
        if let client, await client.isOpen { return client }
        if let opening { return try await opening.value }
        guard let connection else { throw SFTPClientError.connectionLost }
        let task = Task<SFTPClient, any Error> {
            let process = try await connection.openSFTPSubsystem()
            let stderrTask = Task { String(decoding: await process.collectStderr(), as: UTF8.self) }
            do {
                return try await SFTPClient.connect(transport: ChildProcessSFTPTransport(process: process))
            } catch SFTPClientError.connectionLost {
                let status = (try? await process.exitCode) ?? -1
                let stderr = await stderrTask.value.trimmingCharacters(in: .whitespacesAndNewlines)
                throw SFTPClientError.subsystemFailed("ssh exited \(status): \(stderr)")
            }
        }
        opening = task
        defer { opening = nil }
        let client = try await task.value
        self.client = client
        return client
    }

    public func close() async {
        await client?.close()
        client = nil
    }
}

/// `FileSystemProvider` over SFTP. Saves go through a temp file, `fsync`, and `posix-rename`.
public struct SFTPFileSystem: FileSystemProvider {
    private static let log = Logger(subsystem: "com.cnc.Gloss", category: "sftp")

    public let hostID: HostID
    public let channel: SFTPChannel
    /// Poll intervals for `watch`.
    public var focusedInterval: Duration = .seconds(3)
    public var backgroundInterval: Duration = .seconds(10)
    /// Fired once per host when a save had to fall back to a non-atomic rename.
    public var onNonAtomicSave: (@Sendable () -> Void)?

    public init(hostID: HostID, channel: SFTPChannel) {
        self.hostID = hostID
        self.channel = channel
    }

    public init(hostID: HostID, connection: SSHConnection) {
        self.init(hostID: hostID, channel: SFTPChannel(connection: connection))
    }

    public func homeDirectory() async throws -> String {
        try await channel.client().homeDirectory
    }

    public func list(_ directory: String) async throws -> [DirectoryEntry] {
        let client = try await channel.client()
        do {
            let entries = try await client.listDirectory(directory)
            return entries.map { entry in
                DirectoryEntry(
                    name: entry.name, path: PathUtilities.join(directory, entry.name),
                    kind: Self.kind(entry.attributes.fileType), targetKind: entry.target.map { Self.kind($0.fileType) },
                    size: entry.attributes.size.map { Int64(clamping: $0) }, mtime: entry.attributes.mtime.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    mode: entry.attributes.mode
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch let status as SFTPStatus {
            throw Self.map(status, path: directory)
        }
    }

    /// Where a path really is on the host, links followed (the server's realpath).
    public func resolvedPath(_ path: String) async throws -> String {
        try await channel.client().realpath(path)
    }

    public func stat(_ path: String) async throws -> FileAttributes {
        let client = try await channel.client()
        do {
            return Self.attributes(try await client.stat(path))
        } catch let status as SFTPStatus {
            throw Self.map(status, path: path)
        }
    }

    public func read(_ path: String) async throws -> Data {
        let client = try await channel.client()
        do {
            return try await client.readFile(path)
        } catch let status as SFTPStatus {
            throw Self.map(status, path: path)
        } catch SFTPClientError.fileTooLarge(let limit) {
            throw FileSystemError.io("\(path) is larger than \(ByteCountFormatter.string(fromByteCount: Int64(clamping: limit), countStyle: .file)), or never ends")
        }
    }

    public func createFile(at path: String) async throws -> FileAttributes {
        let client = try await channel.client()
        let handle: Data
        do {
            handle = try await client.open(path, flags: [.write, .create, .exclusive], attributes: SFTPAttributes(permissions: 0o644))
        } catch let status as SFTPStatus {
            // v3 reports collisions as generic FAILURE. lstat also sees dangling symlinks.
            if (try? await client.lstat(path)) != nil { throw FileSystemError.alreadyExists(path) }
            throw Self.map(status, path: path)
        }
        do { try await client.close(handle: handle) }
        catch { throw FileSystemError.io("The file was created, but closing it failed: \(error). Refresh the folder before trying again.") }
        return try await stat(path)
    }

    public func writeAtomically(_ data: Data, to path: String, preservingModeFrom original: FileAttributes?) async throws -> FileAttributes {
        let client = try await channel.client()
        // Saving through a symlink replaces the target, not the link; dotfiles checkouts depend on that.
        var target = path
        if let link = try? await client.lstat(path), link.fileType == .symlink, let resolved = try? await client.realpath(path) {
            target = resolved
        }
        var mode = UInt32(original?.mode ?? 0o644)
        if original == nil, let existing = try? await client.stat(target) { mode = UInt32(existing.mode) }
        let directory = PathUtilities.parent(of: target)
        let name = PathUtilities.name(of: target)
        let temporary = PathUtilities.join(directory, ".cc-\(name)-\(String(UInt32.random(in: 0...UInt32.max), radix: 16)).tmp")
        defer { Task { await channel.sweepStaleTemporariesOnce(in: directory, client: client) } }
        var originalRemoved = false
        do {
            let handle = try await client.open(temporary, flags: [.write, .create, .exclusive, .truncate], attributes: SFTPAttributes(permissions: mode))
            do {
                try await client.writeAll(handle: handle, data: data)
                try await client.fsetstat(handle: handle, SFTPAttributes(permissions: mode))
                if await client.supportsFsync { try await client.fsync(handle: handle) }
                try await client.close(handle: handle)
            } catch {
                try? await client.close(handle: handle)
                try? await client.remove(temporary)
                throw error
            }
            if await client.supportsPosixRename {
                try await client.posixRename(temporary, to: target)
            } else {
                onNonAtomicSave?()
                try? await client.remove(target)
                originalRemoved = true
                try await client.rename(temporary, to: target)
            }
            return Self.attributes(try await client.stat(target))
        } catch let status as SFTPStatus {
            // Once the original is gone the temp file is the only copy of the new bytes: leave it and name it.
            if originalRemoved { throw Self.map(status, path: temporary) }
            try? await client.remove(temporary)
            throw Self.map(status, path: path)
        }
    }

    public func createDirectory(at path: String) async throws {
        let client = try await channel.client()
        do {
            try await client.mkdir(path, attributes: SFTPAttributes(permissions: 0o755))
        } catch let status as SFTPStatus {
            // v3 reports collisions as generic FAILURE. lstat also sees dangling symlinks.
            if (try? await client.lstat(path)) != nil { throw FileSystemError.alreadyExists(path) }
            throw Self.map(status, path: path)
        }
    }

    public func makeDirectory(_ path: String) async throws {
        let client = try await channel.client()
        var current = ""
        for component in path.split(separator: "/") {
            current += "/" + component
            if (try? await client.stat(current)) != nil { continue }
            do {
                try await client.mkdir(current, attributes: SFTPAttributes(permissions: 0o755))
            } catch let status as SFTPStatus where status.code == .failure {
                if (try? await client.stat(current)) == nil { throw Self.map(status, path: current) }
            } catch let status as SFTPStatus {
                throw Self.map(status, path: current)
            }
        }
    }

    public func rename(_ path: String, to newPath: String) async throws {
        let client = try await channel.client()
        if (try? await client.lstat(newPath)) != nil { throw FileSystemError.alreadyExists(newPath) }
        do {
            try await client.rename(path, to: newPath)
        } catch let status as SFTPStatus {
            throw Self.map(status, path: path)
        }
    }

    /// Unlinks files; removes directories recursively.
    public func delete(_ path: String) async throws {
        let client = try await channel.client()
        do {
            let attributes = try await client.lstat(path)
            if attributes.fileType == .directory {
                for entry in try await client.listDirectory(path) {
                    try await delete(PathUtilities.join(path, entry.name))
                }
                try await client.rmdir(path)
            } else {
                try await client.remove(path)
            }
        } catch let status as SFTPStatus {
            throw Self.map(status, path: path)
        }
    }

    /// Polls: a file's size and mtime, or a directory's listing, at `focusedInterval`.
    public func watch(_ path: String) -> AsyncStream<FileSystemEvent> {
        let channel = channel
        let interval = focusedInterval
        return AsyncStream { continuation in
            let task = Task {
                var lastFile: (UInt64?, UInt32?)?
                var lastListing: [String: (UInt64?, UInt32?)]?
                var missing = false
                while !Task.isCancelled {
                    do {
                        let client = try await channel.client()
                        let attributes = try await client.stat(path)
                        if attributes.fileType == .directory {
                            let entries = try await client.listDirectory(path)
                            // A name can come twice when the folder changes between READDIR pages; keep the first rather than trap.
                            let listing = Dictionary(entries.map { ($0.name, ($0.attributes.size, $0.attributes.mtime)) }, uniquingKeysWith: { first, _ in first })
                            if let previous = lastListing {
                                var changed = Set(listing.keys).symmetricDifference(previous.keys)
                                for (name, current) in listing {
                                    if let before = previous[name], before.0 != current.0 || before.1 != current.1 { changed.insert(name) }
                                }
                                if !changed.isEmpty { continuation.yield(.changed(changed.map { PathUtilities.join(path, $0) })) }
                            }
                            lastListing = listing
                        } else {
                            let current = (attributes.size, attributes.mtime)
                            if let previous = lastFile, previous != current { continuation.yield(.changed([path])) }
                            // Back after being missing: the viewer clears its "Deleted on disk" banner and reloads.
                            if missing { continuation.yield(.changed([path])) }
                            lastFile = current
                        }
                        missing = false
                    } catch let status as SFTPStatus where status.code == .noSuchFile {
                        // Gone: say so once (the viewer shows "Deleted on disk"), not on every tick.
                        if !missing { continuation.yield(.changed([path])) }
                        missing = true
                        lastFile = nil
                    } catch {
                        // Connection hiccups: try again next tick.
                    }
                    try? await Task.sleep(for: interval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Mapping

    static func kind(_ type: SFTPFileType) -> FileKind {
        switch type {
        case .regular: .file
        case .directory: .directory
        case .symlink: .symlink
        case .other, .unknown: .other
        }
    }

    static func attributes(_ attributes: SFTPAttributes) -> FileAttributes {
        FileAttributes(
            // A server that leaves out permissions gives no type; that is not evidence of a FIFO or device, and
            // documents refuse `.other`, so an unknown type is taken as a regular file.
            kind: attributes.fileType == .unknown ? .file : kind(attributes.fileType), size: Int64(clamping: attributes.size ?? 0),
            mtime: Date(timeIntervalSince1970: TimeInterval(attributes.mtime ?? 0)), mode: attributes.mode
        )
    }

    static func map(_ status: SFTPStatus, path: String) -> FileSystemError {
        switch status.code {
        case .noSuchFile: .notFound(path)
        case .permissionDenied: .permissionDenied(path)
        default: .io("\(status.message.isEmpty ? "SFTP status \(status.rawCode)" : status.message) (\(path))")
        }
    }
}
