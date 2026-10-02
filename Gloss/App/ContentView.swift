import Core
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            ExplorerSidebar()
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 600)
        } detail: {
            Group {
                if let session = model.activeSession {
                    ViewerPane(session: session)
                        .id(session.id)
                        .navigationTitle(session.fileName)
                        .navigationSubtitle(session.hostID == .local ? "" : (model.hosts.entry(for: session.hostID)?.name ?? ""))
                } else {
                    ContentUnavailableView(
                        "Select a file",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("Choose a file in the explorer to view it here.")
                    )
                }
            }
            .inspector(isPresented: Binding(get: { model.showNotesPanel }, set: { model.showNotesPanel = $0 })) {
                NotesPanel()
                    .inspectorColumnWidth(min: 300, ideal: 360, max: 480)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.showNotesPanel.toggle()
                    } label: {
                        Label("Notes", systemImage: "note.text")
                    }
                    .help("Toggle the notes panel (⌘⌥N)")
                }
            }
        }
    }
}
