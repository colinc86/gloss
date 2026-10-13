import AppKit
import Core
import Integrations
import SwiftUI
import Viewers

struct ShareReviewPopover: View {
    @Environment(AppModel.self) private var model
    @State private var preparation: Task<Void,Never>?
    private var collaboration: CollaborationModel { model.collaboration }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Share \(model.activeSession.map { Core.Document.displayName(of: $0.path) } ?? "Review")").font(.headline)
            Text("Captured content and sent notes, including their attachments. Your drafts stay on this Mac.")
                .font(.callout).foregroundStyle(.secondary)
            if collaboration.excludedNotesCount > 0 { Text("\(collaboration.excludedNotesCount) older edited notes need another Send before they can be included.").font(.caption).foregroundStyle(.secondary) }
            if model.activeSession?.kind == .web { Text("Captures the visible viewport, not the complete page.").font(.caption).foregroundStyle(.secondary) }
            if collaboration.needsSave {
                Text("Save before sharing. The review will contain the saved file.")
                Button("Save and Continue") {
                    Task {
                        guard let session = model.activeSession else { return }
                        await session.save()
                        if !session.isDirty, session.conflict == nil { collaboration.needsSave = false }
                        else { collaboration.error = session.lastError ?? "The file hasn't been saved yet." }
                    }
                }
            } else if collaboration.preparing {
                ProgressView("Preparing review…").controlSize(.small)
            } else if let url = collaboration.shareURL {
                SharingPickerButton(url: url, copy: collaboration.shareIsCopy, began: { collaboration.sharingIsActive = true }) { error in
                    collaboration.sharingIsActive = false
                    collaboration.error = error
                    if error == nil { collaboration.isSharePresented = false }
                    collaboration.shareURL = nil
                }.frame(height: 28)
            } else {
                Text("People can add notes. Only the owner sends them to an agent.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Collaborate…") { prepare(copy: false) }
                        .disabled(model.activeReview?.isCopy == true)
                        .help(model.activeReview?.isCopy == true ? "This copy has no shared return channel. Send a separate copy instead." : "Invite people to this review")
                    Button("Send a Copy…") { prepare(copy: true) }
                }
            }
            if let error = collaboration.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            Button("Cancel", role: .cancel) { preparation?.cancel(); collaboration.cancelShare(); collaboration.isSharePresented = false }
        }
        .padding(16).frame(width: 320)
        .onDisappear { preparation?.cancel(); collaboration.cancelShare() }
    }
    private func prepare(copy: Bool) {
        guard let session = model.activeSession else { return }
        preparation = Task { await collaboration.prepareShare(session, copy: copy, browser: model.browser, portableSource: model.reviewSource(session)) }
    }
}

