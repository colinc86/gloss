import AppKit
import SwiftUI
import Testing
@testable import Viewers

/// Zoom in answers ⌘+ as well as ⌘=: most people press ⌘+ (⌘⇧= on a US keyboard), and on layouts where `+` is
/// its own key (German, Swiss) ⌘= needs Shift and was never pressed as such.
@MainActor
struct ZoomShortcutTests {
    private func press(_ characters: String, unmodified: String, flags: NSEvent.ModifierFlags, in window: NSWindow) -> Bool {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                                     context: nil, characters: characters, charactersIgnoringModifiers: unmodified, isARepeat: false, keyCode: 24)!
        return window.performKeyEquivalent(with: event)
    }

    @Test func zoomInAnswersCommandPlusAndCommandEquals() async throws {
        var commands: [ImageViewerController.ZoomCommand] = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: HStack { ZoomControls(magnification: 1, fitHelp: "Fit", zoom: { commands.append($0) }) })
        hosting.frame = window.contentLayoutRect
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        _ = press("=", unmodified: "=", flags: .command, in: window)
        _ = press("+", unmodified: "+", flags: [.command, .shift], in: window)   // a US keyboard's ⌘+
        _ = press("+", unmodified: "+", flags: .command, in: window)             // a German keyboard's
        try await Task.sleep(for: .milliseconds(100))
        window.orderOut(nil)
        #expect(commands == [.zoomIn, .zoomIn, .zoomIn], "each press zooms once")
    }
}
