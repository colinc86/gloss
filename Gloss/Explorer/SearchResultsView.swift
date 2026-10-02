import Core
import SwiftUI

struct SearchResultsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let search = model.explorer.contentSearch
        List {
            ForEach(search.groupedHits, id: \.path) { group in
                Section {
                    ForEach(group.hits) { hit in
                        Button {
                            model.openDocument(hostID: model.explorer.selectedTab?.hostID ?? .local, path: hit.path, line: hit.line)
                        } label: {
                            HStack(alignment: .top, spacing: 6) {
                                Text("\(hit.line)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 36, alignment: .trailing)
                                Text(hit.text.trimmingCharacters(in: .whitespaces))
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(2)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(PathUtilities.relative(group.path, to: model.explorer.selectedTab?.path ?? "/"))
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if search.truncated {
                Text("Showing the first 500 matches").font(.caption).foregroundStyle(.secondary)
            }
            if !search.isSearching && search.hits.isEmpty && !search.query.isEmpty {
                Text("No matches").font(.caption).foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
    }
}
