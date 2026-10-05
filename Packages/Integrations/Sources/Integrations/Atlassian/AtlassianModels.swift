import Foundation

/// A file attached to a Jira issue or a Confluence page.
public struct AtlassianAttachment: Sendable, Equatable {
    public var id: String
    public var filename: String
    public var mimeType: String
    public var size: Int
    /// Confluence's id for the file, the one its pages' media nodes name; nil on Jira.
    public var fileID: String?
    /// Where Confluence serves the bytes, relative to the site's `wiki`; nil on Jira.
    public var downloadPath: String?

    public init(id: String, filename: String, mimeType: String, size: Int, fileID: String? = nil, downloadPath: String? = nil) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.fileID = fileID
        self.downloadPath = downloadPath
    }

    /// Images and PDFs open in Gloss's viewers, where regions take notes; other files are not listed.
    public var isViewable: Bool { mimeType.hasPrefix("image/") || mimeType == "application/pdf" }

    /// The file name with no slashes, so it is one path component.
    public var fileName: String { AtlassianPath.fileTitle(filename) }

    /// Larger files are not listed: the viewers refuse them anyway.
    public static let sizeLimit = 50 * 1024 * 1024

    /// What an issue's or page's attachments folder lists: images and PDFs the viewers take.
    public static func listed(_ all: [AtlassianAttachment]) -> [AtlassianAttachment] {
        all.filter { $0.isViewable && $0.size <= sizeLimit }
    }

    /// The name each attachment is listed under, by id. A file name used twice gets " (2)", " (3)"… before its
    /// extension, so every attachment has a path of its own (and its links lead to it, not to its namesake).
    public static func listedNames(_ list: [AtlassianAttachment]) -> [String: String] {
        var taken: Set<String> = []
        var names: [String: String] = [:]
        for attachment in list {
            var name = attachment.fileName
            var copy = 2
            while taken.contains(name) {
                let ext = (attachment.fileName as NSString).pathExtension
                let base = (attachment.fileName as NSString).deletingPathExtension
                name = ext.isEmpty ? "\(base) (\(copy))" : "\(base) (\(copy)).\(ext)"
                copy += 1
            }
            taken.insert(name)
            names[attachment.id] = name
        }
        return names
    }
}

/// A Jira issue as the app reads it: the fields the document shows, with rich text already as Markdown.
public struct JiraIssue: Sendable, Equatable {
    public struct Comment: Sendable, Equatable {
        public var id: String
        public var author: String
        public var created: Date
        public var body: String
    }

    public var key: String
    public var id: String
    public var summary: String
    public var issueType: String
    public var status: String
    public var priority: String?
    public var assignee: String?
    public var reporter: String?
    public var labels: [String]
    public var parentKey: String?
    public var created: Date
    public var updated: Date
    /// The description as Markdown; nil when the issue has none.
    public var description: String?
    public var comments: [Comment]
    public var projectKey: String
    public var attachments: [AtlassianAttachment] = []

    public init(key: String, id: String, summary: String, issueType: String, status: String, priority: String? = nil, assignee: String? = nil, reporter: String? = nil,
                labels: [String] = [], parentKey: String? = nil, created: Date, updated: Date, description: String? = nil, comments: [Comment] = [], projectKey: String) {
        self.key = key
        self.id = id
        self.summary = summary
        self.issueType = issueType
        self.status = status
        self.priority = priority
        self.assignee = assignee
        self.reporter = reporter
        self.labels = labels
        self.parentKey = parentKey
        self.created = created
        self.updated = updated
        self.description = description
        self.comments = comments
        self.projectKey = projectKey
    }

    /// The fields a list shows.
    public struct Summary: Sendable, Equatable {
        public var key: String
        public var summary: String
        public var status: String
        public var issueType: String
        public var projectKey: String
        public var updated: Date
        /// Images and PDFs attached, which get a folder beside the issue.
        public var viewableAttachments: Int

        public init(key: String, summary: String, status: String, issueType: String, projectKey: String, updated: Date, viewableAttachments: Int = 0) {
            self.key = key
            self.summary = summary
            self.status = status
            self.issueType = issueType
            self.projectKey = projectKey
            self.updated = updated
            self.viewableAttachments = viewableAttachments
        }
    }
}

public struct ConfluenceSpace: Sendable, Equatable {
    public var id: String
    public var key: String
    public var name: String
    /// True for a person's own space (`type == "personal"`); team spaces list first.
    public var isPersonal: Bool

    public init(id: String, key: String, name: String, isPersonal: Bool = false) {
        self.id = id
        self.key = key
        self.name = name
        self.isPersonal = isPersonal
    }
}

public struct ConfluencePage: Sendable, Equatable {
    public var id: String
    public var title: String
    public var spaceId: String
    public var parentId: String?
    public var version: Int
    public var versionDate: Date?
    public var authorId: String?
    /// The page's path on the site (`/spaces/ENG/pages/123/Title`), to make its URL.
    public var webPath: String?
    /// The body as Markdown; nil when the page was listed without its body.
    public var body: String?

    public init(id: String, title: String, spaceId: String, parentId: String? = nil, version: Int, versionDate: Date? = nil, authorId: String? = nil, webPath: String? = nil, body: String? = nil) {
        self.id = id
        self.title = title
        self.spaceId = spaceId
        self.parentId = parentId
        self.version = version
        self.versionDate = versionDate
        self.authorId = authorId
        self.webPath = webPath
        self.body = body
    }
}
