import Core
import Integrations
import SwiftUI

/// File › Open Pull Request…: type to narrow the open pull requests you are part of, or paste a pull request URL
/// or `owner/repo#123`; arrows move, Return opens, Escape closes. Modelled on Open Quickly.
struct OpenPullRequestSheet: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    @Namespace private var selection
    @State private var listHeight: CGFloat = 0
    private static let maximumListHeight: CGFloat = 330
    private static let emptyHeight: CGFloat = 200

    var body: some View {
        @Bindable var picker = model.pullRequestPicker
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.m) {
                Image(systemName: "arrow.triangle.pull")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("Open pull request", text: $picker.query, prompt: Text("Search your open pull requests, or paste owner/repo#123 or a URL"))
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .focused($focused)
                    .onSubmit { picker.submit() }
                    .onKeyPress(.downArrow) { picker.moveSelection(by: 1); return .handled }
                    .onKeyPress(.upArrow) { picker.moveSelection(by: -1); return .handled }
                if picker.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, DS.Space.l + 2)
            .padding(.vertical, DS.Space.l)
            Divider()
            content(picker)
            Divider()
            footer(picker)
        }
        .frame(width: 620)
        .onAppear { focused = true }
        .onExitCommand { picker.dismiss() }
    }

    @ViewBuilder
    private func content(_ picker: PullRequestPickerModel) -> some View {
        if let typed = picker.typedReference, let action = picker.typedAction {
            // A pasted reference opens as is, whatever the list holds; without a token a URL opens as a web page.
            HStack(spacing: DS.Space.m) {
                Image(systemName: action == .needsKey ? "key" : action == .open(typed) ? "arrow.right.circle.fill" : "globe")
                    .foregroundStyle(action == .needsKey ? Color.secondary : Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(action == .needsKey ? "\(typed.repository) #\(typed.number)" : action == .open(typed) ? "Open \(typed.repository) #\(typed.number)" : "Open in the browser")
                        .font(.body.weight(.medium))
                    if action != .open(typed) {
                        Text(action == .needsKey ? "Save a GitHub token in Settings → Integrations to open it" : "Save a GitHub token to open it as a pull request")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if action != .needsKey { KeyCap("↩").foregroundStyle(.secondary) }
            }
            .padding(DS.Space.l)
            .frame(height: 60)
        } else if let error = picker.errorMessage {
            EmptyState(symbol: "key", title: "Can't list pull requests", message: error)
                .frame(height: Self.emptyHeight)
        } else if !picker.isLoading, picker.results.isEmpty {
            EmptyState(
                symbol: picker.query.isEmpty ? "arrow.triangle.pull" : "questionmark.circle",
                title: picker.query.isEmpty ? "No open pull requests" : "Nothing matches",
                message: picker.query.isEmpty ? "None of your open pull requests involve \(picker.login ?? "you"). Paste a URL to open any." : "Try fewer words, or paste the pull request's URL."
            )
            .frame(height: Self.emptyHeight)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(picker.results.enumerated()), id: \.element.htmlUrl) { index, pull in
                            row(pull, selected: index == picker.selectedIndex)
                                .id(pull.htmlUrl)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    picker.selectedIndex = index
                                    picker.submit()
                                }
                        }
                    }
                    .padding(DS.Space.s)
                    .animation(DS.Motion.snappy, value: picker.selectedIndex)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                        withAnimation(DS.Motion.smooth) { listHeight = height }
                    }
                }
                .frame(height: min(Self.maximumListHeight, max(listHeight, 60)))
                .onChange(of: picker.selectedIndex) { _, index in
                    guard picker.results.indices.contains(index) else { return }
                    withAnimation(DS.Motion.smooth) { proxy.scrollTo(picker.results[index].htmlUrl) }
                }
            }
        }
    }

    private func row(_ pull: GitHubPullRequestSummary, selected: Bool) -> some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: pull.draft == true ? "pencil.and.outline" : "arrow.triangle.pull")
                .foregroundStyle(pull.draft == true ? Color.secondary : Color.accentColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(pull.title).lineLimit(1)
                HStack(spacing: DS.Space.xs) {
                    Text("\(pull.repository) #\(pull.number)")
                    if pull.draft == true { Text("· draft") }
                    Text("· updated \(pull.updatedAt.formatted(.relative(presentation: .named)))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            if selected {
                KeyCap("↩")
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
        .font(.body)
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(Color.accentColor.opacity(0.35)))
                    .matchedGeometryEffect(id: "selection", in: selection)
            }
        }
    }

    private func footer(_ picker: PullRequestPickerModel) -> some View {
        HStack(spacing: DS.Space.s) {
            Text(picker.isLoading ? "Listing your open pull requests…" : "\(picker.results.count) open pull request\(picker.results.count == 1 ? "" : "s")")
                .contentTransition(.numericText(value: Double(picker.results.count)))
            Spacer()
            KeyCap("↑"); KeyCap("↓"); Text("move")
            Text("·").foregroundStyle(.quaternary)
            KeyCap("↩"); Text("open")
            Text("·").foregroundStyle(.quaternary)
            KeyCap("esc"); Text("close")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s + 1)
        .animation(DS.Motion.smooth, value: picker.results.count)
    }
}
