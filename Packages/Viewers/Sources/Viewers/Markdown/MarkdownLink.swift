import Foundation

/// What a click on a link in rendered Markdown does. Markdown comes from anyone (a stranger's pull request, a Jira
/// ticket, a cloned README), and NSTextView's default hands every URL to the system: `file://…/Terminal.app`
/// launches an app and `smb://` mounts a share in one click. Only web and mail links leave the app.
public enum MarkdownLink: Equatable, Sendable {
    /// http, https or mailto: opened by the system.
    case external(URL)
    /// A relative or file: link to another document on the same host, by absolute path.
    case document(String)
    /// `#heading` in this document.
    case sameDocument
    /// Any other scheme, or a relative link with no folder to resolve against.
    case refused(String)

    public static func classify(_ link: Any, documentDirectory: String?) -> MarkdownLink {
        let raw = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") { return .sameDocument }
        guard let url = URL(string: trimmed) ?? trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:)) else {
            return .refused(trimmed)
        }
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto":
            return .external(url)
        case "file":
            // Only a plain local path, and only where this document's folder is on the same machine.
            guard documentDirectory != nil, url.host == nil || url.host == "" || url.host == "localhost" else { return .refused(trimmed) }
            return .document((url.path as NSString).standardizingPath)
        case nil:
            guard let documentDirectory else { return .refused(trimmed) }
            let path = url.path.removingPercentEncoding ?? url.path
            if path.isEmpty { return .sameDocument }
            let absolute = path.hasPrefix("/") ? path : (documentDirectory as NSString).appendingPathComponent(path)
            return .document((absolute as NSString).standardizingPath)
        default:
            return .refused(trimmed)
        }
    }
}
