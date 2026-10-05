import Foundation
import Synchronization
@testable import Remote

/// An in-memory SFTP v3 server behind the transport seam. Replies can be shuffled to exercise reassembly.
final class FakeSFTPServer: SFTPTransport, @unchecked Sendable {
    struct File {
        var data: Data
        var permissions: UInt32
        var mtime: UInt32
        /// Answers every READ with a full buffer and never EOF, like /dev/zero or a FIFO.
        var endless = false
        /// The size ATTRS report instead of the data's, as a broken or hostile server might.
        var reportedSize: UInt64?
    }

    private struct State {
        var files: [String: File] = [:]
        var directories: Set<String> = ["/", "/home", "/home/test"]
        var handles: [String: Handle] = [:]
        var nextHandle = 1
        var buffer = Data()
        var queued: [Data] = []
        var closed = false
    }

    private struct Handle {
        var path: String
        var isDirectory: Bool
        var listed = false
    }

    private let state = Mutex(State())
    private let continuation: AsyncStream<Data>.Continuation
    let incoming: AsyncStream<Data>
    let shuffleReplies: Bool
    let extensions: [String: String]

    init(shuffleReplies: Bool = false, extensions: [String: String] = ["posix-rename@openssh.com": "1", "fsync@openssh.com": "1", "limits@openssh.com": "1"]) {
        self.shuffleReplies = shuffleReplies
        self.extensions = extensions
        var continuation: AsyncStream<Data>.Continuation!
        incoming = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func put(_ path: String, _ text: String, permissions: UInt32 = 0o644, mtime: UInt32 = 1_700_000_000) {
        state.withLock { state in
            state.files[path] = File(data: Data(text.utf8), permissions: permissions, mtime: mtime)
            var directory = (path as NSString).deletingLastPathComponent
            while directory.count > 1 {
                state.directories.insert(directory)
                directory = (directory as NSString).deletingLastPathComponent
            }
        }
    }

    /// A file whose READs never end, with the size its ATTRS claim.
    func putEndless(_ path: String, reportedSize: UInt64 = 0) {
        state.withLock { $0.files[path] = File(data: Data(), permissions: 0o644, mtime: 1_700_000_000, endless: true, reportedSize: reportedSize) }
    }

    func put(_ path: String, _ text: String, reportedSize: UInt64) {
        put(path, text)
        state.withLock { $0.files[path]?.reportedSize = reportedSize }
    }

    func contents(_ path: String) -> String? {
        state.withLock { $0.files[path].map { String(decoding: $0.data, as: UTF8.self) } }
    }

    func file(_ path: String) -> File? { state.withLock { $0.files[path] } }
    func hasDirectory(_ path: String) -> Bool { state.withLock { $0.directories.contains(path) } }
    func openHandleCount() -> Int { state.withLock { $0.handles.count } }

    func send(_ data: Data) async throws {
        var replies: [Data] = []
        state.withLock { state in
            state.buffer.append(data)
            while let frame = try? Self.nextRequest(from: &state.buffer) {
                replies.append(contentsOf: handle(frame, &state))
            }
        }
        if shuffleReplies { replies.shuffle() }
        for reply in replies { continuation.yield(reply) }
    }

    func close() {
        state.withLock { $0.closed = true }
        continuation.finish()
    }

    // MARK: Request decoding (the client's codec only decodes replies, so requests are parsed here)

    private struct Request {
        var type: SFTPPacketType
        var id: UInt32
        var reader: BinaryReader
    }

    private static func nextRequest(from buffer: inout Data) throws -> Request? {
        guard buffer.count >= 4 else { return nil }
        var header = BinaryReader(buffer)
        let length = Int(try header.uint32())
        guard buffer.count >= 4 + length else { return nil }
        let payload = buffer.subdata(in: 4..<(4 + length))
        buffer.removeSubrange(0..<(4 + length))
        var reader = BinaryReader(payload)
        guard let type = SFTPPacketType(rawValue: try reader.uint8()) else { throw SFTPCodecError.unknownType(0) }
        let id = type == .initialize ? 0 : try reader.uint32()
        return Request(type: type, id: id, reader: reader)
    }

    private func reply(_ type: SFTPPacketType, id: UInt32?, body: (inout BinaryWriter) -> Void) -> Data {
        var writer = BinaryWriter()
        writer.append(type.rawValue)
        if let id { writer.append(id) }
        body(&writer)
        var packet = BinaryWriter()
        packet.append(UInt32(writer.data.count))
        packet.appendRaw(writer.data)
        return packet.data
    }

    private func status(_ id: UInt32, _ code: SFTPStatusCode, _ message: String = "") -> Data {
        reply(.status, id: id) { $0.append(code.rawValue); $0.append(message); $0.append("") }
    }

    private func attrs(_ file: File) -> SFTPAttributes {
        SFTPAttributes(size: file.reportedSize ?? UInt64(file.data.count), uid: 501, gid: 20, permissions: 0o100000 | file.permissions, atime: file.mtime, mtime: file.mtime)
    }

    private func directoryAttrs() -> SFTPAttributes {
        SFTPAttributes(size: 4096, permissions: 0o040755, atime: 1, mtime: 1)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func handle(_ request: Request, _ state: inout State) -> [Data] {
        var reader = request.reader
        let id = request.id
        func open(_ path: String, isDirectory: Bool) -> Data {
            let handle = "h\(state.nextHandle)"
            state.nextHandle += 1
            state.handles[handle] = Handle(path: path, isDirectory: isDirectory)
            return Data(handle.utf8)
        }
        do {
            switch request.type {
            case .initialize:
                return [reply(.version, id: nil) { writer in
                    writer.append(UInt32(3))
                    for (name, value) in extensions.sorted(by: { $0.key < $1.key }) { writer.append(name); writer.append(value) }
                }]
            case .extended:
                let name = try reader.string()
                switch name {
                case "limits@openssh.com":
                    return [reply(.extendedReply, id: id) { $0.append(UInt64(261120)); $0.append(UInt64(1000)); $0.append(UInt64(1000)); $0.append(UInt64(100)) }]
                case "posix-rename@openssh.com":
                    let old = try reader.string(); let new = try reader.string()
                    guard let file = state.files.removeValue(forKey: old) else { return [status(id, .noSuchFile)] }
                    state.files[new] = file
                    return [status(id, .ok)]
                case "fsync@openssh.com":
                    return [status(id, .ok)]
                default:
                    return [status(id, .opUnsupported)]
                }
            case .realpath:
                let path = try reader.string()
                let resolved = path == "." ? "/home/test" : path
                return [reply(.name, id: id) { $0.append(UInt32(1)); $0.append(resolved); $0.append(resolved); $0.append(SFTPAttributes()) }]
            case .stat, .lstat:
                let path = try reader.string()
                if let file = state.files[path] { return [reply(.attrs, id: id) { $0.append(self.attrs(file)) }] }
                if state.directories.contains(path) { return [reply(.attrs, id: id) { $0.append(self.directoryAttrs()) }] }
                return [status(id, .noSuchFile, "No such file")]
            case .open:
                let path = try reader.string()
                let flags = SFTPOpenFlags(rawValue: try reader.uint32())
                let attributes = try reader.attributes()
                if flags.contains(.create) {
                    if flags.contains(.exclusive), state.files[path] != nil { return [status(id, .failure, "exists")] }
                    if state.files[path] == nil || flags.contains(.truncate) {
                        state.files[path] = File(data: Data(), permissions: attributes.permissions ?? 0o644, mtime: UInt32(Date().timeIntervalSince1970))
                    }
                } else if state.files[path] == nil {
                    return [status(id, .noSuchFile)]
                }
                return [reply(.handle, id: id) { $0.append(open(path, isDirectory: false)) }]
            case .close:
                let handle = String(decoding: try reader.bytes(), as: UTF8.self)
                state.handles[handle] = nil
                return [status(id, .ok)]
            case .read:
                let handle = String(decoding: try reader.bytes(), as: UTF8.self)
                let offset = Int(try reader.uint64()); let length = Int(try reader.uint32())
                guard let open = state.handles[handle], let file = state.files[open.path] else { return [status(id, .failure)] }
                if file.endless { return [reply(.data, id: id) { $0.append(Data(count: length)) }] }
                guard offset < file.data.count else { return [status(id, .eof)] }
                let slice = file.data.subdata(in: offset..<min(file.data.count, offset + length))
                return [reply(.data, id: id) { $0.append(slice) }]
            case .write:
                let handle = String(decoding: try reader.bytes(), as: UTF8.self)
                let offset = Int(try reader.uint64()); let data = try reader.bytes()
                guard let open = state.handles[handle], var file = state.files[open.path] else { return [status(id, .failure)] }
                if file.data.count < offset + data.count { file.data.count = offset + data.count }
                file.data.replaceSubrange(offset..<(offset + data.count), with: data)
                file.mtime = UInt32(Date().timeIntervalSince1970)
                state.files[open.path] = file
                return [status(id, .ok)]
            case .fstat:
                let handle = String(decoding: try reader.bytes(), as: UTF8.self)
                guard let open = state.handles[handle], let file = state.files[open.path] else { return [status(id, .failure)] }
                return [reply(.attrs, id: id) { $0.append(self.attrs(file)) }]
            case .fsetstat:
                let handle = String(decoding: try reader.bytes(), as: UTF8.self)
                let attributes = try reader.attributes()
                guard let open = state.handles[handle], var file = state.files[open.path] else { return [status(id, .failure)] }
                if let permissions = attributes.permissions { file.permissions = permissions & 0o7777 }
                state.files[open.path] = file
                return [status(id, .ok)]
            case .setstat:
                let path = try reader.string(); let attributes = try reader.attributes()
                guard var file = state.files[path] else { return [status(id, .noSuchFile)] }
                if let permissions = attributes.permissions { file.permissions = permissions & 0o7777 }
                state.files[path] = file
                return [status(id, .ok)]
            case .opendir:
                let path = try reader.string()
                guard state.directories.contains(path) else { return [status(id, .noSuchFile)] }
                return [reply(.handle, id: id) { $0.append(open(path, isDirectory: true)) }]
            case .readdir:
                let handle = String(decoding: try reader.bytes(), as: UTF8.self)
                guard var open = state.handles[handle], open.isDirectory else { return [status(id, .failure)] }
                if open.listed { return [status(id, .eof)] }
                open.listed = true
                state.handles[handle] = open
                let prefix = open.path == "/" ? "/" : open.path + "/"
                var names: [(String, SFTPAttributes)] = [(".", directoryAttrs()), ("..", directoryAttrs())]
                for (path, file) in state.files where path.hasPrefix(prefix) && !path.dropFirst(prefix.count).contains("/") {
                    names.append((String(path.dropFirst(prefix.count)), attrs(file)))
                }
                for directory in state.directories where directory.hasPrefix(prefix) && directory != open.path && !directory.dropFirst(prefix.count).contains("/") {
                    names.append((String(directory.dropFirst(prefix.count)), directoryAttrs()))
                }
                return [reply(.name, id: id) { writer in
                    writer.append(UInt32(names.count))
                    for (name, attributes) in names { writer.append(name); writer.append("-rw-r--r-- " + name); writer.append(attributes) }
                }]
            case .mkdir:
                let path = try reader.string()
                if state.directories.contains(path) || state.files[path] != nil { return [status(id, .failure, "exists")] }
                state.directories.insert(path)
                return [status(id, .ok)]
            case .rmdir:
                let path = try reader.string()
                guard state.directories.contains(path) else { return [status(id, .noSuchFile)] }
                state.directories.remove(path)
                return [status(id, .ok)]
            case .remove:
                let path = try reader.string()
                guard state.files.removeValue(forKey: path) != nil else { return [status(id, .noSuchFile)] }
                return [status(id, .ok)]
            case .rename:
                let old = try reader.string(); let new = try reader.string()
                if state.files[new] != nil { return [status(id, .failure, "exists")] }
                guard let file = state.files.removeValue(forKey: old) else { return [status(id, .noSuchFile)] }
                state.files[new] = file
                return [status(id, .ok)]
            default:
                return [status(id, .opUnsupported)]
            }
        } catch {
            return [status(id, .badMessage)]
        }
    }
}
