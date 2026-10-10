import AppKit
import Core
import SwiftUI
import Testing
@testable import Viewers

/// Edit › Find in a Markdown file read rendered: the find bar opens over the page, as it does over the source.
@MainActor
struct RenderedFindTests {
    @Test func findOpensTheFindBarOnTheRenderedPage() throws {
        let controller = MarkdownViewerController(source: TextEditorController(text: "# Plan\n\nCache the forecast.\n", languageName: "markdown"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: MarkdownViewerView(controller: controller))
        hosting.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for subview in view.subviews { if let found = find(type, in: subview) { return found } }
            return nil
        }
        let textView = try #require(find(RenderedTextView.self, in: hosting))
        let item = NSMenuItem(title: "Find…", action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "f")
        item.tag = NSTextFinder.Action.showFindInterface.rawValue
        #expect(textView.validateMenuItem(item), "Find is offered on the rendered page")
        textView.performTextFinderAction(item)
        #expect(textView.enclosingScrollView?.isFindBarVisible == true)
    }
}
