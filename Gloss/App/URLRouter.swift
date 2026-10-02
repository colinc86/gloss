import Core
import Foundation
import OSLog

/// `gloss://open?host=<alias|local>&path=<abs>` opens a file;
/// `gloss://note?host=&path=&line=&text=` (or `cwd=` plus `text=` for a selection without a file)
/// creates a note. Used by the Herdr plugin and by scripts.
@MainActor
enum URLRouter {
    nonisolated enum Route: Equatable {
        case open(hostID: HostID, path: String)
        case note(hostID: HostID, path: String?, cwd: String?, line: Int?, text: String, file: String?)
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
            return .open(hostID: hostID, path: path)
        case "note":
            let text = query["text"] ?? ""
            let file = query["file"]
            guard !text.isEmpty || file != nil else { return nil }
            return .note(hostID: hostID, path: query["path"], cwd: query["cwd"], line: query["line"].flatMap(Int.init), text: text, file: file)
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
        case .open(let hostID, let path):
            await model.openRootIfNeeded(hostID: hostID, containing: path)
            model.openDocument(hostID: hostID, path: path)
        case .note(let hostID, let path, let cwd, let line, let text, let file):
            var body = text
            if let file, let contents = try? String(contentsOfFile: file, encoding: .utf8) {
                body = contents
                try? FileManager.default.removeItem(atPath: file)
            }
            let documentPath = path ?? cwd.map { PathUtilities.join($0, ".gloss-inbox.md") }
            guard let documentPath else { return }
            await model.createNote(hostID: hostID, path: documentPath, line: line, body: body)
        }
    }
}
