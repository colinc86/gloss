import Core
import SwiftUI

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
                TextField("OpenCode servers (comma separated)", text: $settings.opencodeServers)
                Text("Herdr, MCP, hook, OpenCode, and tmux transports arrive in later phases; the clipboard works now.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .tabItem { Label("Agents", systemImage: "paperplane") }

            AttachmentsSettings(settings: settings)
                .tabItem { Label("Attachments", systemImage: "photo.on.rectangle") }
        }
        .frame(width: 520, height: 300)
        .padding()
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
