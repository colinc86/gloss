# Gloss design language

A reading-and-annotating tool sits beside an editor and a terminal all day. It should feel calm when you are reading
and precise when you act. These rules are implemented in `Gloss/Design/DesignSystem.swift` (`DS`); use
the tokens and components there instead of literals.

## Principles

1. **Content first, chrome quiet.** Files and notes carry the color and weight; controls sit back until the
   pointer or the selection arrives, then brighten. Nothing is hidden that has to be discovered: quiet, not absent.
2. **One meaning, one look.** A note state always shows the same symbol and tint (`NoteState.style`) in pills,
   filters, and highlights. Symbols carry meaning for people who cannot tell the tints apart.
3. **Open work leads.** Drafts and questions from agents stand at full contrast; everything else steps back (#12).
   In text a draft fills its words; a sent note is only a solid underline in its color, a resolved one a faint
   dotted underline, an orphan a dashed one (`Theme.mark`). Every other surface uses one ladder (`Theme.strength`:
   draft 1, sent 0.55, resolved 0.3): gutter bars, minimap marks, image and PDF regions, spreadsheet rows, a web page's
   element boxes, and the paths. The note under the pointer, or whose card is selected, fills again whatever its
   state, so it can always be found.
4. **The next step is obvious.** Each surface emphasizes one primary action (a draft's Send) and keeps the rest
   secondary.
5. **Motion explains change.** Animate what moved or changed state, briefly; never decorate.
6. **Native first.** System materials, SF Symbols, system colors (light and dark), continuous corners, standard
   controls where they exist. Custom views only where the system has none.
7. **Code stays code.** Wherever a file's text is quoted (the composer, note cards, search results, the Go to Line
   preview, rendered markdown), code keeps the editor's syntax colors
   (`SyntaxTheme.highlighted`, worked out once, never per redraw); a command people copy, or a card's excerpt,
   stays on one line rather than wrapping mid-token. Prose stays plain: a lone markdown line out of context colors as noise. The one exception is a diff,
   where color already means added and removed.
8. **Glass for controls, a page for reading.** Bare `glassEffect` is for controls floating over content (buttons,
   pills, the Add Note button). A floating surface people read (a peek, a toast with a sentence) uses
   `readableGlass`, so the content behind never crosses its words.
9. **Empty says why.** An empty view names what made it empty (the search, the color, the tab), says what belongs
   there and how it arrives, and offers the one way back. Emptiness that is good news says so ("All clear").
10. **Say what a risky action touches.** Where the app writes outside itself (hooks, settings files), the screen
    says what changes, where the backup goes, and how to undo it, before anything is pressed.
11. **The app reads, the agent writes.** What the app shows of a pull request, a ticket or a page is the live
    thing, read with the user's own key, and the app never changes it: every edit goes through the agent with its
    own tools, and the packet names the exact resource (URL, head commit, field, version) so the agent can. Settings
    say this where the key is entered. Shared reviews are the exception for Gloss's own data: it writes captured
    content and explicitly published notes to `.gloss`, never into the original source.

## Tokens

| Token | Values | Use |
| --- | --- | --- |
| `DS.Space` | 2 · 4 · 6 · 10 · 14 · 20 | 4-point grid: `xs`/`s` inside a component, `m` between parts, `l`/`xl` between groups |
| `DS.Radius` | 4 · 8 · 12 | small controls, cards, sheets; continuous style |
| `DS.Motion.snappy` | 0.18 s | hover, press, toggles: direct feedback |
| `DS.Motion.smooth` | 0.28 s | content that moves or changes state |
| `DS.Motion.bouncy` | 0.35 s | rare: something arriving that deserves attention |

`DS.Motion` forwards to `Viewers.Motion`, so the app and the viewer package share one set of curves; never write a
raw `.smooth(duration:)` or `.snappy(duration:)`. When Reduce Motion is on (System Settings > Accessibility >
Display) all three become a 0.12 s ease with no spring or overshoot, the Add Note button fades instead of springing
out of the selection, and `Motion.allowsLooping` is false, so a working agent's dot stops pulsing and relies on its
color. Every transition that slides, grows, or offsets a view is written `.transition(AnyTransition….calmed)`:
with Reduce Motion it becomes a plain fade, so toasts, banners, bubbles, and the thumbnail column arrive in place
instead of traveling (Apple's guidance: replace motion, don't just shorten it). Never write a moving transition
without `.calmed`. Tests set `Motion.reducedOverride`.

## Type

UI typography stays system: body text `.callout` in panels; metadata `.caption` medium, monospaced digits for
line numbers; pills `.caption2` semibold. Secondary information uses `.secondary`, never a smaller size alone.
Code pages and rendered code blocks use the active syntax theme's optional font family, size and token traits
(2026-10-13); an unset size uses Editor's Default code font size. Gloss keeps its existing source font and its
normally 13 pt rendered fences. Rendered prose keeps its own font; inline code uses the theme family at its
prose-relative size. Quoted code in UI surfaces keeps UI sizing. Themes never change the chrome's typography.

## Accessibility

- **A composite reads as one sentence, and says what the screen shows.** A closed note card without fields or choices
  is a single VoiceOver element:
  "Draft note, yellow, Line 9. On: var isSteep: Bool { … }. Use 10%." The "On:" part is the excerpt well a sighted
  reader sees; the agent's turn is worded as the bubble words it ("Agent asks:" for a question, "Agent replied:"
  otherwise). When something visible is added to a card, its spoken summary gains it too. Its buttons and context-menu commands are its
  accessibility actions, built from the same `commands` builder as the menu so the two can't drift.
- **Every mark that carries meaning is spoken.** Tree rows add their note count, "needs attention", "open notes
  inside" for folders, and "contains the open file" for the path dot (`FileCellView.spokenLabel`).
- **Selected options say so** (`.isSelected` on filter chips, mode switches, swatches); icon-only buttons have
  labels as well as tooltips; color never carries meaning alone (state symbols beside tints).
- **Focus starts in the content, and focus rings are never hidden.** With keyboard navigation on (System Settings ›
  Keyboard), every control shows a ring when it has focus; that ring is how people who use the keyboard know where
  they are, so nothing suppresses it (no `.focusEffectDisabled()`, no `.focusable(false)` on controls people use).
  What matters is where focus starts: the main window gives it to the file tree (`TreeOutlineView`), popovers
  with a field focus the field. Tab order in the main window (checked with an `AXFocusedUIElement` probe, 2026-10-03): file
  tree, its filter field, Find in Files, hidden files, host picker, follow, sidebar toggle, notes toggle, the
  viewer's content, the filter chips (one stop each), notes search, sort, agent chip, Send menu, the notes list,
  then the folder switcher. Every control is reachable; a change that adds or groups stops re-checks this order.
  Since 2026-10-07 the host picker is part of the folder switcher and follow sits at its left, both above the
  tree rather than in the sidebar's toolbar; the order has not been re-checked since.
- **A question's choices stay reachable** (2026-10-12). Its spoken summary names the agent, the question and
  "waiting for your answer", as the bubble does; the choice group says "Choose one" or "Choose any that apply",
  and each radio button or checkbox speaks its label and whether it is selected. The group, answer field and
  actions are reachable inside the card, rather than swallowed by its composite summary. A staged answer says
  "Not sent"; an edited one says "Custom answer · Not sent" and keeps its words. Space chooses the focused
  option, Tab moves on, and every focus ring stays visible. A question arriving never takes focus, and the full
  panel and compact tray offer the same controls and labels.

- **Refinement says whose turn it is** (2026-10-12). Its notice speaks the document, round, waiting-question
  count or the agent's turn, and the completion summary. Updates announce the change without moving focus. End
  Refinement remains reachable at narrow widths. The new stops need a live check of the window's tab order in
  both layouts; the notice uses `DS.Motion` and `.calmed` transitions so Reduce Motion keeps the change without
  travel or pulsing.

- Check with the accessibility API (an `AXUIElement` walk), since System Events does not reach into SwiftUI lists.

## Window and layout

- **Opening the notes panel makes room first.** Like Xcode's inspector, the panel grows the window by its 300 pt
  (capped at the screen) before it appears unless the window already has that slack over its minimum, so a window saved narrow while the panel was closed
  can't leave sidebar + viewer + panel impossible to fit (`NotesPanelRoom`; that state crashed AppKit at launch). The resize animates (0.2 s, none with Reduce Motion) outside SwiftUI's update and the panel appears when it ends;
  if the screen stops the window short of room, the panel stays closed with a beep rather than opening into an
  impossible layout.
