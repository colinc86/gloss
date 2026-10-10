import AppKit
import SwiftUI
import Testing
@testable import Gloss

/// A failed note or iteration action says so with the notes panel hidden: New Iteration is in the menu bar too, and
/// an alert on the panel waited, unseen, until the panel was shown.
@MainActor
struct WindowAlertTests {
    @Test func aNotesFailureShowsWithThePanelHidden() async throws {
        let model = AppModel(launchOptions: AppLaunchOptions(arguments: ["app", "--reset-db"]))
        model.showNotesPanel = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: ContentView().environment(model))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(window.attachedSheet == nil)
        model.notesPanel.lastError = "Couldn't start a new iteration: the disk is full."
        for _ in 0..<100 where window.attachedSheet == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(window.attachedSheet != nil, "the alert shows on the window")
        model.notesPanel.lastError = nil
        for _ in 0..<100 where window.attachedSheet != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(window.attachedSheet == nil)
        await model.shutDown()
    }
}
