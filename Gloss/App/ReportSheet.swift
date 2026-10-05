import AppKit
import SwiftUI

/// Help › Report a Bug or Request a Feature, and the toolbar's ladybug: a title, a description and, if the reader
/// agrees, the app and macOS versions. With a GitHub key that can file it, it is sent from here; otherwise (or if
/// GitHub refuses the key) the same report opens in the browser, filled in, to finish there.
struct ReportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var kind: IssueReporter.Kind = .bug
    @State private var title = ""
    @State private var details = ""
    @State private var includeSystemInfo = true
    @State private var phase = Phase.editing
    @FocusState private var titleFocused: Bool

    enum Phase: Equatable {
        case editing
        case sending
        /// GitHub refused; `browser` when this key can't file here, so the browser is the way on.
        case failed(String, browser: Bool)
        case sent(URL)
    }

    private let systemInfo = IssueReporter.systemInfo()
    private var token: String? { model.integrations.github?.token }
    private var usesBrowser: Bool {
        if token == nil { return true }
        if case .failed(_, true) = phase { return true }
        return false
    }
    private var canSend: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && phase != .sending
    }

    var body: some View {
        Group {
            if case .sent(let page) = phase {
                sent(page)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            } else {
                form
                    .transition(.opacity)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: 480)
        .animation(DS.Motion.smooth, value: phase)
        .interactiveDismissDisabled(phase == .sending)
        .onAppear { titleFocused = true }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text("Send Feedback")
                    .font(.title3.weight(.semibold))
                Text("Tell us what went wrong, or what you'd like Gloss to do.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Picker("Kind", selection: $kind) {
                ForEach(IssueReporter.Kind.allCases) { kind in
                    Label(kind.title, systemImage: kind == .bug ? "ladybug" : "sparkles").tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextField("Title", text: $title, prompt: Text(kind == .bug ? "Notes vanish after renaming a file" : "Export notes as Markdown"))
                .textFieldStyle(.roundedBorder)
                .focused($titleFocused)
                .onChange(of: title) { if title.count > IssueReporter.maximumTitle { title = String(title.prefix(IssueReporter.maximumTitle)) } }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $details)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(DS.Space.xs)
                if details.isEmpty {
                    Text(kind == .bug ? "What happened, and what did you expect? Steps to make it happen again help most." : "What would you like Gloss to do, and what would it help you with?")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, DS.Space.s + DS.Space.xxs)
                        .padding(.vertical, DS.Space.xs)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 150)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(.separator))
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Toggle("Include Gloss and macOS versions", isOn: $includeSystemInfo)
                    .toggleStyle(.checkbox)
                Text(systemInfo)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, DS.Space.xl)
                    .opacity(includeSystemInfo ? 1 : 0.4)
            }
            if case .failed(let message, _) = phase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: DS.Space.m) {
                footnote
                Spacer(minLength: DS.Space.m)
                // Once sent, the issue is filed whether or not the reader waits: no way out that would hide it.
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(phase == .sending)
                Button(action: send) {
                    if phase == .sending {
                        ProgressView().controlSize(.small).frame(minWidth: 40)
                    } else {
                        Text(usesBrowser ? "Continue in Browser" : "Send")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)
            }
        }
    }

    @ViewBuilder private var footnote: some View {
        if usesBrowser {
            Text("Opens on GitHub to finish.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else if let login = model.integrations.githubLogin {
            Text("Sent as @\(login)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func sent(_ page: URL) -> some View {
        VStack(spacing: DS.Space.m) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, options: .nonRepeating)
            Text("Thanks, we've got it.")
                .font(.title3.weight(.semibold))
            Text(kind == .bug ? "We'll look into it." : "We'll consider it for a future version.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("View Report") { NSWorkspace.shared.open(page) }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, DS.Space.s)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Space.l)
    }

    private func send() {
        guard canSend else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let info = includeSystemInfo ? systemInfo : nil
        guard let token, !usesBrowser else {
            NSWorkspace.shared.open(IssueReporter.browserURL(title: title, description: details, kind: kind, systemInfo: info))
            dismiss()
            return
        }
        phase = .sending
        let body = IssueReporter.body(kind: kind, description: String(details.prefix(IssueReporter.maximumDescription)), systemInfo: info)
        let kind = kind
        Task {
            do {
                phase = .sent(try await IssueReporter(token: token).create(title: title, body: body, kind: kind))
            } catch {
                let browser = IssueReporter.needsBrowser(error)
                phase = .failed(browser ? "Your GitHub key can't file reports here. Finish it on GitHub instead." : IntegrationsModel.message(error), browser: browser)
            }
        }
    }
}
