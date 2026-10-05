import AppKit
import Core
import OSLog
import SwiftUI
import Transports
import Viewers

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        TabView {
            Form {
                Section {
                    Toggle(isOn: $settings.openLastRootOnLaunch) {
                        Text("Reopen the last folder")
                        Text("When the app starts, it opens the folder you had open last, on whichever host it lives, with the file that was in front.")
                    }
                    Toggle(isOn: $settings.showsQuestionsOnDock) {
                        Text("Show agent questions on the Dock icon")
                        Text("A badge counts notes an agent answered with a question, so you see them from any app.")
                    }
                    Toggle(isOn: $settings.showDotfilesByDefault) {
                        Text("Show hidden files")
                        Text("Dotfiles appear in the file tree from the start; the eye under the tree switches them until you quit.")
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 236)
            .tabItem { Label("General", systemImage: "gear") }

            Form {
                Section {
                    LabeledContent("Font size") {
                        HStack(spacing: DS.Space.m) {
                            Slider(value: $settings.editorFontSize, in: 9...20, step: 0.5)
                                .frame(width: 200)
                            Text("\(settings.editorFontSize, specifier: "%.1f") pt")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 48, alignment: .trailing)
                                .contentTransition(.numericText(value: settings.editorFontSize))
                        }
                    }
                    Toggle(isOn: $settings.wrapLines) {
                        Text("Wrap long lines")
                        Text("Off, long lines run on and the editor scrolls sideways.")
                    }
                    Toggle(isOn: $settings.showIndentGuides) {
                        Text("Show indent guides")
                        Text("A faint line at each indentation level; the block around the caret is stronger.")
                    }
                } footer: {
                    EditorPreview(fontSize: settings.editorFontSize, wraps: settings.wrapLines, guides: settings.showIndentGuides)
                }
            }
            .formStyle(.grouped)
            .frame(height: 330)
            .animation(DS.Motion.snappy, value: settings.editorFontSize)
            .animation(DS.Motion.smooth, value: settings.showIndentGuides)
            .tabItem { Label("Editor", systemImage: "text.alignleft") }

            AgentsSettings(settings: settings)
                .frame(height: 640)
                .tabItem { Label("Agents", systemImage: "paperplane") }

            HostsSettings()
                .frame(height: 440)
                .tabItem { Label("Hosts", systemImage: "network") }

            IntegrationsSettings()
                .frame(height: 660)
                .tabItem { Label("Integrations", systemImage: "key") }

            AttachmentsSettings(settings: settings)
                .frame(height: 380)
                .tabItem { Label("Attachments", systemImage: "photo.on.rectangle") }
        }
        // Each tab sets its own height and the window resizes to it, as System Settings does.
        .frame(width: 600)
    }
}

/// A few lines of code at the chosen size, so the slider shows what it does instead of describing it.
private struct EditorPreview: View {
    let fontSize: Double
    let wraps: Bool
    let guides: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(verbatim: "func pace(_ leg: Leg) -> Double {")
            HangingLine(text: "    leg.minutes / max(leg.km, 0.1)   // minutes per kilometre, never dividing by zero",
                        fontSize: fontSize, wraps: wraps)
                // The guide the editor would draw at the first indentation level, the caret's block, so stronger.
                .overlay(alignment: .leading) {
                    if guides {
                        Rectangle()
                            .fill(Color.primary.opacity(0.22))
                            .frame(width: 1)
                            .transition(.opacity)
                    }
                }
            Text(verbatim: "}")
        }
        .font(.system(size: fontSize, design: .monospaced))
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Space.m)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .overlay(alignment: .bottomTrailing) {
            Text("Open documents change as you adjust these")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(DS.Space.s)
        }
        .padding(.top, DS.Space.s)
        .accessibilityLabel("Preview of the editor font at \(fontSize, specifier: "%.1f") points")
    }
}

