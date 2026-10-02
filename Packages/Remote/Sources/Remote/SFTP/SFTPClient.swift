import Core
import Foundation
import OSLog

/// Bytes in and out of an SFTP server: the ssh subsystem's pipes, or an in-memory fake in tests.
public protocol SFTPTransport: Sendable {
    var incoming: AsyncStream<Data> { get }
    func send(_ data: Data) async throws
    func close()
}

/// The `sftp` subsystem over a `ChildProcess`.
public struct ChildProcessSFTPTransport: SFTPTransport {
    public let process: ChildProcess

    public init(process: ChildProcess) {
        self.process = process
    }

    public var incoming: AsyncStream<Data> { process.stdout }

    public func send(_ data: Data) async throws {
        try await process.write(data)
    }

    public func close() {
        process.closeStdin()
        process.terminate()
    }
}

public struct SFTPLimits: Sendable, Equatable {
    public var maxPacket: UInt64 = 0
    public var maxRead: UInt64 = 32768
    public var maxWrite: UInt64 = 32768
    public var maxOpenHandles: UInt64 = 0

    public init() {}
}

public struct SFTPEntry: Sendable, Equatable {
    public var name: String
    public var attributes: SFTPAttributes
    /// For symlinks, the target's attributes (nil when dangling).
    public var target: SFTPAttributes?
}

public enum SFTPClientError: Error, Sendable, Equatable {
    case connectionLost
    case protocolError(String)
    case unsupportedVersion(UInt32)
}

