import CryptoKit
import Foundation

public enum FileKind: String, Sendable, Codable {
    case file
    case directory
    case symlink
    case other
}

public struct DirectoryEntry: Sendable, Hashable, Identifiable {
    public var name: String
    /// Absolute path.
    public var path: String
    public var kind: FileKind
    /// For symlinks, what the target is (nil when dangling).
    public var targetKind: FileKind?
    public var size: Int64?
    public var mtime: Date?
    /// POSIX permission bits.
    public var mode: UInt16?
    /// What a virtual file is about, shown beside its name (a Jira issue's summary); never part of its path.
    public var title: String?

    public init(name: String, path: String, kind: FileKind, targetKind: FileKind? = nil, size: Int64? = nil, mtime: Date? = nil, mode: UInt16? = nil, title: String? = nil) {
        self.name = name
        self.path = path
        self.kind = kind
        self.targetKind = targetKind
        self.size = size
        self.mtime = mtime
        self.mode = mode
        self.title = title
    }

    public var id: String { path }
    public var isHidden: Bool { name.hasPrefix(".") }
    /// Directories and symlinks to directories expand in the tree.
    public var isDirectoryLike: Bool { kind == .directory || (kind == .symlink && targetKind == .directory) }
}

public struct FileAttributes: Sendable, Hashable {
    public var kind: FileKind
    public var size: Int64
    public var mtime: Date
    public var mode: UInt16

    public init(kind: FileKind, size: Int64, mtime: Date, mode: UInt16) {
        self.kind = kind
        self.size = size
        self.mtime = mtime
        self.mode = mode
    }

    public var fingerprint: Fingerprint { Fingerprint(mtime: mtime, size: size, hash: nil) }
}

public enum FileSystemEvent: Sendable, Equatable {
    /// These paths changed (created, modified, renamed, or removed).
    case changed([String])
    /// Events were dropped; everything under this directory should be listed again.
    case rescan(String)
}

public enum FileSystemError: Error, Sendable, Equatable {
    case notFound(String)
    case permissionDenied(String)
    case alreadyExists(String)
    case notADirectory(String)
    case io(String)
    /// The file on disk differs from what the caller last read; `current` is its content now.
    case conflict(current: Data, fingerprint: Fingerprint)
}

extension FileSystemError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound(let path): "The file or folder is missing: \(path)"
        case .permissionDenied(let path): "Permission denied: \(path)"
        case .alreadyExists(let path): "A file or folder already exists: \(path)"
        case .notADirectory(let path): "Not a folder: \(path)"
        case .io(let message): message
        case .conflict: "The file changed on disk. Review the changes before saving."
        }
    }
}

/// Everything the explorer, viewers, and stager need from a host's files. `LocalFileSystem` now, SFTP later.
public protocol FileSystemProvider: Sendable {
    var hostID: HostID { get }
    func list(_ directory: String) async throws -> [DirectoryEntry]
    func stat(_ path: String) async throws -> FileAttributes
    func read(_ path: String) async throws -> Data
    /// Writes to a temporary file in the same directory and renames it over `path`, keeping `original`'s mode
    /// (or the existing file's mode, or 0644). Returns the attributes of the written file.
    func writeAtomically(_ data: Data, to path: String, preservingModeFrom original: FileAttributes?) async throws -> FileAttributes
    /// Creates an empty file exclusively; never replaces a file, directory, or symlink.
    func createFile(at path: String) async throws -> FileAttributes
    func makeDirectory(_ path: String) async throws
    /// Creates one folder, failing with `alreadyExists` when anything is at the path (New Folder never adopts one).
    func createDirectory(at path: String) async throws
    func rename(_ path: String, to newPath: String) async throws
    func delete(_ path: String) async throws
    /// Change events for a directory tree or a single file. Stops when the consumer cancels.
    func watch(_ path: String) -> AsyncStream<FileSystemEvent>
}

public enum ConflictCheck: Sendable, Equatable {
    case unchanged
    /// Bytes differ; here is the current content and its fingerprint.
    case changed(current: Data, fingerprint: Fingerprint)
}

extension FileSystemProvider {
    /// Read-only providers and test doubles must opt in to exclusive creation.
    public func createFile(at path: String) async throws -> FileAttributes {
        throw FileSystemError.permissionDenied(path)
    }

    public func createDirectory(at path: String) async throws {
        throw FileSystemError.permissionDenied(path)
    }

    /// Reads and hashes the file whenever a hash is known: mtime has one-second granularity on SFTP v3 and an agent
    /// can rewrite a file to the same length within that second, so size and mtime alone cannot prove it unchanged.
    /// Without a stored hash, size and mtime (at millisecond precision) are all there is.
    public func checkForChanges(at path: String, since expected: Fingerprint) async throws -> ConflictCheck {
        let attributes = try await stat(path)
        guard expected.hash != nil else {
            if let size = expected.size, let mtime = expected.mtime, size == attributes.size,
               (mtime.timeIntervalSince1970 * 1000).rounded() == (attributes.mtime.timeIntervalSince1970 * 1000).rounded() {
                return .unchanged
            }
            let data = try await read(path)
            return .changed(current: data, fingerprint: Fingerprint(mtime: attributes.mtime, size: attributes.size, hash: data.sha256Hex))
        }
        let data = try await read(path)
        let hash = data.sha256Hex
        if expected.hash == hash {
            return .unchanged
        }
        return .changed(current: data, fingerprint: Fingerprint(mtime: attributes.mtime, size: attributes.size, hash: hash))
    }

    /// Reads a file and returns its content with a full fingerprint.
    public func readWithFingerprint(_ path: String) async throws -> (data: Data, fingerprint: Fingerprint) {
        let attributes = try await stat(path)
        let data = try await read(path)
        return (data, Fingerprint(mtime: attributes.mtime, size: attributes.size, hash: data.sha256Hex))
    }
}

extension Data {
    public var sha256Hex: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}

public enum PathUtilities {
    public static func join(_ directory: String, _ name: String) -> String {
        directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    public static func parent(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    public static func name(of path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// An absolute path with `//`, `/./` and `/../` worked out from its text alone, without a trailing slash:
    /// `/proj/./docs/../README.md` is `/proj/README.md`. Documents and their notes are keyed by path, so a path an
    /// agent or a link spells another way must not become a second document. Unlike `standardizingPath` it never
    /// looks at this Mac's disk or home folder, so it holds for a host's paths too. A relative path comes back as it is.
    public static func lexicallyNormalized(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// `~` for `home` at the start of `path`, as a whole folder: `/Users/me/src` is `~/src`, `/Users/meg` stays.
    public static func abbreviatingHome(_ path: String, home: String) -> String {
        let home = home.hasSuffix("/") && home.count > 1 ? String(home.dropLast()) : home
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// `/a/b/c.md` relative to root `/a` is `b/c.md`; paths outside the root come back unchanged.
    public static func relative(_ path: String, to root: String) -> String {
        let normalizedRoot = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(normalizedRoot) ? String(path.dropFirst(normalizedRoot.count)) : path
    }
}
