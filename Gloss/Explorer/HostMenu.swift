import Core
import SwiftUI

/// The hosts at the top of the folder dropdown: what picking one does, and how each is named and drawn.
enum HostMenu {
    /// What picking a host does.
    enum Pick: Equatable {
        /// The explorer shows this host's folders and the dropdown stays open on its recent ones (This Mac, or an
        /// ssh host already connected).
        case show(HostID)
        /// The explorer lists web pages.
        case reviews
        case webPages
        case openPullRequest
        case openAtlassian
        /// Connects (again, after a failure) and opens the host's home.
        case connect(HostID)

        /// Whether the dropdown closes: everything but a host whose folders it goes on to list.
        var dismisses: Bool {
            if case .show = self { return false }
            return true
        }
    }

    static func pick(_ hostID: HostID, kind: HostKind, status: HostsModel.Status) -> Pick {
        switch kind {
        case .web: .webPages
        case .github: .openPullRequest
        case .gloss: .reviews
        case .atlassian: .openAtlassian
        case .local: .show(hostID)
        case .ssh: status == .connected ? .show(hostID) : .connect(hostID)
        }
    }

    /// How a host is named: This Mac, the integrations and the web by what they are, others by their name.
    static func label(_ hostID: HostID, name: String) -> String {
        switch hostID {
        case .gloss: "Reviews"
        case .local: "This Mac"
        case .web: "Web"
        case .github: "GitHub"
        case .atlassian: "Atlassian"
        default: name
        }
    }

    /// A host's symbol; an ssh host's says how its connection is.
    static func symbol(_ hostID: HostID, status: HostsModel.Status) -> String {
        switch hostID {
        case .gloss: "person.2"
        case .local: "desktopcomputer"
        case .web: "globe"
        case .github: "arrow.triangle.pull"
        case .atlassian: "square.stack.3d.up"
        default:
            switch status {
            case .connected: "network"
            case .connecting, .waitingForAgent, .reconnecting: "network.badge.shield.half.filled"
            case .failed: "exclamationmark.triangle"
            case .idle: "network.slash"
            }
        }
    }

    /// The hosts whose name holds `query` (all of them without one).
    static func matching(_ entries: [HostsModel.Entry], query: String) -> [HostsModel.Entry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return entries }
        return entries.filter { label($0.id, name: $0.name).localizedStandardContains(needle) }
    }

    /// What the dropdown says with nothing open on the host.
    static func nothingOpen(_ hostID: HostID) -> String {
        switch hostID {
        case .github: "No pull request open"
        case .atlassian: "No issue or page open"
        default: "No folder open"
        }
    }

    /// How an ssh host's connection reads to VoiceOver.
    static func connectionValue(_ status: HostsModel.Status) -> String {
        switch status {
        case .connected: "Connected"
        case .connecting, .waitingForAgent, .reconnecting: "Connecting"
        case .failed: "Couldn't connect"
        case .idle: "Not connected"
        }
    }

    /// The last item of the dropdown, for the host it shows.
    static func openTitle(_ hostID: HostID, name: String) -> String {
        switch hostID {
        case .gloss: "Open Review…"
        case .web: "Open Location…"
        case .github: "Open Pull Request…"
        case .atlassian: "Open Jira Issue or Confluence Page…"
        default: "Open Folder on \(name)…"
        }
    }
}

extension AppModel {
    /// What the explorer calls a host in sentences ("Open Folder on this Mac…").
    func hostName(_ hostID: HostID) -> String {
        hostID == .local ? "this Mac" : (hosts.entry(for: hostID)?.name ?? hostID.rawValue)
    }

    /// Does what a host picked in the folder dropdown asks: the explorer shows that host, and an integration opens
    /// its sheet, an ssh host not connected yet connects (again, after a failure) and opens its home.
    func browse(_ pick: HostMenu.Pick) {
        switch pick {
        case .show(let hostID):
            pickedHost = hostID
            // A folder already open there comes to the front; none, and the explorer says so under the host.
            if explorer.selectedTab?.hostID != hostID, let tab = explorer.tabs.first(where: { $0.hostID == hostID }) {
                explorer.selectedTabID = tab.id
            }
        case .reviews:
            pickedHost = .gloss
        case .webPages:
            // Pages, not files: the explorer's Web section lists them and takes an address.
            pickedHost = .web
        case .openPullRequest:
            pickedHost = .github
            presentOpenPullRequest()
        case .openAtlassian:
            pickedHost = .atlassian
            presentOpenAtlassian()
        case .connect(let hostID):
            pickedHost = hostID
            Task { await openRemoteRoot(hostID: hostID) }
        }
    }

    /// Opens a folder on `hostID`: the open panel on this Mac, a path sheet for an ssh host (there is no panel for
    /// SFTP), the address field for the web, an integration's sheet.
    func presentOpenFolder(on hostID: HostID) {
        if hostID == .gloss {
            openReviewPanel()
        } else if hostID == .web {
            presentOpenLocation()
        } else if hostID == .local {
            explorer.chooseRootWithPanel(hostID: .local)
        } else if hostID == .github {
            presentOpenPullRequest()
        } else if hostID == .atlassian {
            presentOpenAtlassian()
        } else {
            remotePathPrompt = RemotePathPrompt(hostID: hostID, hostName: hostName(hostID), initialPath: hostHomes[hostID] ?? "")
        }
    }
}
