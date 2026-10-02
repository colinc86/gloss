import Foundation

// SFTP version 3 wire format (draft-ietf-secsh-filexfer-02) as spoken over the `sftp` subsystem.
// Packet: uint32 length (of what follows) | byte type | [uint32 id] | payload. All integers big-endian.

public enum SFTPPacketType: UInt8, Sendable {
    case initialize = 1, version = 2
    case open = 3, close = 4, read = 5, write = 6
    case lstat = 7, fstat = 8, setstat = 9, fsetstat = 10
    case opendir = 11, readdir = 12, remove = 13, mkdir = 14, rmdir = 15
    case realpath = 16, stat = 17, rename = 18, readlink = 19, symlink = 20
    case status = 101, handle = 102, data = 103, name = 104, attrs = 105
    case extended = 200, extendedReply = 201
}

public struct SFTPOpenFlags: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let read = SFTPOpenFlags(rawValue: 0x01)
    public static let write = SFTPOpenFlags(rawValue: 0x02)
    public static let append = SFTPOpenFlags(rawValue: 0x04)
    public static let create = SFTPOpenFlags(rawValue: 0x08)
    public static let truncate = SFTPOpenFlags(rawValue: 0x10)
    public static let exclusive = SFTPOpenFlags(rawValue: 0x20)
}

/// ATTRS: flags then, in order when set, size, uid/gid, permissions, atime/mtime, extended pairs.
public struct SFTPAttributes: Equatable, Sendable {
    public var size: UInt64?
    public var uid: UInt32?
    public var gid: UInt32?
    public var permissions: UInt32?
    public var atime: UInt32?
    public var mtime: UInt32?
    public var extended: [(type: String, data: Data)] = []

    public init(size: UInt64? = nil, uid: UInt32? = nil, gid: UInt32? = nil, permissions: UInt32? = nil, atime: UInt32? = nil, mtime: UInt32? = nil) {
        self.size = size
        self.uid = uid
        self.gid = gid
        self.permissions = permissions
        self.atime = atime
        self.mtime = mtime
    }

    public static func == (lhs: SFTPAttributes, rhs: SFTPAttributes) -> Bool {
        lhs.size == rhs.size && lhs.uid == rhs.uid && lhs.gid == rhs.gid && lhs.permissions == rhs.permissions
            && lhs.atime == rhs.atime && lhs.mtime == rhs.mtime
            && lhs.extended.map(\.type) == rhs.extended.map(\.type) && lhs.extended.map(\.data) == rhs.extended.map(\.data)
    }

    static let sizeFlag: UInt32 = 0x01
    static let uidgidFlag: UInt32 = 0x02
    static let permissionsFlag: UInt32 = 0x04
    static let acmodtimeFlag: UInt32 = 0x08
    static let extendedFlag: UInt32 = 0x8000_0000

    /// POSIX file type from the permission bits.
    public var fileType: SFTPFileType {
        guard let permissions else { return .unknown }
        switch permissions & 0o170000 {
        case 0o100000: return .regular
        case 0o040000: return .directory
        case 0o120000: return .symlink
        default: return .other
        }
    }

    public var mode: UInt16 { UInt16((permissions ?? 0) & 0o7777) }
}

public enum SFTPFileType: Sendable {
    case regular, directory, symlink, other, unknown
}

public enum SFTPStatusCode: UInt32, Sendable {
    case ok = 0, eof = 1, noSuchFile = 2, permissionDenied = 3, failure = 4
    case badMessage = 5, noConnection = 6, connectionLost = 7, opUnsupported = 8
}

public struct SFTPStatus: Error, Equatable, Sendable {
    public var code: SFTPStatusCode
    public var rawCode: UInt32
    public var message: String
    public var language: String

    public init(code: SFTPStatusCode, message: String = "", language: String = "") {
        self.code = code
        rawCode = code.rawValue
        self.message = message
        self.language = language
    }

    init(rawCode: UInt32, message: String, language: String) {
        self.rawCode = rawCode
        code = SFTPStatusCode(rawValue: rawCode) ?? .failure
        self.message = message
        self.language = language
    }
}

public struct SFTPName: Equatable, Sendable {
    public var filename: String
    public var longname: String
    public var attributes: SFTPAttributes

    public init(filename: String, longname: String, attributes: SFTPAttributes) {
        self.filename = filename
        self.longname = longname
        self.attributes = attributes
    }
}

public enum SFTPRequest: Sendable {
    case initialize(version: UInt32)
    case open(path: String, flags: SFTPOpenFlags, attributes: SFTPAttributes)
    case close(handle: Data)
    case read(handle: Data, offset: UInt64, length: UInt32)
    case write(handle: Data, offset: UInt64, data: Data)
    case lstat(path: String)
    case fstat(handle: Data)
    case setstat(path: String, attributes: SFTPAttributes)
    case fsetstat(handle: Data, attributes: SFTPAttributes)
    case opendir(path: String)
    case readdir(handle: Data)
    case remove(path: String)
    case mkdir(path: String, attributes: SFTPAttributes)
    case rmdir(path: String)
    case realpath(path: String)
    case stat(path: String)
    case rename(oldPath: String, newPath: String)
    case readlink(path: String)
    case symlink(linkPath: String, targetPath: String)
    case extended(name: String, data: Data)

