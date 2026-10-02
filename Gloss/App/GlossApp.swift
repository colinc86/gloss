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
        CommandGroup(after: .toolbar) {
            Toggle("Show Hidden Files", isOn: Binding(
                get: { model.explorer.showDotfiles },
                set: { model.explorer.showDotfiles = $0 }
            ))
            .keyboardShortcut(".", modifiers: [.command, .shift])
            Button("Refresh Explorer") { model.explorer.refreshAll() }
                .keyboardShortcut("r", modifiers: [.command])
        }
    }
}
