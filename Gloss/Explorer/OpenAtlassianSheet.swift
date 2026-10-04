import Core
import Integrations
import SwiftUI

/// File › Open Jira Issue or Confluence Page…: Jira lists the issues you are part of, Confluence the site's
/// spaces; an issue key or a URL opens as is. Arrows move, Return opens, Escape closes.
struct OpenAtlassianSheet: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    @Namespace private var selection
    @State private var listHeight: CGFloat = 0
    private static let maximumListHeight: CGFloat = 330
    private static let emptyHeight: CGFloat = 200

    var body: some View {
        @Bindable var picker = model.atlassianPicker
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.m) {
                Image(systemName: picker.product == .jira ? "ticket" : "doc.text")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("Open", text: $picker.query, prompt: Text(picker.product == .jira ? "Search your issues, or paste PROJ-123 or a URL" : "Search spaces, or paste a page URL"))
                    .textFieldStyle(.plain)
                    .font(.title2)
                    .focused($focused)
                    .onSubmit { picker.submit() }
                    .onKeyPress(.downArrow) { picker.moveSelection(by: 1); return .handled }
                    .onKeyPress(.upArrow) { picker.moveSelection(by: -1); return .handled }
                if picker.isLoading {
                    ProgressView().controlSize(.small)
                }
                Picker("Product", selection: $picker.product) {
                    ForEach(AtlassianPickerModel.Product.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
            }
            .padding(.horizontal, DS.Space.l + 2)
            .padding(.vertical, DS.Space.l)
            Divider()
            content(picker)
            Divider()
            footer(picker)
        }
        .frame(width: 640)
        .onAppear { focused = true }
        .onExitCommand { picker.dismiss() }
    }

    @ViewBuilder
    private func content(_ picker: AtlassianPickerModel) -> some View {
        if let typed = picker.typedReference, let action = picker.typedAction {
            HStack(spacing: DS.Space.m) {
                Image(systemName: action == .needsKey ? "key" : action == .open(typed) ? "arrow.right.circle.fill" : "globe")
                    .foregroundStyle(action == .needsKey ? Color.secondary : Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(action == .open(typed) ? Self.describe(typed) : action == .needsKey ? Self.describe(typed).replacingOccurrences(of: "Open ", with: "") : "Open in the browser")
                        .font(.body.weight(.medium))
                    if action != .open(typed) {
                        Text(action == .needsKey ? "Save an Atlassian key in Settings → Integrations to open it" : "Save an Atlassian key to open it as a document")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if action != .needsKey { KeyCap("↩").foregroundStyle(.secondary) }
            }
            .padding(DS.Space.l)
            .frame(height: 60)
        } else if let error = picker.errorMessage {
            EmptyState(symbol: "key", title: "Can't list", message: error)
                .frame(height: Self.emptyHeight)
        } else if !picker.isLoading, picker.results.isEmpty {
            EmptyState(
                symbol: picker.query.isEmpty ? (picker.product == .jira ? "ticket" : "doc.text") : "questionmark.circle",
                title: picker.query.isEmpty ? (picker.product == .jira ? "No issues of yours" : "No spaces") : "Nothing matches",
                message: picker.query.isEmpty
                    ? (picker.product == .jira ? "Nothing is assigned to, reported by or watched by this account. Paste an issue key or URL to open any you can see." : "This account can't see any Confluence space. Paste a page URL to open one you can.")
                    : "Try fewer words, or paste a key or URL."
            )
            .frame(height: Self.emptyHeight)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(picker.results.enumerated()), id: \.element.id) { index, row in
                            self.row(row, product: picker.product, selected: index == picker.selectedIndex)
                                .id(row.id)
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
                    withAnimation(DS.Motion.smooth) { proxy.scrollTo(picker.results[index].id) }
                }
            }
        }
    }

    static func describe(_ reference: AtlassianPath) -> String {
        switch reference {
        case .jiraIssue(_, let key): "Open \(key)"
        case .confluencePageFolder(let space, let id, _): "Open page \(id) in \(space)"
        case .confluenceSpace(let space): "Open space \(space)"
        default: "Open \(reference.path)"
        }
    }

    private func row(_ row: AtlassianPickerModel.Row, product: AtlassianPickerModel.Product, selected: Bool) -> some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: product == .jira ? "ticket" : "doc.text")
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).lineLimit(1)
                Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if selected {
                KeyCap("↩").foregroundStyle(.secondary).transition(.opacity)
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

    private func footer(_ picker: AtlassianPickerModel) -> some View {
        HStack(spacing: DS.Space.s) {
            Text(picker.isLoading ? "Listing…" : "\(picker.results.count) \(picker.product == .jira ? (picker.results.count == 1 ? "issue" : "issues") : (picker.results.count == 1 ? "space" : "spaces"))")
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
