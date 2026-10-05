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
        #expect(classify("guide%20one.md#setup") == .document("/repo/docs/guide one.md"))
        #expect(classify("file:///System/Applications/Utilities/Terminal.app") == .document("/System/Applications/Utilities/Terminal.app"),
                "a file link only opens as a document in the viewer, never launches")
        #expect(classify("#heading") == .sameDocument)
    }

    @Test func withoutAFolderRelativeAndFileLinksAreRefused() {
        guard case .refused = MarkdownLink.classify("notes.md", documentDirectory: nil) else { Issue.record("relative"); return }
        guard case .refused = MarkdownLink.classify("file:///etc/hosts", documentDirectory: nil) else { Issue.record("file"); return }
    }
}