/// One preview line laid out as the editor lays it out: wrapped rows continue at the line's indentation plus one step
/// (`SourceTextView.wrapIndent`), which SwiftUI's `Text` cannot do, so an AppKit label draws it.
private struct HangingLine: NSViewRepresentable {
    let text: String
    let fontSize: Double
    let wraps: Bool

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.isSelectable = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        let style = NSMutableParagraphStyle()
        style.headIndent = SourceTextView.wrapIndent(forLine: text, spaceWidth: space, tabWidth: NSParagraphStyle.default.defaultTabInterval, limit: .greatestFiniteMagnitude)
        style.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        field.maximumNumberOfLines = wraps ? 0 : 1
        field.attributedStringValue = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style])
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NSTextField, context: Context) -> CGSize? {
        let width = proposal.width ?? 400
        field.preferredMaxLayoutWidth = width
        return CGSize(width: width, height: field.fittingSize.height)
    }
}

/// Everything that connects an agent: the MCP server, the three agents Gloss sets up itself on this Mac and on each
/// connected host (with the same registration to run by hand), the Herdr plugin, and copy for any other agent.
private struct AgentsSettings: View {
    @Environment(AppModel.self) private var model
    @Bindable var settings: SettingsStore

    private static let agents: [HookAgent] = [.claude, .codex, .opencode]

    private var hostIDs: [HostID] {
        [HostID.local] + model.connections.keys.sorted { $0.rawValue < $1.rawValue }
    }

