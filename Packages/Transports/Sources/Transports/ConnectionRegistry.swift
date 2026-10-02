import Core
import Foundation
import Remote

/// The live SSH connections the transports may use, keyed by host. The app registers a connection when a host comes
/// up and removes it on disconnect; transports never connect on their own.
public actor ConnectionRegistry {
    public struct Entry: Sendable {
        public var hostID: HostID
        public var alias: String
        public var connection: SSHConnection
    }

    private var entries: [HostID: Entry] = [:]

    public init() {}

    public func register(_ connection: SSHConnection, alias: String, for hostID: HostID) {
        entries[hostID] = Entry(hostID: hostID, alias: alias, connection: connection)
    }

    public func remove(_ hostID: HostID) {
        entries[hostID] = nil
    }

    public func connection(for hostID: HostID) -> SSHConnection? {
        entries[hostID]?.connection
    }

    public func all() -> [Entry] {
        entries.values.sorted { $0.alias < $1.alias }
    }
}
