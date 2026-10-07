import AppKit
import Core
import SwiftUI
import Viewers

/// A field that opens what is typed into it: a web address, or a path on the machine chosen in the small menu at
/// its end (this Mac or an ssh host; for an address, whose loopback `localhost` means). Text that is neither
/// shakes the field and says so. Used by the window title and the explorer's Web section.
struct AddressField: View {
    @Environment(AppModel.self) private var model
    @Binding var text: String
    @Binding var host: HostID
    var focus: FocusState<Bool>.Binding
    var prompt = "Address or path"
    var font: Font = .body
    /// Called after the text opened something.
    var onOpen: () -> Void = {}
    /// Tried when the text is neither an address nor a path; true when it opened something (the Web section
    /// opens the first page its filter left).
    var fallback: () -> Bool = { false }
    /// The user picked the host in the menu, so even an outside page goes through it.
    @State private var chosen = false
    @State private var hint: String?
    @State private var shakes = 0

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: AddressInput.parse(text, home: model.home(of: host), folder: model.addressFolder(on: host)).map { if case .path = $0 { "folder" } else { "globe" } } ?? "globe")
                .foregroundStyle(.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 16)
            TextField("Address", text: $text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .font(font)
                .focused(focus)
                .onSubmit(submit)
                .onChange(of: text) { _, _ in hint = nil }
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity)
            }
            let remotes = model.hosts.entries.filter { $0.kind == .ssh }
            if !remotes.isEmpty || host != .local {
                Menu {
                    // Choosing a host leaves the caret in the field, ready for Return.
                    Picker("Open On", selection: Binding(get: { host }, set: { picked in
                        host = picked
                        chosen = true
                        focus.wrappedValue = true
                    })) {
                        Label("This Mac", systemImage: "desktopcomputer").tag(HostID.local)
                        ForEach(remotes) { entry in
                            Label(entry.name, systemImage: "network").tag(entry.id)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(host == .local ? "This Mac" : model.hosts.entry(for: host)?.name ?? "This Mac")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(host == .local ? Color.secondary : Color.teal)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                .focusable(false)
                .help("Where a path is opened, and whose loopback localhost means: this Mac, or an ssh host through the app's connection to it")
                .accessibilityLabel("Open on")
                .accessibilityValue(host == .local ? "This Mac" : model.hosts.entry(for: host)?.name ?? "")
            }
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.xs)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous).strokeBorder(hint == nil ? Color.clear : Color.orange.opacity(0.6)))
        .keyframeAnimator(initialValue: CGFloat(0), trigger: shakes) { content, offset in
            content.offset(x: offset)
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(-6, duration: 0.05)
                CubicKeyframe(6, duration: 0.07)
                CubicKeyframe(-4, duration: 0.07)
                CubicKeyframe(3, duration: 0.06)
                CubicKeyframe(0, duration: 0.05)
            }
        }
        .animation(DS.Motion.snappy, value: hint)
    }

    private func submit() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if model.openAddress(text, on: host, chosen: chosen) || fallback() {
            hint = nil
            onOpen()
        } else {
            hint = "Not an address or a path"
            if !Motion.isReduced { shakes += 1 }
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [.announcement: "Not an address or a path", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }
}

/// The window's title, which is also its address bar: the document's name and where it lives at rest; a click
/// (or File › Open Location…, ⇧⌘L) turns it into a field holding the page's address or the file's path. Return
/// opens what was typed, Escape or a click elsewhere puts the title back.
struct TitleAddressBar: View {
    @Environment(AppModel.self) private var model
    @State private var editing = false
    @State private var draft = ""
    @State private var host: HostID = .local
    @State private var hovering = false
    /// A menu is open (the field's host menu, or the menu bar): the field keeps editing while it is.
    @State private var menuOpen = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                AddressField(text: $draft, host: $host, focus: $focused, prompt: "Web address or path", onOpen: { editing = false })
                    .frame(width: 460)
                    .onExitCommand { editing = false }
                    .onAppear { focused = true }
                    .onChange(of: focused) { _, isFocused in
                        guard !isFocused else { return }
                        // A click elsewhere puts the title back; opening the host menu takes focus a moment before
                        // the menu says it is tracking, so wait that moment out first.
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(200))
                            if !focused, !menuOpen { editing = false }
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .leading)))
            } else {
                label
                    .transition(.opacity)
            }
        }
        .animation(DS.Motion.snappy, value: editing)
        .onChange(of: model.addressFocusRequest) { _, _ in begin() }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in menuOpen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            menuOpen = false
            // Back to the field after the host menu (or a menu bar command) closes, picked or not.
            if editing { focused = true }
        }
    }

    private var label: some View {
        let session = model.activeSession
        let subtitle = session.map { ContentView.subtitle(for: $0, hosts: model.hosts) } ?? ""
        return Button(action: begin) {
            VStack(alignment: .leading, spacing: 0) {
                Text(session?.fileName ?? "Gloss")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: 420, alignment: .leading)
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, DS.Space.xxs)
            .background(hovering ? Color.primary.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DS.Motion.snappy, value: hovering)
        .help(session == nil ? "Open a web address or a path (⇧⌘L)" : "Click to type another address or path (⇧⌘L)")
        .accessibilityLabel(session.map { [$0.fileName, subtitle].filter { !$0.isEmpty }.joined(separator: ", ") } ?? "Gloss")
        .accessibilityHint("Opens the address field")
    }

    private func begin() {
        draft = Self.address(of: model.activeSession, model: model)
        host = model.addressHost
        editing = true
        focused = true
    }

    /// What the field starts with: the page's address as shown (after redirects and in-page navigation), a file's
    /// path, or a pull request's, issue's or page's web address.
    static func address(of session: DocumentSession?, model: AppModel) -> String {
        guard let session else { return "" }
        if DocumentKindDetector.isWebURL(session.path) {
            if let html = session.html, model.browser.current === html, let shown = model.browser.displayedURL { return shown.absoluteString }
            return session.path
        }
        if session.hostID.isVirtual { return model.webURL(hostID: session.hostID, path: session.path)?.absoluteString ?? "" }
        return session.path
    }
}