    var body: some View {
        let port = model.mcpListeningPort ?? settings.mcpPort
        let token = model.mcpServer?.token
        let status = Self.status(error: model.mcpStatus, listening: model.mcpListeningPort, configured: settings.mcpPort)
        Form {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: DS.Space.s) {
                        Circle()
                            .fill(status.color)
                            .frame(width: 7, height: 7)
                        Text(status.text)
                            .foregroundStyle(status.color == .red ? Color.red : Color.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                }
                TextField("Port", value: $settings.mcpPort, format: .number.grouping(.never))
                    .monospacedDigit()
            } header: {
                Text("MCP server")
            } footer: {
                Text("Agents read and resolve notes through this server. A port change applies after relaunch.")
            }
            ForEach(hostIDs, id: \.self) { hostID in
                hostSection(hostID, port: port, token: token, isLast: hostID == hostIDs.last)
            }
            if model.hooks.lastReport != nil || model.hooks.lastError != nil {
                Section {
                    if let report = model.hooks.lastReport {
                        Text(report).font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = model.hooks.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            OtherAgentsSection(snippets: MCPServer.snippets(port: port, token: token))
        }
        .formStyle(.grouped)
        .task(id: hostIDs) { await model.hooks.refresh(hosts: hostIDs) }
    }

    /// One machine: each agent with its install state and, folded away, the registration to run by hand; then the
    /// Herdr plugin, which is not an agent but lives on the same machine.
    private func hostSection(_ hostID: HostID, port: Int, token: String?, isLast: Bool) -> some View {
        let isLocal = hostID == .local
        // A connected host whose entry is gone (its ssh config alias no longer listed) has no name to register under:
        // no hand-run snippet for it, rather than the local one.
        let alias = isLocal ? nil : model.hosts.entry(for: hostID)?.name
        let snippets = isLocal || alias != nil ? MCPServer.snippets(port: port, host: alias, token: token) : nil
        return Section {
            ForEach(Self.agents) { agent in
                row(agent: agent, hostID: hostID, configuration: snippets.map { Self.configuration(for: agent, in: $0) })
            }
            // Herdr's plugin only on a machine that has Herdr (or still carries the plugin, so it can be removed).
            if model.herdrHosts.contains(hostID) || model.hooks.status[HooksModel.Key(hostID: hostID, agent: .herdrPlugin)].map({ $0 != .notInstalled }) == true {
                row(agent: .herdrPlugin, hostID: hostID)
                if model.hooks.status[HooksModel.Key(hostID: hostID, agent: .herdrPlugin)] == .installed {
                    SnippetCard(agent: "Herdr keybinding", caption: "config.toml", text: HookInstaller.keybindingSnippet)
                }
            }
        } header: {
            Text(isLocal ? "This Mac" : alias ?? hostID.rawValue)
        } footer: {
            if isLast {
                // Said where the decision is made: what Install touches, and how to undo it.
                Label {
                    Text("Nothing changes until you press Install. Before editing an agent's settings file, Gloss saves a copy beside it (*.gloss-backup-…, the last three kept); Remove takes out only what was added.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lock.shield")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func row(agent: HookAgent, hostID: HostID, configuration: IntegrationRow.Configuration? = nil) -> some View {
        let key = HooksModel.Key(hostID: hostID, agent: agent)
        return IntegrationRow(
            agent: agent,
            status: model.hooks.status[key],
            isBusy: model.hooks.busy.contains(key),
            configuration: configuration,
            install: { Task { await model.hooks.install(agent, on: hostID) } },
            remove: { Task { await model.hooks.uninstall(agent, on: hostID) } }
        )
    }
}

extension AgentsSettings {
    /// What the copy button beside an agent puts on the clipboard: the registration Install runs, for whoever would
    /// rather run it themselves, and what the tooltip says about it.
    static func configuration(for agent: HookAgent, in snippets: MCPConfigSnippets) -> IntegrationRow.Configuration {
        switch agent {
        case .opencode:
            .init(text: snippets.opencodeJSON, help: "Copy the opencode.json entry, to add it yourself. It is what Install writes.")
        case .codex:
            .init(text: snippets.codexCommand, help: "Copy the command that registers the MCP tools with Codex, to run it yourself. Drafts arriving with each prompt need the hook Install adds.")
        default:
            .init(text: snippets.claudeCommand, help: "Copy the command that registers the MCP tools with Claude Code, to run it yourself. Drafts arriving with each prompt need the hook Install adds.")
        }
    }

    /// What the server is doing: failed, not started yet, listening where the setting says, or listening on the old
    /// port until a relaunch.
    static func status(error: String?, listening: Int?, configured: Int) -> (color: Color, text: String) {
        if let error { return (.red, error) }
        guard let listening else { return (.orange, "Starting…") }
        if listening != configured { return (.orange, "Listening on \(String(listening)); relaunch to use \(String(configured))") }
        return (.green, "Listening on 127.0.0.1:\(String(listening))")
    }
}

/// Copy for an agent Gloss does not set up itself: the server's address and header, a generic mcpServers entry,
/// and a prompt hook that reads drafts as plain text.
private struct OtherAgentsSection: View {
    let snippets: MCPConfigSnippets

    var body: some View {
        Section {
            SnippetCard(agent: "Endpoint", caption: "Streamable HTTP", text: snippets.endpoint)
            if !snippets.header.isEmpty {
                SnippetCard(agent: "Header", text: snippets.header)
            }
            SnippetCard(agent: "MCP config", caption: "mcpServers", text: snippets.mcpJSON)
            SnippetCard(agent: "Prompt hook", caption: "shell", text: snippets.promptHookCommand)
        } header: {
            Text("Other agents")
        } footer: {
            Text("Any agent that speaks MCP over HTTP can list, read and resolve notes (list_pending_notes, get_note, resolve_note, open_in_viewer, list_documents). One with a prompt hook can run the command from its working directory to receive the drafts there, which then count as sent. The clipboard and tmux need no setup at all.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One agent's registration: its name, a Copy button that confirms itself, and the text in a code box.
private struct SnippetCard: View {
    let agent: String
    var caption: String?
    let text: String
    @State private var copied = false
    @State private var resetCopied: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Text(agent).fontWeight(.medium)
                if let caption {
                    Text(caption).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    // A second click restarts the confirmation instead of letting the first one cut it short.
                    resetCopied?.cancel()
                    resetCopied = Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        if !Task.isCancelled { copied = false }
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(copied ? Color.green : Color.accentColor)
                        .frame(minWidth: 64, alignment: .trailing)
                }
                .buttonStyle(.borderless)
                .animation(DS.Motion.snappy, value: copied)
                .help("Copy the \(agent) registration")
            }
            // A command is never wrapped (a break mid-URL reads as two commands): each line stays whole and the box
            // scrolls sideways, its trailing edge fading to say there is more, as code blocks do on GitHub and Linear.
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(DS.Space.s)
                    .padding(.trailing, DS.Space.l)
            }
            .mask {
                HStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 20)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: DS.Radius.s + 2, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.s + 2, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        }
        .padding(.vertical, DS.Space.xxs)
    }
}

/// One host: a server icon with its connection state as a dot, its name and address, and where it comes from
/// (an ssh config alias, or added here and editable).
private struct HostRow: View {
    let name: String
    let detail: String
    let status: HostsModel.Status
    let fromSSHConfig: Bool
    let edit: (() -> Void)?
    let remove: (() -> Void)?
    @State private var hovering = false

    private var state: (color: Color, label: String) {
        switch status {
        case .connected: (.green, "Connected")
        case .connecting, .waitingForAgent: (.orange, "Connecting")
        case .reconnecting: (.orange, "Reconnecting")
        case .failed(let message): (.red, "Failed: \(message)")
        case .idle: (Color.secondary.opacity(0.5), "Not connected")
        }
    }

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: "server.rack")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 26)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(state.color)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                        .offset(x: 3, y: 2)
                }
                .help(state.label)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).fontWeight(.medium)
                // An alias's address lives in the ssh config, so its line says how it is doing instead.
                Text(fromSSHConfig ? state.label : "\(detail) · \(state.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: DS.Space.m)
            if fromSSHConfig {
                Text("ssh config")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, DS.Space.s)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                    .help("Comes from ~/.ssh/config; edit it there")
            }
            if let edit {
                Button("Edit", action: edit).buttonStyle(.borderless)
            }
            if let remove {
                Button(action: remove) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(hovering ? Color.red : Color.secondary)
                .help("Remove \(name)")
                .accessibilityLabel("Remove \(name)")
            }
        }
        .padding(.vertical, DS.Space.xxs)
        .onHover { hovering = $0 }
        .animation(DS.Motion.snappy, value: hovering)
        .animation(DS.Motion.smooth, value: state.label)
        .accessibilityElement(children: .combine)
        .accessibilityValue(state.label)
    }
}

