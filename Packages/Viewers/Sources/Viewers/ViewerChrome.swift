import SwiftUI

/// The strip above every viewer: what you are looking at on the leading side, how to look at it on the trailing
/// side. One height, one type size, one set of controls, whatever the file type.
public struct ViewerToolbar<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    public init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) { leading }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 8) { trailing }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// A two-or-more way switch with a capsule that slides to the chosen option. Each option has a symbol and a title.
public struct ModeSwitch<Option: Hashable>: View {
    public struct Item {
        let value: Option
        let title: String
        let symbol: String
        public init(_ value: Option, _ title: String, symbol: String) {
            self.value = value
            self.title = title
            self.symbol = symbol
        }
    }

    let items: [Item]
    @Binding var selection: Option
    @Namespace private var thumb
    @State private var hovered: Option?

    public init(_ items: [Item], selection: Binding<Option>) {
        self.items = items
        _selection = selection
    }

    /// Titles beside the symbols when the bar has room; symbols alone (titles in the tooltip) when it is tight.
    public var body: some View {
        ViewThatFits(in: .horizontal) {
            row(compact: false)
            row(compact: true)
        }
    }

    private func row(compact: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.value) { item in
                let selected = item.value == selection
                Button {
                    selection = item.value
                } label: {
                    Label(item.title, systemImage: item.symbol)
                        .labelStyle(TitleOptionalLabelStyle(showsTitle: !compact))
                        .font(.caption.weight(selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(.background.shadow(.drop(color: .black.opacity(0.18), radius: 1.5, y: 0.5)))
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            } else if hovered == item.value {
                                Capsule().fill(Color.primary.opacity(0.06))
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? item.value : (hovered == item.value ? nil : hovered) }
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityLabel(item.title)
                .help(compact ? item.title : "")
            }
        }
        .fixedSize()
        .padding(2)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .animation(Motion.smooth, value: selection)
        .animation(Motion.snappy, value: hovered)
    }
}

/// Related controls sharing one capsule (zoom out, level, zoom in), separated by hairlines.
public struct ToolGroup<Content: View>: View {
    @ViewBuilder var content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: 0) { content }
            .buttonStyle(ToolButtonStyle())
            .padding(.horizontal, 2)
            .frame(height: 24)
            .background(Color.primary.opacity(0.06), in: Capsule())
    }
}

/// A divider for inside a `ToolGroup`.
public struct ToolDivider: View {
    public init() {}
    public var body: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 12)
    }
}

/// Compact buttons for tool groups: a soft fill under the pointer, a slight press.
public struct ToolButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        ToolButtonBody(configuration: configuration)
    }

    private struct ToolButtonBody: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.caption.weight(.medium))
                .foregroundStyle(isEnabled ? (hovering ? Color.primary : Color.secondary) : Color.secondary.opacity(0.4))
                .padding(.horizontal, 7)
                .frame(minWidth: 24, minHeight: 20)
                .background(hovering && isEnabled ? Color.primary.opacity(0.08) : .clear, in: Capsule())
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .animation(Motion.snappy, value: hovering)
                .animation(Motion.snappy, value: configuration.isPressed)
        }
    }
}

/// One hint in a viewer toolbar: a symbol or key caps, then a few words ("⇧ ↓ Extend", "Click a cell").
public struct ToolHint: Hashable, Sendable {
    public var symbol: String?
    public var keys: [String]
    public var text: String
    /// The whole sentence, for the tips card where there is room ("Click a column header to select the column").
    public var explained: String?

    public init(symbol: String? = nil, keys: [String] = [], _ text: String, explained: String? = nil) {
        self.symbol = symbol
        self.keys = keys
        self.text = text
        self.explained = explained
    }
}

/// Quiet how-to hints at a toolbar's trailing edge, most important first. Only the first `inline` show in the bar;
/// the rest wait behind a small "?" that opens them all as a card, so the bar teaches the next step without becoming a
/// wall of grey text. When the bar is narrow, hints drop from the end rather than truncating mid-sentence.
public struct ToolHints: View {
    let hints: [ToolHint]
    let inline: Int
    @State private var showsAll = false

    public init(_ hints: [ToolHint], inline: Int = 2) {
        self.hints = hints
        self.inline = inline
    }

