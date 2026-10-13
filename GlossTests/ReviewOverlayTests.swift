import AppKit
import Core
import Testing
@testable import Gloss

@MainActor
struct ReviewOverlayTests {
    @Test func theNativeCardIsAbovePathsAndTracksOnlyTheDocument() throws {
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        let session = DocumentSession(hostID: .local, path: "/tmp/demo.md", fileSystem: LocalFileSystem(), noteStore: model.noteStore)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = content
        // The document occupies 500 pt, leaving a status bar below it.
        let probe = ReviewOverlay.Probe(model: model, session: session)
        probe.frame = CGRect(x: 0, y: 40, width: 600, height: 500)
        model.noteLink.install(in: window)
        content.addSubview(probe)
        probe.place()
        let parent = try #require(probe.host.superview)
        let paths = try #require(parent.subviews.first { $0 is NotePathLayerView })
        let pathIndex = try #require(parent.subviews.firstIndex(of: paths))
        let reviewIndex = try #require(parent.subviews.firstIndex(of: probe.host))
        #expect(reviewIndex > pathIndex)
        #expect(probe.host.frame == probe.convert(probe.bounds, to: parent))
        #expect(probe.host.hitTest(CGPoint(x: probe.host.frame.midX, y: probe.host.frame.midY)) == nil, "inactive card takes no document clicks")
        let host = probe.host
        probe.frame = CGRect(x: 10, y: 40, width: 450, height: 360)
        probe.place()
        model.noteLink.install(in: window)
        #expect(probe.host === host, "geometry changes preserve the card's SwiftUI state")
        #expect(host.frame == probe.convert(probe.bounds, to: parent))
        let movedReviewIndex = try #require(parent.subviews.firstIndex(of: host))
        let movedPathIndex = try #require(parent.subviews.firstIndex(of: paths))
        #expect(movedReviewIndex > movedPathIndex)
        probe.stop()
    }
    @Test func reviewIsHiddenOnlyWhileTheCompactExplorerIsShown() {
        #expect(!ReviewOverlay.Root.shouldPresent(active: true, showingSession: true, compact: true, explorerShown: true))
        #expect(ReviewOverlay.Root.shouldPresent(active: true, showingSession: true, compact: true, explorerShown: false))
        #expect(ReviewOverlay.Root.shouldPresent(active: true, showingSession: true, compact: false, explorerShown: true))
    }

    @Test func installingAnOverlayDoesNotMovePathsOutOfAnotherWindow() throws {
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        let first = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        let second = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        first.isReleasedWhenClosed = false
        second.isReleasedWhenClosed = false
        defer { first.close(); second.close() }
        model.noteLink.install(in: first)
        let parent = try #require(first.contentView?.superview)
        let paths = try #require(parent.subviews.first { $0 is NotePathLayerView })
        #expect(!model.noteLink.installReview(NSView(), in: second))
        #expect(paths.window === first)
        let hud = NSView()
        let review = NSView()
        #expect(model.noteLink.installHUD(hud, in: first))
        #expect(model.noteLink.installReview(review, in: first))
        let hudIndex = try #require(parent.subviews.firstIndex(of: hud))
        let reviewIndex = try #require(parent.subviews.firstIndex(of: review))
        #expect(hudIndex > reviewIndex, "HUD stays above a card attached later")
    }

    @Test func floatingControlsJoinAndLeaveTheContentKeyLoop() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = try #require(window.contentView)
        let parent = try #require(content.superview)
        let card = NSView(), toast = NSView()
        parent.addSubview(card)
        parent.addSubview(toast)
        let cardLoop = FloatingKeyLoop(), toastLoop = FloatingKeyLoop()
        defer { cardLoop.update(host: card, shown: false); toastLoop.update(host: toast, shown: false) }
        func includes(_ view: NSView) -> Bool {
            var visited = Set<ObjectIdentifier>()
            var next: NSView? = content
            while let node = next, visited.insert(ObjectIdentifier(node)).inserted {
                if node === view { return true }
                next = node.nextKeyView
            }
            return false
        }
        cardLoop.update(host: card, shown: true)
        toastLoop.update(host: toast, shown: true)
        #expect(includes(card) && includes(toast))
        cardLoop.update(host: card, shown: false)
        #expect(!includes(card) && includes(toast), "hiding the card retains the other overlay's loop entry")
        toastLoop.update(host: toast, shown: false)
        #expect(!includes(toast))
    }

}
