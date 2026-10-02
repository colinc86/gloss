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

            HostsSettings()
                .tabItem { Label("Hosts", systemImage: "network") }

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

/// The hosts the explorer offers: app-added ones with their ssh options, plus the `~/.ssh/config` aliases when
/// imports are on. Nothing here is hard-wired to a machine.
private struct HostsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var editing: HostDraft?

    var body: some View {
        @Bindable var hosts = model.hosts
        Form {
            Section {
                ForEach(model.hosts.entries.filter { $0.kind == .ssh }) { entry in
                    LabeledContent(entry.name) {
                        HStack(spacing: 8) {
                            Text(describe(entry)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if entry.origin == .manual {
                                Button("Edit") { editing = HostDraft(entry: entry) }
                                Button("Remove", role: .destructive) { Task { try? await model.hosts.remove(entry.id) } }
                            }
                        }
                    }
                }
                Button("Add Host…") { editing = HostDraft() }
            } header: {
                Text("Hosts")
            } footer: {
                Text("A host is any machine `ssh` can reach. Added hosts store the host name, user, port, and key here; everything else (ProxyJump, agents, options) still comes from your ssh config.")
            }
            Section {
                Toggle("Also list the Host aliases in ~/.ssh/config", isOn: $hosts.importsSSHConfig)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { draft in
            HostEditor(draft: draft) { name, options in
                Task { try? await model.hosts.save(id: draft.hostID, name: name, options: options) }
            }
        }
    }

    private func describe(_ entry: HostsModel.Entry) -> String {
        switch entry.origin {
        case .sshConfig: return "from ~/.ssh/config"
        case .manual:
            let options = entry.options ?? HostOptions()
            var parts: [String] = []
            if !options.user.isEmpty || !options.hostName.isEmpty { parts.append((options.user.isEmpty ? "" : options.user + "@") + options.hostName) }
            if let port = options.port { parts.append("port \(port)") }
            if !options.identityFile.isEmpty { parts.append(PathUtilities.name(of: options.identityFile)) }
            return parts.isEmpty ? "ssh defaults" : parts.joined(separator: " · ")
        case .local: return ""
        }
    }
}

struct HostDraft: Identifiable {
    var hostID: HostID?
    var name = ""
    var options = HostOptions()
    /// `.sheet(item:)` needs an id; a new host has none yet.
    var id: String { hostID?.rawValue ?? "new" }

    init() {}

    init(entry: HostsModel.Entry) {
        hostID = entry.id
        name = entry.name
        options = entry.options ?? HostOptions()
    }
}

private struct HostEditor: View {
    let draft: HostDraft
    let save: (String, HostOptions) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var hostName = ""
    @State private var user = ""
    @State private var port = ""
    @State private var identityFile = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.hostID == nil ? "Add Host" : "Edit Host").font(.headline)
            Form {
                TextField("Name", text: $name, prompt: Text("workbox"))
                TextField("Host name or IP", text: $hostName, prompt: Text("leave empty to use ssh config for the name"))
                TextField("User", text: $user, prompt: Text("optional"))
                TextField("Port", text: $port, prompt: Text("22"))
                HStack {
                    TextField("Identity file", text: $identityFile, prompt: Text("optional; else keys from your agent"))
                    Button("Choose…") { chooseKey() }
                }
            }
            .formStyle(.columns)
            Text("The name is what the sidebar shows and what `ssh` is given as the destination, so a name that is also an alias in ~/.ssh/config inherits that alias's settings.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    save(name.trimmingCharacters(in: .whitespaces), HostOptions(hostName: hostName.trimmingCharacters(in: .whitespaces), user: user.trimmingCharacters(in: .whitespaces), port: Int(port.trimmingCharacters(in: .whitespaces)), identityFile: identityFile.trimmingCharacters(in: .whitespaces)))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || name == "local")
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            name = draft.name
            hostName = draft.options.hostName
            user = draft.options.user
            port = draft.options.port.map(String.init) ?? ""
            identityFile = draft.options.identityFile
        }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url { identityFile = url.path }
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
