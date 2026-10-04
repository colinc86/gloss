import AppKit
import Core
import SwiftUI
import Viewers

/// The main pane before any folder is open: one obvious first step (open a folder, here or on a host) and the
/// folders opened before. Replaces three empty states that each asked for something different.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var appeared = false

    var body: some View {
        let explorer = model.explorer
        let remoteHosts = model.hosts.entries.filter { $0.kind == .ssh }
        let recents = Array((explorer.recentsByHost[.local] ?? []).prefix(4))
        VStack(spacing: DS.Space.xl) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
                .scaleEffect(appeared || Motion.isReduced ? 1 : 0.86)
                .opacity(appeared ? 1 : 0)
                .accessibilityHidden(true)
            VStack(spacing: DS.Space.xs) {
                Text("Gloss")
                    .font(.title.weight(.semibold))
                Text("Open a folder, mark up any file, and hand your notes to an agent.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: DS.Space.m) {
                Button {
                    model.explorer.chooseRootWithPanel(hostID: .local)
                } label: {
                    Label("Open Folder…", systemImage: "folder")
                        .padding(.horizontal, DS.Space.xs)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                if !remoteHosts.isEmpty {
                    Menu {
                        ForEach(remoteHosts) { entry in
                            Button(entry.name) { Task { await model.openRemoteRoot(hostID: entry.id) } }
                        }
                    } label: {
                        Label("On a Host", systemImage: "network")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .fixedSize()
                    .help("Connect over ssh and open the host's home folder")
                }
            }
            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text("Recent")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, DS.Space.m)
                    ForEach(recents) { root in
                        RecentFolderRow(root: root) {
                            Task { await explorer.openRoot(hostID: root.hostID, path: root.path) }
                        }
                    }
                }
                .frame(width: 360)
                .padding(.top, DS.Space.s)
            }
        }
        .padding(DS.Space.xl)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .onAppear {
            withAnimation(Motion.isReduced ? DS.Motion.smooth : .spring(duration: 0.6, bounce: 0.35)) { appeared = true }
        }
        .task { await explorer.refreshRecents(hostIDs: [.local]) }
    }
}

private struct RecentFolderRow: View {
    let root: Root
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: DS.Space.m) {
                Image(systemName: root.pinned ? "star.fill" : "folder")
                    .foregroundStyle(root.pinned ? Color.yellow : Color.accentColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text((root.path as NSString).lastPathComponent).font(.callout.weight(.medium))
                    Text((root.path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: DS.Space.s)
                Text(root.lastOpenedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s)
            .background(Color.primary.opacity(hovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DS.Motion.snappy, value: hovering)
        .help(root.path)
    }
}
