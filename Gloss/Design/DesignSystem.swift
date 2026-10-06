import Core
import SwiftUI
import Viewers

/// The app's design language in code: one place for spacing, corner radii, motion, and the small components every
/// panel shares. See `docs/DESIGN.md` for the principles behind the numbers.
enum DS {
    /// A 4-point grid with a few named steps; prefer these over literals.
    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 6
        static let m: CGFloat = 10
        static let l: CGFloat = 14
        static let xl: CGFloat = 20
    }

    /// Small controls, cards, and sheets; corners grow with the surface.
    enum Radius {
        static let s: CGFloat = 4
        static let m: CGFloat = 8
        static let l: CGFloat = 12
    }

    /// Motion is quick and physical: snappy for direct feedback (hover, press), smooth for content that moves.
    /// See `Viewers.Motion`: the same curves, calmed when Reduce Motion is on.
    enum Motion {
        static var snappy: Animation { Viewers.Motion.snappy }
        static var smooth: Animation { Viewers.Motion.smooth }
        static var bouncy: Animation { Viewers.Motion.bouncy }
    }
}

// MARK: - Note semantics

extension NoteState {
    /// How a state reads at a glance: a symbol and a tint, used by pills, cards, and filters.
    var style: (symbol: String, tint: Color) {
        switch self {
        case .draft: ("circle.dashed", .secondary)
        case .sent: ("paperplane.fill", .blue)
        case .resolved: ("checkmark.circle.fill", .green)
        case .orphaned: ("exclamationmark.triangle.fill", .orange)
        }
    }
}

extension Note {
    /// The state a note's highlight is drawn with. A note the agent answered with a question is open work again,
    /// so it keeps a draft's strength instead of fading like a finished one.
    nonisolated var displayState: NoteState {
        state == .resolved && resolveOutcome == .needsInput ? .draft : state
    }
}

extension Core.Anchor {
    /// The kind of thing a note points at.
    var symbol: String {
        switch self {
        case .text(let anchor): anchor.cells == nil ? "text.alignleft" : "tablecells"
        case .image: "crop"
        case .pdf: "doc.richtext"
        case .wholeFile: "doc"
        case .element: "rectangle.dashed"
        case .embeddedImage: "photo"
        }
    }
}

extension NotesPanelModel.Filter {
    var symbol: String {
        switch self {
        case .all: "tray.full"
        case .drafts: NoteState.draft.style.symbol
        case .sent: NoteState.sent.style.symbol
        case .resolved: NoteState.resolved.style.symbol
        case .attention: NoteState.orphaned.style.symbol
        }
    }

    var tint: Color {
        switch self {
        case .all: .primary
        case .drafts: .primary
        case .sent: NoteState.sent.style.tint
        case .resolved: NoteState.resolved.style.tint
        case .attention: NoteState.orphaned.style.tint
        }
    }
}

extension NotesPanelModel.Sort {
    var symbol: String {
        switch self {
        case .position: "list.number"
        case .newest: "arrow.down.circle"
        case .oldest: "arrow.up.circle"
        case .color: "paintpalette"
        case .state: "circle.dashed"
        }
    }
}

// MARK: - Components

