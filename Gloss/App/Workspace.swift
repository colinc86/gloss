import Core
import Foundation

/// What was open when the app last quit (issue #9): the explorer's folders, the document in front and where in it,
/// Back and Forward, and the notes panel. Kept as one JSON setting, `general.workspace`.
nonisolated struct Workspace: Codable, Equatable {
    struct Place: Codable, Hashable {
        var host: String
        var path: String

        init(host: String, path: String) {
            self.host = host
            self.path = path
        }

        init(_ entry: DocumentHistory.Entry) {
            self.init(host: entry.hostID.rawValue, path: entry.path)
        }

        var hostID: HostID { HostID(rawValue: host) }
        var entry: DocumentHistory.Entry { .init(hostID: hostID, path: path) }
    }

    struct Document: Codable, Equatable {
        var place: Place
        /// The caret's 1-based line in the source.
        var line: Int?
        /// A Markdown document shown as its source rather than rendered.
        var showsSource: Bool?
    }

    static let key = "general.workspace"

    var folders: [Place] = []
    /// Index into `folders` of the tab in front.
    var selectedFolder: Int?
    var document: Document?
    var back: [Place] = []
    var forward: [Place] = []
    var showsNotesPanel = true

    /// The setting before #9: `host\npath[\nline]` of the document in front.
    static func fromLastDocument(_ value: String) -> Workspace? {
        let parts = value.split(separator: "\n").map(String.init)
        guard parts.count >= 2 else { return nil }
        var workspace = Workspace()
        workspace.document = Document(place: Place(host: parts[0], path: parts[1]), line: parts.count >= 3 ? Int(parts[2]) : nil)
        return workspace
    }

    mutating func relocate(_ move: DocumentRelocation) {
        func mapped(_ place: Place) -> Place {
            guard place.hostID == move.hostID, let path = move.destination(for: place.path) else { return place }
            return Place(host: place.host, path: path)
        }
        folders = folders.map(mapped); back = back.map(mapped); forward = forward.map(mapped)
        if let current = document { document?.place = mapped(current.place) }
    }

    func encoded() -> String? {
        (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func decoded(_ value: String) -> Workspace? {
        try? JSONDecoder().decode(Workspace.self, from: Data(value.utf8))
    }
}

/// What the app reopens at launch.
nonisolated enum LaunchRestore: String, CaseIterable, Identifiable {
    /// Everything when System Settings › Desktop & Dock › “Close windows when quitting an application” is off, else
    /// the last folder.
    case system
    case everything
    case lastFolder
    case nothing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "As my Mac does"
        case .everything: "Everything I had open"
        case .lastFolder: "The last folder"
        case .nothing: "Nothing"
        }
    }

    /// `.system` resolved against the Mac's setting (`NSQuitAlwaysKeepsWindows` in the global domain; true keeps
    /// windows).
    func resolved(keepsWindows: Bool = UserDefaults.standard.bool(forKey: "NSQuitAlwaysKeepsWindows")) -> LaunchRestore {
        guard self == .system else { return self }
        return keepsWindows ? .everything : .lastFolder
    }
}