    public var body: some View {
        let shown = Array(hints.prefix(inline))
        HStack(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                ForEach(Array(stride(from: shown.count, through: 1, by: -1)), id: \.self) { count in
                    row(Array(shown.prefix(count)))
                }
                Color.clear.frame(width: 0, height: 0)
            }
            if hints.count > inline {
                MoreHintsButton(isPresented: $showsAll)
                    .popover(isPresented: $showsAll, arrowEdge: .bottom) { HintsCard(hints: hints) }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func row(_ shown: [ToolHint]) -> some View {
        HStack(spacing: 12) {
            ForEach(shown, id: \.self) { hint in
                HintLabel(hint: hint).fixedSize()
            }
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
}

/// A hint's symbol or key caps, then its words.
private struct HintLabel: View {
    let hint: ToolHint
    var explained = false

    var body: some View {
        HStack(spacing: 4) {
            if let symbol = hint.symbol {
                Image(systemName: symbol).imageScale(.small)
            }
            ForEach(hint.keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 16, minHeight: 15)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.primary.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            }
            Text(explained ? hint.explained ?? hint.text : hint.text)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The "?" after the inline hints.
private struct MoreHintsButton: View {
    @Binding var isPresented: Bool
    @State private var hovering = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .imageScale(.medium)
                .foregroundStyle(hovering || isPresented ? Color.secondary : Color.secondary.opacity(0.6))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.snappy, value: hovering)
        .help("All the ways to work here")
        .accessibilityLabel("More tips")
    }
}

/// Every hint, one per line: the card behind "?".
private struct HintsCard: View {
    let hints: [ToolHint]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tips")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(hints, id: \.self) { hint in
                HintLabel(hint: hint, explained: true)
                    .font(.callout)
                    .foregroundStyle(.primary)
            }
        }
        .padding(14)
        .frame(minWidth: 200, alignment: .leading)
    }
}

/// `.titleAndIcon` or `.iconOnly`, chosen at run time (the two built-in styles are different types).
struct TitleOptionalLabelStyle: LabelStyle {
    let showsTitle: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            if showsTitle { configuration.title }
        }
    }
}

/// A brief "Copied" at the toolbar's trailing edge after each copy, so ⌘C is never a silent act. It springs in,
/// holds for 1.2 s, and fades; a new copy restarts it.
public struct CopiedBadge: View {
    let count: Int
    @State private var visible = false
    /// The count when the badge appeared: a viewer rebuilt after switching files is not a new copy.
    @State private var seen: Int?

    public init(count: Int) { self.count = count }

    public var body: some View {
        ZStack {
            if visible {
                Label("Copied", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.12), in: Capsule())
                    .transition((AnyTransition.scale(scale: 0.85).combined(with: .opacity)).calmed)
                    .accessibilityLabel("Copied")
            }
        }
        .animation(Motion.bouncy, value: visible)
        .onAppear { if seen == nil { seen = count } }
        .task(id: count) {
            guard let seen, count > seen else { return }
            visible = true
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            visible = false
        }
    }
}

/// What a find bar searches: a viewer with no find bar of its own (a web page, a PDF).
@MainActor
public protocol FindBarModel: AnyObject, Observable {
    var findText: String { get set }
    /// The last search found nothing.
    var findMissed: Bool { get }
    /// The next (or previous) match, wrapping at either end, case aside; the viewer selects it and scrolls to it.
    func find(backwards: Bool) async
    func endFind()
}

/// Find in a viewer: a field under its toolbar that searches as it is typed. Return finds the next match,
/// Shift-Return the previous, Escape or Done closes it.
struct FindBar<Model: FindBarModel>: View {
    @Bindable var model: Model
    let prompt: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $model.findText)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit {
                    let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                    Task { await model.find(backwards: backwards) }
                }
                .onChange(of: model.findText) { _, _ in Task { await model.find(backwards: false) } }
            if model.findMissed {
                Text("Not found")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .transition(.opacity)
            }
            ToolGroup {
                Button { Task { await model.find(backwards: true) } } label: { Image(systemName: "chevron.up") }
                    .help("Previous match (⇧⌘G)")
                    .accessibilityLabel("Previous match")
                Button { Task { await model.find(backwards: false) } } label: { Image(systemName: "chevron.down") }
                    .help("Next match (⌘G)")
                    .accessibilityLabel("Next match")
            }
            .disabled(model.findText.isEmpty)
            Button("Done") { model.endFind() }
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .animation(Motion.snappy, value: model.findMissed)
        .onAppear { focused = true }
        .onExitCommand { model.endFind() }
    }
}

