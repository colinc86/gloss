import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Viewers

struct ThemesSettings: View {
    @Bindable var model: ThemesModel
    @State private var deleting: ThemeSlot?
    var body: some View {
        ScrollView {
            Form {
                Section {
                    Text("Colors and fonts for code. Gloss follows your Mac's appearance and uses the theme you choose for each.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(ThemeSlot.allCases) { slot in
                    Section {
                        Picker("Theme",selection: Binding(get: { model.selectedID(slot) },set: { id in
                            if let theme = model.store.theme(id: id) { model.select(theme,for: slot) }
                        })) {
                            ForEach(model.offered(slot)) { theme in Text(theme.name).tag(theme.id) }
                            if model.store.theme(id: model.selectedID(slot)) == nil { Text("Unavailable theme").tag(model.selectedID(slot)) }
                        }
                        ThemePreview(theme: model.preview(slot),slot: slot,defaultSize: model.settings.editorFontSize)
                            .frame(height: 164)
                        HStack {
                            Button("Edit…") { model.edit(slot) }.disabled(model.selected(slot).isBuiltIn)
                            Button("Duplicate") { model.duplicate(slot) }
                            Button("Export…") { export(slot) }
                            Spacer()
                            Button("Delete…",role: .destructive) { deleting = slot }.disabled(model.selected(slot).isBuiltIn)
                        }
                        if model.selected(slot).isBuiltIn {
                            Text("Built-in theme · Duplicate to edit").font(.caption).foregroundStyle(.secondary)
                        }
                        if let notice = model.notice(slot) {
                            Text(notice).font(.caption).foregroundStyle(.secondary)
                                .help(model.store.resolve(id: model.selectedID(slot)).problem ?? "")
                        }
                    } header: { Text(slot.title) }
                }
                Section {
                    Button("Import…") { importTheme() }.disabled(model.isImporting)
                    if model.isImporting { ProgressView("Reading theme…") }
                    if let error = model.error { Label(error,systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary) }
                    DisclosureGroup("Theme palette licenses") {
                        ScrollView { Text(Self.licenses).font(.caption).textSelection(.enabled) }.frame(height: 180)
                    }
                    ForEach(model.store.problems,id: \.self) { problem in
                        Text("\(problem.fileName): \(problem.message)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .sheet(item: $model.draft,onDismiss: { model.cancel() }) { draft in ThemeEditor(model: model,draft: draft).presentationSizing(.fitted) }
        .confirmationDialog(deleting.map { "Delete ‘\(model.selected($0).name)’?" } ?? "Delete theme?",isPresented: Binding(get: { deleting != nil },set: { if !$0 { deleting = nil } }),titleVisibility: .visible) {
            Button("Delete Theme",role: .destructive) { if let deleting { model.delete(deleting) }; deleting = nil }
            Button("Cancel",role: .cancel) { deleting = nil }
        } message: { Text("This removes the theme file from Gloss. Any appearance using it will use Gloss.") }
    }
    private static let licenses: String = {
        guard let url = Bundle.main.url(forResource: "ThemeLicenses",withExtension: "txt") else { return "Theme license notices couldn't be loaded." }
        return (try? String(contentsOf: url,encoding: .utf8)) ?? "Theme license notices couldn't be loaded."
    }()
    private func importTheme() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json,UTType(filenameExtension: "xccolortheme") ?? .data,UTType(filenameExtension: "tmTheme") ?? .data]
        panel.message = "Choose Gloss JSON, an Xcode color theme, a TextMate theme, or a VS Code theme."
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            Task { await model.importFile(url) }
        }
    }
    private func export(_ slot: ThemeSlot) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = model.selected(slot).name.replacingOccurrences(of: "/",with: "-") + ".json"
        panel.begin { result in
            if result == .OK, let url = panel.url { model.export(slot,to: url) }
        }
    }
}
