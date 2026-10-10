import AppKit
import Testing
@testable import Viewers

/// Typing with the source showing doesn't render the page nobody sees; the page catches up when it is shown.
@MainActor
struct SourceModeRenderTests {
    @Test func editsInTheSourceRenderOnceThePageShows() async throws {
        let source = TextEditorController(text: "# Title\n\nFirst.\n", languageName: "markdown")
        let markdown = MarkdownViewerController(source: source)
        let start = markdown.renderedVersion
        markdown.mode = .source
        #expect(markdown.renderedVersion == start, "showing the source renders nothing")
        source.viewDidChangeText("# Title\n\nFirst.\n\nSecond.\n")
        source.viewDidChangeText("# Title\n\nFirst.\n\nSecond and third.\n")
        try await Task.sleep(for: .milliseconds(400))
        #expect(markdown.renderedVersion == start, "no render while the source shows")
        markdown.mode = .rendered
        #expect(markdown.renderedVersion == start + 1, "one render as the page comes back")
        #expect(markdown.rendered.string.contains("Second and third."))
        markdown.mode = .source
        markdown.mode = .rendered
        #expect(markdown.renderedVersion == start + 1, "nothing to catch up on")

        // Rendered, an edit still renders shortly after.
        source.viewDidChangeText("# Title\n\nChanged.\n")
        for _ in 0..<50 where markdown.renderedVersion == start + 1 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(markdown.rendered.string.contains("Changed."))
    }
}
