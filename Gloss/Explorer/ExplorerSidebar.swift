import AppKit
import Core
import SwiftUI
import Viewers

/// The explorer column: host and folder controls in the toolbar, a status row, root tabs, the tree, and the filter.
struct ExplorerSidebar: View {
    @FocusState private var searchFocused: Bool
    @FocusState private var filterFocused: Bool
    @Environment(AppModel.self) private var model
    @State private var remotePathPrompt: RemotePathPrompt?
    @State private var diagnostics: String?

    private var pickedHost: HostID { model.pickedHost }

    var body: some View {
        @Bindable var explorer = model.explorer
        VStack(spacing: 0) {
            if model.followHerdr, let pane = model.followedPane {
                FollowCard(pane: pane) { model.followHerdr = false }
                    .padding(.horizontal, DS.Space.s)
                    .padding(.top, DS.Space.s)
                    .transition((AnyTransition.move(edge: .top).combined(with: .opacity)).calmed)
            }
            if let status = statusRow {
                status
            }
            if !explorer.tabs.isEmpty {
                RootSwitcher(hostName: hostName, openFolder: openFolder)
                    .padding(.horizontal, DS.Space.s)
                    .padding(.vertical, DS.Space.s)
                Divider()
            }
            if explorer.contentSearch.isVisible, explorer.selectedTab != nil {
                searchBar
                Divider()
                SearchResultsView()
            } else if explorer.selectedTab != nil {
                FileOutlineView(model: explorer)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label(pickedHost == .github ? "No pull request open" : pickedHost == .atlassian ? "No issue or page open" : "No folder open", systemImage: pickedHost == .github ? "arrow.triangle.pull" : pickedHost == .atlassian ? "square.stack.3d.up" : "folder.badge.plus")
                } description: {
                    // On this Mac the welcome screen beside it carries the button; one first step, not two.
                    Text(pickedHost == .local ? "Its files appear here." : pickedHost == .github ? "Its description, conversation and changed files appear here." : pickedHost == .atlassian ? "A project's issues or a space's pages appear here." : "Connect to browse \(hostName(pickedHost))'s files.")
                } actions: {
                    if pickedHost == .github {
                        Button("Open Pull Request…") { model.presentOpenPullRequest() }
                    } else if pickedHost == .atlassian {
                        Button("Open Issue or Page…") { model.presentOpenAtlassian() }
                    } else if pickedHost != .local {
                        Button("Connect") { openFolder() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(DS.Motion.smooth, value: model.followHerdr && model.followedPane != nil)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                footer
            }
            .background(.bar)
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                hostMenu
                FollowToggle(isOn: Binding(get: { model.followHerdr }, set: { model.followHerdr = $0 }))
            }
        }
        .onChange(of: model.explorer.selectedTabID) { _, _ in
            if let tab = model.explorer.selectedTab { model.pickedHost = tab.hostID }
        }
        .sheet(item: $remotePathPrompt) { prompt in
            RemotePathSheet(prompt: prompt) { path in
                Task { await model.openRemoteRoot(hostID: prompt.hostID, path: path) }
            }
        }
        .alert("Unknown host key", isPresented: Binding(get: { model.hosts.pendingHostKey != nil }, set: { _ in })) {
            Button("Accept and Connect") {
                if let pending = model.hosts.pendingHostKey {
                    Task { _ = await model.hosts.acceptNewHostKey(pending.hostID); await model.openRemoteRoot(hostID: pending.hostID) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This host's key is not in known_hosts yet.\n\(model.hosts.pendingHostKey?.fingerprint ?? "")\nAccept it for this host only?")
        }
    }

    // MARK: Hosts

    private func hostName(_ hostID: HostID) -> String {
        hostID == .local ? "this Mac" : (model.hosts.entry(for: hostID)?.name ?? hostID.rawValue)
    }

    /// Hosts come from `~/.ssh/config` (`Host` aliases without wildcards). Choosing one connects and opens its home;
    /// choosing it again retries after a failure.
    private var hostMenu: some View {
        Menu {
            ForEach(model.hosts.entries) { entry in
                Button {
                    model.pickedHost = entry.id
                    if entry.id == .github {
                        model.presentOpenPullRequest()
                    } else if entry.id == .atlassian {
                        model.presentOpenAtlassian()
                    } else if entry.id != .local {
                        Task { await model.openRemoteRoot(hostID: entry.id) }
                    }
                } label: {
                    Label(entry.id == .github ? "GitHub" : entry.id == .atlassian ? "Atlassian" : entry.name, systemImage: entry.kind == .local ? "desktopcomputer" : entry.id == .github ? "arrow.triangle.pull" : entry.id == .atlassian ? "square.stack.3d.up" : statusIcon(entry.id))
                }
            }
            Divider()
            // ⇧⌘O belongs to File › Open Folder…; two bindings for one key made the menu bar's win silently.
            if pickedHost == .github {
                Button("Open Pull Request…") { model.presentOpenPullRequest() }
            } else if pickedHost == .atlassian {
                Button("Open Jira Issue or Confluence Page…") { model.presentOpenAtlassian() }
            } else {
                Button("Open Folder on \(hostName(pickedHost))…") { openFolder() }
            }
            SettingsLink { Text("Manage Hosts…") }
        } label: {
            // This Mac is the default and the icon says so; a remote host names itself, since which one matters.
            Label(pickedHost == .local ? "local" : pickedHost == .github ? "GitHub" : pickedHost == .atlassian ? "Atlassian" : hostName(pickedHost), systemImage: pickedHost == .local ? "desktopcomputer" : pickedHost == .github ? "arrow.triangle.pull" : pickedHost == .atlassian ? "square.stack.3d.up" : statusIcon(pickedHost))
                .labelStyle(.titleAndIcon)
        }
        .help(pickedHost == .local ? "Browsing this Mac. Choose another host…" : "Browsing \(hostName(pickedHost)). Choose another host…")
        .accessibilityLabel("Host: \(hostName(pickedHost))")
    }

    private func statusIcon(_ hostID: HostID) -> String {
        switch model.hosts.status(for: hostID) {
        case .connected: "network"
        case .connecting, .waitingForAgent, .reconnecting: "network.badge.shield.half.filled"
        case .failed: "exclamationmark.triangle"
        case .idle: "network.slash"
        }
    }

    private func openFolder() {
        if pickedHost == .local {
            model.explorer.chooseRootWithPanel(hostID: .local)
        } else if pickedHost == .github {
            model.presentOpenPullRequest()
        } else if pickedHost == .atlassian {
            model.presentOpenAtlassian()
        } else {
            let home = model.hostHomes[pickedHost] ?? ""
            remotePathPrompt = RemotePathPrompt(hostID: pickedHost, hostName: hostName(pickedHost), initialPath: home)
        }
    }

    /// The picked host's connection as a notice (connecting, waiting for the key agent, reconnecting, failed, or a
    /// warning while connected), and follow problems; nil when there is nothing to say.
    private var statusRow: AnyView? {
        var follow: String?
        if model.followHerdr, model.followedPane == nil { follow = model.followStatus }
        let status: HostsModel.Status? = pickedHost == .local || pickedHost.isVirtual ? nil : model.hosts.status(for: pickedHost)
        guard let content = ConnectionNoticeContent.make(
            host: hostName(pickedHost), status: status, progress: model.hosts.progress[pickedHost],
            warning: model.hosts.warnings[pickedHost], follow: follow
        ) else { return nil }
        return AnyView(
            ConnectionNotice(content: content) {
                if pickedHost != .local, content.showsDetails {
                    Button("Details") { Task { diagnostics = await model.hosts.diagnostics(for: pickedHost) } }
                        .popover(isPresented: Binding(get: { diagnostics != nil }, set: { if !$0 { diagnostics = nil } })) {
                            DiagnosticsPopover(text: diagnostics ?? "")
                        }
                }
                if content.offersConnect, pickedHost != .local {
                    Button(content.kind == .warning ? "Try Again" : "Connect") { Task { await model.openRemoteRoot(hostID: pickedHost) } }
                        .buttonStyle(.glassProminent)
                } else if content.isBusy, pickedHost != .local {
                    Button("Cancel") { Task { await model.hosts.disconnect(pickedHost) } }
                }
            }
            .padding(.horizontal, DS.Space.s)
            .padding(.top, DS.Space.s)
            .transition((AnyTransition.move(edge: .top).combined(with: .opacity)).calmed)
        )
    }


    // MARK: Roots, search, footer

    private var searchBar: some View {
        @Bindable var search = model.explorer.contentSearch
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search file contents", text: $search.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit {
                    model.runContentSearch()
                }
                // Find in Files puts the caret here, as ⌘⇧F does in other editors; Escape puts the tree back.
                .onAppear { searchFocused = true }
                .onChange(of: search.focusRequest) { _, _ in searchFocused = true }
                .onKeyPress(.escape) {
                    search.isVisible = false
                    search.cancel()
                    return .handled
                }
            if search.isSearching { ProgressView().controlSize(.small) }
            // A borderless toggle draws no "on" state, so regex mode was invisible; this one fills when on.
            Button {
                search.isRegex.toggle()
                if !search.query.isEmpty { model.runContentSearch() }
            } label: {
                Text(".*")
                    .font(.caption.monospaced().weight(.semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .foregroundStyle(search.isRegex ? Color.white : Color.secondary)
                    .background(search.isRegex ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Regular expression")
            .accessibilityValue(search.isRegex ? "on" : "off")
            .help(search.isRegex ? "Regular expression (click for plain text)" : "Plain text (click for a regular expression); case is ignored unless the query has a capital letter")
            Button {
                search.isVisible = false
                search.cancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .font(.callout)
    }

    private var footer: some View {
        @Bindable var explorer = model.explorer
        return HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary)
            TextField("Filter files", text: $explorer.filter)
                .textFieldStyle(.plain)
                .focused($filterFocused)
                .onChange(of: explorer.filterFocusRequest) { _, _ in filterFocused = true }
                .onKeyPress(.escape) {
                    if explorer.filter.isEmpty { filterFocused = false } else { explorer.filter = "" }
                    return .handled
                }
            Button {
                explorer.contentSearch.isVisible.toggle()
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Search file contents (⌘⇧F)")
            // Shows its state, not just its function: struck through while hidden files stay hidden.
            Toggle(isOn: $explorer.showDotfiles) {
                Image(systemName: explorer.showDotfiles ? "eye" : "eye.slash")
                    .foregroundStyle(explorer.showDotfiles ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .help(explorer.showDotfiles ? "Hide hidden files (⌘⇧.)" : "Show hidden files (⌘⇧.)")
            .accessibilityLabel("Show hidden files")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .font(.callout)
    }
}

/// ssh's own account of a connection, copyable, so a stuck connect can be reported precisely.
private struct DiagnosticsPopover: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                Text(text).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 520, height: 260)
            HStack {
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
        }
        .padding(12)
    }
}

/// Asks for a directory on a remote host; there is no open panel for SFTP.
struct RemotePathPrompt: Identifiable {
    var hostID: HostID
    var hostName: String
    var initialPath: String
    var id: String { hostID.rawValue }
}

struct RemotePathSheet: View {
    let prompt: RemotePathPrompt
    let open: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open a folder on \(prompt.hostName)").font(.headline)
            TextField("Absolute path", text: $path)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            Text("Any directory you can read over SFTP. The home directory is opened when you pick the host.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open", action: submit).keyboardShortcut(.defaultAction).disabled(!path.hasPrefix("/"))
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { path = prompt.initialPath }
    }

    private func submit() {
        guard path.hasPrefix("/") else { return }
        open(path)
        dismiss()
    }
}

/// Follow mode in the toolbar: a plain button whose crosshair turns accent-filled while following (a toolbar
/// toggle's "on" state is a solid disc that hides the symbol). The card under it carries the live state.
private struct FollowToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Label(isOn ? "Following Herdr" : "Follow Herdr", systemImage: isOn ? "scope" : "scope")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isOn ? Color.accentColor : Color.primary)
                .symbolEffect(.bounce, value: isOn)
        }
        .help(isOn ? "Following the focused Herdr pane: the explorer and the send target follow it. Click to stop."
                   : "Follow Herdr: the explorer and the send target follow whichever agent pane you focus in Herdr.")
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// What follow mode is tracking right now: the agent's live state, its name and host, the pane, and its folder.
private struct FollowCard: View {
    let pane: AppModel.FollowedPane
    let stop: () -> Void

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "scope")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: DS.Space.xs) {
                    Text("Following").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    StatusDot(status: pane.status)
                }
                HStack(spacing: DS.Space.xs) {
                    if let host = pane.host {
                        Text(host).font(.caption.weight(.semibold)).foregroundStyle(.teal)
                    }
                    Text(pane.agent).font(.callout.weight(.semibold))
                    Text(pane.paneID).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
                .lineLimit(1)
                if let path = pane.path {
                    Text((path as NSString).lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(path)
                }
            }
            Spacer(minLength: DS.Space.xs)
            InlineIconButton(title: "Stop following", symbol: "xmark", emphasized: true, action: stop)
        }
        .padding(DS.Space.s)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: DS.Radius.m + 2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.m + 2, style: .continuous).strokeBorder(Color.accentColor.opacity(0.2)))
        .animation(DS.Motion.smooth, value: pane)
    }
}

