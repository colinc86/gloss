import Core
import SwiftUI
import Viewers

/// File › Open Location: a web address, and which machine's loopback it means. A bare `localhost:3000` is enough;
/// the scheme is filled in.
struct OpenLocationSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var via: HostID = .local
    @FocusState private var focused: Bool

    private var url: URL? { Self.url(from: address) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            Text("Open Location")
                .font(.title3.weight(.semibold))
            TextField("Address", text: $address, prompt: Text("example.com, or localhost:3000"))
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .focused($focused)
                .onSubmit(open)
            Picker("Via", selection: $via) {
                Text("This Mac").tag(HostID.local)
                ForEach(model.hosts.entries.filter { $0.kind == .ssh }) { entry in
                    Label(entry.name, systemImage: "network").tag(entry.id)
                }
            }
            .help("localhost on another machine is reached through the app's ssh connection to it")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open", action: open)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(url == nil)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 460)
        .onAppear {
            focused = true
            // Through the machine the reader is working on: the open document's ssh host, if it has one.
            if let host = model.activeSession?.hostID, model.hosts.entry(for: host)?.kind == .ssh { via = host }
        }
    }

    private func open() {
        guard let url else { return }
        dismiss()
        model.openWebPage(url, via: via == .local ? nil : via)
    }

    /// `localhost:3000` → `http://localhost:3000/`; `example.com/docs` → `https://example.com/docs`; a full URL as is.
    nonisolated static func url(from text: String) -> URL? { WebAddress.url(from: text) }
}
