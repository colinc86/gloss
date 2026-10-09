import Core
import Foundation

/// The location being reviewed, independent of a viewer left open in another folder.
nonisolated struct NotesLocation: Hashable {
    let hostID: HostID
    let path: String
    var exactDocument = false

    var title: String { Core.Document.displayName(of: path) }

    func contains(hostID: HostID, path: String) -> Bool {
        guard self.hostID == hostID else { return false }
        if exactDocument { return self.path == path }
        return ExplorerModel.inRootSpelling(path, root: self.path, hostID: hostID) != nil
    }

    func contains(_ document: Core.Document) -> Bool {
        contains(hostID: document.hostID, path: document.path)
    }
}
