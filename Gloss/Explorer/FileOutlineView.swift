import AppKit
import Core
import SwiftUI

/// The tree. Children load lazily on expand; the model tells the coordinator what to reload.
struct FileOutlineView: NSViewRepresentable {
    let model: ExplorerModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .small
        outline.indentationPerLevel = 14
        outline.autoresizesOutlineColumn = true
        outline.allowsMultipleSelection = false
        outline.usesAutomaticRowHeights = false
        outline.rowHeight = 22
        let column = NSTableColumn(identifier: FileCellView.identifier)
        column.resizingMask = .autoresizingMask
        column.width = 400
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.sizeLastColumnToFit()
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))
        let menu = NSMenu()
        menu.delegate = context.coordinator
        outline.menu = menu
        context.coordinator.outline = outline
        model.treeDelegate = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        outline.reloadData()
        if let root = model.selectedTab?.node { outline.expandItem(root) }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.model = model
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, ExplorerTreeDelegate {
        var model: ExplorerModel
        weak var outline: NSOutlineView?

        init(model: ExplorerModel) {
            self.model = model
        }

        private var root: FileNode? { model.selectedTab?.node }

        private func children(of item: Any?) -> [FileNode] {
            guard let node = item as? FileNode else { return root.map { [$0] } ?? [] }
            return node.visibleChildren(showDotfiles: model.showDotfiles, filter: model.filter)
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            children(of: item).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            children(of: item)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? FileNode)?.isDirectory ?? false
        }

        // MARK: Delegate

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? FileNode else { return nil }
            let cell = outlineView.makeView(withIdentifier: FileCellView.identifier, owner: nil) as? FileCellView ?? {
                let view = FileCellView(frame: .zero)
                view.identifier = FileCellView.identifier
                return view
            }()
            cell.configure(with: node)
            return cell
        }

        func outlineViewItemWillExpand(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? FileNode, !node.isLoaded else { return }
            let model = model
            Task { await model.loadChildren(of: node) }
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard let outline else { return }
            model.select(outline.item(atRow: outline.selectedRow) as? FileNode)
        }

        @objc func doubleClicked(_ sender: Any?) {
            guard let outline, let node = outline.item(atRow: outline.clickedRow) as? FileNode else { return }
            if node.isDirectory {
                if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
            } else {
                model.select(node)
            }
        }

        // MARK: Context menu

        private var clickedNode: FileNode? {
            guard let outline, outline.clickedRow >= 0 else { return nil }
            return outline.item(atRow: outline.clickedRow) as? FileNode
        }

        public func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let node = clickedNode else { return }
            let directory = node.isDirectory ? node : node.parent
            func item(_ title: String, _ action: Selector, key: String = "") {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
                item.target = self
                menu.addItem(item)
            }
            if directory != nil {
                item("New File", #selector(menuNewFile))
                item("New Folder", #selector(menuNewFolder))
                menu.addItem(.separator())
            }
            if node.parent != nil {
                item("Rename…", #selector(menuRename))
                if !node.isDirectory { item("Duplicate", #selector(menuDuplicate)) }
                item(node.hostID == .local ? "Move to Trash" : "Delete…", #selector(menuDelete))
                menu.addItem(.separator())
            }
            if node.isDirectory { item("Open as Root", #selector(menuOpenAsRoot)) }
            if node.hostID == .local { item("Reveal in Finder", #selector(menuReveal)) }
            item("Copy Path", #selector(menuCopyPath))
            item("Copy Relative Path", #selector(menuCopyRelativePath))
        }

        @objc private func menuOpenAsRoot() { if let node = clickedNode, node.isDirectory { Task { await model.openRoot(hostID: node.hostID, path: node.path) } } }
        @objc private func menuNewFile() { if let node = clickedNode, let directory = node.isDirectory ? node : node.parent { model.newFile(in: directory) } }
        @objc private func menuNewFolder() { if let node = clickedNode, let directory = node.isDirectory ? node : node.parent { model.newFolder(in: directory) } }
        @objc private func menuRename() { if let node = clickedNode { model.rename(node) } }
        @objc private func menuDuplicate() { if let node = clickedNode { model.duplicate(node) } }
        @objc private func menuDelete() { if let node = clickedNode { model.delete(node) } }
        @objc private func menuReveal() { if let node = clickedNode { model.revealInFinder(node) } }
        @objc private func menuCopyPath() { if let node = clickedNode { model.copyPath(node, relative: false) } }
        @objc private func menuCopyRelativePath() { if let node = clickedNode { model.copyPath(node, relative: true) } }

        /// The selected row, for menu-bar commands.
        var selectedNode: FileNode? {
            guard let outline, outline.selectedRow >= 0 else { return nil }
            return outline.item(atRow: outline.selectedRow) as? FileNode
        }

        // MARK: ExplorerTreeDelegate

        func treeDidReplaceRoot() {
            outline?.reloadData()
            if let root { outline?.expandItem(root) }
        }

        func treeDidReload(_ node: FileNode) {
            guard let outline else { return }
            if node === root {
                outline.reloadItem(node, reloadChildren: true)
                if !outline.isItemExpanded(node) { outline.expandItem(node) }
            } else {
                outline.reloadItem(node, reloadChildren: true)
            }
        }

        func treeDidChangeFilters() {
            outline?.reloadData()
            if let root { outline?.expandItem(root) }
        }
    }
}
