import Core

/// The documents shown in the viewer, in the order they were shown, across folders and hosts, for Back and Forward
/// (issue #3). Entries are places, not sessions: a document closed since (sessions are trimmed to a handful) opens
/// again when it is gone back to.
nonisolated struct DocumentHistory: Equatable {
    struct Entry: Hashable {
        var hostID: HostID
        var path: String
    }

    static let limit = 50

    private(set) var back: [Entry] = []
    private(set) var forward: [Entry] = []
    private(set) var current: Entry?

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    /// A document was shown by any means but Back and Forward: it becomes the current place and the way forward is
    /// forgotten, as in a browser. Showing the current document again changes nothing.
    mutating func visit(_ entry: Entry) {
        guard entry != current else { return }
        if let current {
            back.removeAll { $0 == entry }
            back.append(current)
            if back.count > Self.limit { back.removeFirst(back.count - Self.limit) }
        }
        current = entry
        forward = []
    }

    /// The place before the current one, which becomes current; nil at the start. Places `gone` says can't be
    /// shown any more (a deleted file) are passed over and forgotten.
    mutating func goBack(skipping gone: (Entry) -> Bool = { _ in false }) -> Entry? {
        while let target = back.popLast() {
            if gone(target) { forget(target); continue }
            if let current { forward.append(current) }
            current = target
            return target
        }
        return nil
    }

    mutating func goForward(skipping gone: (Entry) -> Bool = { _ in false }) -> Entry? {
        while let target = forward.popLast() {
            if gone(target) { forget(target); continue }
            if let current { back.append(current) }
            current = target
            return target
        }
        return nil
    }

    /// A place that can't be shown any more (the file was deleted): forgotten wherever it is listed.
    mutating func forget(_ entry: Entry) {
        back.removeAll { $0 == entry }
        forward.removeAll { $0 == entry }
        if current == entry { current = nil }
    }

    /// The most recent places in each direction, nearest first, for the toolbar menus.
    func recentBack(_ count: Int = 10) -> [Entry] { Array(back.reversed().prefix(count)) }
    func recentForward(_ count: Int = 10) -> [Entry] { Array(forward.reversed().prefix(count)) }
}
