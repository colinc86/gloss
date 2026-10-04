import AppKit
import SwiftUI

/// Every keyboard shortcut in one place, grouped by where it works. Menu shortcuts are read from the menu bar itself,
/// so this window can never disagree with it; only keys that work in one place (the composer, a viewer, the folder
/// switcher) and have no menu item are listed by hand.
nonisolated struct ShortcutGroup: Identifiable {
    let title: String
    let symbol: String
    let items: [(action: String, keys: [String])]
    var id: String { title }

    /// Keys that work inside one view and have no menu item.
    static let contextual: [ShortcutGroup] = [
        ShortcutGroup(title: "Note composer", symbol: "text.bubble", items: [
            ("Save the note", ["↩"]),
            ("New line in a note", ["⇧", "↩"]),
            ("Cancel", ["esc"]),
        ]),
        ShortcutGroup(title: "Viewers", symbol: "photo", items: [
            ("Zoom in / out (images)", ["⌘", "=", "/", "⌘", "−"]),
            ("Actual size / fit (images)", ["⌘", "1", "/", "⌘", "0"]),
            ("Move between cells (spreadsheets)", ["←", "→", "↑", "↓"]),
            ("Extend the cell selection", ["⇧", "←", "→", "↑", "↓"]),
            ("Clear the selection", ["esc"]),
        ]),
        ShortcutGroup(title: "Folder switcher", symbol: "folder.badge.gearshape", items: [
            ("Move through folders", ["↑", "↓"]),
            ("Open or switch to it", ["↩"]),
        ]),
    ]

    private static let menuSymbols = ["File": "folder", "Edit": "pencil", "View": "sidebar.left", "Notes": "note.text",
                                      "Window": "macwindow", "Help": "questionmark.circle"]
    /// Edit commands every Mac app has; listing them would bury the app's own.
    private static let standardEdit: Set<String> = ["Undo", "Redo", "Cut", "Copy", "Paste", "Paste and Match Style",
                                                    "Delete", "Select All", "Emoji & Symbols", "AutoFill", "Start Dictation…"]

    /// The menu bar's shortcuts, one group per menu (the app menu left out), in menu order, submenus included.
    @MainActor
    static func fromMenu(_ menu: NSMenu) -> [ShortcutGroup] {
        menu.items.dropFirst().compactMap { top -> ShortcutGroup? in
            guard let submenu = top.submenu else { return nil }
            var items: [(action: String, keys: [String])] = []
            func collect(_ menu: NSMenu) {
                for item in menu.items where !item.isHidden && !item.isSeparatorItem {
                    if let submenu = item.submenu { collect(submenu); continue }
                    guard !item.keyEquivalent.isEmpty, !item.isAlternate, !(top.title == "Edit" && standardEdit.contains(item.title)),
                          !items.contains(where: { $0.action == item.title }) else { continue }
                    items.append((item.title, keys(for: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask)))
                }
            }
            collect(submenu)
            return items.isEmpty ? nil : ShortcutGroup(title: top.title, symbol: menuSymbols[top.title] ?? "command", items: items)
        }
    }

    /// A key equivalent as key caps, modifiers in Apple's order (⌃ ⌥ ⇧ ⌘); an uppercase letter implies ⇧.
    static func keys(for equivalent: String, modifiers: NSEvent.ModifierFlags) -> [String] {
        var caps: [String] = []
        let impliedShift = equivalent.count == 1 && equivalent.uppercased() == equivalent && equivalent.lowercased() != equivalent
        if modifiers.contains(.control) { caps.append("⌃") }
        if modifiers.contains(.option) { caps.append("⌥") }
        if modifiers.contains(.shift) || impliedShift { caps.append("⇧") }
        if modifiers.contains(.command) { caps.append("⌘") }
        let glyphs: [String: String] = ["\r": "↩", "\u{3}": "⌤", "\u{1b}": "esc", "\u{8}": "⌫", "\u{7f}": "⌫", "\t": "⇥", " ": "Space",
                                        "\u{F700}": "↑", "\u{F701}": "↓", "\u{F702}": "←", "\u{F703}": "→", "-": "−"]
        caps.append(glyphs[equivalent] ?? equivalent.uppercased())
        return caps
    }

    /// Groups whose actions or titles mention `query`; all of them when it is empty.
    static func filtered(_ query: String, in groups: [ShortcutGroup]) -> [ShortcutGroup] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return groups }
        return groups.compactMap { group in
            let items = group.items.filter { $0.action.lowercased().contains(needle) || group.title.lowercased().contains(needle) }
            return items.isEmpty ? nil : ShortcutGroup(title: group.title, symbol: group.symbol, items: items)
        }
    }
}

struct ShortcutsWindow: View {
    @State private var query = ""

    var body: some View {
        let all = (NSApp.mainMenu.map(ShortcutGroup.fromMenu) ?? []) + ShortcutGroup.contextual
        let groups = ShortcutGroup.filtered(query, in: all)
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search shortcuts", text: $query).textFieldStyle(.plain)
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous))
            .padding(DS.Space.l)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Space.l) {
                    if groups.isEmpty {
                        Text("No shortcut matches “\(query)”")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, DS.Space.xl)
                    }
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: DS.Space.xs) {
                            Label(group.title, systemImage: group.symbol)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.bottom, DS.Space.xxs)
                            ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                                HStack {
                                    Text(item.action)
                                    Spacer(minLength: DS.Space.l)
                                    HStack(spacing: 3) {
                                        ForEach(Array(item.keys.enumerated()), id: \.offset) { _, key in
                                            ShortcutKey(key)
                                        }
                                    }
                                }
                                .font(.callout)
                                .padding(.vertical, 3)
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
                .padding(DS.Space.l)
                .animation(DS.Motion.smooth, value: groups.map(\.id))
            }
        }
        .frame(width: 460, height: 560)
    }
}

/// A key drawn as a key cap: a little raised, the glyph centred, at least square.
private struct ShortcutKey: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        if key == "/" {
            // Between two alternatives, so ⌘= / ⌘− never reads as one four-key chord.
            Text("or").font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 3)
        } else {
            cap
        }
    }

    private var cap: some View {
        Text(key)
            .font(.system(size: 11.5, weight: .medium, design: .rounded))
            .frame(minWidth: 22, minHeight: 22)
            .padding(.horizontal, key.count > 1 ? DS.Space.xs : 0)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.18), radius: 0, y: 1)
            )
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
    }
}
