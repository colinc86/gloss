import AppKit
import Core
import OSLog

/// New, rename, duplicate, delete, reveal, copy path. Each goes through the host's file system provider.
extension ExplorerModel {
    func newFile(in directory: FileNode) {
        guard let fileSystem = fileSystemProvider(directory.hostID) else { return }
        fileNameRequest = FileNameRequest(title: "New File", actionTitle: "Create", name: Self.freeName("untitled.txt", in: directory, isFolder: false), directory: directory.path) { [weak self] name in
            let path = PathUtilities.join(directory.path, name)
            _ = try await fileSystem.createFile(at: path)
            await self?.loadChildren(of: directory)
            self?.onSelectFile(directory.hostID, path)
        }
    }

    func newFolder(in directory: FileNode) {
        guard let fileSystem = fileSystemProvider(directory.hostID) else { return }
        fileNameRequest = FileNameRequest(title: "New Folder", actionTitle: "Create", name: Self.freeName("untitled folder", in: directory, isFolder: true), directory: directory.path) { [weak self] name in
            let path = PathUtilities.join(directory.path, name)
            try await fileSystem.createDirectory(at: path)
            await self?.loadChildren(of: directory)
        }
    }

    /// The name a new file or folder is offered: `wanted`, or "untitled 2.txt" and on when the folder (as listed)
    /// already has it, ignoring case as the Mac's volume does, so Create works without editing it first. A folder's
    /// name has no extension to keep at the end.
    nonisolated static func freeName(_ wanted: String, among taken: [String], isFolder: Bool) -> String {
        let names = Set(taken.map { $0.lowercased() })
        guard names.contains(wanted.lowercased()) else { return wanted }
        let ext = (wanted as NSString).pathExtension
        let base = ext.isEmpty || isFolder ? wanted : (wanted as NSString).deletingPathExtension
        let suffix = base == wanted ? "" : ".\(ext)"
        var counter = 2
        while names.contains("\(base) \(counter)\(suffix)".lowercased()) { counter += 1 }
        return "\(base) \(counter)\(suffix)"
    }

    private static func freeName(_ wanted: String, in directory: FileNode, isFolder: Bool) -> String {
        freeName(wanted, among: (directory.children ?? []).map(\.name), isFolder: isFolder)
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
        perform("duplicate") { fileSystem in
            _ = try await Self.duplicate(node.path, in: parent.path, using: fileSystem)
            await self.loadChildren(of: parent)
        }
    }

    /// Copies a file beside itself as "name copy.ext", then "name copy 2.ext" and on. Each name is claimed by
    /// creating it exclusively, so a file already there (one the tree hasn't listed yet, say) is never written over.
    nonisolated static func duplicate(_ path: String, in directory: String, using fileSystem: any FileSystemProvider) async throws -> String {
        let name = (path as NSString).lastPathComponent
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        let data = try await fileSystem.read(path)
        let attributes = try await fileSystem.stat(path)
        for counter in 1...1000 {
            let copy = counter == 1 ? "\(base) copy" : "\(base) copy \(counter)"
            let target = PathUtilities.join(directory, ext.isEmpty ? copy : "\(copy).\(ext)")
            do {
                _ = try await fileSystem.createFile(at: target)
            } catch FileSystemError.alreadyExists {
                continue
            }
            do {
                _ = try await fileSystem.writeAtomically(data, to: target, preservingModeFrom: attributes)
            } catch {
                try? await fileSystem.delete(target)   // not an empty file left where the copy was meant to be
                throw error
            }
            return target
        }
        throw FileSystemError.alreadyExists(PathUtilities.join(directory, "\(base) copy"))
    }

    func delete(_ node: FileNode) {
        guard let parent = node.parent else { return }
        let local = node.hostID == .local
        let text = Self.deleteConfirmation(name: node.name, isDirectory: node.isDirectory, hostName: local ? nil : hostName(node.hostID))
        let alert = NSAlert()
        alert.messageText = text.message
        alert.informativeText = text.information
        alert.alertStyle = local ? .informational : .warning
        alert.addButton(withTitle: text.button)
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform("delete") { fileSystem in
            try await fileSystem.delete(node.path)
            await self.loadChildren(of: parent)
        }
    }

    /// What Delete asks: a local item goes to the Trash; a remote one is gone for good, a folder with everything in
    /// it, on the host it names.
    nonisolated static func deleteConfirmation(name: String, isDirectory: Bool, hostName: String?) -> (message: String, information: String, button: String) {
        guard let hostName else {
            return (isDirectory ? "Move the folder \"\(name)\" and its contents to the Trash?" : "Move \"\(name)\" to the Trash?",
                    "You can restore it from the Trash.", "Move to Trash")
        }
        return (isDirectory ? "Delete the folder \"\(name)\" and everything in it on \(hostName)?" : "Delete \"\(name)\" on \(hostName)?",
                "Deleting on a remote host can't be undone.", "Delete")
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
                self.lastError = "Couldn't \(what): \(error.userMessage)"
                Log.explorer.error("\(what, privacy: .public) failed: \(error, privacy: .public)")
            }
        }
    }
}