/// The hosts the explorer offers: app-added ones with their ssh options, plus the `~/.ssh/config` aliases when
/// imports are on. Nothing here is hard-wired to a machine.
private struct HostsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var editing: HostDraft?
    @State private var removing: HostsModel.Entry?

    var body: some View {
        @Bindable var hosts = model.hosts
        Form {
            Section {
                ForEach(model.hosts.entries.filter { $0.kind == .ssh }) { entry in
                    HostRow(name: entry.name, detail: describe(entry), status: model.hosts.status(for: entry.id),
                            fromSSHConfig: entry.origin == .sshConfig,
                            edit: entry.origin == .manual ? { editing = HostDraft(entry: entry) } : nil,
                            remove: entry.origin == .manual ? { removing = entry } : nil)
                }
                Button {
                    editing = HostDraft()
                } label: {
                    Label("Add Host…", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Hosts")
            } footer: {
                Text("A host is any machine `ssh` can reach. Added hosts store the host name, user, port, and key here; everything else (ProxyJump, agents, options) still comes from your ssh config.")
            }
            Section {
                Toggle(isOn: $hosts.importsSSHConfig) {
                    Text("List the hosts in ~/.ssh/config")
                    Text("Every `Host` alias without wildcards appears in the host menu, connecting with your own ssh settings.")
                }
            }
        }
        .formStyle(.grouped)
        .animation(DS.Motion.smooth, value: model.hosts.entries.map(\.id))
        .confirmationDialog("Remove \(removing?.name ?? "this host")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove Host", role: .destructive) {
                if let entry = removing {
                    Task {
                        do { try await model.hosts.remove(entry.id) } catch { Log.app.error("removing host failed: \(error, privacy: .public)") }
                    }
                }
                removing = nil
            }
        } message: {
            // Removing a host deletes its row, and the database cascades to its folders, documents, and notes.
            let notes = removing.map { entry in model.notesPanel.groups.filter { $0.document.hostID == entry.id }.reduce(0) { $0 + $1.notes.count } } ?? 0
            Text(notes == 0
                 ? "Its settings and recent folders are deleted from the app. Your ssh config is not touched."
                 : "Its settings, recent folders, and \(notes) note\(notes == 1 ? "" : "s") on its files are deleted from the app. This can't be undone. Your ssh config is not touched.")
        }
        .sheet(item: $editing) { draft in
            HostEditor(draft: draft) { name, options in
                Task { try? await model.hosts.save(id: draft.hostID, name: name, options: options) }
            }
        }
    }

    private func describe(_ entry: HostsModel.Entry) -> String {
        switch entry.origin {
        case .sshConfig: return "Alias in ~/.ssh/config"
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

/// One agent integration: what it does, whether it is set up, and the one action that moves it forward. Remove
/// appears only when there is something to remove.
private struct IntegrationRow: View {
    /// Text the copy icon puts on the clipboard, and its tooltip.
    struct Configuration {
        var text: String
        var help: String
    }

    let agent: HookAgent
    let status: HookStatus?
    let isBusy: Bool
    var configuration: Configuration?
    let install: () -> Void
    let remove: () -> Void
    @State private var copied = false
    @State private var resetCopied: Task<Void, Never>?

    private var symbol: String {
        switch agent {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .opencode: "curlybraces"
        case .herdrPlugin: "rectangle.split.2x1"
        }
    }

    private var purpose: String {
        switch agent {
        case .claude: "Hands drafts to Claude Code with each prompt and registers the MCP tools."
        case .codex: "Hands drafts to Codex with each prompt and registers the MCP tools."
        case .opencode: "Registers the MCP tools so OpenCode can read and resolve notes."
        case .herdrPlugin: "A Herdr keybinding that turns selected terminal text into a note."
        }
    }

    private var pill: (label: String, symbol: String, tint: Color) {
        switch status {
        case nil: ("Checking", "ellipsis", .secondary)
        case .notInstalled: ("Not set up", "circle.dashed", .secondary)
        case .installed: ("Installed", "checkmark.circle.fill", .green)
        case .outdated: ("Update available", "arrow.triangle.2.circlepath", .orange)
        }
    }

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DS.Space.s) {
                    Text(agent.displayName).font(.body.weight(.medium))
                    StatusPill(label: pill.label, symbol: pill.symbol, tint: pill.tint)
                        .id(pill.label)
                        .transition((AnyTransition.scale(scale: 0.85).combined(with: .opacity)).calmed)
                }
                Text(outdatedReason ?? purpose)
                    .font(.caption)
                    .foregroundStyle(outdatedReason == nil ? Color.secondary : Color.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Space.s)
            if isBusy {
                ProgressView().controlSize(.small)
            } else {
                if let configuration {
                    InlineIconButton(title: copied ? "Copied" : configuration.help, symbol: copied ? "checkmark" : "doc.on.doc", emphasized: true) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(configuration.text, forType: .string)
                        copied = true
                        // A second click restarts the confirmation instead of letting the first one cut it short.
                        resetCopied?.cancel()
                        resetCopied = Task {
                            try? await Task.sleep(for: .seconds(1.6))
                            if !Task.isCancelled { copied = false }
                        }
                    }
                    .contentTransition(.symbolEffect(.replace))
                    .animation(DS.Motion.snappy, value: copied)
                }
                if status == .installed || isOutdated {
                    InlineIconButton(title: "Remove \(agent.displayName) integration", symbol: "trash", role: .destructive, emphasized: true, action: remove)
                }
                switch status {
                case .notInstalled?:
                    // Four optional, independent choices: none shouts. Update stays prominent, the one row asking for it.
                    Button("Install", action: install).buttonStyle(.glass)
                case .outdated?:
                    Button("Update", action: install).buttonStyle(.glassProminent)
                case .installed?:
                    Button("Reinstall", action: install)
                case nil:
                    EmptyView()
                }
            }
        }
        .padding(.vertical, DS.Space.xs)
        .animation(DS.Motion.smooth, value: pill.label)
        .animation(DS.Motion.snappy, value: isBusy)
    }

    private var isOutdated: Bool { if case .outdated = status { true } else { false } }
    private var outdatedReason: String? { if case .outdated(let reason) = status { reason } else { nil } }
}

