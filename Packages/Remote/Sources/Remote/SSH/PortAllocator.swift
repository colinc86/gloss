import Foundation

/// Finds a free loopback TCP port the way servers do: bind port 0, read the port the kernel chose, close.
/// Another process can take the port before its caller binds it, so callers retry on a bind failure.
public enum PortAllocator {
    public enum Error: Swift.Error, Equatable {
        case socket(Int32)
        case bind(Int32)
    }

    public static func freeLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Error.socket(errno) }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, length) }
        }
        guard bound == 0 else { throw Error.bind(errno) }
        var assigned = sockaddr_in()
        var assignedLength = length
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &assignedLength) }
        }
        guard named == 0 else { throw Error.bind(errno) }
        return UInt16(bigEndian: assigned.sin_port)
    }
}
