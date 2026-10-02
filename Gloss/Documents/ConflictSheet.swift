import Core
import SwiftUI

/// Shown when the file on disk changed since it was opened: the editor's edits versus the disk, against the base.
struct ConflictSheet: View {
    let session: DocumentSession
    let conflict: DocumentSession.ConflictState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(session.fileName) changed on disk")
                .font(.headline)
            Text(conflict.canMerge
                 ? "Your edits and the changes on disk do not overlap. They can be merged."
                 : "Your edits overlap changes made on disk. Pick a side, or save your version elsewhere.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(conflict.regions.enumerated()), id: \.offset) { _, region in
                        RegionView(region: region)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 240)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                legend("Mine", .blue)
                legend("Disk", .green)
                legend("Conflict", .red)
                Spacer()
                Button("Save As…") { Task { await session.saveAs() } }
                    .disabled(session.hostID != .local)
                Button("Take Disk Version") { Task { await session.takeTheirs() } }
                Button("Keep Mine") { Task { await session.keepMine() } }
                if conflict.canMerge {
                    Button("Merge and Save") { Task { await session.mergeAndSave() } }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 640, idealWidth: 820, minHeight: 420)
    }

    private func legend(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.3)).frame(width: 12, height: 12)
            Text(label).font(.caption)
        }
    }
}

private struct RegionView: View {
    let region: MergeRegion

    var body: some View {
        switch region {
        case .unchanged(let lines):
            lineBlock(lines, prefix: " ", tint: .clear, limit: 3)
        case .mine(let lines):
            lineBlock(lines, prefix: "+", tint: .blue)
        case .theirs(let lines):
            lineBlock(lines, prefix: "+", tint: .green)
        case .both(let lines):
            lineBlock(lines, prefix: "=", tint: .teal)
        case .conflict(let mine, let theirs):
            VStack(alignment: .leading, spacing: 0) {
                lineBlock(["<<<<<<< mine"] + mine, prefix: "", tint: .red)
                lineBlock(["======="] + theirs + [">>>>>>> disk"], prefix: "", tint: .orange)
            }
        }
    }

    private func lineBlock(_ lines: [String], prefix: String, tint: Color, limit: Int? = nil) -> some View {
        let shown: [String] = {
            guard let limit, lines.count > limit * 2 + 1 else { return lines }
            return Array(lines.prefix(limit)) + ["… \(lines.count - limit * 2) unchanged lines …"] + Array(lines.suffix(limit))
        }()
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                Text(prefix + " " + line)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
                    .background(tint.opacity(0.15))
            }
        }
    }
}
