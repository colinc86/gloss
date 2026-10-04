import Darwin
import Foundation

// At file scope the two-argument call resolves to the C function rather than the `stat` struct.
private typealias StatBuffer = stat
private func posixStat(_ path: String, _ info: inout StatBuffer) -> Int32 { stat(path, &info) }
private func posixLstat(_ path: String, _ info: inout StatBuffer) -> Int32 { lstat(path, &info) }
private func emptyStatBuffer() -> StatBuffer { StatBuffer() }

/// `FileSystemProvider` for the local Mac. Lists with `lstat`, writes atomically through a temp file and `rename(2)`,
/// deletes to the Trash by default, and watches with FSEvents.
public struct LocalFileSystem: FileSystemProvider {
    public enum DeleteBehavior: Sendable {
        case trash
        case permanent
    }

    public let hostID: HostID
    public let deleteBehavior: DeleteBehavior

    public init(hostID: HostID = .local, deleteBehavior: DeleteBehavior = .trash) {
        self.hostID = hostID
        self.deleteBehavior = deleteBehavior
    }

    public func list(_ directory: String) async throws -> [DirectoryEntry] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory)
        } catch {
            throw Self.map(error, path: directory)
        }
        return names.compactMap { name in
            let path = PathUtilities.join(directory, name)
            guard let info = Self.linkAttributes(path) else { return nil }
            var targetKind: FileKind?
            if info.kind == .symlink { targetKind = Self.attributes(path)?.kind }
            return DirectoryEntry(name: name, path: path, kind: info.kind, targetKind: targetKind, size: info.size, mtime: info.mtime, mode: info.mode)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func stat(_ path: String) async throws -> FileAttributes {
        guard let attributes = Self.attributes(path) else { throw Self.map(errno: errno, path: path) }
        return attributes
    }

    public func read(_ path: String) async throws -> Data {
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path), options: [.uncached])
        } catch {
            throw Self.map(error, path: path)
        }
    }

    public func writeAtomically(_ data: Data, to path: String, preservingModeFrom original: FileAttributes?) async throws -> FileAttributes {
        // Write to the symlink's target rather than replacing the link with a regular file.
        let path = Self.linkAttributes(path)?.kind == .symlink ? URL(fileURLWithPath: path).resolvingSymlinksInPath().path : path
        let directory = PathUtilities.parent(of: path)
        let name = PathUtilities.name(of: path)
        let mode = original?.mode ?? Self.attributes(path)?.mode ?? 0o644
        let temporary = PathUtilities.join(directory, ".cc-\(name)-\(UInt32.random(in: 0...UInt32.max)).tmp")
        do {
            // Made new (never through an existing file or link at that name) with the original's mode from the
            // start, so a private file is never readable by others in between; flushed before the rename, so a
            // crash leaves the old file or the new one, never an empty one.
            let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(mode & 0o7777))
            guard descriptor >= 0 else { throw Self.map(errno: errno, path: path) }
            var written = 0
            let failure: Int32? = data.withUnsafeBytes { buffer -> Int32? in
                while written < buffer.count {
                    let result = write(descriptor, buffer.baseAddress! + written, buffer.count - written)
                    if result < 0 { if errno == EINTR { continue }; return errno }
                    written += result
                }
                // The umask may have taken bits off at creation; the mode is set exactly.
                if fchmod(descriptor, mode_t(mode & 0o7777)) != 0 { return errno }
                if fsync(descriptor) != 0 { return errno }
                return nil
            }
            close(descriptor)
            if let failure {
                try? FileManager.default.removeItem(atPath: temporary)
                throw Self.map(errno: failure, path: path)
            }
            // The rename would otherwise drop the original's extended attributes (Finder tags, quarantine, app
            // metadata). Failure is fine: the file may not exist yet.
            _ = copyfile(path, temporary, nil, copyfile_flags_t(COPYFILE_XATTR))
            guard Foundation.rename(temporary, path) == 0 else {
                let code = errno
                try? FileManager.default.removeItem(atPath: temporary)
                throw Self.map(errno: code, path: path)
            }
        } catch let error as FileSystemError {
            throw error
        } catch {
            try? FileManager.default.removeItem(atPath: temporary)
            throw Self.map(error, path: path)
        }
        guard let attributes = Self.attributes(path) else { throw FileSystemError.io("stat after write failed for \(path)") }
        return attributes
    }

    public func makeDirectory(_ path: String) async throws {
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        } catch {
            throw Self.map(error, path: path)
        }
    }

    public func rename(_ path: String, to newPath: String) async throws {
        if FileManager.default.fileExists(atPath: newPath) { throw FileSystemError.alreadyExists(newPath) }
        do {
            try FileManager.default.moveItem(atPath: path, toPath: newPath)
        } catch {
            throw Self.map(error, path: path)
        }
    }

    public func delete(_ path: String) async throws {
        do {
            switch deleteBehavior {
            case .trash:
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            case .permanent:
                try FileManager.default.removeItem(atPath: path)
            }
        } catch {
            throw Self.map(error, path: path)
        }
    }

    public func watch(_ path: String) -> AsyncStream<FileSystemEvent> {
        FSEventsWatcher.events(forPaths: [path])
    }

    // MARK: POSIX helpers

    static func linkAttributes(_ path: String) -> FileAttributes? {
        var info = emptyStatBuffer()
        guard posixLstat(path, &info) == 0 else { return nil }
        return attributes(from: info)
    }

    static func attributes(_ path: String) -> FileAttributes? {
        var info = emptyStatBuffer()
        guard posixStat(path, &info) == 0 else { return nil }
        return attributes(from: info)
    }

    private static func attributes(from info: StatBuffer) -> FileAttributes {
        let kind: FileKind
        switch info.st_mode & S_IFMT {
        case S_IFREG: kind = .file
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symlink
        default: kind = .other
        }
        let mtime = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        return FileAttributes(kind: kind, size: Int64(info.st_size), mtime: mtime, mode: UInt16(info.st_mode & 0o7777))
    }

    static func map(errno code: Int32, path: String) -> FileSystemError {
        switch code {
        case ENOENT: .notFound(path)
        case EACCES, EPERM: .permissionDenied(path)
        case EEXIST: .alreadyExists(path)
        case ENOTDIR: .notADirectory(path)
        default: .io("\(String(cString: strerror(code))) (\(path))")
        }
    }

    static func map(_ error: any Error, path: String) -> FileSystemError {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError: return .notFound(path)
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return .permissionDenied(path)
            case NSFileWriteFileExistsError: return .alreadyExists(path)
            default: break
            }
        }
        if nsError.domain == NSPOSIXErrorDomain { return map(errno: Int32(nsError.code), path: path) }
        return .io("\(nsError.localizedDescription) (\(path))")
    }
}
