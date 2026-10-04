import Core
import SwiftUI
import Viewers

/// The folder above the tree, and the way to every other: one row naming the open root, which opens a switcher of
/// open folders, favorites (pinned), and recent ones. Replaces a strip of chips that scrolled out of sight once a
/// few folders were open, and gives folders you come back to a place that survives closing them.
struct RootSwitcher: View {
    @Environment(AppModel.self) private var model
    let hostName: (HostID) -> String
    let openFolder: () -> Void
    @State private var isOpen = false
    @State private var hovering = false

    var body: some View {
        let explorer = model.explorer
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: DS.Space.s) {
                if let tab = explorer.selectedTab {
                    Image(systemName: tab.hostID == .local ? "folder.fill" : "network")
                        .foregroundStyle(Color.accentColor)
                        .contentTransition(.symbolEffect(.replace))
                    if tab.hostID != .local {
                        Text(hostName(tab.hostID))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.teal)
                    }
                    Text(tab.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .contentTransition(.opacity)
                    if explorer.isPinned(hostID: tab.hostID, path: tab.path) {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .transition((AnyTransition.scale.combined(with: .opacity)).calmed)
                    }
                    CountBadge(count: explorer.folderCountForRoot(tab))
                }
                Spacer(minLength: DS.Space.xs)
                if explorer.tabs.count > 1 {
                    Text("\(explorer.tabs.count) open")
                        .font(.caption2.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText(value: Double(explorer.tabs.count)))
                }
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s)
            .background(Color.primary.opacity(hovering || isOpen ? 0.07 : 0.035), in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DS.Motion.snappy, value: hovering)
        .animation(DS.Motion.smooth, value: isOpen)
        .animation(DS.Motion.smooth, value: explorer.selectedTabID)
        .help(explorer.selectedTab.map { "\(hostName($0.hostID)): \($0.path). Click to switch folders." } ?? "Switch folders")
        .accessibilityLabel(explorer.selectedTab.map { "Folder \($0.title)" } ?? "Folders")
        .accessibilityHint("Shows open, favorite, and recent folders")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            RootSwitcherList(hostName: hostName, openFolder: { isOpen = false; openFolder() }, dismiss: { isOpen = false })
                .environment(model)
        }
        .task(id: isOpen) {
            if isOpen { await explorer.refreshRecents(hostIDs: Set(explorer.tabs.map(\.hostID) + [model.pickedHost])) }
        }
    }
}

private struct CountBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, DS.Space.xs + 1)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: Capsule())
                .contentTransition(.numericText(value: Double(count)))
                .help("\(count) open note\(count == 1 ? "" : "s") in this folder")
        }
    }
}

/// One folder in the switcher: open (a tab) or closed (a favorite or recent root).
nonisolated struct SwitcherEntry: Identifiable, Equatable {
    enum Section: String { case open = "Open", favorites = "Favorites", recent = "Recent" }
    let id: RootID
    let hostID: HostID
    let path: String
    let pinned: Bool
    let section: Section
    var title: String { (path as NSString).lastPathComponent }

    /// The sections in order, filtered by `query` (name first, then anywhere in the path; case-insensitive).
    /// Closed roots already open under another spelling are left out; at most `recentLimit` recents without a query.
    static func sections(tabs: [(id: RootID, hostID: HostID, path: String, pinned: Bool)], recents: [Root], query: String,
                         recentLimit: Int = 6) -> [(section: Section, entries: [SwitcherEntry])] {
        let open = tabs.map { SwitcherEntry(id: $0.id, hostID: $0.hostID, path: $0.path, pinned: $0.pinned, section: .open) }
        let openKeys = Set(tabs.map { ExplorerModel.markKey($0.hostID, $0.path) })
        let closed = recents.filter { !openKeys.contains(ExplorerModel.markKey($0.hostID, $0.path)) }
        let favorites = closed.filter(\.pinned).map { SwitcherEntry(id: $0.id, hostID: $0.hostID, path: $0.path, pinned: true, section: .favorites) }
        let others = closed.filter { !$0.pinned }.map { SwitcherEntry(id: $0.id, hostID: $0.hostID, path: $0.path, pinned: false, section: .recent) }
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        func filtered(_ entries: [SwitcherEntry]) -> [SwitcherEntry] {
            guard !needle.isEmpty else { return entries }
            let byName = entries.filter { $0.title.lowercased().contains(needle) }
            let byPath = entries.filter { !$0.title.lowercased().contains(needle) && $0.path.lowercased().contains(needle) }
            return byName + byPath
        }
        let recent = filtered(others)
        return [(.open, filtered(open)), (.favorites, filtered(favorites)), (.recent, needle.isEmpty ? Array(recent.prefix(recentLimit)) : recent)]
            .filter { !$0.entries.isEmpty }
    }
}

