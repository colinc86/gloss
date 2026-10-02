import SwiftUI

struct ContentView: View {
    let launchOptions: AppLaunchOptions

    var body: some View {
        NavigationSplitView {
            List {
                if let root = launchOptions.root {
                    Label(root, systemImage: "folder")
                } else {
                    Text("No root open")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            ContentUnavailableView(
                "Select a file",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Choose a file in the explorer to view it here.")
            )
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
