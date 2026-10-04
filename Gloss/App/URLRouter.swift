import Core
import Foundation
import OSLog

/// `gloss://open?host=<alias|local>&path=<abs>[&line=<n>]` opens a file, scrolled to a line;
/// `gloss://note?host=&path=&line=&text=[&color=blue]` (or `cwd=` plus `text=` for a selection without a file)
/// creates a note. Used by the Herdr plugin and by scripts.
@MainActor
enum URLRouter {
    nonisolated enum Route: Equatable {
        case open(hostID: HostID, path: String, line: Int? = nil)
        case note(hostID: HostID, path: String?, cwd: String?, line: Int?, text: String, file: String?, color: NoteColor? = nil)
    }

    /// `~/Library/Application Support/Gloss/inbox`, where the plugin writes long selections.
    nonisolated static var inboxDirectory: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gloss/inbox").path
    }

    nonisolated static func isInboxFile(_ path: String) -> Bool {
        let resolved = (path as NSString).standardizingPath
        let inbox = (inboxDirectory as NSString).standardizingPath
        guard resolved.hasPrefix(inbox + "/"), !resolved.dropFirst(inbox.count + 1).contains("/") else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    nonisolated static func parse(_ url: URL, hosts: [String: HostID]) -> Route? {
        guard url.scheme?.lowercased() == "gloss", let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value }
        let hostName = query["host"] ?? "local"
        let hostID = hostName == "local" ? HostID.local : hosts[hostName] ?? (HostID(validating: hostName) ?? .local)
        switch url.host?.lowercased() ?? components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() {
        case "open":
            guard let path = query["path"], path.hasPrefix("/") else { return nil }
            return .open(hostID: hostID, path: path, line: query["line"].flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil })
        case "note":
            let text = query["text"] ?? ""
            let file = query["file"]
            guard !text.isEmpty || file != nil else { return nil }
            return .note(hostID: hostID, path: query["path"], cwd: query["cwd"], line: query["line"].flatMap(Int.init), text: text, file: file,
                         color: query["color"].flatMap { NoteColor(rawValue: $0.lowercased()) })
        default:
            return nil
        }
    }

    static func handle(_ url: URL, model: AppModel) async {
        let hosts = Dictionary(uniqueKeysWithValues: ((try? await model.noteStore.hosts()) ?? []).map { ($0.name, $0.id) })
        guard let route = parse(url, hosts: hosts) else {
            Log.app.error("Unhandled URL: \(url.absoluteString, privacy: .public)")
            return
        }
        switch route {
        case .open(let hostID, let path, let line):
            await model.openRootIfNeeded(hostID: hostID, containing: path)
            if let line { model.openDocument(hostID: hostID, path: path, line: line) } else { model.openDocument(hostID: hostID, path: path) }
        case .note(let hostID, let path, let cwd, let line, let text, let file, let color):
            var body = text
            // `file=` carries a long selection from the Herdr plugin. Only the app's own inbox is honoured: any
            // process can open a URL, so reading and deleting arbitrary paths from it would be a hole.
            if let file, Self.isInboxFile(file), let contents = try? String(contentsOfFile: file, encoding: .utf8) {
                body = contents
                try? FileManager.default.removeItem(atPath: file)
            }
            let documentPath = path ?? cwd.map { PathUtilities.join($0, ".gloss-inbox.md") }
            guard let documentPath else { return }
            await model.createNote(hostID: hostID, path: documentPath, line: line, body: body, color: color ?? .yellow)
        }
    }
}
