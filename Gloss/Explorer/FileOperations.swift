import AppKit
import Core
import OSLog

/// New, rename, duplicate, delete, reveal, copy path. Each goes through the host's file system provider.
extension ExplorerModel {
    func newFile(in directory: FileNode) {
        guard let fileSystem = fileSystemProvider(directory.hostID) else { return }
        fileNameRequest = FileNameRequest(title: "New File", actionTitle: "Create", name: "untitled.txt", directory: directory.path) { [weak self] name in
            let path = PathUtilities.join(directory.path, name)
            _ = try await fileSystem.createFile(at: path)
            await self?.loadChildren(of: directory)
            self?.onSelectFile(directory.hostID, path)
        }
    }

    func newFolder(in directory: FileNode) {
        guard let fileSystem = fileSystemProvider(directory.hostID) else { return }
        fileNameRequest = FileNameRequest(title: "New Folder", actionTitle: "Create", name: "untitled folder", directory: directory.path) { [weak self] name in
            let path = PathUtilities.join(directory.path, name)
            try await fileSystem.createDirectory(at: path)
            await self?.loadChildren(of: directory)
        }
    }

    func rename(_ node: FileNode) {
        guard let parent = node.parent else { return }
        fileNameRequest = FileNameRequest(title: "Rename", actionTitle: "Rename", name: node.name, directory: parent.path) { [weak self] name in
            guard let self, name != node.name else { return }
            try await self.onRename(node.hostID, node.path, PathUtilities.join(parent.path, name), node.isDirectory)
            await self.loadChildren(of: parent)
        }
    }

    func duplicate(_ node: FileNode) {
        guard let parent = node.parent, !node.isDirectory else { return }
        let base = (node.name as NSString).deletingPathExtension
        let ext = (node.name as NSString).pathExtension
        var candidate = ext.isEmpty ? "\(base) copy" : "\(base) copy.\(ext)"
        var counter = 2
        let siblings = Set((parent.children ?? []).map(\.name))
        while siblings.contains(candidate) {
            candidate = ext.isEmpty ? "\(base) copy \(counter)" : "\(base) copy \(counter).\(ext)"
            counter += 1
        }
        let target = PathUtilities.join(parent.path, candidate)
        perform("duplicate") { fileSystem in
            let data = try await fileSystem.read(node.path)
            let attributes = try await fileSystem.stat(node.path)
            _ = try await fileSystem.writeAtomically(data, to: target, preservingModeFrom: attributes)
            await self.loadChildren(of: parent)
        }
    }

    func delete(_ node: FileNode) {
        guard let parent = node.parent else { return }
        let local = node.hostID == .local
        let alert = NSAlert()
        alert.messageText = local ? "Move \"\(node.name)\" to the Trash?" : "Delete \"\(node.name)\" on the remote host?"
        alert.informativeText = local ? "You can restore it from the Trash." : "Remote deletes cannot be undone."
        alert.alertStyle = local ? .informational : .warning
        alert.addButton(withTitle: local ? "Move to Trash" : "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform("delete") { fileSystem in
            try await fileSystem.delete(node.path)
            await self.loadChildren(of: parent)
        }
    }

    func revealInFinder(_ node: FileNode) {
        guard node.hostID == .local else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
    }

    /// A pull request's, issue's or page's web address, for Copy URL on the integration hosts' nodes.
    func copyURL(_ node: FileNode) {
        guard let url = webURL(node.hostID, node.path) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        onCopied("URL copied")
    }

    func copyPath(_ node: FileNode, relative: Bool) {
        let text = relative ? PathUtilities.relative(node.path, to: selectedTab?.path ?? "/") : node.path
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        onCopied(relative ? "Relative path copied" : "Path copied")
    }

    private func perform(_ what: String, _ body: @escaping @MainActor (any FileSystemProvider) async throws -> Void) {
        guard let tab = selectedTab, let fileSystem = fileSystemProvider(tab.hostID) else { return }
        Task {
            do {
                try await body(fileSystem)
            } catch {
                self.lastError = "Could not \(what): \(error.userMessage)"
                Log.explorer.error("\(what, privacy: .public) failed: \(error, privacy: .public)")
            }
        }
    }
}
