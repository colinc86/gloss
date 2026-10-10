import AppKit
import Core
import Testing
@testable import Gloss

/// Dragging a row out of the explorer: a file here as itself, a host's file as its path there, an integration's
/// document not at all.
struct ExplorerDragTests {
    @Test func rowsDragOutAsFilesOrPaths() {
        #expect((FileOutlineView.dragItem(hostID: .local, path: "/tmp/a b.md") as? NSURL) == URL(fileURLWithPath: "/tmp/a b.md") as NSURL)
        #expect((FileOutlineView.dragItem(hostID: HostID(rawValue: "h_box"), path: "/srv/app/main.py") as? NSString) == "/srv/app/main.py")
        #expect(FileOutlineView.dragItem(hostID: .github, path: "/o/r/pull/1/changes/a.swift") == nil)
        #expect(FileOutlineView.dragItem(hostID: .atlassian, path: "/jira/CP/CP-7.md") == nil)
    }
}