/// A segmented filter that shows every option's count and names only the selected one. The selection is a capsule
/// that slides between options (one shared geometry), so the eye follows the change instead of re-reading the row.
/// As the bar narrows it drops the selected title, then the counts (the selected option keeps its count, and an
/// urgent one with work waiting keeps an orange dot), so nothing ever wraps onto a second line (issue #7).
struct FilterBar<Option: Hashable & Identifiable>: View {
    /// How much each chip shows, widest first.
    enum Density {
        case titled, counted, symbols
    }

    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    let symbol: (Option) -> String
    let tint: (Option) -> Color
    let count: (Option) -> Int
    /// An option whose count means "this needs you" (Attention): a non-zero count shows in orange.
    var urgent: (Option) -> Bool = { _ in false }
    @Namespace private var capsule
    @State private var hovered: Option?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(.titled)
            row(.counted)
            row(.symbols)
        }
    }

    private func row(_ density: Density) -> some View {
        HStack(spacing: DS.Space.xxs) {
            ForEach(options) { option in
                chip(option, density: density)
            }
        }
        .padding(DS.Space.xxs + 1)
        .background(Color.primary.opacity(0.05), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06)))
        .animation(DS.Motion.smooth, value: selection)
    }

    private func chip(_ option: Option, density: Density) -> some View {
        let selected = option == selection
        let number = count(option)
        let showsCount = density != .symbols || selected
        return Button {
            selection = option
        } label: {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: symbol(option))
                    .imageScale(.small)
                    .foregroundStyle(selected ? tint(option) : Color.secondary)
                    .overlay(alignment: .topTrailing) {
                        // Work waiting where the count no longer shows.
                        if !showsCount, urgent(option), number > 0 {
                            Circle().fill(Color.orange).frame(width: 5, height: 5).offset(x: 3, y: -2)
                        }
                    }
                if selected, density == .titled {
                    Text(title(option))
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .fixedSize()
                        .transition((AnyTransition.opacity.combined(with: .scale(scale: 0.9, anchor: .leading))).calmed)
                }
                if showsCount {
                    Text("\(number)")
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(selected ? AnyShapeStyle(.primary)
                                         : number == 0 ? AnyShapeStyle(.tertiary)
                                         : urgent(option) ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                        .fontWeight(urgent(option) && number > 0 && !selected ? .bold : nil)
                        .contentTransition(.numericText(value: Double(number)))
                }
            }
            .font(.caption)
            .padding(.horizontal, density == .symbols ? DS.Space.s : DS.Space.s + 2)
            .padding(.vertical, DS.Space.xs)
            .frame(maxWidth: selected ? nil : .infinity)
            .background {
                if selected {
                    Capsule()
                        .fill(.background.shadow(.drop(color: .black.opacity(0.18), radius: 1.5, y: 0.5)))
                        .matchedGeometryEffect(id: "selection", in: capsule)
                } else if hovered == option {
                    Capsule().fill(Color.primary.opacity(0.06))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .help("\(title(option)): \(number)")
        .accessibilityLabel("\(title(option)), \(number)")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { hovered = $0 ? option : (hovered == option ? nil : hovered) }
        .animation(DS.Motion.snappy, value: hovered)
        .animation(DS.Motion.smooth, value: number)
    }
}

/// A compact status capsule: symbol plus label, tinted by meaning. The symbol carries the state for people who
/// cannot tell the tints apart.
struct StatusPill: View {
    let label: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label {
            Text(label)
        } icon: {
            Image(systemName: symbol).imageScale(.small)
        }
        .labelStyle(.titleAndIcon)
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, DS.Space.xxs)
        .foregroundStyle(tint)
        .background(tint.opacity(0.14), in: Capsule())
        .contentTransition(.interpolate)
    }
}

/// A quiet icon button for inline actions. It sits at reduced emphasis and brightens with its container's hover,
/// so a list of cards is calm until the pointer arrives; it is never hidden, so nothing has to be discovered.
struct InlineIconButton: View {
    let title: String
    let symbol: String
    var role: ButtonRole?
    var prominent = false
    var emphasized: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 20)
                .foregroundStyle(foreground)
                .background(background, in: RoundedRectangle(cornerRadius: DS.Radius.s + 1, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help(title)
        .accessibilityLabel(title)
        .onHover { hovering = $0 }
        .animation(DS.Motion.snappy, value: hovering)
    }

    private var foreground: Color {
        if role == .destructive, hovering { return .red }
        if prominent { return emphasized || hovering ? .white : .accentColor }
        return hovering ? .primary : (emphasized ? .secondary : Color.secondary.opacity(0.55))
    }

    private var background: Color {
        if prominent { return emphasized || hovering ? .accentColor : Color.accentColor.opacity(0.12) }
        return hovering ? Color.primary.opacity(0.08) : .clear
    }
}

/// Shrinks a touch while pressed; the feedback a physical button would give.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(DS.Motion.snappy, value: configuration.isPressed)
    }
}