/// A remote host's connection, said plainly: what is happening, what it means, and the one action that helps.
/// Busy stages show a spinner, a key agent waiting for approval is a mode with a pulsing key, failures are warnings.
struct ConnectionNoticeContent: Equatable {
        var kind: NoticeKind
        var symbol: String
        var title: String
        var detail: String
        var isBusy = false
        var showsDetails = false
    var offersConnect = false

    typealias Content = ConnectionNoticeContent

    static func make(host: String, status: HostsModel.Status?, progress: String?, warning: String?, follow: String?) -> Content? {
        var result: Content?
        switch status {
        case nil:
            break
        case .idle?:
            result = Content(kind: .info, symbol: "network.slash", title: "Not connected", detail: "Connect to browse \(host)'s files.", offersConnect: true)
        case .connecting?:
            result = Content(kind: .info, symbol: "network", title: "Connecting to \(host)", detail: progress ?? "Starting ssh…", isBusy: true, showsDetails: true)
        case .waitingForAgent?:
            result = Content(kind: .mode, symbol: "key.fill", title: "Waiting for your key agent",
                             detail: "Approve the request to sign in to \(host). Its prompt may be behind other windows.", isBusy: true, showsDetails: true)
        case .reconnecting(let attempt)?:
            result = Content(kind: .info, symbol: "arrow.triangle.2.circlepath", title: "Reconnecting to \(host)", detail: "Attempt \(attempt)…", isBusy: true, showsDetails: true)
        case .failed(let message)?:
            result = Content(kind: .warning, symbol: "exclamationmark.triangle.fill", title: "Couldn't connect to \(host)", detail: message, showsDetails: true, offersConnect: true)
        case .connected?:
            if let warning { result = Content(kind: .warning, symbol: "exclamationmark.circle", title: "Connected with a problem", detail: warning) }
        }
        if let follow {
            if var existing = result {
                existing.detail += " · " + follow
                result = existing
            } else {
                result = Content(kind: .info, symbol: "scope", title: "Follow Herdr", detail: follow)
            }
        }
        return result
    }
}

struct ConnectionNotice<Actions: View>: View {
    let content: ConnectionNoticeContent
    @ViewBuilder var actions: Actions

    var body: some View {
        Notice(kind: content.kind, symbol: content.symbol, title: content.title, detail: content.detail, pulses: content.kind == .mode) {
            if content.isBusy { ProgressView().controlSize(.small) }
            actions
        }
    }
}
