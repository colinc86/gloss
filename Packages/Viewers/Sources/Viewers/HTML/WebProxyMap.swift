import Core
import Foundation

/// The tunnels that let a page on a remote host's loopback show here: remote port → local port on this Mac.
/// `proxied` turns the logical URL into the one the web view loads; `logical` turns a loaded URL back into the
/// address the user sees and the document is keyed by.
public struct WebProxyMap: Equatable, Hashable, Sendable {
    public var hostID: HostID
    public var tunnels: [UInt16: UInt16]

    public init(hostID: HostID, tunnels: [UInt16: UInt16] = [:]) {
        self.hostID = hostID
        self.tunnels = tunnels
    }

    nonisolated public static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]", "0.0.0.0"]

    /// The port of an http(s) URL on a loopback host, with the scheme's default when none is written; nil otherwise.
    nonisolated public static func loopbackPort(of url: URL) -> UInt16? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host()?.lowercased(), loopbackHosts.contains(host) else { return nil }
        if let port = url.port { return UInt16(exactly: port) }
        return scheme == "https" ? 443 : 80
    }

    /// The URL the web view loads for a logical loopback URL, when its port is tunnelled.
    nonisolated public func proxied(_ logical: URL) -> URL? {
        guard let remote = Self.loopbackPort(of: logical), let local = tunnels[remote],
              var components = URLComponents(url: logical, resolvingAgainstBaseURL: true) else { return nil }
        components.host = "127.0.0.1"
        components.port = Int(local)
        return components.url
    }

    /// The logical URL for one the web view loaded through a tunnel: `localhost:<remote port>`; nil when the URL
    /// is not one of this map's tunnels.
    nonisolated public func logical(_ loaded: URL) -> URL? {
        guard let scheme = loaded.scheme?.lowercased(), scheme == "http" || scheme == "https",
              loaded.host()?.lowercased() == "127.0.0.1", let port = loaded.port,
              let remote = tunnels.first(where: { Int($0.value) == port })?.key,
              var components = URLComponents(url: loaded, resolvingAgainstBaseURL: true) else { return nil }
        components.host = "localhost"
        components.port = (scheme == "http" && remote == 80) || (scheme == "https" && remote == 443) ? nil : Int(remote)
        return components.url
    }

    /// Whether `url` is the loaded form of one of this map's tunnels.
    nonisolated public func isProxied(_ url: URL) -> Bool { logical(url) != nil }
}
