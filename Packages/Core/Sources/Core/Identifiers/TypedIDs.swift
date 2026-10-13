import Foundation

/// A string identifier with a fixed prefix followed by a ULID, such as `n_01J9X…`.
public protocol PrefixedIdentifier: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible
where RawValue == String {
    /// The prefix including its underscore, for example `n_`.
    static var prefix: String { get }
    init(rawValue: String)
}

extension PrefixedIdentifier {
    /// Mints a fresh identifier.
    public static func new() -> Self {
        Self(rawValue: prefix + ULID.generate())
    }

    /// Accepts a string only when it carries this type's prefix and a well-formed ULID.
    /// Use for identifiers arriving from MCP calls, URLs, or hook scripts.
    public init?(validating string: String) {
        guard string.hasPrefix(Self.prefix) else { return nil }
        let body = String(string.dropFirst(Self.prefix.count))
        guard ULID.isValid(body) else { return nil }
        self.init(rawValue: string)
    }

    public var description: String { rawValue }

    /// Creation time embedded in the identifier, when it was minted by `new()`.
    public var createdAt: Date? {
        ULID.timestamp(of: String(rawValue.dropFirst(Self.prefix.count)))
    }
}

public struct NoteID: PrefixedIdentifier {
    public static let prefix = "n_"
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct DocumentID: PrefixedIdentifier {
    public static let prefix = "d_"
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct HostID: PrefixedIdentifier {
    public static let prefix = "h_"
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// The local Mac. Seeded by the first database migration.
    public static let local = HostID(rawValue: "h_local")
    /// Live web pages. Seeded by `v4-integrations`, as are `github` and `atlassian`.
    public static let web = HostID(rawValue: "h_web")
    public static let github = HostID(rawValue: "h_github")
    public static let atlassian = HostID(rawValue: "h_atlassian")
    /// The hosts with fixed ids instead of ULIDs.
    public static let gloss = HostID(rawValue: "h_gloss")
    public static let fixed: Set<HostID> = [.local, .web, .github, .atlassian, .gloss]
    /// Served by the app from an API or a web view, never a machine's file system; nothing on them can be written.
    public var isVirtual: Bool { self == .web || self == .github || self == .atlassian || self == .gloss }

    public init?(validating string: String) {
        if HostID.fixed.contains(HostID(rawValue: string)) {
            self.init(rawValue: string)
            return
        }
        guard string.hasPrefix(Self.prefix), ULID.isValid(String(string.dropFirst(Self.prefix.count))) else { return nil }
        self.init(rawValue: string)
    }
}

public struct RootID: PrefixedIdentifier {
    public static let prefix = "r_"
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct SendID: PrefixedIdentifier {
    public static let prefix = "s_"
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct AttachmentID: PrefixedIdentifier {
    public static let prefix = "a_"
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct TargetID: PrefixedIdentifier {
    public static let prefix = "t_"
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct StagedFileID: PrefixedIdentifier {
    public static let prefix = "f_"
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct MessageID: PrefixedIdentifier {
    public static let prefix = "m_"
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}
