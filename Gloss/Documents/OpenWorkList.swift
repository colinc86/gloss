import AppKit
import Core
import SwiftUI
import UniformTypeIdentifiers
import Viewers

/// A file in the open folder with notes still in play, for picking up where you left off.
nonisolated struct OpenWorkItem: Identifiable, Equatable {
    let document: Core.Document
    /// Folder inside the root ("src/app"), empty at the root itself.
    let place: String
    let drafts: Int
    let sent: Int
    /// Questions back from the agent and notes that lost their place.
    let attention: Int
    let lastTouched: Date
    var id: DocumentID { document.id }

    /// Files under `root` with open notes, most recently touched first.
    static func items(from groups: [DocumentNotes], rootPath: String, hostID: HostID, limit: Int = 5) -> [OpenWorkItem] {
        let base = ExplorerModel.aliasFree(rootPath)
        return groups.compactMap { group -> OpenWorkItem? in
            guard group.document.hostID == hostID,
                  ExplorerModel.inRootSpelling(group.document.path, root: rootPath, hostID: hostID) != nil else { return nil }
            let drafts = group.notes.filter { $0.state == .draft }.count
            let sent = group.notes.filter { $0.state == .sent }.count
            let attention = group.notes.filter { $0.state == .orphaned || ($0.state == .resolved && $0.resolveOutcome == .needsInput) }.count
            guard drafts + sent + attention > 0 else { return nil }
            let folder = (ExplorerModel.aliasFree(group.document.path) as NSString).deletingLastPathComponent
            let place = folder.count > base.count ? String(folder.dropFirst(base == "/" ? 1 : base.count + 1)) : ""
            let touched = group.notes.map(\.updatedAt).max() ?? .distantPast
            return OpenWorkItem(document: group.document, place: place, drafts: drafts, sent: sent, attention: attention, lastTouched: touched)
        }
        .sorted { $0.lastTouched > $1.lastTouched }
        .prefix(limit)
        .map { $0 }
    }
}

/// "Pick up where you left off": the empty viewer's shortcut back into files with notes waiting.
struct OpenWorkList: View {
    let items: [OpenWorkItem]
    let open: (OpenWorkItem) -> Void
    @State private var appeared = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text("Pick up where you left off")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, DS.Space.m)
            VStack(spacing: DS.Space.xxs) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    OpenWorkRow(item: item) { open(item) }
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared || Motion.isReduced ? 0 : 6)
                        .animation(DS.Motion.smooth.delay(Motion.isReduced ? 0 : Double(index) * 0.04), value: appeared)
                }
            }
        }
        .frame(width: 400)
        .onAppear { appeared = true }
    }
}

private struct OpenWorkRow: View {
    let item: OpenWorkItem
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.m) {
                Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (item.document.path as NSString).pathExtension) ?? .data))
                    .resizable()
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.document.fileName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !item.place.isEmpty {
                        Text(item.place)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: DS.Space.m)
                HStack(spacing: DS.Space.s) {
                    if item.attention > 0 { count(item.attention, symbol: NoteState.orphaned.style.symbol, tint: .orange, label: "need attention") }
                    if item.drafts > 0 { count(item.drafts, symbol: NoteState.draft.style.symbol, tint: .secondary, label: item.drafts == 1 ? "draft" : "drafts") }
                    if item.sent > 0 { count(item.sent, symbol: NoteState.sent.style.symbol, tint: .blue, label: "sent") }
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0)
                    .offset(x: hovering ? 0 : -4)
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s)
            .background(Color.primary.opacity(hovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DS.Motion.snappy, value: hovering)
        .help(item.document.path)
    }

    private func count(_ number: Int, symbol: String, tint: Color, label: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).imageScale(.small).foregroundStyle(tint)
            Text("\(number)").monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.caption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(number) \(label)")
    }
}
