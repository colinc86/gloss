import Foundation

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

        public init(key: String, summary: String, status: String, issueType: String, projectKey: String, updated: Date) {
            self.key = key
            self.summary = summary
            self.status = status
            self.issueType = issueType
            self.projectKey = projectKey
            self.updated = updated
        }
    }
}

public struct JiraProject: Sendable, Equatable {
    public var id: String
    public var key: String
    public var name: String

    public init(id: String, key: String, name: String) {
        self.id = id
        self.key = key
        self.name = name
    }
}

public struct ConfluenceSpace: Sendable, Equatable {
    public var id: String
    public var key: String
    public var name: String

    public init(id: String, key: String, name: String) {
        self.id = id
        self.key = key
        self.name = name
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
