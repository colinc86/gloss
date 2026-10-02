import AppKit
import Core
import SwiftUI
import Transports

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        TabView {
            Form {
                Toggle("Open the last root on launch", isOn: $settings.openLastRootOnLaunch)
                Toggle("Show hidden files by default", isOn: $settings.showDotfilesByDefault)
            }
            .tabItem { Label("General", systemImage: "gear") }

            Form {
                Slider(value: $settings.editorFontSize, in: 9...20, step: 0.5) {
                    Text("Font size: \(settings.editorFontSize, specifier: "%.1f")")
                }
                Toggle("Wrap long lines", isOn: $settings.wrapLines)
                Text("Font changes apply to documents opened afterwards.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .tabItem { Label("Editor", systemImage: "text.alignleft") }

            Form {
                LabeledContent("Last target") {
                    Text(model.send.lastTarget?.label ?? "none").foregroundStyle(.secondary)
                }
                TextField("MCP port", value: $settings.mcpPort, format: .number.grouping(.never))
                if let status = model.mcpStatus {
                    Text(status).font(.caption).foregroundStyle(.red)
                } else {
                    Text("Listening on 127.0.0.1:\(String(settings.mcpPort)). A port change applies after relaunch.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                MCPSnippetRow(title: "Claude Code", text: MCPServer.snippets(port: settings.mcpPort).claudeCommand)
                MCPSnippetRow(title: "Codex", text: MCPServer.snippets(port: settings.mcpPort).codexCommand)
                MCPSnippetRow(title: "OpenCode config", text: MCPServer.snippets(port: settings.mcpPort).opencodeJSON)
                TextField("OpenCode servers", text: $settings.opencodeServers)
                Text("Comma separated base URLs.").font(.caption).foregroundStyle(.secondary)
            }
            .tabItem { Label("Agents", systemImage: "paperplane") }

            HooksSettings()
                .tabItem { Label("Hooks", systemImage: "link") }

            AttachmentsSettings(settings: settings)
                .tabItem { Label("Attachments", systemImage: "photo.on.rectangle") }
        }
        .frame(width: 560, height: 360)
        .padding()
    }
}

/// One copyable registration line for an agent.
private struct MCPSnippetRow: View {
    let title: String
    let text: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                Text(text).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")
            }
        }
    }
}

/// Install, update, or remove the UserPromptSubmit hooks and MCP registrations, here and on connected hosts.
private struct HooksSettings: View {
    @Environment(AppModel.self) private var model

    private var hostIDs: [HostID] {
        [HostID.local] + model.connections.keys.sorted { $0.rawValue < $1.rawValue }
    }

    var body: some View {
        Form {
            ForEach(hostIDs, id: \.self) { hostID in
                Section(hostID == .local ? "This Mac" : (model.hosts.entry(for: hostID)?.name ?? hostID.rawValue)) {
                    ForEach(HookAgent.allCases) { agent in
                        row(agent: agent, hostID: hostID)
                    }
                    if model.hooks.status[HooksModel.Key(hostID: hostID, agent: .herdrPlugin)] == .installed {
                        MCPSnippetRow(title: "Herdr keybinding (config.toml)", text: HookInstaller.keybindingSnippet)
                    }
                }
            }
            if let report = model.hooks.lastReport {
                Text(report).font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.hooks.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .task(id: hostIDs) { await model.hooks.refresh(hosts: hostIDs) }
    }

    private func row(agent: HookAgent, hostID: HostID) -> some View {
        let key = HooksModel.Key(hostID: hostID, agent: agent)
        let status = model.hooks.status[key]
        return LabeledContent(agent.displayName) {
            HStack(spacing: 8) {
                Text(describe(status)).foregroundStyle(.secondary).font(.caption)
                Button(status == .installed ? "Reinstall" : "Install") {
                    Task { await model.hooks.install(agent, on: hostID) }
                }
                Button("Remove") {
                    Task { await model.hooks.uninstall(agent, on: hostID) }
                }
                .disabled(status == nil || status == .notInstalled)
            }
            .disabled(model.hooks.busy.contains(key))
        }
    }

    private func describe(_ status: HookStatus?) -> String {
        switch status {
        case nil: "checking…"
        case .notInstalled: "not installed"
        case .installed: "installed"
        case .outdated(let reason): "outdated: \(reason)"
        }
    }
}

private struct AttachmentsSettings: View {
    @Bindable var settings: SettingsStore
    @State private var cacheSize: Int64 = 0

    var body: some View {
        Form {
            LabeledContent("Cache location") {
                Text(AttachmentCache.root.path).font(.caption).textSelection(.enabled)
            }
            LabeledContent("Cache size") {
                Text(ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
            }
            Stepper("Remote staged files expire after \(settings.stagedFileExpiryDays) days", value: $settings.stagedFileExpiryDays, in: 1...90)
            Button("Clear Cache") {
                SettingsStore.clearAttachmentCache()
                cacheSize = SettingsStore.attachmentCacheSize()
            }
        }
        .task { cacheSize = SettingsStore.attachmentCacheSize() }
    }
}
