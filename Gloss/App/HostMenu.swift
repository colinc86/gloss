import Core
import SwiftUI

/// The one host menu, a chip at the address field's leading edge: every host (This Mac, Web, GitHub, Atlassian,
/// the ssh hosts) with its connection's icon, then what to open on the host shown, and Manage Hosts…. At rest it
/// picks what the explorer browses; while the field is editing, This Mac or an ssh host picked here is where the
/// typed path opens instead.
struct HostMenu: View {
    @Environment(AppModel.self) private var model
    /// The host the chip names: the explorer's at rest, the field's while editing.
    let shown: HostID
    /// Set while the address field is editing: takes This Mac or an ssh host as where its path opens.
    var chooseForAddress: ((HostID) -> Void)?
    /// Called before a pick takes the user away from the field: Web, the integrations, and the Open item.
    /// Manage Hosts… opens Settings in its own window and leaves the field as it was.
    var leave: () -> Void = {}

    /// What picking a host does.
    enum Pick: Equatable {
        /// The address field opens its path there.
        case address(HostID)
        /// The explorer shows this Mac.
        case thisMac
        /// The explorer lists web pages.
        case webPages
        case openPullRequest
        case openAtlassian
        /// Connects (again, after a failure) and opens the host's home.
        case connect(HostID)
    }

    static func pick(_ hostID: HostID, kind: HostKind, editing: Bool) -> Pick {
        switch kind {
        case .web: .webPages
        case .github: .openPullRequest
        case .atlassian: .openAtlassian
        case .local: editing ? .address(hostID) : .thisMac
        case .ssh: editing ? .address(hostID) : .connect(hostID)
        }
    }

    /// How a host is named: This Mac, the integrations and the web by what they are, others by their name.
    static func label(_ hostID: HostID, name: String) -> String {
        switch hostID {
        case .local: "This Mac"
        case .web: "Web"
        case .github: "GitHub"
        case .atlassian: "Atlassian"
        default: name
        }
    }

    @ViewBuilder
    var body: some View {
        let menu = Menu {
            ForEach(model.hosts.entries) { entry in
                Button {
                    choose(entry)
                } label: {
                    Label(Self.label(entry.id, name: entry.name), systemImage: symbol(entry.id))
                }
            }
            Divider()
            // ⇧⌘O belongs to File › Open Folder…; two bindings for one key made the menu bar's win silently.
            // While editing, the item follows the chip; Open Location… would only start the field over.
            let browsed = chooseForAddress != nil ? shown : model.pickedHost
            if browsed == .web {
                if chooseForAddress == nil {
                    Button("Open Location…") { model.presentOpenLocation() }
                }
            } else if browsed == .github {
                Button("Open Pull Request…") { leave(); model.presentOpenPullRequest() }
            } else if browsed == .atlassian {
                Button("Open Jira Issue or Confluence Page…") { leave(); model.presentOpenAtlassian() }
            } else {
                Button("Open Folder on \(model.hostName(browsed))…") { leave(); model.presentOpenFolder(on: browsed) }
            }
            SettingsLink { Text("Manage Hosts…") }
        } label: {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: symbol(shown))
                    .foregroundStyle(failed(shown) ? Color.orange : tint(shown))
                Text(name(shown))
                    .foregroundStyle(tint(shown))
                    .lineLimit(1)
            }
            .font(.caption.weight(.medium))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(chooseForAddress != nil
              ? "Where a path is opened, and whose loopback localhost means: this Mac, or an ssh host through the app's connection to it. Web, GitHub and Atlassian open in the explorer."
              : "Browsing \(name(shown)). Choose another host…")
        .accessibilityLabel(chooseForAddress != nil ? "Open on" : "Host")
        .accessibilityValue(name(shown))
        // In the field, Tab and the caret stay with the text; at rest the chip is a stop like any control.
        if chooseForAddress != nil {
            menu.focusable(false)
        } else {
            menu
        }
    }

    private func choose(_ entry: HostsModel.Entry) {
        switch Self.pick(entry.id, kind: entry.kind, editing: chooseForAddress != nil) {
        case .address(let hostID):
            chooseForAddress?(hostID)
        case let pick:
            leave()
            model.browse(pick)
        }
    }

    private func name(_ hostID: HostID) -> String {
        Self.label(hostID, name: model.hostName(hostID))
    }

    /// Teal names a remote machine, since which one matters; the rest stay quiet.
    private func tint(_ hostID: HostID) -> Color {
        model.hosts.entry(for: hostID)?.kind == .ssh ? .teal : .secondary
    }

    private func failed(_ hostID: HostID) -> Bool {
        guard model.hosts.entry(for: hostID)?.kind == .ssh, case .failed = model.hosts.status(for: hostID) else { return false }
        return true
    }

    private func symbol(_ hostID: HostID) -> String {
        switch hostID {
        case .local: "desktopcomputer"
        case .web: "globe"
        case .github: "arrow.triangle.pull"
        case .atlassian: "square.stack.3d.up"
        default:
            switch model.hosts.status(for: hostID) {
            case .connected: "network"
            case .connecting, .waitingForAgent, .reconnecting: "network.badge.shield.half.filled"
            case .failed: "exclamationmark.triangle"
            case .idle: "network.slash"
            }
        }
    }
}

extension AppModel {
    /// What the explorer calls a host in sentences ("Open Folder on this Mac…").
    func hostName(_ hostID: HostID) -> String {
        hostID == .local ? "this Mac" : (hosts.entry(for: hostID)?.name ?? hostID.rawValue)
    }

    /// Does what a host picked in the host menu asks: the explorer shows that host, and an integration opens its
    /// sheet, an ssh host connects (again, after a failure) and opens its home.
    func browse(_ pick: HostMenu.Pick) {
        switch pick {
        case .address:
            return
        case .thisMac:
            pickedHost = .local
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
        if hostID == .web {
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