/// Pipelined SFTP v3 client: every call awaits its own continuation keyed by request id, so callers can
/// have many requests in flight and the server may answer out of order.
public actor SFTPClient {
    private static let log = Logger(subsystem: "com.cnc.Gloss", category: "sftp")
    public static let maxInFlight = 16

    private let transport: any SFTPTransport
    private var pending: [UInt32: CheckedContinuation<SFTPReply, any Error>] = [:]
    private var versionWaiter: CheckedContinuation<SFTPReply, any Error>?
    private var nextID: UInt32 = 1
    private var buffer = Data()
    private var reader: Task<Void, Never>?
    private var closed = false

    public private(set) var extensions: [String: String] = [:]
    public private(set) var limits = SFTPLimits()
    public private(set) var homeDirectory = "/"

    public var isOpen: Bool { !closed }
    public var supportsPosixRename: Bool { extensions["posix-rename@openssh.com"] != nil }
    public var supportsFsync: Bool { extensions["fsync@openssh.com"] != nil }

    private init(transport: any SFTPTransport) {
        self.transport = transport
    }

    /// INIT → VERSION, then `limits@openssh.com` when advertised, then the home directory.
    public static func connect(transport: any SFTPTransport) async throws -> SFTPClient {
        let client = SFTPClient(transport: transport)
        try await client.handshake()
        return client
    }

    private func handshake() async throws {
        reader = Task { [weak self] in
            guard let self else { return }
            for await chunk in transport.incoming {
                await self.received(chunk)
            }
            await self.transportEnded()
        }
        let reply: SFTPReply = try await withCheckedThrowingContinuation { continuation in
            versionWaiter = continuation
            Task {
                do { try await transport.send(SFTPCodec.encode(.initialize(version: 3), id: 0)) } catch { self.failVersion(error) }
            }
        }
        guard case .version(let version, let extensions) = reply else { throw SFTPClientError.protocolError("expected VERSION") }
        guard version == 3 else { throw SFTPClientError.unsupportedVersion(version) }
        self.extensions = extensions
        if extensions["limits@openssh.com"] != nil, case .extendedReply(let data) = try await request(.extended(name: "limits@openssh.com", data: Data())) {
            var reader = BinaryReader(data)
            var limits = SFTPLimits()
            limits.maxPacket = try reader.uint64()
            limits.maxRead = max(4096, min(try reader.uint64(), 4 * 1024 * 1024))
            limits.maxWrite = max(4096, min(try reader.uint64(), 4 * 1024 * 1024))
            limits.maxOpenHandles = try reader.uint64()
            self.limits = limits
        }
        homeDirectory = try await realpath(".")
    }

    private func failVersion(_ error: any Error) {
        versionWaiter?.resume(throwing: error)
        versionWaiter = nil
    }

    private func received(_ chunk: Data) {
        buffer.append(chunk)
        while true {
            let frame: SFTPFrame?
            do {
                frame = try SFTPCodec.decode(from: &buffer)
            } catch {
                Self.log.error("SFTP framing error: \(error, privacy: .public)")
                failAll(SFTPClientError.protocolError("\(error)"))
                transport.close()
                return
            }
            guard let frame else { return }
            if let id = frame.id {
                if let continuation = pending.removeValue(forKey: id) {
                    continuation.resume(returning: frame.reply)
                } else {
                    Self.log.error("SFTP reply for unknown id \(id)")
                }
            } else if let waiter = versionWaiter {
                versionWaiter = nil
                waiter.resume(returning: frame.reply)
            }
        }
    }

    private func transportEnded() {
        closed = true
        failAll(SFTPClientError.connectionLost)
    }

    private func failAll(_ error: any Error) {
        let waiters = pending.values
        pending = [:]
        for waiter in waiters { waiter.resume(throwing: error) }
        versionWaiter?.resume(throwing: error)
        versionWaiter = nil
    }

    public func close() {
        closed = true
        reader?.cancel()
        transport.close()
        failAll(SFTPClientError.connectionLost)
    }

    // MARK: Raw requests

    public func request(_ request: SFTPRequest) async throws -> SFTPReply {
        guard !closed else { throw SFTPClientError.connectionLost }
        let id = nextID
        nextID = nextID == UInt32.max ? 1 : nextID + 1
        let packet = SFTPCodec.encode(request, id: id)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task {
                do {
                    try await transport.send(packet)
                } catch {
                    if let waiter = self.takePending(id) { waiter.resume(throwing: error) }
                }
            }
        }
    }

    private func takePending(_ id: UInt32) -> CheckedContinuation<SFTPReply, any Error>? {
        pending.removeValue(forKey: id)
    }

    private func expectStatus(_ reply: SFTPReply) throws {
        guard case .status(let status) = reply else { throw SFTPClientError.protocolError("expected STATUS") }
        guard status.code == .ok else { throw status }
    }

    // MARK: Typed operations

    public func open(_ path: String, flags: SFTPOpenFlags, attributes: SFTPAttributes = SFTPAttributes()) async throws -> Data {
        switch try await request(.open(path: path, flags: flags, attributes: attributes)) {
        case .handle(let handle): return handle
        case .status(let status): throw status
        default: throw SFTPClientError.protocolError("expected HANDLE")
        }
    }

    public func close(handle: Data) async throws {
        try expectStatus(try await request(.close(handle: handle)))
    }

    /// Nil at EOF.
    public func read(handle: Data, offset: UInt64, length: UInt32) async throws -> Data? {
        switch try await request(.read(handle: handle, offset: offset, length: length)) {
        case .data(let data): return data
        case .status(let status) where status.code == .eof: return nil
        case .status(let status): throw status
        default: throw SFTPClientError.protocolError("expected DATA")
        }
    }

    public func write(handle: Data, offset: UInt64, data: Data) async throws {
        try expectStatus(try await request(.write(handle: handle, offset: offset, data: data)))
    }

    private func attrs(_ reply: SFTPReply) throws -> SFTPAttributes {
        switch reply {
        case .attrs(let attributes): return attributes
        case .status(let status): throw status
        default: throw SFTPClientError.protocolError("expected ATTRS")
        }
    }

    public func stat(_ path: String) async throws -> SFTPAttributes { try attrs(try await request(.stat(path: path))) }
    public func lstat(_ path: String) async throws -> SFTPAttributes { try attrs(try await request(.lstat(path: path))) }
    public func fstat(handle: Data) async throws -> SFTPAttributes { try attrs(try await request(.fstat(handle: handle))) }
    public func setstat(_ path: String, _ attributes: SFTPAttributes) async throws { try expectStatus(try await request(.setstat(path: path, attributes: attributes))) }
    public func fsetstat(handle: Data, _ attributes: SFTPAttributes) async throws { try expectStatus(try await request(.fsetstat(handle: handle, attributes: attributes))) }
    public func remove(_ path: String) async throws { try expectStatus(try await request(.remove(path: path))) }
    public func mkdir(_ path: String, attributes: SFTPAttributes = SFTPAttributes()) async throws { try expectStatus(try await request(.mkdir(path: path, attributes: attributes))) }
    public func rmdir(_ path: String) async throws { try expectStatus(try await request(.rmdir(path: path))) }
    public func rename(_ oldPath: String, to newPath: String) async throws { try expectStatus(try await request(.rename(oldPath: oldPath, newPath: newPath))) }

    public func opendir(_ path: String) async throws -> Data {
        switch try await request(.opendir(path: path)) {
        case .handle(let handle): return handle
        case .status(let status): throw status
        default: throw SFTPClientError.protocolError("expected HANDLE")
        }
    }

    /// Nil at EOF.
    public func readdir(handle: Data) async throws -> [SFTPName]? {
        switch try await request(.readdir(handle: handle)) {
        case .name(let names): return names
        case .status(let status) where status.code == .eof: return nil
        case .status(let status): throw status
        default: throw SFTPClientError.protocolError("expected NAME")
        }
    }

    public func realpath(_ path: String) async throws -> String {
        switch try await request(.realpath(path: path)) {
        case .name(let names): guard let first = names.first else { throw SFTPClientError.protocolError("empty REALPATH") }; return first.filename
        case .status(let status): throw status
        default: throw SFTPClientError.protocolError("expected NAME")
        }
    }

    public func readlink(_ path: String) async throws -> String {
        switch try await request(.readlink(path: path)) {
        case .name(let names): guard let first = names.first else { throw SFTPClientError.protocolError("empty READLINK") }; return first.filename
        case .status(let status): throw status
        default: throw SFTPClientError.protocolError("expected NAME")
        }
    }

    /// `posix-rename@openssh.com`: atomic overwrite.
    public func posixRename(_ oldPath: String, to newPath: String) async throws {
        var writer = BinaryWriter()
        writer.append(oldPath)
        writer.append(newPath)
        try expectStatus(try await request(.extended(name: "posix-rename@openssh.com", data: writer.data)))
    }

    public func fsync(handle: Data) async throws {
        var writer = BinaryWriter()
        writer.append(handle)
        try expectStatus(try await request(.extended(name: "fsync@openssh.com", data: writer.data)))
    }

    // MARK: Higher-level

    /// Reads a whole file with up to 16 READs in flight, reassembled by offset.
    public func readFile(_ path: String) async throws -> Data {
        let handle = try await open(path, flags: .read)
        defer { Task { try? await self.close(handle: handle) } }
        let size = try await fstat(handle: handle).size ?? 0
        let chunk = limits.maxRead
        var result = Data(capacity: Int(size))
        var offset: UInt64 = 0
        var reachedEOF = false
        while !reachedEOF {
            let count = max(1, min(Self.maxInFlight, Int((size - min(offset, size) + chunk - 1) / chunk)))
            let offsets = (0..<count).map { offset + UInt64($0) * chunk }
            let pieces: [(UInt64, Data?)] = try await withThrowingTaskGroup(of: (UInt64, Data?).self) { group in
                for start in offsets {
                    group.addTask { (start, try await self.read(handle: handle, offset: start, length: UInt32(chunk))) }
                }
                var collected: [(UInt64, Data?)] = []
                for try await piece in group { collected.append(piece) }
                return collected.sorted { $0.0 < $1.0 }
            }
            for (start, data) in pieces {
                guard let data, !data.isEmpty else { reachedEOF = true; break }
                if UInt64(result.count) != start { result.count = Int(start) }
                result.append(data)
                if UInt64(data.count) < chunk { reachedEOF = true; break }
            }
            offset += UInt64(count) * chunk
            if offset >= size && size > 0 && !reachedEOF {
                // Past the size we started with; one more read confirms EOF (the file may have grown).
                if let extra = try await read(handle: handle, offset: UInt64(result.count), length: UInt32(chunk)), !extra.isEmpty {
                    result.append(extra)
                } else {
                    reachedEOF = true
                }
            }
            if size == 0 && !reachedEOF, pieces.allSatisfy({ $0.1 == nil || $0.1!.isEmpty }) { reachedEOF = true }
        }
        return result
    }

    /// Writes a whole file through an already opened handle, chunked to `maxWrite`, 8 writes in flight.
    public func writeAll(handle: Data, data: Data) async throws {
        let chunk = Int(limits.maxWrite)
        var offset = 0
        while offset < data.count {
            let batchEnd = min(data.count, offset + chunk * 8)
            try await withThrowingTaskGroup(of: Void.self) { group in
                var start = offset
                while start < batchEnd {
                    let end = min(batchEnd, start + chunk)
                    let piece = data.subdata(in: start..<end)
                    let at = UInt64(start)
                    group.addTask { try await self.write(handle: handle, offset: at, data: piece) }
                    start = end
                }
                for try await _ in group {}
            }
            offset = batchEnd
        }
    }

    /// OPENDIR → READDIR until EOF → CLOSE, without `.` and `..`, symlink targets stat'ed.
    public func listDirectory(_ path: String) async throws -> [SFTPEntry] {
        let handle = try await opendir(path)
        var names: [SFTPName] = []
        do {
            while let page = try await readdir(handle: handle) { names.append(contentsOf: page) }
        } catch {
            try? await close(handle: handle)
            throw error
        }
        try await close(handle: handle)
        var entries: [SFTPEntry] = []
        entries.reserveCapacity(names.count)
        for name in names where name.filename != "." && name.filename != ".." {
            var entry = SFTPEntry(name: name.filename, attributes: name.attributes, target: nil)
            if name.attributes.fileType == .symlink {
                entry.target = try? await stat(PathUtilities.join(path, name.filename))
            }
            entries.append(entry)
        }
        return entries
    }
}
