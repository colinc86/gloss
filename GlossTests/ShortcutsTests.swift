import AppKit
import Testing
@testable import Gloss

@MainActor
struct ShortcutsTests {
    private func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        items.forEach(submenu.addItem)
        top.submenu = submenu
        return top
    }

    private func item(_ title: String, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    @Test func menuShortcutsComeFromTheMenuBarItself() {
        let bar = NSMenu()
        bar.addItem(menu("Gloss", [item("Settings…", ",")]))
        bar.addItem(menu("Edit", [item("Copy", "c"), item("Find…", "f")]))
        bar.addItem(menu("Notes", [item("Next Note", "'"), item("Previous Note", "'", [.command, .shift]),
                                   item("Send Drafts in Document", "\r"), NSMenuItem.separator(), item("No Key", "")]))
        let groups = ShortcutGroup.fromMenu(bar)
        #expect(groups.map(\.title) == ["Edit", "Notes"], "the app menu is left out")
        #expect(groups[0].items.map(\.action) == ["Find…"], "standard Edit commands are not listed")
        let notes = groups[1].items
        #expect(notes.map(\.action) == ["Next Note", "Previous Note", "Send Drafts in Document"])
        #expect(notes[1].keys == ["⇧", "⌘", "'"])
        #expect(notes[2].keys == ["⌘", "↩"])
    }

    @Test func keyCapsFollowApplesModifierOrder() {
        #expect(ShortcutGroup.keys(for: "o", modifiers: [.command, .shift, .option, .control]) == ["⌃", "⌥", "⇧", "⌘", "O"])
        #expect(ShortcutGroup.keys(for: "O", modifiers: .command) == ["⇧", "⌘", "O"], "an uppercase letter implies shift")
        #expect(ShortcutGroup.keys(for: "\u{F700}", modifiers: [.control, .command]) == ["⌃", "⌘", "↑"])
    }

    @Test func searchKeepsMatchingActionsAndWholeGroupsByTitle() {
        let groups = ShortcutGroup.contextual
        #expect(ShortcutGroup.filtered("", in: groups).count == groups.count)
        let zoom = ShortcutGroup.filtered("zoom", in: groups)
        #expect(zoom.flatMap { $0.items.map(\.action) } == ["Zoom in / out (images, PDFs, pages)"])
        #expect(ShortcutGroup.filtered("viewers", in: groups).first?.items.count == groups.first { $0.title == "Viewers" }?.items.count)
        #expect(ShortcutGroup.filtered("zzz", in: groups).isEmpty)
        #expect(ShortcutGroup.filtered("delete", in: groups).map(\.title) == ["Notes panel"], "the notes list's own keys are listed")
        #expect(ShortcutGroup.filtered("pick", in: groups).first?.items.count == 2)
    }
}
