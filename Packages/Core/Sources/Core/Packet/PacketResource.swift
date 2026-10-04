import Foundation

/// What a virtual host says about a document for the packet's header: the thing the agent should act on with its
/// own tools, and the lines that pin it down (`Path: … at <sha>`, `Field: description`, `Version: 7`).
public struct PacketResource: Sendable, Equatable {
    public var url: URL
    public var details: [String]

    public init(url: URL, details: [String] = []) {
        self.url = url
        self.details = details
    }
}