/// GitHub and Atlassian keys. Each section says what the key can see once it is tested, and the footer says
/// what the app does with it: read, only ever read.
private struct IntegrationsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var githubToken = ""
    @State private var site = ""
    @State private var email = ""
    @State private var atlassianToken = ""
    /// The service whose key is about to go, while documents of it are open (they close with it).
    @State private var removing: IntegrationsModel.Service?

    /// Removes a key; asks first when that closes open pull requests, issues or pages.
    private func remove(_ service: IntegrationsModel.Service) {
        let host: HostID = service == .github ? .github : .atlassian
        if model.sessions.values.contains(where: { $0.hostID == host }) || model.explorer.tabs.contains(where: { $0.hostID == host }) {
            removing = service
        } else {
            model.integrations.clear(service)
        }
    }

    var body: some View {
        let integrations = model.integrations
        Form {
            Section {
                statusLine(integrations.githubStatus, unset: "No token saved")
                SecureField("Personal access token", text: $githubToken, prompt: Text(integrations.github == nil ? "github_pat_… or ghp_…" : "Saved · paste a new one to replace it"))
                    .onSubmit { Task { await saveGitHub() } }
                HStack {
                    Spacer()
                    if integrations.github != nil {
                        Button("Remove", role: .destructive) { remove(.github) }
                        Button("Test Connection") { Task { await integrations.test(.github) } }
                            .disabled(integrations.githubStatus == .checking)
                    }
                    Button("Save") { Task { await saveGitHub() } }
                        .buttonStyle(.glass)
                        .disabled(githubToken.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Label("GitHub", systemImage: "arrow.triangle.pull")
            } footer: {
                Text("Pull requests open as documents: description, conversation, changed files at the head commit. A read-only fine-grained token with Pull requests and Contents access is enough.")
            }
            Section {
                statusLine(integrations.atlassianStatus, unset: "No key saved")
                TextField("Site", text: $site, prompt: Text(integrations.atlassian?.site.host() ?? "example.atlassian.net"))
                    .textContentType(.URL)
                TextField("Email", text: $email, prompt: Text(integrations.atlassian?.email ?? "you@example.com"))
                    .textContentType(.emailAddress)
                SecureField("API token", text: $atlassianToken, prompt: Text(integrations.atlassian == nil ? "From id.atlassian.com → Security → API tokens" : "Saved · paste a new one to replace it"))
                    .onSubmit { Task { await saveAtlassian() } }
                HStack {
                    Spacer()
                    if integrations.atlassian != nil {
                        Button("Remove", role: .destructive) { remove(.atlassian) }
                        Button("Test Connection") { Task { await integrations.test(.atlassian) } }
                            .disabled(integrations.atlassianStatus == .checking)
                    }
                    Button("Save") { Task { await saveAtlassian() } }
                        .buttonStyle(.glass)
                        .disabled(!canSaveAtlassian)
                }
            } header: {
                Label("Atlassian", systemImage: "square.stack.3d.up")
            } footer: {
                Text("Jira issues and Confluence pages open as Markdown documents, read from the live site.")
            }
            Section {
            } footer: {
                Label {
                    Text("The app only reads with these keys. Changes to pull requests, tickets and pages are made by your agent with its own tools; the packet names the exact resource. Keys are kept in your Keychain.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lock.shield")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let error = integrations.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        // The service is held by the dialog, so its wording does not change while it closes.
        .confirmationDialog(Text("Remove this key?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { service in
            Button(service == .github ? "Remove GitHub Token" : "Remove Atlassian Key", role: .destructive) {
                model.integrations.clear(service)
                removing = nil
            }
        } message: { service in
            Text(service == .github ? "The pull requests open now close. Their notes stay." : "The issues and pages open now close. Their notes stay.")
        }
        .formStyle(.grouped)
        .animation(DS.Motion.smooth, value: integrations.githubStatus)
        .animation(DS.Motion.smooth, value: integrations.atlassianStatus)
    }

    private var canSaveAtlassian: Bool {
        let saved = model.integrations.atlassian
        let siteGiven = !site.trimmingCharacters(in: .whitespaces).isEmpty || saved != nil
        let emailGiven = !email.trimmingCharacters(in: .whitespaces).isEmpty || saved != nil
        return siteGiven && emailGiven && !atlassianToken.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func saveGitHub() async {
        await model.integrations.saveGitHub(token: githubToken)
        githubToken = ""
    }

    private func saveAtlassian() async {
        let saved = model.integrations.atlassian
        await model.integrations.saveAtlassian(
            site: site.isEmpty ? (saved?.site.absoluteString ?? "") : site,
            email: email.isEmpty ? (saved?.email ?? "") : email,
            token: atlassianToken
        )
        atlassianToken = ""
    }

    /// The live state as a coloured dot and a sentence, as the Agents tab shows the MCP server.
    private func statusLine(_ status: IntegrationsModel.Status, unset: String) -> some View {
        let (color, text): (Color, String) = switch status {
        case .unset: (.secondary, unset)
        case .checking: (.orange, "Checking…")
        case .ok(let detail): (.green, detail)
        case .failed(let detail): (.red, detail)
        }
        return LabeledContent("Status") {
            HStack(spacing: DS.Space.s) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(text).foregroundStyle(status == .unset ? .secondary : .primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
        }
    }
}

private struct AttachmentsSettings: View {
    @Bindable var settings: SettingsStore
    @State private var notesSize: Int64 = 0
    @State private var sentSize: Int64 = 0
    @State private var confirmingClear = false

    var body: some View {
        Form {
            Section {
                StorageRow(title: "Crops and page renders", size: notesSize, folder: AttachmentCache.notesRoot)
            } header: {
                Text("Note images")
            } footer: {
                Text("What image and PDF notes point at. Each file goes when its note is deleted.")
            }
            Section {
                StorageRow(title: "Copies made for agents", size: sentSize, folder: AttachmentCache.root)
                Stepper(value: $settings.stagedFileExpiryDays, in: 1...90) {
                    HStack {
                        Text("Keep for")
                        Spacer()
                        Text("\(settings.stagedFileExpiryDays) day\(settings.stagedFileExpiryDays == 1 ? "" : "s")")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText(value: Double(settings.stagedFileExpiryDays)))
                    }
                }
                Button("Clear Sent Copies…", role: .destructive) { confirmingClear = true }
                    .disabled(sentSize == 0)
            } header: {
                Text("Sent copies")
            } footer: {
                Text("Each send copies its images where the agent can read them. Remote hosts keep theirs for the same number of days.")
            }
        }
        .formStyle(.grouped)
        .animation(DS.Motion.snappy, value: settings.stagedFileExpiryDays)
        .animation(DS.Motion.smooth, value: sentSize)
        .confirmationDialog("Clear the copies made for agents?", isPresented: $confirmingClear) {
            Button("Clear Sent Copies", role: .destructive) {
                Task {
                    await Task.detached(priority: .userInitiated) { SettingsStore.clearAttachmentCache() }.value
                    await refresh()
                }
            }
        } message: {
            Text("An agent still working on a recent send may lose access to its images. Note images stay.")
        }
        .task { await refresh() }
    }

    /// Walking the folders touches every file; done off the main thread so a big cache can't stall the window.
    private func refresh() async {
        let sizes = await Task.detached(priority: .userInitiated) {
            (SettingsStore.folderSize(AttachmentCache.notesRoot), SettingsStore.attachmentCacheSize())
        }.value
        notesSize = sizes.0
        sentSize = sizes.1
    }
}

/// A folder's size, with a button to show it in Finder (its path in the tooltip, not the row).
private struct StorageRow: View {
    let title: String
    let size: Int64
    let folder: URL

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: DS.Space.m) {
                Text(size == 0 ? "Empty" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: Double(size)))
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                } label: {
                    Image(systemName: "magnifyingglass.circle")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder: \(folder.path)")
                .accessibilityLabel("Show \(title) in Finder")
                .disabled(!FileManager.default.fileExists(atPath: folder.path))
            }
        }
    }
}
