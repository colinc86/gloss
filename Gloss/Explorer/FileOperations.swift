import AppKit
import Core
import OSLog

/// New, rename, duplicate, delete, reveal, copy path. Each goes through the host's file system provider.
extension ExplorerModel {
    func newFile(in directory: FileNode) {
        guard let name = prompt(title: "New File", message: "Name for the new file in \(directory.name):", defaultValue: "untitled.txt") else { return }
        perform("create file") { fileSystem in
            let path = PathUtilities.join(directory.path, name)
            _ = try await fileSystem.writeAtomically(Data(), to: path, preservingModeFrom: nil)
            await self.loadChildren(of: directory)
            self.onSelectFile(directory.hostID, path)
        }
    }

    func newFolder(in directory: FileNode) {
        guard let name = prompt(title: "New Folder", message: "Name for the new folder in \(directory.name):", defaultValue: "untitled folder") else { return }
        perform("create folder") { fileSystem in
            try await fileSystem.makeDirectory(PathUtilities.join(directory.path, name))
            await self.loadChildren(of: directory)
        }
    }

    func rename(_ node: FileNode) {
        guard let parent = node.parent,
              let name = prompt(title: "Rename", message: "New name for \(node.name):", defaultValue: node.name), name != node.name else { return }
        perform("rename") { fileSystem in
            try await fileSystem.rename(node.path, to: PathUtilities.join(parent.path, name))
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

    func copyPath(_ node: FileNode, relative: Bool) {
        let text = relative ? PathUtilities.relative(node.path, to: selectedTab?.path ?? "/") : node.path
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        onCopied(relative ? "Relative path copied" : "Path copied")
    }

    private func prompt(title: String, message: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else { return nil }
        return name
    }

    private func perform(_ what: String, _ body: @escaping @MainActor (any FileSystemProvider) async throws -> Void) {
        guard let tab = selectedTab, let fileSystem = fileSystemProvider(tab.hostID) else { return }
        Task {
            do {
                try await body(fileSystem)
            } catch {
                self.lastError = "Could not \(what): \(error)"
                Log.explorer.error("\(what, privacy: .public) failed: \(error, privacy: .public)")
            }
        }
    }
}