struct CollaborationPopover: View {
    @Environment(AppModel.self) private var model
    let review: ReviewContext
    @State private var editingName = false
    @State private var allActivity = false
    var body: some View {
        @Bindable var settings = model.settings
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(review.title).font(.headline)
                Text(review.isCopy ? "Separate copy · No return channel" : "Shared review · iCloud Drive").font(.caption).foregroundStyle(.secondary)
                Text(status).font(.callout).foregroundStyle(.secondary)
                if !review.isCopy, review.status.canWrite != nil { Text(review.canWrite ? "You can add notes" : "You can view only").font(.caption) }
                if let error = review.error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                    Button("Try Again") { Task { await model.collaboration.retry(review) } }
                }
                Divider()
                Text("Contributors").font(.subheadline.weight(.semibold))
                ForEach(review.snapshot.authors, id: \.id) { author in
                    HStack {
                        ContributorAvatar(name: CollaborationModel.displayName(author.name), id: author.id.rawValue)
                        Text((author.id == model.settings.authorID ? "You" : CollaborationModel.displayName(author.name)) + (review.snapshot.info.isOwner(author.id) ? " · Owner" : ""))
                            .lineLimit(2)
                    }
                }
                Text("Names chosen by contributors. This is not an access list.").font(.caption2).foregroundStyle(.secondary)
                Divider()
                Text(allActivity ? "All Activity" : "New Since You Looked").font(.subheadline.weight(.semibold))
                if review.unread.isEmpty { Text("You're all caught up").foregroundStyle(.secondary) }
                ForEach(unreadNotes, id: \.id) { note in
                    Button("\(CollaborationModel.displayName(review.snapshot.author(note.author)?.name)) added a note · \(note.anchor.summary)") {
                        guard let local = review.noteMap[note.id], let group = model.notesPanel.allGroups.first(where: { $0.document.id == review.documentID }), let indexed = group.notes.first(where: { $0.id == local }) else { return }
                        model.reveal(note: indexed, in: group.document)
                    }.buttonStyle(.plain)
                }
                ForEach(review.snapshot.messages.filter { (allActivity || review.unread.contains($0.id.rawValue)) }, id: \.id) { turn in
                    Button("\(CollaborationModel.displayName(review.snapshot.author(turn.author)?.name)) replied") { reveal(turn.note) }.buttonStyle(.plain)
                }
                ForEach(review.snapshot.events.filter { (allActivity || review.unread.contains($0.id.rawValue)) }, id: \.id) { event in
                    Button("\(CollaborationModel.displayName(review.snapshot.author(event.author)?.name)) · \(event.type)") { reveal(event.note) }.buttonStyle(.plain)
                }
                if review.unread.contains("content:" + review.snapshot.info.current.hash) {
                    Button("Updated content · Iteration \(review.snapshot.info.current.iteration)") {
                        if let session = model.activeSession { model.iterations.backToCurrent(session) }
                        model.collaboration.markContentSeen(review)
                    }
                }
                Button(allActivity ? "New Since You Looked" : "All Activity…") { allActivity.toggle() }
                Button("Mark All as Seen") { Task { await model.collaboration.markAllSeen(review) } }.disabled(review.unread.isEmpty)
                Divider()
                if editingName {
                    TextField("Your name", text: $settings.yourName, prompt: Text("Unnamed contributor"))
                    Button("Done") { editingName = false; Task { await model.collaboration.updateName() } }
                } else {
                    HStack { Text("Your name: \(CollaborationModel.displayName(settings.yourName))"); Spacer(); Button("Edit…") { editingName = true } }
                }
                if review.isOwner {
                    Button("Open Original") { Task { if let document = try? await model.noteStore.document(review.documentID), document.hostID != .gloss { model.openDocument(hostID: document.hostID, path: document.path) } } }
                    Button("Link Original…") { model.linkReviewOriginal(review) }
                    Button("Refresh Shared Content") { Task { await model.collaboration.synchronizeOwnerChanges() } }
                }
                if review.isCopy || !review.canWrite || review.error != nil {
                    Button("Save My Notes…") { model.savePrivateReviewNotes(review) }
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([review.session.url]) }
                Text("Manage access in Finder's sharing options.").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }.frame(width: 320).frame(maxHeight: 520)
    }
    private var status: String {
        if let error = review.status.uploadError { return "Waiting for iCloud · \(error)" }
        if review.status.isUploading { return "Sending changes · Waiting for iCloud" }
        if review.status.download == .notDownloaded { return "Downloading the review's content…" }
        if review.status.isUploaded { return "Changes uploaded" }
        return "Showing the last available update"
    }
    private var unreadNotes: [GlossNote] { review.snapshot.notes.filter { allActivity || review.unread.contains($0.id.rawValue + ":" + $0.rev) } }
    private func reveal(_ id: NoteID) {
        guard let local = review.noteMap[id], let group = model.notesPanel.allGroups.first(where: { $0.document.id == review.documentID }), let note = group.notes.first(where: { $0.id == local }) else { return }
        model.reveal(note: note, in: group.document)
    }
}

