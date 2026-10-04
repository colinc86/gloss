import Foundation

/// A path on the `atlassian` host: `/jira/<PROJECT>/<KEY>.md` is an issue; `/confluence/<SPACE>/<ancestor ids…>/<page id>`
/// is a page's folder, holding `<Title>.md` (the page) and its child pages' folders. A page is its id: the ancestors
/// and the title in a path are where it was and what it was called when the path was made, and a path from before a
/// rename or a move still reads the page. Anything else is not served.
public enum AtlassianPath: Equatable, Sendable {
    case jiraRoot
    case jiraProject(String)
    case jiraIssue(project: String, key: String)
    case confluenceRoot
    case confluenceSpace(String)
    case confluencePageFolder(space: String, id: String, ancestors: [String] = [])
    case confluencePage(space: String, id: String, title: String, ancestors: [String] = [])

    public init?(_ path: String) {
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        switch parts.first {
        case "jira":
            switch parts.count {
            case 1: self = .jiraRoot
            // Keys are upper case in Jira; a path typed in lower case names the same issue.
            case 2:
                guard Self.isProjectKey(parts[1]) else { return nil }
                self = .jiraProject(parts[1].uppercased())
            case 3:
                guard parts[2].lowercased().hasSuffix(".md") else { return nil }
                let key = String(parts[2].dropLast(3)).uppercased()
                guard Self.isIssueKey(key), key.hasPrefix(parts[1].uppercased() + "-") else { return nil }
                self = .jiraIssue(project: parts[1].uppercased(), key: key)
            default: return nil
            }
        case "confluence":
            switch parts.count {
            case 1: self = .confluenceRoot
            case 2: self = .confluenceSpace(parts[1])
            default:
                let isID = { (part: String) in !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber } }
                if parts.last!.hasSuffix(".md") {
                    let folder = Array(parts[2..<(parts.count - 1)])
                    guard let id = folder.last, folder.allSatisfy(isID) else { return nil }
                    self = .confluencePage(space: parts[1], id: id, title: String(parts.last!.dropLast(3)), ancestors: Array(folder.dropLast()))
                } else {
                    let folder = Array(parts[2...])
                    guard let id = folder.last, folder.allSatisfy(isID) else { return nil }
                    self = .confluencePageFolder(space: parts[1], id: id, ancestors: Array(folder.dropLast()))
                }
            }
        default: return nil
        }
    }

    public var path: String {
        switch self {
        case .jiraRoot: "/jira"
        case .jiraProject(let project): "/jira/\(project)"
        case .jiraIssue(let project, let key): "/jira/\(project)/\(key).md"
        case .confluenceRoot: "/confluence"
        case .confluenceSpace(let space): "/confluence/\(space)"
        case .confluencePageFolder(let space, let id, let ancestors): "/confluence/\(space)" + (ancestors + [id]).map { "/" + $0 }.joined()
        case .confluencePage(let space, let id, let title, let ancestors): "/confluence/\(space)" + (ancestors + [id]).map { "/" + $0 }.joined() + "/\(title).md"
        }
    }

    /// The Confluence page a path is about, whatever its ancestors or title in the path.
    public var pageID: String? {
        switch self {
        case .confluencePageFolder(_, let id, _), .confluencePage(_, let id, _, _): id
        default: nil
        }
    }

    /// The same page's folder, or the folder of a child page listed inside it.
    public func childFolder(_ id: String) -> AtlassianPath? {
        guard case .confluencePageFolder(let space, let parent, let ancestors) = self else { return nil }
        return .confluencePageFolder(space: space, id: id, ancestors: ancestors + [parent])
    }

    /// `PROJ-123`: a project key, one dash, digits.
    public static func isIssueKey(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, isProjectKey(String(parts[0])), !parts[1].isEmpty, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        return true
    }

    /// A project key as Jira forms them: a letter, then letters, digits or underscores. It goes into JQL unquoted
    /// nowhere, but a path component that is not a key is refused before any request is made.
    public static func isProjectKey(_ text: String) -> Bool {
        guard let first = text.first, first.isLetter else { return false }
        return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// A title as a file name: no slashes, trimmed, never empty.
    public static func fileTitle(_ title: String) -> String {
        let cleaned = title.replacingOccurrences(of: "/", with: "∕").replacingOccurrences(of: ":", with: "∶").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(120))
    }

    /// `PROJ-123`, `https://site/browse/PROJ-123`, or a Confluence page URL `https://site/wiki/spaces/KEY/pages/123/Title`.
    public static func parse(reference text: String, site: URL?) -> AtlassianPath? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isIssueKey(trimmed.uppercased()) {
            let key = trimmed.uppercased()
            return .jiraIssue(project: String(key.split(separator: "-")[0]), key: key)
        }
        guard let url = URL(string: trimmed.contains("://") ? trimmed : "https://" + trimmed), let host = url.host()?.lowercased() else { return nil }
        if let site, let siteHost = site.host()?.lowercased(), siteHost != host { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        if parts.count >= 2, parts[0] == "browse", isIssueKey(parts[1].uppercased()) {
            let key = parts[1].uppercased()
            return .jiraIssue(project: String(key.split(separator: "-")[0]), key: key)
        }
        if let spaces = parts.firstIndex(of: "spaces"), parts.count > spaces + 3, parts[spaces + 2] == "pages", parts[spaces + 3].allSatisfy(\.isNumber) {
            return .confluencePageFolder(space: parts[spaces + 1], id: parts[spaces + 3])
        }
        return nil
    }
}