/// A first-run or nothing-here screen that teaches instead of just reporting: a symbol that breathes twice, a title, one
/// sentence, up to three numbered steps that arrive one after another, and an optional action.
struct EmptyState<Actions: View>: View {
    struct Step: Identifiable {
        let id = UUID()
        let symbol: String
        let text: String
    }

    let symbol: String
    let title: String
    let message: String
    var steps: [Step] = []
    /// The symbol's colour; secondary unless the emptiness is good news ("All clear" in green).
    var tint: Color = .secondary
    @ViewBuilder var actions: Actions
    @State private var shown = 0

    var body: some View {
        VStack(spacing: DS.Space.l) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                // Twice on arrival, then still: a symbol that never stops keeps the app redrawing (and the CPU busy)
                // while nothing is happening.
                .symbolEffect(.breathe.plain, options: .repeat(2))
                .padding(.bottom, DS.Space.xs)
            VStack(spacing: DS.Space.xs) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if !steps.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        HStack(spacing: DS.Space.m) {
                            Text("\(index + 1)")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 20, height: 20)
                                .background(Color.primary.opacity(0.07), in: Circle())
                            Image(systemName: step.symbol)
                                .frame(width: 18)
                                .foregroundStyle(Color.accentColor)
                            Text(step.text)
                                .font(.callout)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .opacity(index < shown ? 1 : 0)
                        .offset(y: index < shown ? 0 : 6)
                    }
                }
                .padding(DS.Space.l)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous))
            }
            actions
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: 360)
        // Fill whatever space the pane has, but never ask the window for more.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .task {
            // Steps arrive in order, the way they happen.
            for index in steps.indices {
                try? await Task.sleep(for: .milliseconds(index == 0 ? 150 : 110))
                withAnimation(DS.Motion.smooth) { shown = index + 1 }
            }
        }
    }
}

extension EmptyState where Actions == EmptyView {
    init(symbol: String, title: String, message: String, steps: [Step] = []) {
        self.init(symbol: symbol, title: title, message: message, steps: steps) { EmptyView() }
    }
}

/// An in-context notice above content: what happened, why it matters, and what to do. Info is blue, a warning is
/// orange, a temporary mode (placing a note) is the accent colour with a pulsing symbol.
enum NoticeKind { case info, warning, mode }

struct Notice<Actions: View>: View {
    let kind: NoticeKind
    let symbol: String
    let title: String
    let detail: String
    var pulses = false
    @ViewBuilder var actions: Actions

    private var tint: Color {
        switch kind {
        case .info: .blue
        case .warning: .orange
        case .mode: .accentColor
        }
    }

    var body: some View {
        // Side by side when there is room; in a narrow pane (the sidebar) the actions move under the text so the
        // explanation is never cut short.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Space.m) {
                badge
                text(lines: 2)
                    .frame(minWidth: 220, alignment: .leading)
                Spacer(minLength: DS.Space.m)
                actionRow
            }
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(alignment: .top, spacing: DS.Space.m) {
                    badge
                    text(lines: 4)
                    Spacer(minLength: 0)
                }
                HStack {
                    Spacer(minLength: 0)
                    actionRow
                }
            }
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: DS.Radius.m + 2, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.m + 2, style: .continuous).strokeBorder(tint.opacity(0.25)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title). \(detail)")
    }

    private var badge: some View {
        Image(systemName: symbol)
            .font(.callout.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(tint.opacity(0.16), in: Circle())
            .symbolEffect(.pulse, options: .repeat(.continuous), isActive: pulses)
    }

    private func text(lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.callout.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(lines)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actionRow: some View {
        HStack(spacing: DS.Space.s) { actions }
            .controlSize(.small)
    }
}

extension View {
    /// Glass for a floating surface people read (a note peek, a toast with a sentence): a nearly opaque window-colour
    /// page under the glass, so busy content behind never crosses the words. Bare `glassEffect` is for controls.
    func readableGlass(in shape: some Shape) -> some View {
        background(Color(nsColor: .windowBackgroundColor).opacity(0.88), in: shape)
            .glassEffect(.regular, in: shape)
    }
}
