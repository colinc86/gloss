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
                TextField("MCP port", value: $settings.mcpPort, format: .number)
                if let status = model.mcpStatus {
                    Text(status).font(.caption).foregroundStyle(.red)
                } else {
                    Text("MCP server listening on 127.0.0.1:\(settings.mcpPort); a port change applies at the next launch.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                MCPSnippetRow(title: "Claude Code", text: MCPServer.snippets(port: settings.mcpPort).claudeCommand)
                MCPSnippetRow(title: "Codex", text: MCPServer.snippets(port: settings.mcpPort).codexCommand)
                MCPSnippetRow(title: "OpenCode (opencode.json)", text: MCPServer.snippets(port: settings.mcpPort).opencodeJSON)
                TextField("OpenCode servers (comma separated)", text: $settings.opencodeServers)
            }
            .tabItem { Label("Agents", systemImage: "paperplane") }

            AttachmentsSettings(settings: settings)
                .tabItem { Label("Attachments", systemImage: "photo.on.rectangle") }
        }
        .frame(width: 560, height: 340)
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