struct ReviewsSection: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        List {
            reviewGroup("Shared With You") { !$0.isOwner && !$0.isCopy }
            reviewGroup("Shared by You") { $0.isOwner }
            reviewGroup("Copies") { $0.isCopy }
            Button("Open Review…") { model.openReviewPanel() }
        }.listStyle(.sidebar)
    }
    private func reviewGroup(_ title: String, matches: (ReviewContext) -> Bool) -> some View {
        Section(title) {
            ForEach(model.collaboration.reviews.filter(matches)) { review in
                Button { model.showReview(review) } label: {
                    HStack {
                        Image(systemName: "doc.text")
                        VStack(alignment: .leading) {
                            Text(review.title).lineLimit(1)
                            Text(review.locationTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if !review.unread.isEmpty { Circle().fill(Color.accentColor).frame(width: 6, height: 6).help("\(review.unread.count) new updates") }
                    }
                }.buttonStyle(.plain).accessibilityLabel(review.locationTitle + ", \(review.unread.count) new updates")
            }
        }
    }
}

struct ContributorLabel: View {
    @Environment(AppModel.self) private var model
    let note: Note
    var body: some View {
        HStack(spacing: 6) {
            ContributorAvatar(name: CollaborationModel.displayName(note.contributorName ?? model.settings.yourName), id: note.contributorID ?? model.settings.authorID.rawValue)
            Text(model.collaboration.authorLabel(note)).font(.caption.weight(.medium)).lineLimit(2)
            if let review = model.collaboration.context(for: note.documentID), let remote = review.noteMap.first(where: { $0.value == note.id })?.key,
               let record = review.snapshot.notes.first(where: { $0.id == remote }), review.unread.contains(record.id.rawValue + ":" + record.rev) {
                Circle().fill(Color.accentColor).frame(width: 5,height: 5).help("New").accessibilityLabel("New")
            }
        }.accessibilityElement(children: .combine)
    }
}
struct ContributorAvatar: View {
    let name: String
    let id: String
    var body: some View {
        let initials = name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        // Stable author tint, independent of the note color and state palette.
        let hue = Double(id.utf8.reduce(0) { ($0 * 31 + Int($1)) % 360 }) / 360
        Text(initials).font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.primary)
            .frame(width: 20,height: 20).background(Color(hue: hue,saturation: 0.2,brightness: 0.8).opacity(0.3),in: Circle())
            .accessibilityHidden(true)
    }
}
struct PeopleFilter: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var panel = model.notesPanel
        Menu {
            Button("All People") { panel.peopleFilter = [] }
            if let review = model.activeReview {
                ForEach(review.snapshot.authors, id: \.id) { author in
                    Toggle(CollaborationModel.displayName(author.name), isOn: Binding(get: { panel.peopleFilter.contains(author.id.rawValue) },set: { included in
                        if included { panel.peopleFilter.insert(author.id.rawValue) } else { panel.peopleFilter.remove(author.id.rawValue) }
                    }))
                }
                Toggle("Your private drafts", isOn: Binding(get: { panel.peopleFilter.contains("you") },set: { included in
                    if included { panel.peopleFilter.insert("you") } else { panel.peopleFilter.remove("you") }
                }))
            }
        } label: { Label("People",systemImage: "person.2") }
        .menuStyle(.borderlessButton).font(.caption).accessibilityLabel("Filter notes by contributor")
    }
}

struct CollaborationNotice: View {
    @Environment(AppModel.self) private var model
    let session: DocumentSession
    var body: some View {
        if let context = model.collaboration.context(for: session.document?.id) {
            if let error = context.error {
                Notice(kind: .warning, symbol: "icloud.slash", title: "Review unavailable", detail: error, wrapsActions: true) {
                    Button("Try Again") { Task { await model.collaboration.retry(context) } }
                }
            } else if let notice = context.notice {
                Notice(kind: .mode, symbol: "person.2", title: notice, detail: context.isOwner ? "Review the notes before sending them to an agent." : "Notes reach the owner when the review syncs.", wrapsActions: true) {
                    if !context.receivedNoteIDs.isEmpty { Button("Show Notes") { model.collaboration.revealReceived(context) } }
                    Button("Dismiss") { context.notice = nil }
                }
            } else if session.hostID == .gloss {
                Notice(kind: .mode, symbol: "doc.text", title: context.locationTitle,
                       detail: context.snapshot.info.documentKind == .web ? "Captured viewport snapshot · Read-only content" : "Captured content · Read-only", wrapsActions: true) {
                    if !context.canWrite { Text(context.isCopy ? "This copy has no return channel." : "You can view only.") }
                }
            }
        }
    }
}

extension AppModel {
    func reviewSource(_ session: DocumentSession) -> GlossSource {
        if session.kind == .web {
            let url = session.path
            return .web(url: url, reachable: !(URL(string: url)?.host.map { ["localhost","127.0.0.1","::1"].contains($0) } ?? true) && session.hostID == .web)
        }
        if session.hostID == .github, let path = PullRequestPath(session.path) {
            return .github(repo: path.repository, pull: path.number, path: path.changedFile ?? path.rest, head: nil, base: nil)
        }
        if session.hostID == .atlassian, let path = AtlassianPath(session.path), let site = integrations.atlassian?.site.host {
            switch path {
            case .jiraIssue(_, let key): return .jira(site: site, key: key)
            case .confluencePage(_,let id,_,_): return .confluence(site: site,pageID: id,version: nil)
            default: break
            }
        }
        return .file(name: Core.Document.displayName(of: session.path), git: nil)
    }
    func linkReviewOriginal(_ review: ReviewContext) {
        guard review.isOwner else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let bytes = try await Task.detached { try Data(contentsOf: url) }.value
                let captured = try await collaboration.fileSystem.read(review.capturePath)
                guard bytes == captured else {
                    review.error = "Choose an original file that matches this review's current capture."; return
                }
                let document = try await noteStore.upsertDocument(hostID: .local,path: url.path,kind: review.snapshot.info.documentKind ?? .file,fingerprint: Fingerprint(hash: bytes.sha256Hex))
                try await noteStore.linkReviewOriginal(review.id,to: document.id,baseline: captured)
                // Reopen the review under the source identity, retaining its stable local note ids.
                await collaboration.relink(review, to: document.id)
                rebuildReview(review)
            } catch { review.error = error.userMessage }
        }
    }
}
