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
        let outline = TreeOutlineView()
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .small
        outline.indentationPerLevel = 14
        // The column spans the sidebar (see `fitColumn`); shrinking it to its content would pull note marks inward.
        outline.autoresizesOutlineColumn = false
        outline.allowsMultipleSelection = false
        outline.usesAutomaticRowHeights = false
        outline.rowHeight = 22
        let column = NSTableColumn(identifier: FileCellView.identifier)
        // The single column always spans the sidebar, so trailing marks sit at its visible edge.
        column.resizingMask = .autoresizingMask
        column.width = 200
        column.minWidth = 60
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.autoresizingMask = [.width]
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
        // Keep the one column exactly as wide as the visible sidebar as it resizes.
        scroll.contentView.postsFrameChangedNotifications = true
        context.coordinator.frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak outline] _ in
            MainActor.assumeIsolated { if let outline { Self.fitColumn(outline) } }
        }
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        outline.reloadData()
        if let root = model.selectedTab?.node { outline.expandItem(root) }
        return scroll
    }

    /// The one column spans exactly the visible sidebar, so a row's trailing note mark sits at its edge.
    static func fitColumn(_ outline: NSOutlineView) {
        guard let column = outline.tableColumns.first, let clip = outline.enclosingScrollView?.contentView else { return }
        // In the source-list style a cell ends 16 pt past its column and rows keep a 10 pt trailing inset.
        let width = max(column.minWidth, clip.bounds.width - 26)
        if abs(column.width - width) > 0.5 { column.width = width }
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.model = model
        if let outline = nsView.documentView as? NSOutlineView {
            // The first layout has no size yet; settle once it does.
            DispatchQueue.main.async { Self.fitColumn(outline) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, ExplorerTreeDelegate {
        var model: ExplorerModel
        weak var outline: NSOutlineView?
        var frameObserver: (any NSObjectProtocol)?

        isolated deinit {
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        }

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
            cell.configure(with: node, mark: model.mark(for: node), folderCount: node.isDirectory ? model.folderCount(for: node) : 0,
                           holdsActive: holdsActive(node, in: outlineView))
            return cell
        }

        /// Only a collapsed folder marks the way to the open file; once open, the file's own row is in view.
        func holdsActive(_ node: FileNode, in outlineView: NSOutlineView) -> Bool {
            model.holdsActiveDocument(node) && !outlineView.isItemExpanded(node)
        }

        func outlineViewItemDidExpand(_ notification: Notification) { refreshRow(for: notification) }
        func outlineViewItemDidCollapse(_ notification: Notification) { refreshRow(for: notification) }

        private func refreshRow(for notification: Notification) {
            guard let outline, let node = notification.userInfo?["NSObject"] as? FileNode else { return }
            let row = outline.row(forItem: node)
            guard row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileCellView else { return }
            cell.configure(with: node, mark: model.mark(for: node), folderCount: model.folderCount(for: node),
                           holdsActive: holdsActive(node, in: outline), animated: true)
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
            // Each item carries the symbol the rest of the app uses for the action, as the menu bar's items do.
            func item(_ title: String, _ action: Selector, symbol: String, key: String = "") {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
                item.target = self
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                // Shown where the system shows menu images (macOS 26); macOS 27 decides for itself and typically
                // hides them, which is the platform's call, not this menu's.
                menu.addItem(item)
            }
            if !node.isDirectory {
                item("New Note…", #selector(menuNewNote), symbol: "note.text.badge.plus")
                menu.addItem(.separator())
            }
            // A pull request's tree is what GitHub holds; nothing in it is made, renamed or removed here.
            let writable = !node.hostID.isVirtual
            if directory != nil, writable {
                item("New File", #selector(menuNewFile), symbol: "doc.badge.plus")
                item("New Folder", #selector(menuNewFolder), symbol: "folder.badge.plus")
                menu.addItem(.separator())
            }
            if node.parent != nil, writable {
                item("Rename…", #selector(menuRename), symbol: "pencil")
                if !node.isDirectory { item("Duplicate", #selector(menuDuplicate), symbol: "plus.square.on.square") }
                item(node.hostID == .local ? "Move to Trash" : "Delete…", #selector(menuDelete), symbol: "trash")
                menu.addItem(.separator())
            }
            if node.isDirectory { item("Open as Its Own Folder", #selector(menuOpenAsRoot), symbol: "folder") }
            if node.hostID == .local { item("Reveal in Finder", #selector(menuReveal), symbol: "finder") }
            if node.hostID.isVirtual {
                // A pull request's, issue's or page's path is the app's own; its address is what is worth copying.
                item("Copy URL", #selector(menuCopyURL), symbol: "link")
            } else {
                item("Copy Path", #selector(menuCopyPath), symbol: "doc.on.doc")
                item("Copy Relative Path", #selector(menuCopyRelativePath), symbol: "arrow.turn.down.right")
            }
        }

        @objc private func menuOpenAsRoot() { if let node = clickedNode, node.isDirectory { Task { await model.openRoot(hostID: node.hostID, path: node.path) } } }
        @objc private func menuNewFile() { if let node = clickedNode, let directory = node.isDirectory ? node : node.parent { model.newFile(in: directory) } }
        @objc private func menuNewFolder() { if let node = clickedNode, let directory = node.isDirectory ? node : node.parent { model.newFolder(in: directory) } }
        /// A whole-file note for the clicked file, in a popover on its row; the file does not have to be open.
        @objc private func menuNewNote() {
            guard let outline, let node = clickedNode, !node.isDirectory else { return }
            let row = outline.row(forItem: node)
            guard row >= 0 else { return }
            notePopover?.close()
            let popover = NSPopover()
            popover.behavior = .transient
            let model = model
            let close: () -> Void = { [weak popover] in popover?.close() }
            let state = NoteEditorState(anchor: .wholeFile, body: "", color: model.lastFileNoteColor, anchorRect: .zero)
            popover.contentViewController = NSHostingController(rootView: NotePopover(
                state: state,
                onSave: { state in
                    model.lastFileNoteColor = state.color
                    model.onCreateFileNote(node.hostID, node.path, state.body, state.color)
                    close()
                },
                onDelete: { _ in close() },
                onCancel: close
            ))
            // Point at the file name rather than the row's far edge.
            var rect = outline.rect(ofRow: row)
            if let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView, let field = cell.textField {
                rect = field.convert(field.bounds, to: outline)
            }
            popover.show(relativeTo: rect, of: outline, preferredEdge: .maxX)
            notePopover = popover
        }

        private weak var notePopover: NSPopover?

        @objc private func menuRename() { if let node = clickedNode { model.rename(node) } }
        @objc private func menuDuplicate() { if let node = clickedNode { model.duplicate(node) } }
        @objc private func menuDelete() { if let node = clickedNode { model.delete(node) } }
        @objc private func menuReveal() { if let node = clickedNode { model.revealInFinder(node) } }
        @objc private func menuCopyPath() { if let node = clickedNode { model.copyPath(node, relative: false) } }
        @objc private func menuCopyURL() { if let node = clickedNode { model.copyURL(node) } }
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

        func treeDidChangeNoteMarks() {
            guard let outline else { return }
            outline.enumerateAvailableRowViews { rowView, row in
                guard let node = outline.item(atRow: row) as? FileNode,
                      let cell = rowView.view(atColumn: 0) as? FileCellView else { return }
                cell.configure(with: node, mark: model.mark(for: node), folderCount: node.isDirectory ? model.folderCount(for: node) : 0,
                               holdsActive: holdsActive(node, in: outline), animated: true)
            }
        }

        func treeReveal(_ chain: [FileNode]) {
            guard let outline, let target = chain.last else { return }
            for directory in chain.dropLast() where !outline.isItemExpanded(directory) {
                outline.expandItem(directory)
            }
            let row = outline.row(forItem: target)
            guard row >= 0 else { return }
            if outline.selectedRow != row { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            outline.scrollRowToVisible(row)
        }
    }
}

/// The file tree takes the window's first keyboard focus, once, when focus is nowhere or on a toolbar control: with
/// keyboard navigation on, a window should start in its content, not on the host picker.
final class TreeOutlineView: NSOutlineView {
    private var claimedInitialFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !claimedInitialFocus, let window else { return }
        claimedInitialFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, let content = window.contentView else { return }
            let current = window.firstResponder as? NSView
            if current == nil || current === window.contentView || !(current?.isDescendant(of: content) ?? false) || current is NSToolbar {
                window.makeFirstResponder(self)
            }
        }
    }
}
