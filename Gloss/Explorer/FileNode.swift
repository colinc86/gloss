import AppKit
import Core

/// One row of the explorer tree. A reference type so `NSOutlineView` can use it as an item.
/// Identity is stable across refreshes: `ExplorerModel` reuses nodes for paths that still exist.
final class FileNode: NSObject {
    let hostID: HostID
    private(set) var entry: DirectoryEntry
    weak var parent: FileNode?
    /// Nil until the directory has been listed once.
    var children: [FileNode]?
    var isLoading = false
    var isIgnored = false
    /// Open in the tree, so a tree built again (the compact layout's slide-over, back to the sidebar) opens it again.
    var isExpanded = false

    init(hostID: HostID, entry: DirectoryEntry, parent: FileNode?) {
        self.hostID = hostID
        self.entry = entry
        self.parent = parent
    }

    var path: String { entry.path }
    var name: String { entry.name }
    var isDirectory: Bool { entry.isDirectoryLike }
    var isLoaded: Bool { children != nil }

    /// Merges a fresh listing into the existing children, keeping node objects whose path still exists.
    func merge(entries: [DirectoryEntry]) -> (inserted: [FileNode], removed: [FileNode]) {
        var existing: [String: FileNode] = [:]
        for child in children ?? [] { existing[child.path] = child }
        var merged: [FileNode] = []
        var inserted: [FileNode] = []
        for entry in entries {
            if let node = existing.removeValue(forKey: entry.path) {
                node.entry = entry
                if !node.isDirectory { node.children = nil }
                merged.append(node)
            } else {
                let node = FileNode(hostID: hostID, entry: entry, parent: self)
                merged.append(node)
                inserted.append(node)
            }
        }
        children = merged.sorted(by: Self.treeOrder)
        return (inserted, Array(existing.values))
    }

    /// Folders (and links to folders) first, then names the way Finder orders them: case-insensitive, with
    /// numbers compared by value (`file2` before `file10`).
    static func treeOrder(_ lhs: FileNode, _ rhs: FileNode) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    /// Children after the dotfile toggle and the name filter.
    func visibleChildren(showDotfiles: Bool, filter: String) -> [FileNode] {
        (children ?? []).filter { child in
            if !showDotfiles && child.entry.isHidden { return false }
            return child.isDirectory || child.matches(filter: filter)
        }
    }

    /// Whether the explorer's filter keeps this file: its name, or the name as its row shows it (a Jira issue's
    /// summary), holds the filter, case and accents aside as Open Quickly does. The tree and Reveal ask the same.
    func matches(filter: String) -> Bool {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        return needle.isEmpty || name.localizedStandardContains(needle) || FileCellView.displayName(entry).localizedStandardContains(needle)
    }

    /// Walks down to the node at `path`, loaded children only.
    func descendant(at path: String) -> FileNode? {
        if path == self.path { return self }
        guard path.hasPrefix(self.path.hasSuffix("/") ? self.path : self.path + "/") else { return nil }
        for child in children ?? [] {
            if let found = child.descendant(at: path) { return found }
        }
        return nil
    }
}