    public var type: SFTPPacketType {
        switch self {
        case .initialize: .initialize
        case .open: .open
        case .close: .close
        case .read: .read
        case .write: .write
        case .lstat: .lstat
        case .fstat: .fstat
        case .setstat: .setstat
        case .fsetstat: .fsetstat
        case .opendir: .opendir
        case .readdir: .readdir
        case .remove: .remove
        case .mkdir: .mkdir
        case .rmdir: .rmdir
        case .realpath: .realpath
        case .stat: .stat
        case .rename: .rename
        case .readlink: .readlink
        case .symlink: .symlink
        case .extended: .extended
        }
    }
}

public enum SFTPReply: Equatable, Sendable {
    case version(UInt32, extensions: [String: String])
    case status(SFTPStatus)
    case handle(Data)
    case data(Data)
    case name([SFTPName])
    case attrs(SFTPAttributes)
    case extendedReply(Data)
}

public struct SFTPFrame: Equatable, Sendable {
    /// Nil for VERSION, which carries no id.
    public var id: UInt32?
    public var reply: SFTPReply
}

public enum SFTPCodecError: Error, Equatable, Sendable {
    case truncated
    case unknownType(UInt8)
    case oversizedPacket(UInt32)
}

/// Pure encode and decode; the client adds pipelining around it.
public enum SFTPCodec {
    /// Packets above this are a framing error, not a huge read.
    public static let maximumPacketLength: UInt32 = 256 * 1024 * 1024

    public static func encode(_ request: SFTPRequest, id: UInt32) -> Data {
        var body = BinaryWriter()
        body.append(request.type.rawValue)
        switch request {
        case .initialize(let version):
            body.append(version)
        case .open(let path, let flags, let attributes):
            body.append(id); body.append(path); body.append(flags.rawValue); body.append(attributes)
        case .close(let handle):
            body.append(id); body.append(handle)
        case .read(let handle, let offset, let length):
            body.append(id); body.append(handle); body.append(offset); body.append(length)
        case .write(let handle, let offset, let data):
            body.append(id); body.append(handle); body.append(offset); body.append(data)
        case .lstat(let path), .opendir(let path), .remove(let path), .rmdir(let path), .realpath(let path), .stat(let path), .readlink(let path):
            body.append(id); body.append(path)
        case .fstat(let handle), .readdir(let handle):
            body.append(id); body.append(handle)
        case .setstat(let path, let attributes):
            body.append(id); body.append(path); body.append(attributes)
        case .fsetstat(let handle, let attributes):
            body.append(id); body.append(handle); body.append(attributes)
        case .mkdir(let path, let attributes):
            body.append(id); body.append(path); body.append(attributes)
        case .rename(let oldPath, let newPath):
            body.append(id); body.append(oldPath); body.append(newPath)
        case .symlink(let linkPath, let targetPath):
            body.append(id); body.append(linkPath); body.append(targetPath)
        case .extended(let name, let data):
            body.append(id); body.append(name); body.appendRaw(data)
        }
        var packet = BinaryWriter()
        packet.append(UInt32(body.data.count))
        packet.appendRaw(body.data)
        return packet.data
    }

    /// Decodes one frame from the front of `buffer` when a whole packet is present, consuming it.
    public static func decode(from buffer: inout Data) throws -> SFTPFrame? {
        guard buffer.count >= 4 else { return nil }
        var reader = BinaryReader(buffer)
        let length = try reader.uint32()
        guard length <= maximumPacketLength else { throw SFTPCodecError.oversizedPacket(length) }
        guard buffer.count >= 4 + Int(length) else { return nil }
        let start = buffer.startIndex
        let payload = buffer.subdata(in: (start + 4)..<(start + 4 + Int(length)))
        buffer.removeSubrange(start..<(start + 4 + Int(length)))
        return try decodePayload(payload)
    }

