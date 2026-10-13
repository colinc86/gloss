import AppKit
import Core
import UniformTypeIdentifiers

extension AppModel {
    /// A manual return artifact, including only this reader's private input. It has no live sharing channel.
    func savePrivateReviewNotes(_ review: ReviewContext) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = review.title + " — My Notes.txt"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task {
                do {
                    let notes = try await noteStore.reviewHistoryNotes(review.documentID)
                    var sections = ["My notes on " + review.title]
                    for note in notes {
                        let own = note.contributorID == nil || note.contributorID == settings.authorID.rawValue
                        let privateBody = own && (note.publishedAt == nil || note.hasUnpublishedChanges)
                        let turns = try await noteStore.messages(for: note.id).filter { $0.author == .user && !$0.isSent && $0.contributorID == nil }
                        guard privateBody || !turns.isEmpty else { continue }
                        sections.append(note.anchor.summary + "\n" + (privateBody ? note.body : "") + turns.map { "\nReply: " + $0.body }.joined())
                    }
                    let bytes = Data(sections.joined(separator: "\n\n").utf8)
                    try await Task.detached { try bytes.write(to: url,options: .atomic) }.value
                } catch { review.error = error.userMessage }
            }
        }
    }
}