- **Back and Forward** (issue #3): two chevrons at the toolbar's leading edge (`.navigation`), as Safari and Xcode
  place them, stepping through the documents shown across folders and hosts (Go › Back ⌃⌘←, Forward ⌃⌘→; ⌘[ and
  ⌘] stay with the review browser's own history). A click takes one step; the chevron's menu lists the ten nearest
  places, file name over its folder (and host when not this Mac), to jump several. Disabled at either end.
- **Controls compact before they clip.** A `ModeSwitch` drops its titles for symbols (titles move to tooltips and
  stay the VoiceOver labels) and the image viewer's Fit becomes its symbol when the toolbar is tight
  (`ViewThatFits`). Avoid ViewThatFits in the window toolbar itself: a label that changes shape there changed the
  split view's minimum size mid-layout.
- Minimum window widths with the notes panel open (sidebar at its smallest): about 1020 pt for text, 1100 pt for
  the richest viewer toolbars; below the compact width the window takes the compact layout instead.
- **Compact layout** (2026-10-11, `LayoutModel`): measured from the window's content width (`onGeometryChange`, never
  `NSWindow.minSize`), compact below Settings' width (1000 pt) and full again 40 pt past it. The split view's sidebar
  column is hidden (`.detailOnly`) and the explorer lives in a 300 pt slide-over from the leading edge (regular
  material, a hairline and a soft shadow, a 12% scrim over the document) that the sidebar button and ⌃⌘S open; it
  stays built while compact so its folders keep their state. The inspector is replaced by `NotesTray` under the
  document (`.bar` material, a hairline above): closed, a 36 pt row with the note in hand (color rail, anchor,
  first line, its pill), ‹ "3 of 8" › over the panel's listed notes (wrapping), Send (prominent, with the count) and
  a chevron; open, a grab handle (resize cursor, a chevron to close) over the whole `NotesPanel`, 200 pt to 60% of
  the window, the height kept once the drag ends. The toolbar keeps its items and shape; the Notes button opens and
  closes the tray. Show Paths to Notes is off while compact. Settings › General › Layout: Layout (Automatic, Always
  Compact, Always Full), Go compact below (a stepper, 800–1400 pt by 50), Notes in the compact layout (Start as a
  bar, Start open), Put the explorer away after opening a file; View › Layout is the same choice.

## App icon

The whole icon is the page: a sheet of glass with four lines of text, one of them a draft note, drawn the way the app
draws one (a filled band behind the line, nothing beside it). The bundled icon is **graphite yellow**, a dark smoked
sheet with a yellow note. `Gloss/AppIcon.icon` is an Icon Composer document whose layers are glass, so macOS 26 draws
its default, dark, clear and tinted looks itself.

Every style comes from one generator, `docs/icon/make-variants.swift`, which writes an Icon Composer document per
style into `docs/icon/variants/`: frost (light glass) and graphite in each of the six note colors, and four fun ones
(starburst, blueprint, rainbow, pixel). To change a style, edit the generator, run
`swift docs/icon/make-variants.swift docs/icon/variants`, and copy the chosen document's contents into
`Gloss/AppIcon.icon` for the bundled icon. The README's `docs/media/icon.png` is the bundled icon's 256 px render
(`actool` the `.icon`, then `iconutil -c iconset` the `.icns`). After a rebuild the Dock may keep the old icon until
the bundle is touched and re-registered with `lsregister -f`.

**Settings › General › App Icon** offers every style. macOS has no alternate app icons, so a pick other than Graphite
Yellow is `NSApplication.applicationIconImage`: the Dock and the app switcher while Gloss runs, a flat picture that
doesn't follow the Mac's dark, tinted or clear icon style. Graphite Yellow sets it back to nil, so the system draws the
bundled `.icon`. Finder, Launchpad and the Dock while Gloss is closed always show the bundled icon; changing those
would mean writing into the signed bundle. The pictures are 512 px renders of each style in
`Gloss/Assets.xcassets/AppIconStyles`, made by `docs/icon/render-styles.sh` (Icon Composer's `ictool`); the Dock image
sets one into the standard grid (824 of 1024, with a shadow). **Match light and dark mode** (2026-10-11), a switch at the
top of the section, keeps two picks, any of the 16: a segmented Light | Dark control says which one a click sets, and
the two picks carry a small sun or moon badge on a material capsule at their corner so both show at once. Gloss
swaps the Dock picture whenever the app's appearance changes (KVO on `NSApp.effectiveAppearance`, so `--appearance`
counts), drawing even Graphite Yellow as its picture while matching, so the Mac's icon style doesn't decide for it.
Turned on the first time, it starts from the color already picked: Frost for light, Graphite for dark.

The About panel is the standard one with credits (`AboutPanel`): one line on what the app does, in label color,
then what it is built on, smaller and secondary.

## Dock

The Dock icon badges the number of notes an agent answered with a question (resolved, needs input), plus results
waiting for your review in every folder: the app usually sits behind the agent's terminal, and a question waiting on
you should be visible from there, as unread mail is.
Drafts don't count (they are your own unsent work). Settings › General can turn it off. Right-clicking the Dock icon
offers the next step from anywhere: "2 Questions from Agents…" (brings the window forward with the notes panel on
Resolved) when there are any, then the five most recent folders on this Mac.

## Menus

Every command is in a menu, so the app can be learned by reading them. Custom items carry the same SF Symbol the
UI uses for the action (paper plane to send, check to resolve, scope to reveal) as a `Label` with
a `Label`, and macOS decides whether to show it (macOS 27 typically hides menu images; the app follows the
platform there rather than forcing icons on). AppKit menus
(the file tree's context menu) set `NSMenuItem.image` too, but leave `preferredImageVisibility` at its default:
macOS 27 decides when menu images show and typically hides them, and the app follows the platform there rather
than forcing icons on. Replacing a
standard group must keep its standard items (replacing the save group took Close with it; Close Window is back on
⌘W). Menu items are title case and say how much they touch: "Send Shown Drafts in This Location (5)", "Copy This Document's
Drafts as Packet (2)", disabled when there is nothing to act on or no agent to send to. Window tabbing is off (`NSWindow.allowsAutomaticWindowTabbing`), since the folder switcher does that job.
The menus follow Apple's menu bar order and roles (2026-10-11): **File** opens (Open Folder, Open Quickly, Open
Location, Open Pull Request, Open Jira Issue or Confluence Page), closes and saves; **Edit** keeps the system's items
and its Find submenu for the file in front, followed by finding across files (Find in Files ⇧⌘F, Filter Files ⌥⌘J,
Search Notes); **View** shows and hides (Show Sidebar from `SidebarCommands`, Show/Hide Notes Panel ⌥⌘N, Show Source /
Show Rendered ⇧⌘M), then the checkmarked filters (Show Hidden Files, Show Resolved Notes, Separate Resolved Notes,
Show Paths to Notes, Show Earlier Notes), then Refresh Explorer ⌘R; **Go** moves (Back, Forward, Go to Line…, Reveal
in Explorer, Next/Previous Note, Next/Previous Change, Follow Herdr, Follow Page in Notes Panel); **Notes** makes,
sends and reviews notes, ending with an Iteration submenu (New Iteration, All Iterations, Back to Current Iteration,
Hide Changes), and Preview Packet… (⌥⌘↩) beside Copy; View also holds Layout (Automatic, Compact, Full);
**Help** has Keyboard Shortcuts, Report a Bug and Acknowledgments. Items that show or hide a part of the window say
which (Show Notes Panel becomes Hide Notes Panel) rather than carrying a checkmark; filters and modes that are an
attribute keep their checkmark. No command is in two menus, and two commands don't share a symbol.

Refine This Document (2026-10-12) sits with the sending actions in Notes and in the Send button's menu. It sends
at once, so it has no ellipsis; it needs a live document and an available chosen agent, but no drafts. While the
document is being refined, Refine This Document is disabled and End Refinement is added. An earlier iteration
offers Back to Current before it can start. The notice's Send N Answers has Preview Answers… in its context
menu. Several documents can be refining; the command always names the document in front, with no prompt to end
another.

Every text field has a way in from the keyboard: Edit › Filter Files (⌥⌘J, as Xcode's navigator filter) and
Edit › Search Notes (menu only: ⌥⌘F is Find and Replace in most Mac apps) put the caret in their fields, as Find
in Files, Open Quickly, and Go to Line do. New shortcuts follow the conventions of Xcode and the system before
inventing one; when a natural choice is taken elsewhere, the menu item alone is fine. Search and filter fields
behave like Mac search fields: Escape clears the text, a second Escape leaves the field (Find in Files closes).
Commands that act in the main window bring it forward first: New Note from Selection, chosen while Settings or
Keyboard Shortcuts is in front, raises the main window and then opens the composer (a popover there), instead of
doing nothing (`AppModel.beginNoteInMainWindow`).
Gloss › Check for Updates… sits under About, where Mac apps keep it; release builds only.
Help › Keyboard Shortcuts (⌘/) opens a reference window (`ShortcutsWindow`): shortcuts grouped by where they work,
each key a raised key cap, alternatives separated by a quiet "or", with a search field. It replaces the default
help item, which pointed at a help book that does not exist. The menu groups are read from the menu bar itself (`ShortcutGroup.fromMenu`), so a new or changed shortcut appears there without anyone remembering to list it; the app menu and the standard Edit commands are left out. Only keys with no menu item (the note composer, viewers, the folder switcher) are listed by hand in `ShortcutGroup.contextual`.
Help › Acknowledgments opens a plain window (`AcknowledgmentsWindow`) with the bundled `Acknowledgments.txt`:
every resolved package's license and NOTICE, then the theme palettes' notices, in small monospaced, selectable
text. `scripts/acknowledgments.py` writes the file; a test fails when a resolved package is missing from it. The
About panel's credits end with "Open source under the MIT License. See Help › Acknowledgments."

## Drag and drop

Files and folders dragged from Finder onto the window open (`DropToOpen`): a folder becomes a root, a file opens
in its folder (opening that folder first when no root holds it). While a drag hovers, a dashed accent outline
with a faint tint and a small glass card ("Open folder" / "Open file", symbol bouncing when it changes) say what
the drop will do. The source editor does not take file URLs, so a file dropped on it opens instead of pasting its
path. Dropping on the Dock icon is not supported yet.

## Words

- Menu items and buttons are title case ("Copy Packet to Clipboard", "No Agents Found"); help text, notices,
  descriptions, and accessibility labels are sentence case.
- An item that asks for more before it acts ends in "…" (Rename…, New Note…, Clear Sent Copies…); one that acts at
  once does not.
- The app's nouns, not the code's: "folder" (never "root"), "agent" (never "target"), "note", "draft", "sent".
- Say what happened in a sentence a person would say ("The file isn't there. It may have been moved…"), never an
  error's debug description.

- **Refinement's words** (2026-10-12): "Starting Refinement…" while its request goes; "The agent is reading the
  document" before the first questions; "Refining · Round 2 · 3 questions for you" while answers wait ("1
  question for you" for one); "The agent is reading your answers" once they go; "No more questions" once the
  agent finishes. Actions are Refine This Document, End Refinement, Show Questions, Send 1 Answer or Send 3
  Answers, Preview Answers…, and Done. A choice group says "Choose one" or "Choose any that apply"; the freeform
  field says "Your answer", and an answer not sent says "Not sent", as every follow-up does; an edited choice
  answer says "Custom answer · Not sent". Clear choices removes the generated selection, leaving custom words
  alone. Dirty entry says "Save before Refinement" and "The agent needs the saved document.", with Save First;
  saving does not start Refinement until it is chosen again. A delivery failure stays beside what can be
  retried; it never says the agent is reading something that did not go.


## Components

### Shared components

- **StatusPill**: symbol + label in a 14% tinted capsule. States: Draft (dashed circle, secondary), Sent (paper
  plane, blue: waiting on the agent), Resolved (check, green), Your turn (orange: a question mark while an agent waits
  on an answer, the draft's dashed circle while a follow-up waits to be sent), Orphaned (warning, orange; it wins over
  Your turn, since nothing else matters until the note has a place). The page's peek uses the same pill
  (`NoteCard.badge`).
- **InlineIconButton**: 22×20 icon button with a tooltip and accessibility label. At rest 55% secondary; full
  secondary when its card is hovered or selected; primary with a soft fill under the pointer. `prominent` makes the
  one primary action accent-filled; destructive turns red only under the pointer.
- **PressableStyle**: buttons shrink to 90% while pressed.
- **FilterBar**: a capsule track of options, each with its symbol and count; all names show when they fit, falling back to the selected name and then icons at narrow widths. The selection is one capsule that slides between options (`matchedGeometryEffect`), counts roll with
  `numericText`, empty options dim. Counts show how much work exists, ignoring search and color filters.
  The notes filters are All, Drafts, Sent, Resolved, and Attention (orange ▲): notes that lost their place plus
  questions back from agents, the same "needs attention" the tree's markers and the Dock badge use. Its count turns
  orange and bold when it is above zero, the one count in the bar that asks for you.
  It compacts before anything wraps (issue #7, `ViewThatFits` over three rows): first the selected title goes, then
  every count but the selected one's; an urgent option whose count is hidden keeps a 5 pt orange dot on its symbol.
  Counts never wrap (`lineLimit(1)`, `fixedSize`), and tooltips and VoiceOver labels always carry title and count.
- **KeyCap**: a key drawn as a small rounded cap, for hints next to the controls they describe.
- **EmptyState**: teaches instead of reporting. A 40 pt hierarchical symbol that breathes, a `.title3` title, one
  sentence, up to three numbered steps (arriving 110 ms apart, each fading up 6 pt) on a faint rounded card, and an
  optional action. Never let it size the window: it fills the pane with zero minimums.
- **Notice**: the in-context banner above a viewer. A rounded card tinted by kind (info blue, warning orange, a
  temporary mode in the accent color) with the symbol in a tinted circle, a bold title, one line of detail, and
  actions at the trailing edge (the one that resolves it prominent). It slides down from the top with
  `DS.Motion.smooth`; a mode (placing a note) pulses its symbol. Titles name the situation ("Changed on disk",
  "Read-only", "Placing a note"), details say what it means or what to do.
- **Deleted on disk**: an open file that disappears gets a warning Notice ("Deleted on disk", trash symbol) with
  Close and, for editable text, Save Here (writes the open text back to the path). The session looks twice,
  300 ms apart, before saying so, because saves that write a new file and rename it over the old one leave the
  path empty for a moment; if the file comes back, the banner clears on its own. Close asks first when there are
  unsaved edits (they exist only in the editor now); Save Here on a file that has meanwhile come back goes through
  the normal save and its conflict check instead of writing over it. Remote files report deletion the same way.
- **Notice layout adapts**: side by side when the row has room; in narrow places (the sidebar) the actions drop
  under the text (`ViewThatFits`) and the detail may run four lines, so an instruction is never cut off.
- **StatusDot**: 8 pt. Working: blue with a ring that pulses outward (1.2 s). Waiting for you: orange. Idle: green.
  Unknown: secondary. The tooltip and accessibility label say the state in words.
- **Toggles show their state**: an icon toggle draws what is true now, not only what it does. The hidden-files
  toggle is `eye.slash` in secondary while dotfiles are hidden and an accent `eye` while they show, swapping with a
  symbol replace transition; its tooltip names the action it will take.

### Explorer

- **Root switcher** (`RootSwitcher`): one row above the tree, always shown, names the open folder (accent folder,
  teal host for remote roots, its open-note count; no favorite star, which shows in the open list) with "N open" and a chevron that
  turns over while the switcher is up; with Web picked it reads `globe` "Web", and with no folder open the host's
  icon and name (teal for ssh) and "No folder open". It is also the host picker (2026-10-07; the sidebar toolbar's
  host dropdown and the title's host chip are gone). Clicking opens a 320 pt popover with sections: **Hosts**
  (every host, `HostMenu`: This Mac, Web, GitHub, Atlassian and the ssh hosts in teal, each with its symbol, an
  ssh host's saying how its connection is and an orange `exclamationmark.triangle` after a failure; the current
  one tinted with a checkmark), **Open** (the current one tinted),
  **Favorites** (pinned roots, kept even when closed, with no star of their own), **Recent** (six more on the picked host), then the Open item
  for the picked host (Open Folder on this Mac…/on an ssh host…, Open Location…, Open Pull Request…, Open Jira
  Issue or Confluence Page…) and Manage Hosts…. Under the pointer a folder row shows `star` (add to Favorites) or,
  under Favorites, `star.slash` (remove), then `xmark` (close) when it is open; each keeps its slot on every row,
  so they line up. Picking This Mac or a connected ssh host brings a folder already
  open there to the front and keeps the popover open on that host's recent folders (with none open, the row reads
  "No folder open", or "No pull request open"/"No issue or page open", and the tree's place offers Open Folder on
  the host; a folder never shows under another host's name); Web shows the Web section, GitHub and Atlassian open their sheets, and an ssh host
  not connected connects (again, after a failure) and opens its home, each closing the popover. Stars bounce when
  toggled; rows show their parent folder with `~` for home, truncated from the start. Replaces the chip strip,
  which scrolled roots out of sight. Keyboard first: the popover opens with a "Filter hosts and folders" field
  focused and the current folder highlighted (the picked host with none open); typing filters (hosts by name,
  folders by name first, then paths) and puts the highlight on the first folder left, so `git` and Return opens a
  folder rather than GitHub; ↑/↓ move a highlight through hosts and folders drawn as an accent ring (the current one
  keeps its fill, so the two never blur), Return picks, Escape closes (`SwitcherEntry.sections`, `SwitcherItem`).
  An ssh host row tells VoiceOver how its connection is (Connected, Connecting, Not connected, Couldn't connect).
- **Reviews** (2026-10-13): the location switcher lists Reviews (the internal host is `gloss`); the explorer
  groups Shared With You, Shared by You and Copies. Each row reads the review title over its owner/copy context,
  with a 6 pt accent dot for new updates, its count in the tooltip and spoken label. Open Review… opens a package;
  Finder/Open/drop do the same. Internal package folders never become a file tree. Known reviews reopen from the
  instance index; Favorites/Recents integration is deferred. A copy says “Copy” and never opens a live return channel.
- **Tree note marker**: on a file row, a 14 pt capsule at the row's trailing edge with up to three overlapping
  7 pt dots in the colors of its open notes (most used first, each ringed in the window background so they
  separate) and the count; orange-tinted when something needs attention (an orphan, or an agent's question).
  Folders show only a tertiary count of open notes inside them. Only open work counts: resolved notes vanish from
  the tree. Changes pop in with a short spring. The tree's single column always spans the sidebar so marks align.
- **The way to the open file**: a collapsed folder that holds the open document carries a 7 pt accent dot on its
  icon's lower corner, ringed in the window background (white with no ring on a selected row). It fades in and out
  (0.2 s; instant with Reduce Motion) and leaves once the folder is expanded, when the file's own row is in view.
- **Find in Files results**: before a search, an `EmptyState` hint; then a summary ("6 lines in 2 files", Collapse
  All); one pinned, collapsible group per file (rotating chevron, file icon, name, dimmed folder, count) and one row
  per matching line with its number in a tertiary gutter and every match on an accent wash in bold (smart case for
  text, the pattern itself for regex). Code lines keep the editor's syntax colors under the wash, as Xcode's Find
  navigator shows them (worked out once per row); markdown and plain text stay monochrome, since a lone prose line
  colors as noise. Rows brighten under the pointer. Failures use `Notice`, nothing found uses
  `EmptyState`.
  Choosing Find in Files puts the caret in its field (even when the search is already showing), so typing starts
  the search at once; Escape in the field closes it and the tree returns.
- **Open Quickly**: a 600 pt sheet whose list is exactly as tall as its results (up to 330 pt, then it scrolls), so two matches make a short sheet that shrinks and grows smoothly as you type, as Spotlight's does; empty and error states keep a steady 240 pt. A `.title2` search field; rows with the file type's system icon, the name with
  the typed letters in accent bold (only when they all occur in the name), and the folder dimmed after it; one
  rounded selection that glides between rows (`matchedGeometryEffect`) and shows a `↩` key cap; empty and error
  states use `EmptyState`; a footer with the result count ("12 files · 3 pages") and key hints. Hover never moves the
  selection (a list changing under a resting pointer would steal it from the keyboard). A query that can only be an
  address gets a first row, an accent globe and "Open https://…" (with "via host" in teal for a loopback address while the open
  document is on an ssh host; a query that may be a file name, `README.md`, gets the row after the files instead); visited pages matching it follow under a "Web Pages" caption (a clock, or a pin for a pinned one,
  the title lit like a file name, the address dimmed), then "Files". Arrows and Return cover every row. With no folder
  open, or an integration root in front, the panel still opens, offering addresses and up to 30 pages.
  Files with open notes carry the tree's marker in the row (`NoteMarkBadge`: their colors as overlapping dots and
  the count, orange when one needs attention), so the files worth jumping to stand out in the list.
- **Connection notice** (sidebar, remote hosts): Not connected (info, Connect); Connecting to devbox (info, ssh's
  current stage as the detail, spinner, Details, Cancel); Waiting for your key agent (mode, pulsing key, "Approve
  the request… its prompt may be behind other windows", Cancel); Reconnecting (info, attempt n); Couldn't connect
  (warning, ssh's message, Details, Connect). A healthy connection says nothing; a connected host with a problem
  (missing ripgrep) is a quiet warning. Each stage is rendered offscreen in `ConnectionNoticeTests` for review.
- **Follow mode**: shown only where Herdr exists (its binary on this Mac, or a connected host whose probe found
  it), since following needs Herdr's focus events; the Herdr plugin row in Settings → Agents is gated the same way.
  The crosshair (`FollowToggle`) sits in the bar under the tree, after the hidden-files eye and drawn like it
  (moved there 2026-10-09; it was at the left of the root switcher): a secondary `scope` while off, tinted while
  following, bouncing as it turns on or off. It isn't there while Web is the host, which has no bar. A
  toolbar toggle's solid "on" disc hid the symbol. Go › Follow Herdr (no shortcut) toggles it with the sidebar closed. While a pane is followed, a card tops the sidebar: "FOLLOWING" with the agent's `StatusDot`, host
  (teal) and agent, pane id, and the pane's folder, plus a stop button; it slides in and out from the top. Follow
  problems (Herdr not running, an unknown machine) stay in the status line.

- **Pull request roots** (milestone 2): with a GitHub token saved, the host menu lists GitHub (`arrow.triangle.pull`)
  after this Mac. A pull request opens as a root named `owner/repo #N` (root switcher, tree root, breadcrumb, notes
  panel header all say so; the tree's root wears the pull symbol) holding `Pull request.md`, `Conversation.md`,
  `changes/…` and `pull-N.diff`. Nothing on it can be made, renamed or removed, so the tree's menu offers none of
  that; the status bar's lock explains "a pull request's file at its head commit". The sidebar's empty state for
  GitHub leads to the picker, never to "Connect".
- **Open Pull Request…** (File menu, ⌥⌘P; also the GitHub host's menu entry): the Open Quickly panel's shape with
  the pull symbol. The field narrows the open pull requests you are involved in by every word typed (`repo`, `#12`,
  a word of the title); a pasted URL or `owner/repo#123` shows one "Open owner/repo #123" row and opens as is. The
  list does not wait for the token's check. Without a token a pasted URL shows "Open in the browser" and opens as a
  web page; a short reference says a token is needed, and Return keeps the query. Rows read title first, then `owner/repo #n · draft · updated 3 days ago`.
- **Jira and Confluence roots** (milestone 2): with an Atlassian site saved, the host menu lists Atlassian
  (`square.stack.3d.up`) after GitHub. A Jira project opens as a root named `Jira · PROJ` (ticket symbol) holding
  the issues you are assigned, reported or watch as `PROJ-123.md`; a Confluence space as `Confluence · SPACE`
  (page symbol) holding its pages, each a folder named by its title that holds `<Title>.md` and the child pages.
  Everything is read-only; the status bar's lock explains "the live ticket or page. Ask your agent for changes."
  The breadcrumb leads with `Jira · PROJ` (its menu: Open in Jira, Copy Issue URL) or `Confluence · SPACE`. A
  document that changes at its source reloads with "Updated in Jira or Confluence" for eight seconds.
- **Open Jira Issue or Confluence Page…** (File menu, ⌥⌘I; also the Atlassian host's menu entry and its empty
  state): the same panel as pull requests with a Jira / Confluence segment at the field's end. Jira lists the issues
  you are part of, newest change first, as `summary` then `KEY · type · status · updated 2 days ago`; Confluence
  lists the site's spaces. A typed key (`cp-12`, any case), a `/browse/KEY` URL or a page URL opens as is, even
  before the lists arrive. Without a key a pasted URL opens in the browser; a bare key says a key is needed. Jira
  and Confluence each report their own refusal.

### Notes

- **A selected card** (2026-10-07): the list draws no selection band of its own (no accent or gray fill; its table's
  highlight style is none, set by `NoSystemSelectionHighlight`). A selected card, alone or among several, is outlined
  1.5 pt in its note's own color on a lifted ground (`Color.primary` at 6%, light and dark), with its rail at full
  strength and 4 pt wide, as the note's highlight and path strengthen on the page. Text, pills, bubbles and fields
  keep their own colors. The outline is at full strength while the list has the keyboard in the key window and at
  half otherwise, as a system selection grays, so it still says where typing goes. The list's keyboard focus ring is
  left as the system draws it. A click into a card's own field keeps the keyboard there; a click anywhere else in the
  list, or selecting another card, gives it to the list.
- **Adjacent selected cards** (issue #19, 2026-10-08): two or more selected cards next to each other in the list are
  outlined once, around all of them, instead of each drawing its own outline over its neighbor's. The outline is the
  same 1.5 pt rounded stroke, 4 pt outside the cards, at the same strength (full while the list has the keyboard, half
  otherwise), drawn by `NotePathLayerView` over the list and clipped to it. Cards of different colors blend: a
  vertical gradient with a stop at each card's middle in its note's color; one color is drawn flat. A document's
  header, the rule before resolved notes, or an unselected card ends a run; a lone selected card keeps its own
  outline. Each card in a run keeps its lifted ground and wide rail.
- **Note card**: color rail (3 pt, 4 pt when selected, faded when settled unless selected; hover only lights its glow), anchor label
  with the anchor kind's symbol, the comment, the latest turn of its thread, the delivery line, then the action row
  with Send first and Delete apart at the trailing edge.
  Under the anchor label, a text note quotes what it is about, as GitHub review comments show their line: the first
  non-blank line of the anchored text, trimmed, in `.caption` monospaced on a faint rounded well, one line with a
  tail ellipsis (the whole line in its tooltip), in the editor's syntax colors when the file has a grammar. Hidden
  on compact settled cards; regions, cells, and whole-file notes have none.
  The pointer never changes a card's size: a card that grows under it pushes the one below and flickers in and out
  of hover. Hover lights the rail's glow, the action icons and the note's path on the page, nothing more.
  The thread (`NoteThread`) is the comment, then the note's messages in order (2026-10-07): turns (the agent's
  replies and questions, the user's follow-ups) and moves. The panel reads every note's messages through one
  observation (`NotesPanelModel.messages`), so a card never opens its own.
  Collapsed, a card shows the comment (two lines), the move that took the note from where it was made while it is
  still away, and the latest turn whole, never cut (the agent's bubble or the user's follow-up; 2026-10-08). An
  unanswered question stays ahead of a later turn, with its choices and answer field, so a status reply never
  covers what still needs the user (2026-10-12). A quiet "Show conversation (N)" link with a chevron pointing down opens every turn and move and the whole comment in one
  smooth animation; open, it reads "Hide conversation" (or "Show less") with the chevron pointing up, the symbol
  swapping in place. It's there when there is more than the collapsed card shows ("Show more" when only the comment
  was cut, and always once open, to close it). Whether the comment is cut is measured on unseen collapsed and uncut
  copies (`TruncatingText`), so the link stays put while the card is open.
  Selecting a card (a click) opens it, without taking the keyboard; the toggle closes it while selected, or opens a
  card without selecting it, and a card the toggle opened stays open when another is selected. Open, the card ends
  with the follow-up field (below). Edit… and the pencil edit only the comment; the turns are
  their own messages.
- **The user's turn in a thread**: a follow-up is a block in the accent color at 6%, inset from the leading edge
  so the two voices read apart, headed "You" in the accent color and nothing more: what kind of turn it is, its
  words say (the user's call, 2026-10-07). Until it is sent, a quiet secondary "Not sent" follows the name, with a
  10% fill and a dashed accent outline (a draft's dash), and it carries its own Edit (in place; Return saves, an
  emptied one is deleted, Escape cancels) and Delete. Sent, it is plain.
- **Following up** (replaces Reply to Agent, 2026-10-07): an open card ends with a field, the composer's own
  (`NoteBodyEditor`), placeholder "Follow up" (or "Your answer", outlined orange, while an agent waits on one).
  Return adds what is typed to the thread as an unsent follow-up and clears the field; Shift-Return starts a new
  line; Escape clears it. Nothing leaves the app until the card's Send (the paper plane, lit while a follow-up waits)
  or any other Send takes the note, so the person sees what goes before it goes. A follow-up on a resolved note
  reopens it. The typed text lives in `NotesPanelModel.followUpText`, keyed by note, so a recycled row never loses
  it; if the follow-up can't be added, the text stays with an orange line saying so. The field waits to be clicked:
  only Follow Up… (menu, the ↩ action icon, accessibility action) opens the card and puts the caret in it, so
  opening a card never takes the keyboard. Follow Up… is offered on every note but a draft never sent, whose
  comment is edited instead; its action icon is the accent-filled one while an agent waits on an answer.
- **Choices from an agent** (2026-10-12): a question can offer one answer or several, on a new note (`ask_user`)
  or a question in its thread (`reply_to_note`, `asks: true`). Under the orange question bubble, "Choose one"
  heads native radio buttons, or "Choose any that apply" heads checkboxes; no choice starts selected. Each label
  wraps rather than cutting off what the answer means. A click stages the answer as the user's own turn, "You ·
  Not sent", with the selected words in their given order, and it can be edited before Send. The "Your answer"
  field is there too: a choice never prevents a freeform answer. Choosing again changes the staged choices,
  never words the person has edited into a "Custom answer · Not sent", and never sends. Clear choices removes
  the generated draft, not a custom answer. Delete and Undo retain the question association, selected options
  and custom status. A new question has its own fresh choices; earlier ones stay with their question in Show
  conversation, read-only once answered. Closing a card or changing the layout keeps what was chosen and typed.
  Choices work on ordinary questions too, whether or not the document is being refined.

- **The question still waiting** (2026-10-12): a later status reply does not cover an unanswered question. The
  collapsed card keeps that question and its choices in sight, orange with primary text; the status remains in
  the conversation. A question arriving while an answer is being written leaves its text and the keyboard alone.

- **Moves** (2026-10-07): when an agent says where its change now is, or the note's text was removed, the thread
  shows one quiet `.caption` secondary line where it happened, with a pencil for an edit and a minus circle for a
  removal: "Edited by Claude Code", "Removed by Codex", "Edited" or "Removed" (Gloss found the note on rewritten words,
  or the text gone, so no one is named), "Restored original" (2026-10-08: "Moved" read as if the note, not the text,
  had changed). Gloss's moves in a row (two reloads) are one line. When an agent says where its
  change is after Gloss recorded such a move since the note was last sent (its edit reached the file first), the two
  are one line, the agent's, from where the note was before either; a move from before the send (the user's own
  edit) stays Gloss's. An agent putting the note back where it was leaves no line and nothing to restore. Its chevron ("Show the original")
  shows the text the note was on, struck through in tertiary monospace on the excerpt's well, and, for the move that
  brought it where it is, a small Restore Original button; the card's menu has Restore Original too while the note is
  away. The excerpt well shows the current text, or "Removed" with a minus circle for a removal point.
  Resolved notes (not ones where the agent asked a question) rest as one line: anchor, pill, the first line of the
  comment, and their latest turn if they have one. Selected or opened, they show the excerpt, delivery line and
  actions, so finished work stays in reach without crowding the open work above it. In the default sort (Position in File), documents
  with open work come first and documents whose notes are all settled follow, each part in path order.
- **Separate Resolved Notes** (2026-10-08; the sort menu under Show Resolved Notes, and View; remembered; off by
  default, and disabled while resolved notes are hidden): the list runs twice, open notes by document, then resolved
  ones by document in the same document order (a document with both kinds heads both runs), with one thin untitled
  `Divider` row between, not selectable. When only one kind is listed (the Resolved tab, a search, every note open)
  there is one run and no rule (`NotesPanelModel.sections`).
- **The page draws what the panel lists**: the panel's tab, colors and search choose the highlights on the page
  too, so the Drafts tab leaves only drafts on the page. With the panel closed, nothing is filtered on screen and
  every note is drawn. Show Resolved Notes (the sort menu, and View) off takes resolved notes out of every tab but
  Resolved, open or closed; a question back from an agent stays. A note revealed from elsewhere that the filters
  hide brings itself into the list (All, resolved shown), so a selected note is never invisible.
- **A note arrives**: a card for a note that just appeared (made anywhere, or brought back by Undo) glows in its
  own color at 20% for 1.6 s, then fades over 0.9 s, so the panel answers "where did it go?" the way Things and
  Linear light a new item. Nothing glows on the first load, when everything is new and nothing arrived
  (`NotesPanelModel.arrivals`).
- **The agent's turn** (`AgentMessageBubble`): each of an agent's messages is a bubble, its small tail pointing up
  at what it answers, headed only by who spoke ("Claude Code", "Codex"; "Agent" when the note was never sent from
  here), with no kind word or icon: whether it asks or reports, its words say (the user's call, 2026-10-07). What
  reading can't tell is kept: the question still waiting on the user is tinted orange with the text in primary;
  everything else is a quiet gray. VoiceOver reads the name, the words, and "waiting for your answer" for that open
  question. The latest arrives on the bouncy curve, growing from its tail, and its text is selectable.
- **Sending takes off** (`LaunchingPlane`): when a send starts, from the button or ⌘↩, the Send button's paper plane
  flies up and away, tilting 14° and shrinking as it fades (an ease-in over 0.32 s, like something thrown). A small
  spinner fades into its place after 0.2 s while the packet is in flight; when the send is over, a fresh plane glides
  in from below-left on the bouncy curve, so it reads as "sent, ready for the next one", not the same plane coming
  back. A send that finishes at once (the clipboard) still lets the takeoff play out before the return. Under Reduce
  Motion the plane and the spinner simply cross-fade.
- **Empty filtered lists say why** (`NotesPanelModel.emptyCopy`): a search with no match names the words and offers
  Clear Search (which clears only the search); a color filter names the color ("No blue or pink notes"); each tab
  says what belongs there and how notes arrive (Drafts: how to make one; Sent: "Nothing waiting on an agent";
  Resolved: what lands there). An empty Attention tab is good news and says so: "All clear" under a green seal.
  All use `EmptyState`, so they match "No notes yet"; the message cross-fades as the tab changes.
- **An agent's own question** (`ask_user`, issue #4): a card with no comment of the user's, only the orange bubble
  headed "Claude Code" (the agent's name from its MCP client), on the lines it asked about, under Attention and on
  the Dock badge like any question. When it arrives the document opens to it and the window comes forward without
  taking the keyboard from the terminal (`orderFrontRegardless`), unless the user is writing a note, when it only
  waits under Attention.
- **Agent set-up needs an update** (#10): checked at launch for this Mac and when a host connects (Claude Code,
  Codex, OpenCode; the Herdr plugin is left to Settings). When an installed agent is out of date (an old prompt hook,
  a stale MCP url) a glass toast sits at the bottom right, with the notes panel's toasts when it's open and in the
  window's corner when it isn't: "Claude Code needs an update", the reason in `.caption`, ✕, and Open Settings, which
  opens Settings on its Agents tab, where Update fixes it. ✕ holds until something else needs updating.
- **Editing in the card** (#14): the pencil and Edit… turn the card's comment into the composer's own field, in
  place, with the color swatches, Cancel and Save under it; Return saves, Shift-Return adds a line, Escape cancels,
  and the field's border takes the note's color. It doesn't depend on the note being on screen in the viewer (the
  composer popover is for new notes and re-anchoring). If the comment changed while it was open (an agent's answer was
  added), Save refuses with an orange line and keeps the typing; a second Save then means it.
- **Document group header**: the file's system icon, its name (middle-truncated), a count capsule, and the host
  only when it is not this Mac.
  The header opens its document on click (a quiet ↗ appears under the pointer, as group headers open their subject in
  Mail and Xcode's issue navigator); right-click offers Open and Reveal in Finder.
- **Same-named files**: when two groups share a file name, each header adds, in `.caption` secondary after the name,
  the shortest run of parent folders that sets it apart ("…/docs", "…/proj"), as editors do for tabs
  (`PathDisambiguator`). Unique names stay bare, and the full path is in the tooltip.
- **Note composer**: title, then an anchor chip tinted with the note's color, naming the characters too when only
  part of one line is selected ("Line 12, chars 5–20", UTF-16 columns as the editor counts them); a quote of up to three lines of the
  selected text under a color rail, so the comment is written against what it is about (code keeps the editor's
  syntax colors, `SyntaxTheme.highlighted`, worked out once per quote; plain text and prose stay a quiet gray); the field with a
  placeholder prompt and a color-tinted border; the swatches; Cancel and one prominent action ("Add Note" for new
  notes, "Save" when editing). No key hints: Return to save and Shift-Return for a new line are standard. Choosing a color re-tints the chip, rail, and border
  together, and the selection ring slides between swatches with `DS.Motion.bouncy`.
  While a new note is empty, starter chips sit under the field (`StarterPhrases`: Explain, Fix, Add a test, Why):
  one click writes the start of the sentence ("Fix this: ") with the caret after it and the field focused, and the
  chips fade up out of the way once there is text.
- **ColorSwatches**: 14 pt gradient dots that grow slightly under the pointer; the selected one wears a ring in its
  own color, shared across swatches with `matchedGeometryEffect`.
- **Add Note button**: glass pill beside the selection with a dot in the color the note will get (the last color
  used), the label, and its key, ⌘↩ (which is the button's while it shows; Send has ⌘↩ otherwise). It grows out
  of the selected line to where it rests (`DS.Motion.bouncy`, scale from 0.2 anchored on the point where the
  selection's edge meets it, `AddNoteButton.emergence`), follows a growing selection with `DS.Motion.smooth`,
  lifts 4% under the pointer, and leaves the same way in 0.1 s so it never lingers over text. Escape puts it away
  (the selection goes with it) from anywhere in the main window but a search or filter field, and Escape in the
  composer cancels it, as its Cancel button does (one key monitor in `AppModel`; the composer's field handles its
  own, since NSTextView otherwise takes Escape for word completion).
- **Agent chip**: where notes go, as a rounded field: a `StatusDot`, the agent in semibold, its task in secondary
  (truncating), the pane in tertiary monospace, a folder badge when the agent works in the explorer's folder, and
  an up/down chevron; it opens the agent menu.
- **Agent chip wraps instead of clipping**: the task sits beside the agent only when it fits whole; otherwise the
  chip grows to two lines (agent, pane, folder badge; then the task in `.caption` secondary). A one-word stub such as
  "Reor…" tells nothing, so it is never shown.
- **Selection bar** (issue #8): select two or more cards (⌘-click, ⇧-click, ⌘A) and a bar slides in under the color
  strip (one selected card relies on its own buttons, so a click never brings the bar or pushes the list down;
  the user's call, 2026-10-07), tinted accent: "3 selected", then `.glassProminent` Send with the count (the paper plane takes off as the
  send starts), Resolve, Reopen as Drafts, a ⋯ menu (Copy as Packet, Color, everything again in words), Delete, and ✕
  to clear the selection. Each action counts only the notes it applies to (Send takes drafts and sent notes, Reopen
  resolved ones) and is absent when none apply. Right-clicking a selected card offers the same, worded for the
  selection ("Send 3 Notes to claude"). With none or one selected, the row beside the agent chip holds the panel's own
  Send (the drafts in its scope as the panel shows them, the same as ⌘↩, with the count and any color filter's dots),
  split by a hairline into Send and a chevron; selecting several hides it, since the bar above then says what goes.
  The chevron's menu picks what Send sends, This File or This Location (This File at launch), each with its count,
  and copies the same notes as a packet. Counts and packets share the same location, current iteration and filters,
  which apply even while the panel is closed. Send is as tall as the agent chip, in the chip's shape: an accent
  rounded rectangle (`DS.Radius.m`) with white labels, a secondary fill while it can't send. A missing recipient
  says Choose an Agent; an unavailable one keeps its name with an orange warning mark and can't receive sends.
  Choosing a recipient does not navigate away from the reviewed location.
- **Location boundary**: the panel shows only the selected location’s files and subfolders on the same host. Switching locations
  clears card selection, historical overrides, and scroll position immediately, preserving notes and unfinished follow-ups.
  Search, state/color counts, and bulk actions share this scope. With no location the panel asks for one. Explorer badges stay global.
- **Available actions** use secondary contrast without extra dimming and at least 28 × 28 pt hit areas; hover and destructive styling remain.
- **File naming** uses a sheet with Create/Rename, a focused name field, and inline errors that retain the name. Rename recovery
  shows both paths and a Retry Rename Recovery action; affected files cannot be saved until the operation is reconciled.
- **Delete is undoable, not confirmed**: deleting a note (trash button, context menu, or the Delete key) happens at
  once, and several selected go as one ("3 notes deleted", one Undo brings them all back); a glass toast ("Note deleted", the note's first line, Undo) rises over the bottom of the panel for 6 s
  (held while the pointer is on it), and Edit › Undo (⌘Z) does the same. A deleted note goes to Recently Deleted
  (`NoteStore.trashNotes`), so Undo only takes it out again, with its id, thread, image attachments and send history
  (issue #15). A question before every delete
  gets clicked through; a way back doesn't. Every delete path uses the same undoable delete (the composer's trash too), and each
  text editor keeps its own undo history so loading a file can't wipe the window's Undo Delete Note.
  An Undo that fails is never silent: the toast turns to an orange warning ("Undo didn't work", a sentence why),
  offers Try Again and a dismiss button, and stays until dismissed. Every way the toast goes (restored, dismissed,
  replaced by a newer delete) is logged under `notes`, so a note that did not come back leaves a trace.
- **Recently Deleted** (issue #15): the last item of the sort menu, after a divider, with a trash symbol. It replaces
  the list (and the filter bar, search and send row) with a bar: a "‹ Notes" back button, the title, and Empty…
  (destructive, confirmed: "Delete every note in Recently Deleted for good?"). Under it, the notes deleted under the
  folder in front, grouped by file, newest deletion first; each card is read-only (the color rail at 60 %, the
  anchor, the comment, "Deleted 3 days ago") with Restore and Delete Now, also in its context menu. A footer says how
  long notes stay. Deleted notes draw nothing on the page and no paths. With no folder in front it says so.
- **Iterations** (issue #18): at the trailing edge of each document's header in the notes panel, a borderless
  "Iteration 3 ⌄" menu (caption size, secondary) for that document once it has review history; the file name truncates first.
  The same menu is available in the viewer header. An empty current iteration keeps its document header within the location.
  While an earlier iteration is shown it reads that one ("Iteration 0") in the accent color with a clock symbol, and
  VoiceOver says it is an earlier iteration. Picking from a closed document's menu opens it first. It lists the iterations newest first, each a checkable row with its label
  ("Iteration 2 · Oct 6", or its name) over "Current · 4 notes" or "Oct 8 · 3 notes · a1b2c3d" (and "no snapshot"
  once pruned); then New Iteration, Show Changes Since (a submenu of iterations with a snapshot; text documents), Hide
  Changes while tinted, and Rename… (an alert with a field; empty goes back to the date). Picking an earlier one puts
  a `.mode` notice over the viewer: the iteration's label, "Read-only: the file as this iteration left it, with its
  notes.", Show Changes Since and Back to Current (prominent); the viewer shows the snapshot, locked, with no Add Note
  button, and the panel lists that iteration's notes (an iteration with none keeps its document's header, with "No
  notes in this iteration" under it), read-only: their cards offer only Reveal, Bring Forward and
  the Copy items (no follow-up field, edit, resolve, reopen or delete). The copy's card says "Brought forward from Iteration 2 · Oct 6" under its anchor. New Iteration with open
  notes asks in a 420 pt sheet: "Start a new iteration of PLAN.md?", how many notes aren't resolved, a "Don't ask
  again" checkbox, Cancel, Leave Them Behind, and Bring Them Along (default); with one note, Leave It Behind and Bring It
  Along.
- **Preview Packet** (2026-10-11, `PacketPreview`): a 420 pt popover under the Send button. The title with a
  This File | This Location segmented control, then "acme-site · 3 notes · 2 files → Claude" (the agent
  orange when unavailable); a Readable | Raw switch over a 260 pt pane: Readable lists the notes by file (color rail,
  anchor in caption, "Follow-up", a paperclip count, the comment to three lines) with a teal eye line when the packet
  asks for review; Readable also shows the document's Refinement directive and question/choice/answer turns
  (2026-10-12). Raw is the exact text, monospaced and selectable, with "Pictures are copied to <host> when sent."
  for a remote target. "Not included" lists what the scope leaves out with a link-style fix (Show All, Send This
  Location). Copy and Send N Notes (prominent, the default button) at the foot. A small spinner while it rebuilds,
  150 ms after what it shows changes.
- **All Iterations** (2026-10-11): the first item of a document's iteration menu (and Notes › Iteration). On, the
  menu reads "All Iterations" in the accent color with `square.stack.3d.up`, and the document's notes are listed newest
  iteration first, each iteration's run under a small caption header ("Iteration 2 · Oct 8 · 5 notes", the clock
  symbol and secondary for earlier ones, the stack symbol and accent for the current one). Earlier cards are the
  read-only cards above. Clicking one shows its iteration in the viewer and keeps the list; picking one iteration in
  the menu ends it. Selection never takes in earlier notes.
- **Earlier notes** (2026-10-11): with View › Show Earlier Notes (also in the panel's sort menu), or while a document
  lists all iterations, earlier iterations' notes still found in a text document's text are drawn as a faint dashed
  outline (1 pt, the note's color at 40%) under this iteration's marks, never filled. The gutter gains an 11 pt column
  after the lanes with a small hollow card on the line each starts on, two stacked when several share it, tertiary and
  secondary on hover, with "3 earlier notes here" as its tooltip. Clicking it opens a card beside the text in the
  peek's style (`readableGlass`, 340 pt): "3 earlier notes here" and a close button, then each note newest first with
  its color rail, "Iteration 1 · Oct 6", its pill, the comment, the agent's last word in its bubble, and Show in
  Iteration 1 and Bring Forward. The minimap doesn't show them.
- **Refinement** (2026-10-12): Refine This Document in Notes and the Send button's menu sends a whole-file
  request to the agent chosen for that document, even with no notes yet; other drafts stay. Saved content is
  required; Save First saves dirty text, then the user chooses Refine This Document again. A failed request
  stays with Retry; restoring a Refinement never resends it. While it is on, a small `.mode` Notice above the
  document, under a warning if there is one, names the round and whose turn it is: "Refining · Round 2 · 3
  questions for you", or "The agent is reading your answers". The document stays in hand, and its questions are
  the ordinary anchored cards under Attention. Its count takes current-iteration questions across filters;
  earlier questions do not count. Show Questions brings the current questions into the list; once answers are
  ready, Send 3 Answers is the prominent action; otherwise Show Questions is prominent. That send takes this
  document's answers to its original recipient, including ones hidden by the filters and text still in fields,
  and leaves other drafts. Its count says what goes; staging failure preserves the words and sends nothing.
  Preview Answers… in the send's context menu opens a 420 pt popover of the exact text, including field edits,
  without staging them. End Refinement is quiet but always in reach, including while the agent works: it stops
  the instruction on packets not yet handed over and leaves every note, question and answer where it is. There
  is no confirmation. Actions drop under the detail when the notice is narrow, as other Notices do. The round
  counts questions and answers, not document iterations. A successfully delivered answer batch arms the next
  round; its first later question advances it once. Several documents can be refined at once; each shows its own
  notice, and changing documents changes neither.

- **Refinement ends** (2026-10-12): when the agent has made its changes and has no more questions, its
  `finish_refinement` puts "No more questions" over its short summary in the notice, with Done to put it away.
  The instruction has already ended. The Review Results action remains where it was; finishing neither accepts
  results nor opens review or changes iterations. Current questions, unsent answers and field edits block
  finishing; earlier-iteration questions and results waiting for acceptance do not. The summary wraps in full.
  Leaving Refinement by hand puts the notice away at once; open questions still wait under Attention.

- **Questions in the compact layout** (2026-10-12): the closed NotesTray uses the question's first line when the
  card has no comment of the user's, beside its anchor and Your turn pill. Answer… opens the tray to that card,
  with the same choices, answer field and Send as the full panel; choices do not crowd the 36 pt bar. Closing
  the tray keeps the answer, and the Refinement notice stays above the document. Options wrap within the card,
  including at the tray's smallest width.

- **Review** (2026-10-10): a send made with Review When Done (the Send menu, under the scope; also Settings › Notes)
  leaves its notes, once resolved, at full strength with a teal "To review" pill (`eye.circle.fill`) and an open
  note's underline until accepted. A full-width teal "Review 3 Results" button (eye) sits under the panel's filters
  while any wait in the location in front; Notes › Review Resolved Notes does the same. Review is a card floating over
  the bottom of the document, above the note outlines and paths (they draw behind its glass; it is hosted on its own layer
  above theirs, joins the window's key-view loop while shown, and hides while the compact explorer slides over; the copy
  HUD and update toast stay above it) (at most 560 pt wide, inset 14 pt, `readableGlass`, radius 12, the peek's shadow),
  sliding up; the note it shows is scrolled to the middle, clear of it. It reads as the note's card does: the note's
  color rail, the anchor and file in caption, `NoteCard.badge` (To review, then Resolved once accepted or Your turn
  once followed up; a Skipped pill beside it when the agent skipped) and a ✕; the comment; the agent's resolve
  message in its bubble, or "Resolved without a message", or for a note followed up the user's turn ("You · Not
  sent"). A 2 pt teal hairline along the top fills as notes are reviewed. The bottom row: ‹ "3 of 8" › (inline icon
  buttons, the count rolling), Accept All… as quiet secondary text, then Later, Follow Up… and Accept (prominent);
  a reviewed note shows only the steps. Follow Up… opens the card's composer in place (Return adds, Shift-Return a
  new line, Esc cancels). Switching notes cross-fades. Accept has no key: the document stays editable. Esc ends review;
  so does switching location. At the end a green check bounces over "All reviewed" and what happened ("6 accepted ·
  2 followed up"), with Back, and Send N Follow-Ups (prominent, to the agent in front) when follow-ups written in the
  review are unsent, else Done (prominent).
- **Send toast**: a glass card floating over the bottom of the notes panel that slides up with `DS.Motion.bouncy`.
  Sending: a spinner and "Sending 2 notes…" with the agent. Delivered: a green check that bounces, "Sent 2 notes",
  "to claude · task", and a hairline that drains over 4 s (hovering pauses it) before it leaves on its own.
  Failed: a red mark, the reason, Retry (same notes, same agent), and it stays until dismissed.
- **Note peek**: resting the pointer on highlighted text for 450 ms shows that note in a 320 pt glass card beside
  it (below the text, above when there is no room): color rail, anchor label, state pill, the comment, the agent's
  latest word in its thread (orange while it is a question waiting on you), and Edit / Resolve (or Reopen) / Show in
  notes panel. Moving to another note switches at once; the card
  stays while the pointer is on it and leaves 250 ms after the pointer leaves both; scrolling, typing, or a
  selection dismisses it. Orphaned and invalidated highlights never peek. A removal point peeks when the pointer is
  within 3 pt of its caret.
  The card is read over busy code, so its glass sits on a 88% window-color fill: the lines behind never cross the
  note's words (glass alone suits controls, not content). A draft or sent note's peek leads with Send to the current
  agent (prominent), then Edit, Resolve, and Show in Notes Panel, matching the panel's cards.
- **Notes search row**: a rounded field (5% fill, hairline border) whose clear button scales in, and a sort
  button whose symbol names the order (numbered list, arrows, palette, dashed circle). Below it, `ColorFilterStrip`:
  one chip per color in use with its count (shown when two or more colors exist); a chip fills with its color and
  rings when on, the others dim to 45%, and "Clear" appears. Several colors may be on together.

### Shared reviews

- **Opening and removing reviews** (2026-10-13): launch opens only indexed, downloaded and current reviews in
  the background, without delaying the window, MCP or document restoration. Stale, evicted or ambiguous packages
  wait for Open Review…, Finder Open or drop; launch does not discover reviews in the iCloud folder or show
  background opening alerts. Confirmed deletion or an invalid package removes the visible review and closes its
  captured viewer, keeping notes and private drafts. Restoring it reuses those notes and the owner's original link.
  An ambiguous download keeps the entry. Invalid identifiers, links or special files never become usable captures.
- **Share** (2026-10-13): `square.and.arrow.up` in the toolbar's system glass, with “Share this document's content
  and notes” as its help and “Share review of PLAN.md” as its spoken label; File › Share… opens the same 320 pt
  preparation popover. It says “Captured content and sent notes, including their attachments. Your drafts stay on
  this Mac.”, and for a page “Captures the visible viewport, not the complete page.” Collaborate… and Send a Copy…
  prepare the right identity first, then a retained native picker offers Choose People… or Send Copy… with the
  other mode disabled. No participant invitation is inferred from a contributor name. Dirty content says “Save
  before sharing. The review will contain the saved file.”, with Save and Continue; saving returns to the sharing
  choices. Preparing review… shows a small spinner; Cancel keeps drafts and stops preparation. Upload wait says
  why the invitation is not ready. A saved local review can remain when its invitation is canceled.
- **Contributors** (2026-10-13): cards, peeks, the tray and turns add a 20 pt initials avatar and the speaker's name,
  “You” or “Alex · Owner”; absent names read “Unnamed contributor”. Tint is stable from author identity and stays
  on the avatar, apart from note color/state. Human turns keep their own speaker; an agent's bubble names the contributor
  who sent to it. Agent attribution is honored only from owners; a contributor's question-kind turn does not enter
  Attention as an agent question. No Apple Account photograph, verified identity or online presence is implied.
  Settings › Notes › Shared reviews has Your name; the Collaboration popover's Edit… changes the same value. People is a separate menu filter
  with contributor toggles, Your private drafts and All People; remembering it per review is deferred.
- **Owner on another Mac** (2026-10-13): on open, import and permission changes, this install joins the owner
  set for a shared review with the native owner role, or an unshared review in your own iCloud Drive with no role.
  Copies and shared participant/unknown roles never adopt. Every owner install gets the Owner label and ordinary
  agent Send and acceptance actions; the named creator stays the same. Link Original… still requires matching
  saved bytes before agent delivery. Becoming an owner or linking the original never forwards non-owner
  contributors' posted answers; explicit Send forwards them. Turns from any owner import as sent, including after
  a role upgrade, and keep their named speaker. Previously delivered turns stay delivered.
- **Sending a shared note** (2026-10-13): a participant's recipient chip reads To Owner and Send posts their own
  notes/answers into the review. “With Owner” is published work before the owner's agent delivery; “Changes not
  sent” is a private edit, still available to change. A notice says “3 notes saved · Waiting for iCloud” or “Sent
  3 notes to the review”, according to known status, never that the owner read them. The owner keeps the ordinary
  agent picker and explicit Send. Received notes say “3 notes from Morgan”, with Show Notes isolating those exact
  ids and Dismiss; they are never auto-forwarded. Posted answers need this explicit owner Send even when the
  note was sent before. Agent delivery finishes Send while review publication continues in the background.
  Participant packet/clipboard/Refinement and acceptance routes are unavailable. Own comment edits, writable
  Resolve/Reopen and author-or-owner moderation keep their attribution.
- **Collaboration** (2026-10-13): a `person.2` toolbar button beside Share has an accent new-activity dot and help
  “Review collaborators and activity” or “4 new updates”. Its own 320 pt popover scrolls up to 520 pt: title,
  “Shared review · iCloud Drive” or “Separate copy · No return channel”, sync status and known self permission;
  Contributors with names and “Names chosen by contributors. This is not an access list.”; New Since You Looked,
  All Activity… and Mark All as Seen; Your name with Edit…; owner Open Original, Link Original… and Refresh Shared
  Content; Save My Notes… when copying or recovering input; Show in Finder with “Manage access in Finder's sharing
  options.” All Activity stays in this popover. No `SWCollaborationView`, calls, cursors or guessed invitation roster.
- **New since you looked** (2026-10-13): an accent dot by the contributor means “New”; it does not recolor the note
  or borrow Attention orange. Opening a review alone marks nothing seen. Revealing marks the shown note revision,
  visible turn/event records (the expanded conversation includes its shown thread); Mark All covers its current
  record snapshot, so an update arriving meanwhile stays new. Updated content has its own content-hash marker and
  “Updated content · Iteration 3” action. Unread is private to this reader and counts delayed older-created records.
- **Captured content** (2026-10-13): a `.mode` notice over a received viewer says “Captured content · Read-only”,
  or “Captured viewport snapshot · Read-only content” for a page. Write permission lets a participant annotate;
  it never unlocks the capture. A view-only review says “You can view only.” A copy says “This copy has no return
  channel.” The owner opens the original separately; Link Original… requires matching saved bytes and never
  guesses by name. The shared review starts with the current capture, keeping only post-share iterations. Source
  changed-content rollover runs once; the package mirrors its number, reusing the blob for an existing same-byte
  round. A complete new capture arrives before it replaces current content, and earlier captures keep their identity.
- **Sync and recovery** (2026-10-13): routine status is secondary text: “Sending changes · Waiting for iCloud”,
  “Changes uploaded”, or “Showing the last available update”. Errors use a warning Notice “Review unavailable”
  with Try Again and preserved private notes; merge completion can say “Review updates combined”. Same-instance
  duplicates are combined on open and after a merge; an already-open review stays the destination. Merge errors
  stay on that review, with Try Again repeating consolidation, never a modal loop. Presenter updates are backed
  by polling that slows to 30 seconds when quiet. Save My Notes…
  writes a manual text recovery/return artifact, including earlier private rounds. Stop Sharing and access changes
  belong to Finder's native sharing options; a local close or failed download never claims revocation. Native
  invitations, access changes and conflict behavior remain subject to the two-Mac live check.
- **Shared review accessibility** (2026-10-13): attribution, With Owner/Changes not sent, sync and New are spoken
  with the card/turn they describe. Decorative initials are hidden from VoiceOver because the name is spoken.
  People and recovery actions remain reachable with visible focus rings; unknown permission never becomes an
  enabled write. Full and compact use the same notes and attribution. Check popover focus, long names, light/dark
  and Reduce Motion live; no contributor dot implies presence or uses looping motion.

### Viewers

- **Viewer status bar**: leading, an accent dot while edited, then a breadcrumb from the explorer root to the file
  (host first when remote); each step reveals itself in the tree and brightens under the pointer, and the file
  step reads as primary. Trailing: the selection as "3 lines · 117 characters" (cursor position when nothing is
  selected; exact Ln/Col in the tooltip), the file's open notes as color dots and a count that opens the notes
  panel, the note steppers, the link and path toggles, a lock when read-only, and a language chip ("Swift",
  "Markdown", "HTML").
  Right-clicking a breadcrumb segment offers what Finder's path bar does: Reveal in Finder and, for the file, Open With
  Default App (local files), then Copy Path (with the "Path copied" confirmation).
- **Viewer toolbar** (`ViewerToolbar`, Viewers package): one 34 pt bar-material strip above every viewer. Leading:
  an icon and what you are looking at ("1,600 × 1,600 px", "Page 1 of 3", "3 rows · 5 columns"), plus the live
  selection in primary. Trailing: how to look at it. `ModeSwitch` (a capsule thumb that slides between options,
  each with a symbol: Rendered / Source, Text / Region) replaces segmented pickers; `ToolGroup` puts related
  controls in one capsule with hairline dividers (zoom − / live % / +, then Fit), using `ToolButtonStyle` (soft
  hover fill, slight press). The zoom readout is live and clicking it returns to 100%.
- **Tool hints** (`ToolHints`, Viewers package): how-to text at a toolbar's trailing edge is a row of short hints,
  each a symbol or key caps plus two or three words, in `.caption` tertiary. Most important first; when the bar
  narrows, hints drop from the end instead of truncating mid-sentence. At most two show inline (`inline:`); the rest wait
  behind a quiet "?" that opens a Tips card listing every hint as a whole sentence (`explained:`, e.g. "Click a
  column header to select the column"), so the bar teaches the next step without becoming a wall of gray text. The
  key caps carry the keys; the sentences never repeat them. Hints follow the state: before a selection
  they teach how to select; with one they show the keys that act on it (esc Clear, ⇧↓ Extend), crossfading
  between the two. Never a full sentence. Used by the CSV grid, the image viewer (Drag a region; esc Clear, Drag again to redraw;
  Click a note to open it once there are notes) and the PDF viewer in Region mode.
- **Rendered code blocks** carry their language in the fill's top-right corner ("Swift", "Python", "Shell"): 10 pt
  medium in the tertiary label color, spelled the way each community spells it, the fence's word as written when
  unknown, nothing on a bare fence. Quote bars are an opaque gray, so where two paragraphs' pieces of one bar meet
  the bar stays even instead of darkening at the seam.
- **HTML in rendered Markdown** is drawn when every tag in it is on GitHub's allowlist and TextKit can draw it (`p`
  and `div` with `align`, `h1`–`h6`, `details` and `summary`, tables, `ul`/`ol`/`li`, `blockquote`, `pre`, `hr`,
  `dl`, `picture`, `img`, `b`, `i`, `a`, `code`, `kbd`, `sup`, `sub`, `s`, `ins`, `span`, `br`); a block with any
  other tag, or a shape it can't lay out (a list in a table cell), stays gray source, so a script or form is never
  half drawn. Each element is drawn as its Markdown twin is: tables with the same tab stops and header fill, lists
  with the same markers, quotes with the same bar, `pre` as a code block. Whitespace collapses as a browser collapses
  it, a summary reads bold behind a ▾ with its details always open, `kbd` is monospaced on the inline-code fill, and
  an `<img>` is a picture like `![]()`, sized by its `width` and `height`, notes and all. Text keeps its source
  mapping, exact wherever it is its own source.
- **Web pictures in rendered Markdown** (badges, screenshots) are fetched as GitHub shows them, from this Mac even for
  a document on an ssh host: a plain GET with no cookies or credentials, 15 s and 25 MB at most, redirected only to
  http(s), kept in memory for every document, and a failure left alone for five minutes. Until one arrives, or if it
  never does, its alt text stands in. Notes on them work as on any picture.
- **Animated pictures in rendered Markdown** (GIF, APNG) play where they sit. TextKit draws an attachment as one still
  image, so the rendered view lays an image view over each playing picture in view (`AnimatedPicturesView`, under
  the notes overlay, taking no clicks) and the attachment draws nothing beneath it; the views exist only near the
  visible area and stop while the window is hidden. Regions, whole-picture notes and the overlay work as on still
  pictures; a crop is the first frame. With Reduce Motion on they hold still on their first frame, and a
  `<picture>` draws the `<source>` whose `media` is `(prefers-reduced-motion: reduce)`, as a browser would. Every
  `<source srcset>` counts as an embed in `EmbedScanner`, drawn or not, so a picture's number never depends on the
  setting.
- **Mermaid diagrams in rendered Markdown** (issue #16, 2026-10-08): a fence whose language is `mermaid` is drawn by
  the Mermaid release bundled in `Viewers/Resources/Mermaid` (MIT, pinned, see `MermaidRenderer.version`), in one
  offscreen web view shared by every document that draws a diagram at a time and closes after 30 s idle. Every
  diagram is laid out on a page of the same size, so none takes its width from the one before. A step that takes
  over 10 s gives the web view up and starts a fresh one; such a failure is not remembered, and the next render tries
  again. The page loads nothing (a content security policy and a navigation policy that refuses every load but its
  own), Mermaid runs with `securityLevel: 'strict'`, and the diagram is snapshotted to a PNG at 2x on the page's own
  background, so HTML labels draw as on GitHub. Drawings are kept by source and theme, up to 96 MB; the rendered
  view's appearance picks Mermaid's `default` or `dark` theme, and a change draws them again, each replacing the old one as it arrives. Until a
  diagram is drawn its code shows; one Mermaid refuses stays code with a line under it giving Mermaid's error. A
  diagram is a picture whose source is `mermaid:` (which no picture's address can be), mapped to its whole fence;
  `EmbedScanner` counts Mermaid fences as embeds of `mermaid:`, ending a fence with the quote or list item that holds
  it, so notes, crops and occurrences work as on any picture, and the packet says `Image: Mermaid diagram (WxH)`. A
  diagram the scanner doesn't see where it is drawn takes no notes, rather than another diagram's number.
- **PDF page thumbnails** (`PDFThumbnailColumn`): for documents with more than one page, a sidebar toggle at the start
  of the PDF toolbar slides in a 120 pt column that maps the document and its notes, as Preview's sidebar maps pages.
  Each page is a small sheet with a soft shadow, lifting a little under the pointer; the current page is ringed in the
  accent color with its number in accent, and the column keeps it in view. A page with open notes carries a badge in
  its corner: up to three of the notes' colors as overlapping dots and their count, popping in on the bouncy curve
  as notes are added. A click goes to the page. Thumbnails render lazily as they scroll in. Off until asked for; the
  toggle draws filled while the column shows.
- **Image viewer canvas**: the picture lies on the under-page gray like a sheet, with a soft shadow (10 pt blur, 2 pt
  drop, 24% black) that stays the same on screen at any zoom. A picture with transparency sits on a quiet
  checkerboard (8-point squares at any zoom; white and 93% gray in light, 20% and 25% in dark), clipped to the
  picture, so its transparent areas are visible instead of blending into the canvas.
- **Rendered images** are set into the page as Bear and Craft set theirs: continuous rounded corners (8 pt, or an eighth
  of the short side for small pictures, so icons stay crisp) and a 0.5 pt hairline in 14% of the label color, so a
  pale image keeps its edge on a white page. Drawn at display time, so the hairline follows light and dark.
- **Notes on rendered images**: a drag that starts on a picture draws a region over it in the image viewer's selection
  style, and a click selects the whole picture; either shows the Add Note button. The note is drawn on the picture as
  the image viewer draws regions (`RegionStyle`), not as tinted text, and its path starts from that box. Regions are
  kept in the picture's own pixels, so they stay put at any pane width.
- **Rendered tables** never start a row with a tab: TextKit draws a faint sliver for a tab at the very start of a
  line, which showed as gray marks down the table's left edge. A left-aligned first column is placed by the row's
  first-line indent; only a right- or center-aligned first column keeps the leading tab its stop needs.
- **Markdown toolbar**: the leading label is what a reader wants at a glance, "412 words · 2 min read", counted on
  the rendered text (no markup) at 230 words a minute, as writing apps show it.
- **Review browser** (milestone 2): one web view (`WebBrowserController`) shows every HTML file and live page, so
  Back and Forward cross from a file to a site and back and a single-page app changes route without reloading; the
  document follows the page (a link to a file opens that file, an http(s) link becomes a web document, Back returns
  to the file's own session). WebKit is the engine; the app is a browser for reviewing only: no bookmarks, passwords,
  extensions or downloads (a response the view cannot show, or a blob:/data: link, is refused with "Downloads aren't
  available here" in the toolbar, in orange; a file input says "File uploads aren't available here"). Only what the
  reader asks for moves the viewer: a click, a form, Back or Forward may open another file or a tunnel; a script or a
  redirect may not (a redirect to a port not yet tunnelled says "This page tried to open port N on its host"). A
  page's alert, confirm and prompt come up as sheets on the window. A closed document's page stops running.
- **Web page toolbar**: leading, Back and Forward (`chevron.left`/`chevron.right`, disabled at either end), then the
  address: at rest a quiet caption, the file's `<title>` with a globe for a served file, the logical URL for a live
  page (`http://localhost:3000/dashboard`, never the forwarded `127.0.0.1:<port>` form); a click makes it a field,
  Return opens what was typed (`localhost:3000` is enough, the scheme is filled in), Escape puts the address back. A
  page reached through an ssh host's loopback wears a teal `via devbox` chip (`network`), the same mark the status bar
  and the notes panel use. Trailing, in Rendered mode: Pick Element (`rectangle.dashed` and its name, accent-filled
  while on, also Notes › Pick Element on Page, ⇧⌘E, enabled only on a rendered page; while on, the hints `↑ ↓ Parent,
  child` and `esc Leave`), Reload (`arrow.clockwise`, for a file it runs the page and its scripts again
  keeping the scroll place), the zoom controls a picture and a PDF have (zoom out, the level, which goes to actual
  size, zoom in; ⌘−, ⌘1, ⌘=; Safari's steps from 50% to 300%, shared by every page), then the Rendered/Source switch; a live page's Source is its current DOM, read-only.
  While the page loads, a 2 pt accent line (`LoadProgressLine`) grows along the toolbar's bottom edge; at the end it
  fills, then fades after 350 ms, instead of vanishing mid-way.
  Edit › Find (⌘F) on a rendered page opens a 30 pt find bar under the toolbar (WebKit has no find bar of its own on
  the Mac): `magnifyingglass`, a "Find on page" field searching as it is typed, case aside and wrapping, an orange
  "Not found" when nothing matches, previous/next chevrons (⇧⌘G, ⌘G; Return and Shift-Return in the field), and
  Done (Escape too). A PDF has the same bar ("Find in document"): PDFKit has none either; the match found is selected
  and scrolled to, and the next search starts from it. So does a spreadsheet's grid ("Find in table"): row by row,
  each matching cell is selected in turn, as a click would, ready for a note.
- **Pictures on a page** (decided 2026-10-06): no mode, as in rendered Markdown. A press on an `img`, `picture` or
  `svg` (found through transparent wrappers and links laid over it, never through text or through something that
  paints its own background) starts a picture gesture, except on one inside a button, label or other control, or
  one the size of an icon (under 48 pt both ways), whose click stays the page's; a `canvas` or `video` is left to
  the page too (its controls, a map), and so is a picture marked `draggable` or one the page moves under the drag (a
  carousel), and Pick Element reaches all of them. Past 3 pt the gesture drags out a region,
  otherwise the release takes the whole picture. The choice is drawn like a crop tool, as `RegionStyle` draws it
  in the other viewers: the rest of the picture dimmed, a white edge with a dark outline, L-shaped corner handles,
  and a size pill below in the picture's own pixels (`naturalWidth/Height` after `object-fit` and
  `object-position`; an svg's displayed size). It is a selection: the floating Add Note button and ⌘↩ sit beside
  it and follow it as the page scrolls. The first click on a linked picture chooses it instead of following the
  link; a second click on the chosen picture goes on to the page; a click elsewhere, or a text selection, puts it
  away. A drag that starts on text still selects text.
- **Element notes**: in Pick Element mode the pointer outlines the element under it in the accent color, the
  picture under the pointer before its wrappers, with a label naming it and its parent (`div.card › img`; an overlay
  above the page that takes no clicks and adds no text, so text offsets never move); ↑ steps to the parent and ↓
  back down (or to the first child). A click opens the note editor at that element at once, no Add Note pill in
  between, and a drag across a picture picks a region of it (the way to a region on a picture the page itself makes
  draggable); Escape leaves the mode, a pick leaves it too. A committed element note draws as a 2 pt outline in its
  color with a 12% fill, over just its region on a picture (the stored pixels scaled to the picture's size now)
  (drafts full, sent 70%, resolved 35%, orphaned dashed, a `?` badge while it needs a glance), and carries a 2x crop
  of the element (of the chosen part, on a picture) taken before the outline exists and with the choice's dimming
  put away. The note card reads `Element [data-testid="save"]`, or `Image img, region 300×150` on a picture: the last
  compound of a selector that prefers an id, then a `data-testid`, then a `tag:nth-of-type` path, never class
  names. When the page changes, the element is found again by selector, then by text (one match moves the note
  and flags it; several pick the nearest; none orphans it), and a page back exactly as it was returns an orphan to
  a draft.
- **Title as address bar** (`TitleAddressBar`): the window draws no title of its own (`.toolbar(removing: .title)`;
  `navigationTitle` still names the window for Mission Control and VoiceOver). Beside Back and Forward, the document's
  name (`.headline`) over its subtitle (`.caption`, secondary: the ssh host, `owner/repo #12`, a page's title) sits
  without a glass capsule and gains a faint rounded fill on hover, so it reads as clickable without looking like a
  button. A click, File › Open Location… (⇧⌘L) turns it into a 460 pt field holding the
  page's live address or the file's path. The field (`AddressField`) has a leading globe or folder that follows
  what the text reads as, and, when ssh hosts exist, a small menu at its end naming the machine (This Mac in
  secondary, an ssh host in teal) that keeps the caret in the field. Return opens; text that is neither an address nor a path shakes
  the field (not with Reduce Motion), outlines it orange and says "Not an address or a path" inside it, announced
  to VoiceOver. Escape or a click elsewhere puts the title back; an open menu (the host
  menu, the menu bar) does not, and the caret returns to the field when it closes. The browser's own toolbar
  keeps only Back, Forward and the "via host" capsule.
- **Web in the explorer**: the root switcher's hosts always list Web (`globe`) after this Mac. Picked, the tree and
  filter footer give way, under the switcher, to an `AddressField` (which also narrows the lists as you type; Return opens what was typed)
  and a sidebar list of Pinned and Recent pages: the title over the address in caption, a teal host name for a page
  reached through an ssh host, the page in the viewer selected. Double-click or Return opens a row; arrows only move
  the selection. Context menu: Open, Pin or Unpin, Copy Address, Remove from Recent. Reveal in Explorer (⇧⌘J) on a page picks Web.
- **Wrapped lines keep their indentation**: when lines wrap, a line's continuation rows start at its own
  indentation plus one four-space step (as Xcode and VS Code wrap), so a wrapped comment or argument list never reads
  as a new line of code. The indent is capped at 40% of the column for deeply nested lines (re-measured when the column's width changes by
  40 pt or more, so narrowing the window never leaves a continuation with no room), follows typing just after
  each edit (never inside it: restyling there moved the caret to the next line on every keystroke), and is a
  paragraph attribute only: the text and every note anchor are untouched.
- **Changed lines** (a pull request's file, milestone 2): rows the pull request added or rewrote are tinted green
  across the whole width (`Theme.changeAddedBackground`, 10%, lighter than a resolved note so a green note on an added
  line still reads), with a 2 pt green bar at the gutter's text edge as VS Code marks changed rows; a red hairline
  across gutter and text marks where lines were taken out. The minimap shows hunks in a lane of their own
  under the notes (green bars, red ticks for deletions), clickable. The status bar reads "3 changes" with ⌃/⌄
  steppers, "2 of 3" while stepping; Go › Next Change (⌥⌘↓) and Previous Change (⌥⌘↑) walk the hunks from the
  caret and wrap, landing each with the find indicator. A reload after a new commit shows "Pull request updated" for
  eight seconds (an Atlassian document says "Updated in Jira or Confluence").
- **Minimap** (`MinimapView`, 2026-10-09; replaced the 12 pt overview ruler): a 100 pt picture of the whole file at
  the editor's trailing edge, as VS Code draws one. Each run of characters is a block in its syntax color (55%),
  two points to a line and 0.8 pt to a column, tabs to four-column stops, clipped past the width. Geometry is in real
  points, so a short file is a short picture at the top with marks a line tall (the ruler stretched a five-line file
  over the pane, a one-line note a fifth of the window); a file taller than the view scrolls in step with the editor.
  Notes tint their lines across the picture with a 3 pt bar at the trailing edge, on the state ladder (drafts over
  settled work, orphans outlined, a removal a hairline); hunks keep a lane at the left. A slider covers the source
  lines on screen (a wrapped line counts once) and is hidden while the whole file shows. A click on a note scrolls to
  it as browsing the notes panel does (the keyboard stays put); a click elsewhere centers that line and a drag moves
  the slider. Shown for every file in the editor (text, code, Markdown and HTML source); Settings › Editor › Show
  minimap turns it off, and then it takes no room. A highlight whose text was replaced while editing (invalidated)
  leaves it, as it leaves the gutter.
  Rendered Markdown has its own (`RenderedMinimapView`): the whole rendered page, laid out once more offscreen at the
  reading column's width (TextKit 2 lays out only near the screen, so the view itself cannot be snapshotted) and drawn
  shrunk to the strip: headings, code blocks, tables, quotes, pictures and diagrams as they render. It is rebuilt
  once the rendered text, column width and display have held still for 150 ms (never during a live window resize;
  an appearance change alone rebuilds at once), and skipped past 150k characters. Notes
  tint the lines they cover, notes on pictures their region; the slider and clicks map through text locations rather
  than pixels, since the view's own height is partly TextKit's estimate. Both minimaps draw their chrome through
  `MinimapStyle`.
- **Removal points** (2026-10-07): a note whose text an agent or an edit removed is a point where the text was
  (a zero-length anchor), at the start of what now sits there (never the end of a heading above it), drawn as a caret: a 2 pt bar in the note's color, the line's height, with a small round
  cap at its top, at the state ladder's strength (full when focused). The gutter marks its row with a hollow dot in
  the note's lane, the minimap with a hairline, and the path ribbon reaches the caret (`NoteGeometry` gives a
  2 pt rect for a point). Rendered Markdown maps the point to one rendered point (the start of an inexact run, never
  the whole block) and draws the same caret; a web page's text note draws it as an element in `<gloss-overlay>` at
  the collapsed range, since a CSS highlight of nothing shows nothing.
- **Stepping through notes**: Go › Next Note (⌘') and Previous Note (⇧⌘'), the keys Xcode uses for issues, and
  ⌃/⌄ steppers beside the status bar's note count. Open notes go in reading order (text by offset, PDF by page then
  top to bottom, images in the order made); a step goes on from the note last reached, or from the caret once it has
  moved, and wraps at either end. Each step shows the note without selecting it (so Add Note never floats over a note
  that exists), pops the find indicator, and selects its card in the notes panel; the count reads "2 of 5" while a
  stepped-to note is current. Nothing to step to beeps.
- **Link and paths** (`NoteLinkModel`, `NotePathLayerView`, `NotePathGeometry`): two toggles after the note steppers
  in the status bar, in the steppers' style (18 × 16, accent glyph on a faint accent chip when on, the glyph struck
  through by a thin diagonal when off, since SF Symbols has no unlinked or broken path), also in the menus
  (Go › Follow Page in Notes Panel, View › Show Paths to Notes); both remembered. **Link** (`link`) makes the notes panel follow
  the page: the visible note nearest the middle of the page (one the middle runs through first, then the nearest
  edge, then the one higher on the page) has its card scrolled to the middle of the list (smooth, instant with
  Reduce Motion). It is one way, and it waits while the pointer is over the list, so the list never moves under the
  reader; turning it on opens the panel. **Paths** (`point.bottomleft.forward.to.point.topright.scurvepath`), only
  while linked, joins each visible note to its card in the note's color:
  - *Outline*: 1.5 pt out from the highlight, built rather than merged: the highlight's pieces on one line (cells,
    inline code, styled runs) are one span, wrapped lines and a paragraph gap join into one staircase, and every
    corner, convex or concave, is rounded (3 pt, less where an edge is short), as macOS draws a multi-line
    selection. Nothing inside the note is ever stroked.
  - *Path* (#11, drawn to the user's wireframe): it leaves the middle of the outline's rightmost edge, level (on
    the line that reaches furthest right, so nothing of the note lies beyond it), runs a short level stub (8 % of the
    way, 8–40 pt), then one S with level handles half the span long carries it the whole rest of the way, gentle
    however far it climbs or drops, and arrives level at the middle of the card's color rail, meeting the bar at a
    right angle.
  - *Ribbon*: filled, not stroked: 1.5 pt (2.5 strong), a round start and a square end flush against the rail's
    side, colored from 75 % to the note's full color. Settled notes at 45 %, as the rail. The hovered card's, the
    selected card's, and the note under the pointer on the page draw strong (2.5 pt, the rail's glow) and over the
    others.
  - *Motion*: drawn by AppKit layers in the window's frame view above the content, updated from the viewer's own
    scroll notification, so outlines move in the same frame as the text; ribbons follow the cards as the list
    scrolls and fade out over the last 12 pt as a card leaves the list. Showing and hiding fades in 0.2 s.
  Every viewer that can place a note reports it through `NoteGeometry` (text by line fragment, rendered Markdown,
  PDF regions and text, image regions, grid cells and rows, a web page's element notes and text notes); Quick Look
  has no place to point at, so its note goes without a path.
- **Landing on a note**: every jump to a range (a minimap mark, a card in the notes panel, a search result) ends with
  AppKit's find indicator over the target, the brief yellow pop Xcode uses, so the eye finds where it landed
  instead of scanning. A note over several lines pops on its first line only; caret moves (no range) don't pop.
- **Indent guides**: a hairline at each indentation level a line sits inside (the step is read from the file, so
  two-space YAML gets two-column guides), spanning all of a line's wrapped rows. Blank lines inside a block take the
  shallower neighbour, so guides run through gaps. The block around the caret (or the block a line like `func x() {`
  opens) is drawn stronger, the way Nova and VS Code mark the active scope. Quiet enough to sit under text: 7–8%
  of the label color, the active one 22–24%. Settings › Editor turns them off; its preview draws a guide and wraps
  with the editor's hanging indent, so it shows exactly what the editor will do.
  Guides are built for the lines on screen plus 200 either side, read through the editor's own line index
  (`IndentGuides(window:…)`), and rebuilt only after an edit or when scrolling nears that window's edge: about
  0.3 ms per keystroke in a 45,000-line file, where rescanning the whole text took about 38 ms.
- **Current line**: in the focused editor with a bare caret, the caret's line (all of its wrapped rows) gets a
  full-width neutral band (4% black, 5% white in dark), carried across the gutter so number and line read as one
  row; the number turns `labelColor`. No band while text is selected (the selection marks the place) or while the
  window or editor is not focused. It follows the caret instantly, without animation.
- **Gutter note bars**: each note is a 3 pt rounded bar in its color beside the line numbers, spanning every line
  it covers. Overlapping notes take side-by-side lanes (up to three, 2 pt apart). Strength follows state: open
  notes 85%, resolved 30%, orphaned a dashed outline. Hovering a bar widens it, shows a pointing hand, and opens the
  note's peek; clicking edits the note. The current line's number is primary, the rest tertiary.
- **Go to Line**: a 460 pt palette in the Open Quickly family: a `.title2` field with "of 24" (real lines; the
  empty spot after a final newline is not one), a live preview of the target line between its neighbours with the
  target washed in accent, a hairline position bar showing where it sits in the file, and a footer that explains
  the input ("Past the end, so it goes to the last line, 24"; orange when it cannot be read) with key caps.
- **Conflict sheet**: a tinted icon tile (accent "merge" when the edits don't overlap, orange when they do), the
  file name, one sentence on what happened, and a count ("1 change of yours · 1 change from disk"). The merge view
  folds long unchanged stretches; each change has a colored side bar and a label (Yours blue, On disk green, Both
  teal); a conflict is an orange card with Yours and On disk side by side, never git markers. Buttons say what they
  do (Save Mine As…, Use Disk Version, Keep Mine, Merge and Save) with tooltips on the consequence. Merge is the
  default when it is safe; with a real conflict nothing is the default, because overwriting someone else's change
  must be a deliberate choice. `ConflictContent` renders without a session for review.
- **Image viewer**: the picture sits centered on the under-page backdrop (`CenteringClipView`). On open, a large
  image shrinks to fit and a small one shows at actual size; the view keeps fitting as the pane settles or
  resizes until the user zooms (pinch, +/−, 100%). Choosing a region looks like a crop tool: the rest of the image
  dims to 42%, the edge is white over a dark outline, white L-handles mark the corners, and a dark pill below the
  region gives its size in pixels (Add Note owns the space above). Note regions are rounded tints with a colored
  border and a tab at the top-left corner; the note selected in the panel gets an accent halo. Strokes, handles,
  and labels are sized in screen points at any zoom.
  Edit › Copy (⌘C) copies the selected region (or the whole picture with nothing selected) as PNG and TIFF, so it
  pastes into chats, issues, and editors; the selection hints show "⌘C Copy" here and in the CSV grid. A PDF region copies the same
  way (rendered at 2×; drawing a region gives the PDF view focus so ⌘C reaches it; every other menu item is still
  validated by PDFKit itself), and with no region PDF Copy stays PDFKit's text copy: copying means "what is selected",
  whatever the viewer. Each copy says so: a green "Copied" capsule (`CopiedBadge`) springs into the toolbar for
  1.2 s, so ⌘C is never silent. Copies with no toolbar of their own (context menus in the tree and on note cards) show a glass
  "Path copied" / "Comment copied" capsule at the bottom of the window for 1.4 s (`CopyHUD`); packets confirm
  through the send toast.
- **PDF pages are sheets**: on the under-page backdrop like images, with page breaks, page shadows and 20 pt
  margins, so where a page ends is visible (it read as a text file edge to edge before).
  While the pages move, a glass `PagePill` ("2 / 5") floats over the bottom center, counting with numeric text and
  fading 1.2 s after the last page change; never on open and never for a single page.
- **Regions are one style everywhere** (`RegionStyle`, Viewers package): images and PDF pages draw note regions
  and the region being chosen with the same code — rounded tinted notes with a color tab and a selection halo; the
  crop-tool selection (dimmed surroundings, white edge over a dark outline, outlined white L-handles, a size pill
  below in px for images and pt for PDFs). The PDF overlay is flipped so both share it.
- **CSV grid**: values in the system font; columns whose every value is a number are right-aligned in monospaced
  digits (header too) so magnitudes line up. Headers show the column letter in tertiary monospace and the name in
  semibold. A row note tints its row softly (12%; 5% resolved) and puts a 3 pt color bar beside the line number,
  the same mark as the editor gutter; cell and column notes tint only their cells.
- **CSV grid sizing**: each column starts as wide as its header or the widest of its first 200 values, plus padding,
  between 64 and 320 pt (`CSVGridController.columnWidths`); people can still drag it wider. Zebra stripes sit behind
  records only, so a short file ends where its data ends instead of striping the whole pane.
- **CSV copy**: Edit › Copy (⌘C) puts the selection on the pasteboard as tab-separated text, the form spreadsheets
  paste into cells: whole records for rows, the header then values for columns, and for scattered cells the
  smallest block holding them with the gaps empty; tabs and newlines inside values become spaces.
- **Event-tracking loops end on the button's real state**: a manual drag loop also stops when a periodic event
  finds the mouse button up, so a lost mouse-up can never leave a window deaf to clicks, keys, and URLs.

### First run, loading, and empty states

  The wait itself times out (0.1 s) rather than relying on periodic events, which stop arriving in some states:
  the CSV drag loop hung the whole app (quit included) when a click lost its mouse-up.
- **Resume where you left off** (#9): the workspace (`general.workspace`, JSON: folders in tab order and the one in
  front, the document in front with the line at the top of its view and rendered or source, Back and Forward, the notes
  panel) is saved half a second after any of it changes and again at quit. Settings › General › "When Gloss opens,
  reopen" picks Everything, The last folder (the folder and its document, as before), Nothing, or As my Mac does
  (the default: Everything unless "Close windows when quitting an application" is on, then The last folder). Restoring
  opens folders in order and passes over a missing folder or a host that won't connect; the document comes back with
  its line at the top of the view (a caret, not a selection: resuming is not a jump). Launch options win.
- **Welcome** (`WelcomeView`): with no folder open, the main pane greets instead of asking for a file: the app
  icon (springs in, 0.6 s, once), the name, one line on what the app is for, then the one first step as a
  `.glassProminent` Open Folder… with "On a Host" (a menu of ssh hosts) beside it, and up to four recent folders
  (favorites starred, last opened as relative time). The sidebar's own empty state drops its button for this Mac,
  so there is one first step on screen, not two; the notes panel keeps its three steps for what comes next.
- **Opening and failing**: a document that is still opening shows nothing for 250 ms (local files are there by
  then; a spinner that flashes reads as a glitch), then fades in the file's icon and name with a small spinner and
  "Opening…" ("Opening on devbox…" for remote hosts). A failed open says what happened in a sentence (not a Swift
  error) and offers Try Again (`DocumentSession.openFailure`, `retryOpen`).
- **Pick up where you left off** (`OpenWorkList`): under the empty viewer's Open Quickly, up to five files in the
  open folder with notes still in play (drafts, sent, questions back, orphans), most recently touched first. Each
  row: the file's icon, name, its folder inside the root in `.caption` secondary, then counts with the state symbols
  (attention orange, drafts, sent blue); a chevron slides in under the pointer. Rows fade up one after another
  (40 ms apart) on arrival; with Reduce Motion they simply appear. Hidden when nothing is open.

### Color and motion

- **Motion budget**: nothing animates forever while the app is idle. Symbols breathe twice on arrival; only a live
  state (an agent working, a mode in progress) may loop, and then only in Core Animation (`PulseRing`), which the
  render server runs: an endless symbol effect kept the app at 25% CPU and starved clicks, and a SwiftUI phase
  animation on the status dot cost 20%; the Core Animation ring costs ~0.2%.
- **Highlight strength follows open work**: drafts 28%, sent 18%, resolved 8%; a note the agent answered with a
  question (`displayState`) is drawn as a draft, never faded. Checked in light and dark mode.
- **Dark appearance**: note tints are 30% stronger in dark (`Theme.darkBoost`): over a near-black page a light tint
  mixes toward mud (yellow turns olive). Web pages keep the light tints, since a page brings its own background.
  Quiet text that is fine on a light sidebar (tertiary) moves up to secondary over dark vibrancy when it is small,
  as the tree's folder counts do. Check both with `--appearance dark|light`.

### Settings

- **Themes tab** (2026-10-13): `paintpalette`, after Editor, a scrollable grouped form at the standard 600 pt
  Settings width and 620 pt height. “Colors and fonts for code. Gloss follows your Mac's appearance and uses the
  theme you choose for each.” Light Appearance and Dark Appearance each have a Theme picker, a 164 pt sample
  drawn in that section's appearance, and Edit…, Duplicate, Export… and Delete…. Gloss is the adaptive default
  in both; built-ins say “Built-in theme · Duplicate to edit” and disable Edit/Delete. Import… is common to both,
  with “Reading theme…” while parsing, quiet file problems and the Theme palette licenses disclosure below.
  Changing a picker restyles open code immediately; an inactive choice changes its preview until that appearance
  is active. Missing/broken files say “Solar Copy isn't available. Using Gloss.” without a document banner;
  preserving the chosen id lets a repaired file return. Editor keeps Default code font size, wrap, guides and minimap.
- **Theme editor** (2026-10-13): a fitted, resizable sheet, 760 × 580 pt initially, up to 1100 × 900 pt. Name has
  initial focus, beside Light/Dark Appearance; the title is Edit Theme, Duplicate Theme or Import Theme. An
  `HSplitView` keeps Tokens | Editor | Font controls at the left and Code | Markdown | Diff preview at the right.
  Token rows show names and swatches; the selected row has a color well, hex field, Use Foreground, Bold and
  Italic. Additional token styles expands imported/specific keys. Editing a row clears only the descendants
  and aliases owned by that row (PM decision, 2026-10-13), never another editable row or its keys. Punctuation
  keeps Special Punctuation, Variable keeps Built-in Variable, and Link keeps Link Label and text.reference;
  Heading still replaces its own text.title override. Ownership uses the longest editable-key match, then its alias. Editor lists Background, Foreground,
  Selection, Current Line, Gutter Background, Line Numbers, Current Line Number, Invisibles, Caret and Code Block
  Background. Caret stays the system accent unless a theme sets a custom cursor; choosing a system cursor
  restores AppKit's native caret rather than pinning a sampled color. Font offers System Monospaced/installed families, fractional 9–20 pt Size and 1–2× Line Spacing,
  each numeric field with Use Default; “Font not installed. Using System Monospaced.” explains a fallback.
  Source and license and the warning count stay secondary in the footer; Cancel and Save (Add Theme for an import)
  are always visible. Theme colors belong to the preview/code page; controls and other reading surfaces stay system.
- **Saving a theme** (2026-10-13): existing-theme edits preview live in open code without changing text, undo,
  selection or the line at the top. Cancel loads the current file; Duplicate/import saves no file and selects
  nothing until Save/Add Theme. “This theme changed outside Gloss.” keeps the draft and offers Replace File or
  Save a Copy; canceling the editor uses the current disk version. A failed save keeps its fields and offers
  Try Again. Delete asks “Delete ‘Solar Copy’?” and says “This removes the theme file from Gloss. Any appearance
  using it will use Gloss.” Cancel and Delete Theme are the actions; deletion moves the user file to Trash,
  resetting every affected choice. Export uses the native save panel and keeps source/license metadata.
- **Importing a theme** (2026-10-13): the native file panel says “Choose Gloss JSON, an Xcode color theme, a
  TextMate theme, or a VS Code theme.” The Import Theme sheet uses the same editor/preview, with a disclosure
  headed by the actual mapping report, such as “Mapped 18 token styles from 64 rules; 9 scopes had no match.”
  Unmatched scopes/skipped features stay in its detail; “No token styles mapped. Unmapped tokens use Foreground.”
  explains an empty token mapping. Name/appearance can be changed before Add Theme; a fresh id protects existing
  files. Xcode imports use a fixed key priority rather than dictionary order: type prefers identifier.type,
  identifier.class, then declaration.type; function prefers identifier.function, then declaration.other.
  Doc-comment markup fills only unset captures, and unreadable mapped colors are reported as skipped. No code
  runs and no external include or path-valued tokenColors file is read. Failure stays in Settings and leaves the
  chosen theme alone.
- **Theme legibility and accessibility** (2026-10-13): token contrast below 3:1 and foreground below 4.5:1 shows a
  warning symbol and “Low contrast · 2.4:1”; the footer says “3 colors may be hard to read.” Low contrast never
  disables Save; malformed color/font input does. Wells/hex fields name their token or editor color, Bold/Italic
  are separate controls, and the Name field starts focus. Selection clashes say “Selection resembles a note fill.
  The editor uses a distinct tint.” Notes keep their six identities, state symbols and fill/underline/dotted/dashed
  grammar. Their colors stay plain system colors on prose, PDF paper, image regions, cards and other UI
  surfaces. Only editor/gutter/source minimap and rendered code-block notes use contrast-adjusted colors on a
  non-system theme background; Gloss is unchanged. Selection draws covered note underlines again above it. Code quotes get legible token colors on their own UI surface while
  keeping UI sizing. Chrome and note legends remain system colors. Verify focus/VoiceOver and all preview modes
  live; no theme change needs a moving transition or overrides Reduce Motion.
- **Agents tab**: one place for everything that connects an agent, top to bottom: the MCP server's status and port;
  a section per machine (This Mac, then each connected host) with Claude Code, Codex and OpenCode, each installed
  by its row, whose copy icon (its tooltip says what it copies) takes the registration Install runs, for whoever
  would rather run it;
  the Herdr plugin last on each machine; then "Other agents", copy for any harness Gloss does not set up (the
  endpoint, the `Authorization` header, and a generic `mcpServers` entry). A machine where an older build left its
  prompt hook shows that agent's row as Update, the reason in orange ("…a prompt hook that sent drafts without Send").
  Where notes go is the notes panel's agent chip, not a setting, so it is not repeated here. The integrations are optional and independent, so no Install button is prominent (glass,
  not glass prominent); only Update, on an outdated row, asks for attention. A footer with a shield says what
  Install touches and how to undo it: nothing changes until you press Install, each edited settings file is first
  copied beside itself (`*.gloss-backup-…`, the last three kept), and Remove takes out only what was added.
- **Settings**: every tab is a `.formStyle(.grouped)` form, 600 pt wide, with its own height so the window
  resizes to each tab as System Settings does (General 684 with its Updates section, 540 without it, Editor 380, Themes 620, Notes 560, Agents 640, Integrations 660, Attachments 380, Hosts 440). The Notes tab holds Review (Review agents' work), Iterations (open notes, the two
  automatic starts, snapshots kept) and Recently Deleted's retention. Toggles
  carry a second line saying what they do; words match the rest of the app ("folder", never "root"). A setting
  shows its effect where it can: the editor font slider drives a live code preview, with the size in monospaced
  digits beside it. A setting must do something, at once: Editor's default code font size (for themes without an
  explicit size), wrapping, and indent guides restyle every open editor as they change (`Theme.editorSettingsDidChange`), keeping the line at the top of the view
  in place, so the slider can be dragged while watching real code. Attributes only: text, undo, and anchors stay.
  Sections have a header and a footer that explains them; explanations never sit as rows of their own. Live state
  reads as a status line with a colored dot (MCP: green listening, red with the error). Text people copy into a
  terminal or config is a `SnippetCard`: name (and file, if any) with a Copy button that turns into a green
  "Copied" check for 1.6 s, then the text in a monospaced code box. A command is never wrapped (a break mid-URL
  read as two commands): each line stays whole, the box scrolls sideways, and its trailing edge fades over 20 pt
  to say there is more, as code blocks do on GitHub and Linear.
  Storage reads as what it is for, not where it lives: a `StorageRow` names the contents ("Crops and page
  renders"), shows the size ("Empty" at zero) and a Show in Finder button with the path in its tooltip. Clearing
  anything an agent might still read asks first and says what stays.
  A host is a `HostRow`: a server symbol with its connection state as a dot (green connected, orange connecting,
  red failed, gray idle), the name, and a second line with the address and state (ssh config aliases show only the
  state, with an "ssh config" tag, since their address lives in that file). Hosts added in the app can be edited
  and removed; removal asks first.
- **General › Updates** (release builds): "Check for updates automatically" (Sparkle's own setting), "Last checked"
  with the relative date and Check Now. The update dialog itself is Sparkle's
  standard one; the release notes in it use the system font and follow light and dark (the appcast's stylesheet).
- **Feedback sheet** (`ladybug` in the toolbar, before the notes toggle; Help › Report a Bug or Request a Feature…):
  480 pt, title "Send Feedback" and a line saying what it is for; a segmented Bug / Feature Request (ladybug,
  sparkles); a title field whose prompt is an example of a good title; a description box with a placeholder asking
  for what happened and what was expected (or what it would help with); a checkbox "Include Gloss and macOS
  versions" with the exact line under it, dimmed when off. The footnote says who it is sent as ("Sent as @login"),
  or "Opens on GitHub to finish." when there is no key, and the default button reads Send or Continue in Browser
  to match. A refusal shows in orange above the buttons and turns Send into Continue in Browser. Sent, the sheet
  becomes a green check that bounces once, "Thanks, we've got it.", with View Report and Done.
- **Integrations** (`key`): one section per service, GitHub and Atlassian. Each has the Status line (dot and
  sentence: "Signed in as octocat · repo, user", "Sam Rivera · Jira and Confluence", or the service's own error),
  a `SecureField` for the token (its prompt says "Saved · paste a new one to replace it" once one is), Atlassian's
  site and email fields with the saved values as prompts, and Save (glass), Test Connection and Remove. The footer is
  the trust note, with `lock.shield` as on Hooks: the app only reads with these keys, the agent makes every change,
  and keys live in the Keychain. Saving tests the key first: a key the service refuses is not saved and the sentence
  says so ("…It wasn't saved"); one that cannot be checked (offline) is saved and says it could not be checked.
  Remove asks first when it would close open pull requests, issues or pages. Integration roots offer Copy URL in the
  tree's menu instead of Copy Path, and Find in Files is off for them, as Open Quickly's file list is (they are browsed,
  not searched; Open Quickly still takes addresses and pages there).
