import AppKit

/// Frame-view overlays sit outside the content's automatic key loop. Join them without taking keyboard focus.
@MainActor
final class FloatingKeyLoop {
    private static var shownLoops: [FloatingKeyLoop] = []
    private weak var host: NSView?
    private weak var window: NSWindow?
    private weak var anchor: NSView?
    private weak var successor: NSView?
    private var isShown = false

    func update(host: NSView, shown: Bool) {
        guard shown != isShown || (shown && window !== host.window) else { return }
        let oldWindow = window
        restore()
        Self.shownLoops.removeAll { $0 === self || $0.host == nil }
        isShown = false
        window = nil
        self.host = nil
        if shown, let window = host.window {
            self.host = host
            self.window = window
            isShown = true
            Self.shownLoops.append(self)
        }
        if let oldWindow { Self.rebuild(in: oldWindow) }
        if let window, window !== oldWindow { Self.rebuild(in: window) }
    }

    private func restore() {
        if let anchor, anchor.nextKeyView === host { anchor.nextKeyView = successor }
        host?.nextKeyView = nil
        anchor = nil
        successor = nil
    }

    private static func rebuild(in window: NSWindow) {
        let loops = shownLoops.filter { $0.window === window && $0.host != nil }
        for loop in loops.reversed() { loop.restore() }
        guard let content = window.contentView else { return }
        window.recalculateKeyViewLoop()
        _ = content.nextValidKeyView
        let current = window.firstResponder as? NSView
        var insertion = current.flatMap { $0.isDescendant(of: content) ? $0 : nil } ?? content
        for loop in loops {
            guard let host = loop.host else { continue }
            var visited = Set<ObjectIdentifier>()
            var previous: NSView?
            var next: NSView? = content
            while let node = next, visited.insert(ObjectIdentifier(node)).inserted {
                if node === host { break }
                previous = node
                next = node.nextKeyView
            }
            let anchor = next === host ? (previous ?? insertion) : insertion
            loop.anchor = anchor
            loop.successor = next === host ? host.nextKeyView : anchor.nextKeyView
            host.nextKeyView = loop.successor
            anchor.nextKeyView = host
            insertion = host
        }
    }
}
