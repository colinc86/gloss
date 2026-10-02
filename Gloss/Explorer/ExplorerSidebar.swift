import Core
import SwiftUI

/// The explorer column: host and folder controls in the toolbar, a status row, root tabs, the tree, and the filter.
struct ExplorerSidebar: View {
    @Environment(AppModel.self) private var model
    @State private var remotePathPrompt: RemotePathPrompt?

    private var pickedHost: HostID { model.pickedHost }

    var body: some View {
        @Bindable var explorer = model.explorer
        VStack(spacing: 0) {
            if let status = statusRow {
                status
                Divider()
            }
            if !explorer.tabs.isEmpty {
                rootTabs
                Divider()
            }
            if explorer.contentSearch.isVisible, explorer.selectedTab != nil {
                searchBar
                Divider()
                SearchResultsView()
            } else if explorer.selectedTab != nil {
                FileOutlineView(model: explorer)
            } else {
                ContentUnavailableView {
                    Label("No folder open", systemImage: "folder.badge.plus")
                } description: {
                    Text(pickedHost == .local ? "Open a folder to browse it here." : "Connect to browse \(hostName(pickedHost))'s files.")
                } actions: {
                    Button(pickedHost == .local ? "Open Folder…" : "Connect") { openFolder() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                Toggle(isOn: Binding(get: { model.followHerdr }, set: { model.followHerdr = $0 })) {
                    Label("Follow Herdr", systemImage: "scope")
                }
                .help("Follow the focused Herdr agent pane")
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
                    if entry.id != .local { Task { await model.openRemoteRoot(hostID: entry.id) } }
                } label: {
                    Label(entry.name, systemImage: entry.kind == .local ? "desktopcomputer" : statusIcon(entry.id))
                }
            }
            Divider()
            Button("Open Folder on \(hostName(pickedHost))…") { openFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            SettingsLink { Text("Manage Hosts…") }
        } label: {
            Label(pickedHost == .local ? "local" : hostName(pickedHost), systemImage: pickedHost == .local ? "desktopcomputer" : statusIcon(pickedHost))
                .labelStyle(.titleAndIcon)
        }
        .help("Choose the host to browse")
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
        } else {
            let home = model.hostHomes[pickedHost] ?? ""
            remotePathPrompt = RemotePathPrompt(hostID: pickedHost, hostName: hostName(pickedHost), initialPath: home)
        }
    }

    /// Connection state of the picked host, and the follow state, in one line with a retry when something failed.
    private var statusRow: AnyView? {
        var text: String?
        var busy = false
        var failed = false
        if pickedHost != .local {
            switch model.hosts.status(for: pickedHost) {
            case .idle: text = "Not connected"
            case .connecting: text = model.hosts.progress[pickedHost] ?? "Connecting to \(hostName(pickedHost))…"; busy = true
            case .waitingForAgent: text = "Waiting for your SSH key agent to sign. If it asks for approval, its prompt may be behind other windows."; busy = true
            case .connected: text = model.hosts.warnings[pickedHost]
            case .reconnecting(let attempt): text = "Reconnecting (attempt \(attempt))…"; busy = true
            case .failed(let message): text = message; failed = true
            }
        }
        if model.followHerdr, let follow = model.followStatus {
            text = [text, "Following: \(follow)"].compactMap { $0 }.joined(separator: " · ")
        }
        guard let text else { return nil }
        return AnyView(
            HStack(spacing: 6) {
                if busy { ProgressView().controlSize(.small) }
                if failed { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                Text(text).font(.caption).foregroundStyle(failed ? .primary : .secondary).lineLimit(3)
                Spacer(minLength: 0)
                if failed || (pickedHost != .local && model.hosts.status(for: pickedHost) == .idle) {
                    Button("Connect") { Task { await model.openRemoteRoot(hostID: pickedHost) } }
                        .controlSize(.small)
                } else if busy, pickedHost != .local {
                    Button("Cancel") { Task { await model.hosts.disconnect(pickedHost) } }
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        )
    }

    // MARK: Roots, search, footer

    private var rootTabs: some View {
        @Bindable var explorer = model.explorer
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(explorer.tabs) { tab in
                    HStack(spacing: 4) {
                        Image(systemName: tab.hostID == .local ? "folder" : "network").font(.caption2)
                        Text(tab.title).lineLimit(1)
                        Button {
                            explorer.closeTab(tab.id)
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.borderless)
                        .opacity(explorer.selectedTabID == tab.id ? 1 : 0.5)
                    }
                    .font(.callout)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(explorer.selectedTabID == tab.id ? Color.accentColor.opacity(0.18) : Color.clear, in: Capsule())
                    .contentShape(Capsule())
                    .onTapGesture { explorer.selectedTabID = tab.id }
                    .help("\(hostName(tab.hostID)): \(tab.path)")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private var searchBar: some View {
        @Bindable var search = model.explorer.contentSearch
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search file contents", text: $search.query)
                .textFieldStyle(.plain)
                .onSubmit {
                    if let tab = model.explorer.selectedTab { search.search(in: tab.path, connection: model.connections[tab.hostID]) }
                }
            if search.isSearching { ProgressView().controlSize(.small) }
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
            Button {
                explorer.contentSearch.isVisible.toggle()
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Search file contents (⌘⇧F)")
            Toggle(isOn: $explorer.showDotfiles) {
                Image(systemName: "eye")
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .help("Show hidden files (⌘⇧.)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .font(.callout)
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
