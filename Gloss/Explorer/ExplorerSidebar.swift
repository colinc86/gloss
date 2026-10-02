import Core
import SwiftUI

struct ExplorerSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var explorer = model.explorer
        VStack(spacing: 0) {
            header
            Divider()
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
                    Text("Open a folder to browse it here.")
                } actions: {
                    Button("Open Folder…") { explorer.chooseRootWithPanel(hostID: .local) }
                }
            }
            Divider()
            footer
        }
        .background(.background)
    }

    private var header: some View {
        @Bindable var explorer = model.explorer
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                HostPicker()
                Spacer()
                Toggle(isOn: Binding(get: { model.followHerdr }, set: { model.followHerdr = $0 })) {
                    Image(systemName: "scope")
                }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .help("Follow the focused Herdr agent pane")
                Button {
                    explorer.chooseRootWithPanel(hostID: .local)
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("Open Folder (⌘⇧O)")
                .buttonStyle(.borderless)
            }
            if model.followHerdr, let status = model.followStatus {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let message = hostStatusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if !explorer.tabs.isEmpty {
                rootTabs
            }
        }
        .padding(8)
    }

    private var hostStatusMessage: String? {
        guard let tab = model.explorer.selectedTab, tab.hostID != .local else { return nil }
        switch model.hosts.status(for: tab.hostID) {
        case .idle: return "Disconnected"
        case .connecting: return "Connecting…"
        case .waitingForAgent: return "Waiting for the SSH agent (check 1Password)…"
        case .connected: return nil
        case .reconnecting(let attempt): return "Reconnecting (attempt \(attempt))…"
        case .failed(let message): return message
        }
    }

    private var rootTabs: some View {
        @Bindable var explorer = model.explorer
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(explorer.tabs) { tab in
                    HStack(spacing: 4) {
                        Text(tab.title)
                            .lineLimit(1)
                        Button {
                            explorer.closeTab(tab.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.borderless)
                        .opacity(explorer.selectedTabID == tab.id ? 1 : 0.5)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(explorer.selectedTabID == tab.id ? Color.accentColor.opacity(0.2) : Color.clear, in: Capsule())
                    .contentShape(Capsule())
                    .onTapGesture { explorer.selectedTabID = tab.id }
                    .help(tab.path)
                }
            }
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
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(.secondary)
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
        .padding(6)
        .font(.callout)
    }
}


/// Chooses a host; picking a remote one connects and opens its home directory as a root.
struct HostPicker: View {
    @Environment(AppModel.self) private var model
    @State private var selection: HostID = .local

    var body: some View {
        Picker("Host", selection: $selection) {
            ForEach(model.hosts.entries) { entry in
                Label(entry.name, systemImage: entry.kind == .local ? "desktopcomputer" : statusIcon(entry.id)).tag(entry.id)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 160)
        .onChange(of: selection) { _, hostID in
            guard hostID != .local else { return }
            Task { await model.openRemoteRoot(hostID: hostID) }
        }
        .onChange(of: model.explorer.selectedTabID) { _, _ in
            if let tab = model.explorer.selectedTab { selection = tab.hostID }
        }
        .alert("Unknown host key", isPresented: Binding(get: { model.hosts.pendingHostKey != nil }, set: { _ in })) {
            Button("Accept and Connect") {
                if let pending = model.hosts.pendingHostKey {
                    Task { await model.openRemoteRoot(hostID: pending.hostID) ; _ = await model.hosts.acceptNewHostKey(pending.hostID) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This host's key is not in known_hosts yet.\n\(model.hosts.pendingHostKey?.fingerprint ?? "")\nAccept it for this host only?")
        }
    }

    private func statusIcon(_ hostID: HostID) -> String {
        switch model.hosts.status(for: hostID) {
        case .connected: "network"
        case .connecting, .waitingForAgent, .reconnecting: "network.badge.shield.half.filled"
        case .failed: "exclamationmark.triangle"
        case .idle: "network.slash"
        }
    }
}
