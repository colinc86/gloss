import Core
import OSLog
import SwiftUI

@main
struct GlossApp: App {
    @State private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    init() {
        let options = AppLaunchOptions(arguments: CommandLine.arguments)
        Log.app.info("Launch options: \(String(describing: options), privacy: .public)")
        _model = State(initialValue: AppModel(launchOptions: options))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .task { await model.start() }
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            AppCommands(model: model)
        }

        Settings {
            SettingsPlaceholderView()
        }
    }
}

/// Menus and shortcuts. Grows with each step; see the plan's shortcut table.
struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Folder…") {
                model.explorer.chooseRootWithPanel(hostID: .local)
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                guard let session = model.activeSession else { return }
                Task { await session.save() }
            }
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(model.activeSession?.textController == nil)
        }
        CommandMenu("Notes") {
            Button("New Note from Selection") { model.activeSession?.beginNote() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(model.activeSession == nil)
            Button("Send Drafts in Document") { Task { await model.sendAllDrafts(scope: .activeDocument) } }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.send.lastTarget == nil)
            Button("Send All Drafts") { Task { await model.sendAllDrafts(scope: .all) } }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(model.send.lastTarget == nil)
            Button("Copy Packet for Document") { Task { await model.copyPacket(scope: .activeDocument) } }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Divider()
            Button("Resolve Selected Note") {
                guard let id = model.notesPanel.selectedNoteID else { return }
                Task { await model.notesPanel.resolve(id) }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(model.notesPanel.selectedNoteID == nil)
            Divider()
            Toggle("Show Notes Panel", isOn: Binding(get: { model.showNotesPanel }, set: { model.showNotesPanel = $0 }))
                .keyboardShortcut("n", modifiers: [.command, .option])
        }
        CommandGroup(after: .toolbar) {
            Toggle("Show Hidden Files", isOn: Binding(
                get: { model.explorer.showDotfiles },
                set: { model.explorer.showDotfiles = $0 }
            ))
            .keyboardShortcut(".", modifiers: [.command, .shift])
            Button("Refresh Explorer") { model.explorer.refreshAll() }
                .keyboardShortcut("r", modifiers: [.command])
            Button("Toggle Rendered / Source") { model.activeSession?.toggleMarkdownMode() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(model.activeSession?.markdown == nil)
        }
    }
}
