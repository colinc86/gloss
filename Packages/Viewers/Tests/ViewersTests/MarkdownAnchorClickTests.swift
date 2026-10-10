import AppKit
import Testing
@testable import Viewers

/// A click on a table of contents' `#anchor` scrolls the rendered page to that heading.
@MainActor
struct MarkdownAnchorClickTests {
    @Test func anAnchorLinkScrollsToItsHeading() {
        let markdown = "# Guide\n\n- [Setup](#set-up)\n\nIntro.\n\n## Set up\n\nSteps.\n"
        let controller = MarkdownViewerController(source: TextEditorController(text: markdown, languageName: "markdown"))
        let coordinator = RenderedMarkdownView.Coordinator(controller: controller)
        let before = controller.pendingRenderedScrollVersion
        #expect(coordinator.textView(NSTextView(), clickedOnLink: "#set-up", at: 0))
        #expect(controller.pendingRenderedScrollVersion == before + 1)
        let heading = (controller.rendered.string as NSString).range(of: "Set up")
        #expect(controller.pendingRenderedScroll.map { NSIntersectionRange($0, heading).length > 0 } == true, "the heading, not the link")
        #expect(controller.pendingRenderedScrollAtTop)
    }
}
