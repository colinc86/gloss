import Foundation

/// A path on the `atlassian` host: `/jira/<PROJECT>/<KEY>.md` is an issue, `/confluence/<SPACE>/<page id>/<Title>.md`
/// a page, with a page's children listed inside its folder. Anything else is not served.
public enum AtlassianPath: Equatable, Sendable {
    case jiraRoot
    case jiraProject(String)
    case jiraIssue(project: String, key: String)
    case confluenceRoot
    case confluenceSpace(String)
    case confluencePageFolder(space: String, id: String)
    case confluencePage(space: String, id: String, title: String)

    public init?(_ path: String) {
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        switch parts.first {
        case "jira":
            switch parts.count {
            case 1: self = .jiraRoot
            case 2:
                guard Self.isProjectKey(parts[1]) else { return nil }
                self = .jiraProject(parts[1])
            case 3:
                guard parts[2].hasSuffix(".md") else { return nil }
                let key = String(parts[2].dropLast(3))
                guard Self.isIssueKey(key), key.hasPrefix(parts[1] + "-") else { return nil }
                self = .jiraIssue(project: parts[1], key: key)
            default: return nil
            }
        case "confluence":
            switch parts.count {
            case 1: self = .confluenceRoot
            case 2: self = .confluenceSpace(parts[1])
            case 3: guard parts[2].allSatisfy(\.isNumber) else { return nil }; self = .confluencePageFolder(space: parts[1], id: parts[2])
            case 4:
                guard parts[2].allSatisfy(\.isNumber), parts[3].hasSuffix(".md") else { return nil }
                self = .confluencePage(space: parts[1], id: parts[2], title: String(parts[3].dropLast(3)))
            default: return nil
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
        case .confluencePageFolder(let space, let id): "/confluence/\(space)/\(id)"
        case .confluencePage(let space, let id, let title): "/confluence/\(space)/\(id)/\(title).md"
        }
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
