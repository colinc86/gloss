import Core
import Integrations
import Foundation
import Security
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

    /// A secret only this user's processes can read (the file is 0600). Any web page can open a
    /// `gloss://` link; one that creates a note (which an agent's hook then reads as the user's words) or
    /// opens a tunnel to a host must carry it, which the Herdr plugin does and a page cannot.
    nonisolated static var tokenPath: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gloss/url-token").path
    }

    /// The token, made on first use.
    nonisolated static func token() -> String? {
        if let existing = try? String(contentsOfFile: tokenPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), existing.count >= 32 {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        let directory = (tokenPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: tokenPath, contents: Data((token + "\n").utf8), attributes: [.posixPermissions: 0o600]) else { return nil }
        return token
    }

    /// Whether a link carries the token, compared in constant time.
    nonisolated static func carriesToken(_ url: URL, expected: String?) -> Bool {
        guard let expected, let given = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "token" })?.value,
              given.utf8.count == expected.utf8.count else { return false }
        return zip(given.utf8, expected.utf8).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    nonisolated static func isInboxFile(_ path: String) -> Bool {
        let resolved = (path as NSString).standardizingPath
        let inbox = (inboxDirectory as NSString).standardizingPath
        guard resolved.hasPrefix(inbox + "/"), !resolved.dropFirst(inbox.count + 1).contains("/") else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    nonisolated static func pathOf(_ route: Route) -> String? {
        if case .open(_, let path, _) = route { return path }
        return nil
    }

    nonisolated static func parse(_ url: URL, hosts: [String: HostID], atlassianSite: URL? = nil) -> Route? {
        guard url.scheme?.lowercased() == "gloss", let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value }
        let hostName = query["host"] ?? "local"
        let hostID = hostName == "local" ? HostID.local : hosts[hostName] ?? (HostID(validating: hostName) ?? .local)
        switch url.host?.lowercased() ?? components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased() {
        case "open":
            let line = query["line"].flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
            if let text = query["url"], let url = URL(string: text) {
                // A pull request URL opens on the github host, an issue or page of the saved Atlassian site on the
                // atlassian host (a Confluence page by its folder: opening finds the document); any other web
                // address opens in the browser.
                if let resolved = AppModel.resolveResourceURL(url) { return .open(hostID: .github, path: resolved.path, line: line) }
                if let atlassianSite, let reference = AtlassianPath.parse(reference: text, site: atlassianSite) {
                    switch reference {
                    case .jiraIssue, .confluencePageFolder, .confluencePage: return .open(hostID: .atlassian, path: reference.path, line: line)
                    default: break
                    }
                }
                if DocumentKindDetector.isWebURL(text) { return .open(hostID: hostID, path: text, line: nil) }
                return nil
            }
            guard let path = query["path"], path.hasPrefix("/") else { return nil }
            return .open(hostID: hostID, path: PathUtilities.lexicallyNormalized(path), line: line)
        case "note":
            let text = query["text"] ?? ""
            let file = query["file"]
            guard !text.isEmpty || file != nil else { return nil }
            return .note(hostID: hostID, path: query["path"].map(PathUtilities.lexicallyNormalized), cwd: query["cwd"].map(PathUtilities.lexicallyNormalized),
                         line: query["line"].flatMap(Int.init), text: text, file: file,
                         color: query["color"].flatMap { NoteColor(rawValue: $0.lowercased()) })
        default:
            return nil
        }
    }

    /// Opens a routed document, adding a root for it when needed; also what confirming a link does.
    static func open(hostID: HostID, path: String, line: Int?, model: AppModel) async {
        await model.openRootIfNeeded(hostID: hostID, containing: path)
        if let line { model.openDocument(hostID: hostID, path: path, line: line) } else { model.openDocument(hostID: hostID, path: path) }
    }

    static func handle(_ url: URL, model: AppModel) async {
        let hosts = Dictionary(uniqueKeysWithValues: ((try? await model.noteStore.hosts()) ?? []).map { ($0.name, $0.id) })
        guard let route = parse(url, hosts: hosts, atlassianSite: model.integrations.atlassian?.site) else {
            Log.app.error("Unhandled URL: \(url.absoluteString, privacy: .public)")
            return
        }
        let trusted = carriesToken(url, expected: token())
        switch route {
        case .open(let hostID, _, _) where !trusted && hostID != .local && !hostID.isVirtual && DocumentKindDetector.isWebURL(Self.pathOf(route) ?? ""):
            // Opening a page on an ssh host's loopback connects to the host and forwards a port: not for a link
            // any page could have opened.
            Log.app.error("Refused an untrusted link that would open a tunnel to \(hostID.rawValue, privacy: .public)")
        case .note where !trusted:
            Log.app.error("Refused an untrusted link that would create a note")
        case .open(let hostID, let path, let line) where !trusted && !hostID.isVirtual && !DocumentKindDetector.isWebURL(path):
            // Any web page can open a link. Unasked, it could open (and render, scripts and all) a file it just
            // downloaded, add its folder as a root, or make the app connect to an ssh host; so the user confirms.
            let hostName = hostID == .local ? nil : hosts.first { $0.value == hostID }?.key
            model.pendingLinkOpen = AppModel.PendingLinkOpen(hostID: hostID, hostName: hostName, path: path, line: line)
        case .open(let hostID, let path, let line):
            await open(hostID: hostID, path: path, line: line, model: model)
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