    static func decodePayload(_ payload: Data) throws -> SFTPFrame {
        var reader = BinaryReader(payload)
        let rawType = try reader.uint8()
        guard let type = SFTPPacketType(rawValue: rawType) else { throw SFTPCodecError.unknownType(rawType) }
        switch type {
        case .version:
            let version = try reader.uint32()
            var extensions: [String: String] = [:]
            while reader.remaining > 0 {
                let name = try reader.string()
                let value = try reader.string()
                extensions[name] = value
            }
            return SFTPFrame(id: nil, reply: .version(version, extensions: extensions))
        case .status:
            let id = try reader.uint32()
            let code = try reader.uint32()
            let message = reader.remaining > 0 ? try reader.string() : ""
            let language = reader.remaining > 0 ? try reader.string() : ""
            return SFTPFrame(id: id, reply: .status(SFTPStatus(rawCode: code, message: message, language: language)))
        case .handle:
            let id = try reader.uint32()
            return SFTPFrame(id: id, reply: .handle(try reader.bytes()))
        case .data:
            let id = try reader.uint32()
            return SFTPFrame(id: id, reply: .data(try reader.bytes()))
        case .name:
            let id = try reader.uint32()
            let count = try reader.uint32()
            var names: [SFTPName] = []
            for _ in 0..<count {
                names.append(SFTPName(filename: try reader.string(), longname: try reader.string(), attributes: try reader.attributes()))
            }
            return SFTPFrame(id: id, reply: .name(names))
        case .attrs:
            let id = try reader.uint32()
            return SFTPFrame(id: id, reply: .attrs(try reader.attributes()))
        case .extendedReply:
            let id = try reader.uint32()
            return SFTPFrame(id: id, reply: .extendedReply(reader.rest()))
        default:
            throw SFTPCodecError.unknownType(rawType)
        }
    }
}

// MARK: - Binary helpers

public struct BinaryWriter {
    public private(set) var data = Data()

    public init() {}

    public mutating func append(_ value: UInt8) { data.append(value) }

    public mutating func append(_ value: UInt32) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    public mutating func append(_ value: UInt64) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    /// `string`: uint32 length + bytes.
    public mutating func append(_ value: Data) {
        append(UInt32(value.count))
        data.append(value)
    }

    public mutating func append(_ value: String) {
        append(Data(value.utf8))
    }

    public mutating func appendRaw(_ value: Data) {
        data.append(value)
    }

    public mutating func append(_ attributes: SFTPAttributes) {
        var flags: UInt32 = 0
        if attributes.size != nil { flags |= SFTPAttributes.sizeFlag }
        if attributes.uid != nil || attributes.gid != nil { flags |= SFTPAttributes.uidgidFlag }
        if attributes.permissions != nil { flags |= SFTPAttributes.permissionsFlag }
        if attributes.atime != nil || attributes.mtime != nil { flags |= SFTPAttributes.acmodtimeFlag }
        if !attributes.extended.isEmpty { flags |= SFTPAttributes.extendedFlag }
        append(flags)
        if let size = attributes.size { append(size) }
        if flags & SFTPAttributes.uidgidFlag != 0 { append(attributes.uid ?? 0); append(attributes.gid ?? 0) }
        if let permissions = attributes.permissions { append(permissions) }
        if flags & SFTPAttributes.acmodtimeFlag != 0 { append(attributes.atime ?? 0); append(attributes.mtime ?? 0) }
        if !attributes.extended.isEmpty {
            append(UInt32(attributes.extended.count))
            for pair in attributes.extended { append(pair.type); append(pair.data) }
        }
    }
}

public struct BinaryReader {
    private let data: Data
    private var offset = 0

    public init(_ data: Data) {
        self.data = data
    }

    public var remaining: Int { data.count - offset }

    public mutating func uint8() throws -> UInt8 {
        guard remaining >= 1 else { throw SFTPCodecError.truncated }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    public mutating func uint32() throws -> UInt32 {
        guard remaining >= 4 else { throw SFTPCodecError.truncated }
        var value: UInt32 = 0
        for _ in 0..<4 { value = (value << 8) | UInt32(data[data.startIndex + offset]); offset += 1 }
        return value
    }

    public mutating func uint64() throws -> UInt64 {
        guard remaining >= 8 else { throw SFTPCodecError.truncated }
        var value: UInt64 = 0
        for _ in 0..<8 { value = (value << 8) | UInt64(data[data.startIndex + offset]); offset += 1 }
        return value
    }

    public mutating func bytes() throws -> Data {
        let length = Int(try uint32())
        guard remaining >= length else { throw SFTPCodecError.truncated }
        let start = data.startIndex + offset
        defer { offset += length }
        return data.subdata(in: start..<(start + length))
    }

    public mutating func string() throws -> String {
        String(decoding: try bytes(), as: UTF8.self)
    }

    public mutating func rest() -> Data {
        defer { offset = data.count }
        return data.subdata(in: (data.startIndex + offset)..<data.endIndex)
    }

    public mutating func attributes() throws -> SFTPAttributes {
        let flags = try uint32()
        var attributes = SFTPAttributes()
        if flags & SFTPAttributes.sizeFlag != 0 { attributes.size = try uint64() }
        if flags & SFTPAttributes.uidgidFlag != 0 { attributes.uid = try uint32(); attributes.gid = try uint32() }
        if flags & SFTPAttributes.permissionsFlag != 0 { attributes.permissions = try uint32() }
        if flags & SFTPAttributes.acmodtimeFlag != 0 { attributes.atime = try uint32(); attributes.mtime = try uint32() }
        if flags & SFTPAttributes.extendedFlag != 0 {
            let count = try uint32()
            for _ in 0..<count { attributes.extended.append((try string(), try bytes())) }
        }
        return attributes
    }
}
