import Foundation
import Testing
@testable import Viewers

struct MarkdownLinkTests {
    @Test func onlyWebAndMailLeaveTheApp() {
        let classify = { (link: Any) in MarkdownLink.classify(link, documentDirectory: "/repo/docs") }
        #expect(classify(URL(string: "https://example.com/a")!) == .external(URL(string: "https://example.com/a")!))
        #expect(classify("mailto:a@example.com") == .external(URL(string: "mailto:a@example.com")!))
        for hostile in ["file://attacker.example/share/x", "smb://attacker.example/share", "vnc://host", "ssh://host",
                        "javascript:alert(1)", "x-apple.systempreferences:com.apple.preference.security", "data:text/html,hi"] {
            guard case .refused = classify(hostile) else { Issue.record("\(hostile) was not refused"); continue }
        }
        #expect(classify("../README.md") == .document("/repo/README.md"))
        #expect(classify("guide%20one.md#setup") == .document("/repo/docs/guide one.md", fragment: "setup"), "the heading travels with the path")
        #expect(classify("guide.md#") == .document("/repo/docs/guide.md"), "an empty fragment is none")
        #expect(classify("file:///System/Applications/Utilities/Terminal.app") == .document("/System/Applications/Utilities/Terminal.app"),
                "a file link only opens as a document in the viewer, never launches")
        #expect(classify("#heading") == .sameDocument("heading"))
        #expect(classify("#caf%C3%A9") == .sameDocument("café"), "the fragment decoded")
        #expect(classify("a%2525.md") == .document("/repo/docs/a%25.md"), "decoded once")
        guard case .refused = classify("//intranet/docs/spec.md") else { Issue.record("scheme-relative"); return }
        guard case .refused = classify("file:notes.md") else { Issue.record("relative file:"); return }
    }

    @Test func withoutAFolderRelativeAndFileLinksAreRefused() {
        guard case .refused = MarkdownLink.classify("notes.md", documentDirectory: nil) else { Issue.record("relative"); return }
        guard case .refused = MarkdownLink.classify("file:///etc/hosts", documentDirectory: nil) else { Issue.record("file"); return }
    }

    /// `#anchor` links find their heading as GitHub names it, so a README's table of contents works.
    @Test func anchorsNameHeadingsAsGitHubDoes() {
        let source = "# Gloss\n\n## Getting Started!\n\ntext\n\n## Notes & Links\n\n## Notes & Links\n\n```\n# not a heading\n```\n"
        #expect(MarkdownAnchors.headings(in: source).map(\.anchor) == ["gloss", "getting-started", "notes--links", "notes--links-1"])
        #expect(MarkdownAnchors.line(of: "getting-started", in: source) == 3)
        #expect(MarkdownAnchors.line(of: "Notes--Links-1", in: source) == 9, "case aside, the repeat")
        let nested = "# Top\n\n> ## Quoted\n\n- ### In a list\n\n## Top\n"
        #expect(MarkdownAnchors.headings(in: nested).map(\.anchor) == ["top", "quoted", "in-a-list", "top-1"], "a heading in a quote or a list item has its anchor too")
        #expect(MarkdownAnchors.line(of: "in-a-list", in: nested) == 5)
        #expect(MarkdownAnchors.line(of: "not-a-heading", in: source) == nil, "code is not a heading")
    }
}