/// The switcher's sections, keyboard first: a filter field takes typing, ↑ and ↓ move the highlight, Return opens
/// or switches to it. Each row can be starred, and open ones closed.
private struct RootSwitcherList: View {
    @Environment(AppModel.self) private var model
    let hostName: (HostID) -> String
    let openFolder: () -> Void
    let dismiss: () -> Void
    @State private var query = ""
    @State private var highlight = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let explorer = model.explorer
        let sections = SwitcherEntry.sections(
            tabs: explorer.tabs.map { (id: $0.id, hostID: $0.hostID, path: $0.path, pinned: explorer.isPinned(hostID: $0.hostID, path: $0.path)) },
            recents: explorer.recentsByHost[model.pickedHost] ?? [], query: query)
        let flat = sections.flatMap(\.entries)
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter folders", text: $query)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onKeyPress(.downArrow) { move(1, count: flat.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, count: flat.count); return .handled }
                    .onSubmit { if flat.indices.contains(highlight) { choose(flat[highlight]) } }
            }
            .font(.callout)
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, DS.Space.xs + 2)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: DS.Radius.s + 2, style: .continuous))
            if flat.isEmpty {
                Text("No folder matches “\(query)”")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Space.m)
            }
            ForEach(sections, id: \.section) { group in
                section(group.section.rawValue)
                ForEach(group.entries) { entry in
                    row(entry, highlighted: flat.firstIndex(of: entry) == highlight)
                }
            }
            Divider().padding(.vertical, DS.Space.xs)
            Button(action: openFolder) {
                Label("Open Folder…", systemImage: "folder.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.Space.s)
                    .padding(.vertical, DS.Space.xs)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(DS.Space.s)
        .frame(width: 320)
        .onAppear {
            // Start on the current folder, so ↓ and Return go to the next one.
            highlight = flat.firstIndex { $0.id == explorer.selectedTabID } ?? 0
            fieldFocused = true
        }
        .onChange(of: query) { _, _ in highlight = 0 }
        // Closing or re-pinning a row can shorten the list under the highlight.
        .onChange(of: flat.map(\.id)) { _, ids in highlight = min(highlight, max(0, ids.count - 1)) }
        .animation(DS.Motion.smooth, value: (explorer.recentsByHost[model.pickedHost] ?? []).map(\.pinned))
        .animation(DS.Motion.smooth, value: explorer.tabs.map(\.id))
        .animation(DS.Motion.snappy, value: highlight)
        .animation(DS.Motion.smooth, value: flat.map(\.id))
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        highlight = (highlight + delta + count) % count
    }

    private func choose(_ entry: SwitcherEntry) {
        let explorer = model.explorer
        dismiss()
        if entry.section == .open {
            explorer.selectedTabID = entry.id
        } else {
            Task { await explorer.openRoot(hostID: entry.hostID, path: entry.path) }
        }
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, DS.Space.s)
            .padding(.top, DS.Space.xs)
    }

    private func row(_ entry: SwitcherEntry, highlighted: Bool) -> some View {
        let explorer = model.explorer
        let isOpen = entry.section == .open
        let tab = explorer.tabs.first { $0.id == entry.id }
        return RootRow(title: entry.title, path: entry.path, host: entry.hostID == .local ? nil : hostName(entry.hostID),
                       isCurrent: isOpen && explorer.selectedTabID == entry.id, isOpen: isOpen, isHighlighted: highlighted,
                       pinned: entry.pinned, notes: tab.map { explorer.folderCountForRoot($0) } ?? 0,
                       choose: { choose(entry) },
                       togglePin: { Task { await explorer.setPinned(entry.id, hostID: entry.hostID, path: entry.path, !entry.pinned) } },
                       close: isOpen ? { explorer.closeTab(entry.id) } : nil)
    }
}

private struct RootRow: View {
    let title: String
    let path: String
    let host: String?
    let isCurrent: Bool
    let isOpen: Bool
    var isHighlighted = false
    let pinned: Bool
    let notes: Int
    let choose: () -> Void
    let togglePin: () -> Void
    let close: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: host == nil ? (isOpen ? "folder.fill" : "folder") : "network")
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: DS.Space.xs) {
                    if let host {
                        Text(host).font(.caption.weight(.semibold)).foregroundStyle(.teal)
                    }
                    Text(title)
                        .font(.callout.weight(isCurrent ? .semibold : .regular))
                        .lineLimit(1)
                }
                Text((path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: DS.Space.xs)
            CountBadge(count: notes)
            Button(action: togglePin) {
                Image(systemName: pinned ? "star.fill" : "star")
                    .foregroundStyle(pinned ? Color.yellow : Color.secondary)
                    .symbolEffect(.bounce, value: pinned)
            }
            .buttonStyle(.plain)
            .opacity(pinned || hovering ? 1 : 0)
            .help(pinned ? "Remove from Favorites" : "Add to Favorites")
            .accessibilityLabel(pinned ? "Remove \(title) from Favorites" : "Add \(title) to Favorites")
            if let close {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .background(Color.primary.opacity(hovering ? 0.08 : 0), in: Circle())
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0)
                .help("Close \(title)")
                .accessibilityLabel("Close \(title)")
            }
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.xs + 1)
        .background {
            if isCurrent || isHighlighted {
                // The keyboard's place reads as a ring when it is not the current folder, so the two never blur.
                RoundedRectangle(cornerRadius: DS.Radius.s + 2, style: .continuous)
                    .fill(Color.accentColor.opacity(isCurrent ? 0.14 : 0.08))
                    .overlay {
                        if isHighlighted {
                            RoundedRectangle(cornerRadius: DS.Radius.s + 2, style: .continuous).strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1.5)
                        }
                    }
            } else if hovering {
                RoundedRectangle(cornerRadius: DS.Radius.s + 2, style: .continuous).fill(Color.primary.opacity(0.06))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: choose)
        .onHover { hovering = $0 }
        .animation(DS.Motion.snappy, value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: isOpen ? "Switch to \(title)" : "Open \(title)", choose)
    }
}