/// The find actions a viewer that answers Edit › Find itself handles, from a menu item's tag.
enum FindMenuAction {
    static let handled: Set<NSTextFinder.Action> = [.showFindInterface, .nextMatch, .previousMatch, .hideFindInterface]

    static func action(of sender: Any?) -> NSTextFinder.Action? {
        guard let tag = (sender as? any NSValidatedUserInterfaceItem)?.tag, let action = NSTextFinder.Action(rawValue: tag),
              handled.contains(action) else { return nil }
        return action
    }
}

/// Zoom out, the zoom level (a click goes to actual size), zoom in, and Fit, with ⌘−, ⌘1, ⌘=, ⌘0: the image viewer's,
/// the PDF viewer's and a web page's (without Fit) alike.
struct ZoomControls: View {
    let magnification: CGFloat
    /// Nil leaves Fit out (a web page has nothing to fit).
    let fitHelp: String?
    let zoom: (ImageViewerController.ZoomCommand) -> Void

    var body: some View {
        ToolGroup {
            Button { zoom(.zoomOut) } label: { Image(systemName: "minus") }
                .keyboardShortcut("-", modifiers: [.command])
                .help("Zoom out")
                .accessibilityLabel("Zoom out")
            ToolDivider()
            Button { zoom(.actualSize) } label: {
                Text("\(Int((magnification * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(minWidth: 38)
                    .contentTransition(.numericText(value: magnification))
            }
            .keyboardShortcut("1", modifiers: [.command])
            .help("Actual size")
            ToolDivider()
            Button { zoom(.zoomIn) } label: { Image(systemName: "plus") }
                .keyboardShortcut("=", modifiers: [.command])
                .help("Zoom in")
                .accessibilityLabel("Zoom in")
                // ⌘+ too, as most people press it (⌘⇧= on a US keyboard), and where `+` is a key of its own
                // (German, Swiss) ⌘= needs Shift: an invisible twin that takes no room and isn't read out.
                .background {
                    Button("") { zoom(.zoomIn) }
                        .keyboardShortcut("+", modifiers: [.command])
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
        }
        .animation(Motion.snappy, value: magnification)
        if let fitHelp {
            ToolGroup {
                Button { zoom(.fit) } label: {
                    ViewThatFits(in: .horizontal) {
                        Label("Fit", systemImage: "arrow.down.right.and.arrow.up.left").fixedSize()
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                    }
                }
                .accessibilityLabel("Fit")
                .keyboardShortcut("0", modifiers: [.command])
                .help(fitHelp)
            }
        }
    }
}

/// "Add Note" at the head of a text view's context menu while text is selected, beside the floating button and ⌘↩
/// (a right-click is where many look first).
enum AddNoteMenuItem {
    static let identifier = NSUserInterfaceItemIdentifier("GlossAddNote")

    /// Text views hand back the same menu each time: an item put there for an earlier selection comes out first.
    static func insert(into menu: NSMenu, selection: NSRange, target: AnyObject, action: Selector) {
        insert(into: menu, when: selection.length > 0, target: target, action: action)
    }

    /// The same for any viewer: the item leads the menu while `offered` (something is selected that a note can be on).
    static func insert(into menu: NSMenu, when offered: Bool, target: AnyObject, action: Selector) {
        if let index = menu.items.firstIndex(where: { $0.identifier == identifier }) {
            menu.removeItem(at: index)
            if index < menu.items.count, menu.items[index].isSeparatorItem { menu.removeItem(at: index) }
        }
        guard offered else { return }
        let item = NSMenuItem(title: "Add Note", action: action, keyEquivalent: "")
        item.identifier = identifier
        item.target = target
        item.image = NSImage(systemSymbolName: "note.text.badge.plus", accessibilityDescription: nil)
        menu.insertItem(.separator(), at: 0)
        menu.insertItem(item, at: 0)
    }
}

/// Add Note from a viewer's context menu, as the app offers it: whether the selection takes a note now (the floating
/// button would show) and how to start one. Set by the app on each viewer's controller; nil offers none.
public struct AddNoteHook {
    public var canAdd: () -> Bool
    public var add: () -> Void

    public init(canAdd: @escaping () -> Bool, add: @escaping () -> Void) {
        self.canAdd = canAdd
        self.add = add
    }
}
