import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            ExplorerSidebar()
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 600)
        } detail: {
            if let session = model.activeSession {
                ViewerPane(session: session)
                    .id(session.id)
            } else {
                ContentUnavailableView(
                    "Select a file",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Choose a file in the explorer to view it here.")
                )
            }
        }
    }
}

struct SettingsPlaceholderView: View {
    var body: some View {
        Text("Settings arrive in a later step.")
            .padding()
            .frame(width: 400, height: 200)
    }
}
