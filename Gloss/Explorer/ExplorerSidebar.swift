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
                Picker("Host", selection: .constant(HostID.local)) {
                    Text("local").tag(HostID.local)
                }
                .labelsHidden()
                .frame(maxWidth: 120)
                Spacer()
                Button {
                    explorer.chooseRootWithPanel(hostID: .local)
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help("Open Folder (⌘⇧O)")
                .buttonStyle(.borderless)
            }
            if !explorer.tabs.isEmpty {
                rootTabs
            }
        }
        .padding(8)
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
                .onSubmit { if let root = model.explorer.selectedTab?.path { search.search(in: root) } }
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
