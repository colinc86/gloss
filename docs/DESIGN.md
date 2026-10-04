# Gloss design language

A reading-and-annotating tool sits beside an editor and a terminal all day. It should feel calm when you are reading
and precise when you act. These rules are implemented in `Gloss/Design/DesignSystem.swift` (`DS`); use
the tokens and components there instead of literals.

## Principles

1. **Content first, chrome quiet.** Files and notes carry the colour and weight; controls sit back until the
   pointer or the selection arrives, then brighten. Nothing is hidden that has to be discovered: quiet, not absent.
2. **One meaning, one look.** A note state always shows the same symbol and tint (`NoteState.style`) in pills,
   filters, and highlights. Symbols carry meaning for people who cannot tell the tints apart.
3. **Open work leads.** Drafts and questions from agents stand at full contrast; resolved notes step back.
4. **The next step is obvious.** Each surface emphasises one primary action (a draft's Send) and keeps the rest
   secondary.
5. **Motion explains change.** Animate what moved or changed state, briefly; never decorate.
6. **Native first.** System materials, SF Symbols, system colours (light and dark), continuous corners, standard
   controls where they exist. Custom views only where the system has none.
7. **Code stays code.** Wherever a file's text is quoted (the composer, note cards, search results, the Go to Line
   preview, rendered markdown), code keeps the editor's syntax colours
   (`SyntaxTheme.highlighted`, worked out once, never per redraw); a command people copy, or a card's excerpt,
   stays on one line rather than wrapping mid-token. Prose stays plain: a lone markdown line out of context colours as noise. The one exception is a diff,
   where colour already means added and removed.
8. **Glass for controls, a page for reading.** Bare `glassEffect` is for controls floating over content (buttons,
   pills, the Add Note button). A floating surface people read (a peek, a toast with a sentence) uses
   `readableGlass`, so the content behind never crosses its words.
9. **Empty says why.** An empty view names what made it empty (the search, the colour, the tab), says what belongs
   there and how it arrives, and offers the one way back. Emptiness that is good news says so ("All clear").
10. **Say what a risky action touches.** Where the app writes outside itself (hooks, settings files), the screen
    says what changes, where the backup goes, and how to undo it, before anything is pressed.
11. **The app reads, the agent writes.** What the app shows of a pull request, a ticket or a page is the live
    thing, read with the user's own key, and the app never changes it: every edit goes through the agent with its
    own tools, and the packet names the exact resource (URL, head commit, field, version) so the agent can. Settings
    say this where the key is entered.

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
colour. Every transition that slides, grows, or offsets a view is written `.transition(AnyTransition….calmed)`:
with Reduce Motion it becomes a plain fade, so toasts, banners, bubbles, and the thumbnail column arrive in place
instead of travelling (Apple's guidance: replace motion, don't just shorten it). Never write a moving transition
without `.calmed`. Tests set `Motion.reducedOverride`.

## Type

System font only. Body text `.callout` in panels; metadata `.caption` medium, monospaced digits for line numbers;
pills `.caption2` semibold. Secondary information uses `.secondary`, never a smaller size alone.

## Accessibility

- **A composite reads as one sentence, and says what the screen shows.** A note card is a single VoiceOver element:
  "Draft note, yellow, Line 9. On: var isSteep: Bool { … }. Use 10%." The "On:" part is the excerpt well a sighted
  reader sees; the agent's turn is worded as the bubble words it ("Agent asks:" for a question, "Agent replied:"
  otherwise). When something visible is added to a card, its spoken summary gains it too. Its buttons and context-menu commands are its
  accessibility actions, built from the same `commands` builder as the menu so the two can't drift.
- **Every mark that carries meaning is spoken.** Tree rows add their note count, "needs attention", "open notes
  inside" for folders, and "contains the open file" for the path dot (`FileCellView.spokenLabel`).
- **Selected options say so** (`.isSelected` on filter chips, mode switches, swatches); icon-only buttons have
  labels as well as tooltips; colour never carries meaning alone (state symbols beside tints).
- **Focus starts in the content, and focus rings are never hidden.** With keyboard navigation on (System Settings ›
  Keyboard), every control shows a ring when it has focus; that ring is how people who use the keyboard know where
  they are, so nothing suppresses it (no `.focusEffectDisabled()`, no `.focusable(false)` on controls people use).
  What matters is where focus starts: the main window gives it to the file tree (`TreeOutlineView`), popovers
  with a field focus the field. Tab order in the main window (checked with an `AXFocusedUIElement` probe, 2026-10-03): file
  tree, its filter field, Find in Files, hidden files, host picker, follow, sidebar toggle, notes toggle, the
  viewer's content, the filter chips (one stop each), notes search, sort, agent chip, Send menu, the notes list,
  then the folder switcher. Every control is reachable; a change that adds or groups stops re-checks this order.
- Check with the accessibility API (an `AXUIElement` walk), since System Events does not reach into SwiftUI lists.

## Window and layout

- **Opening the notes panel makes room first.** Like Xcode's inspector, the panel grows the window by its 300 pt
  (capped at the screen) before it appears unless the window already has that slack over its minimum, so a window saved narrow while the panel was closed
  can't leave sidebar + viewer + panel impossible to fit (`NotesPanelRoom`; that state crashed AppKit at launch). The resize animates (0.2 s, none with Reduce Motion) outside SwiftUI's update and the panel appears when it ends;
  if the screen stops the window short of room, the panel stays closed with a beep rather than opening into an
  impossible layout.
- **Controls compact before they clip.** A `ModeSwitch` drops its titles for symbols (titles move to tooltips and
  stay the VoiceOver labels) and the image viewer's Fit becomes its symbol when the toolbar is tight
  (`ViewThatFits`). Avoid ViewThatFits in the window toolbar itself: a label that changes shape there changed the
  split view's minimum size mid-layout.
- Minimum window widths with the notes panel open (sidebar at its smallest): about 1020 pt for text, 1100 pt for
  the richest viewer toolbars; hide the panel or the sidebar to tile the window beside a terminal.

## App icon

The app at a glance: a white page of lines, tilted a little, with one line marked by a yellow draft highlight and
its rail, on an indigo-to-blue squircle; a white badge in the corner carries the accent paper plane flying up
and right (sending, not landing). Standard macOS grid (824 pt squircle in 1024, soft drop shadows). It is drawn by
`docs/icon/draw-icon.swift`; to change it, edit the script, run `swift docs/icon/draw-icon.swift out.png`, scale
to 1024 px, and write the ten sizes into `Assets.xcassets/AppIcon.appiconset`. After a rebuild the Dock may keep
the old icon until the bundle is touched and re-registered with `lsregister -f`.

The About panel is the standard one with credits (`AboutPanel`): one line on what the app does, in label colour,
then what it is built on, smaller and secondary.

## Dock

The Dock icon badges the number of notes an agent answered with a question (resolved, needs input): the app usually
sits behind the agent's terminal, and a question waiting on you should be visible from there, as unread mail is.
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
⌘W). Menu items are title case and say how much they touch: "Send All Drafts (5)", "Copy This Document's
Drafts as Packet (2)", disabled when there is nothing to act on or no agent to send to. Window tabbing is off (`NSWindow.allowsAutomaticWindowTabbing`), since the folder switcher does that job.
Every text field has a way in from the keyboard: View › Filter Files (⌥⌘J, as Xcode's navigator filter) and
Notes › Search Notes (menu only: ⌥⌘F is Find and Replace in most Mac apps) put the caret in their fields, as Find
in Files, Open Quickly, and Go to Line do. New shortcuts follow the conventions of Xcode and the system before
inventing one; when a natural choice is taken elsewhere, the menu item alone is fine. Search and filter fields
behave like Mac search fields: Escape clears the text, a second Escape leaves the field (Find in Files closes).
Commands that act in the main window bring it forward first: New Note from Selection, chosen while Settings or
Keyboard Shortcuts is in front, raises the main window and then opens the composer (a popover there), instead of
doing nothing (`AppModel.beginNoteInMainWindow`).
Help › Keyboard Shortcuts (⌘/) opens a reference window (`ShortcutsWindow`): shortcuts grouped by where they work,
each key a raised key cap, alternatives separated by a quiet "or", with a search field. It replaces the default
help item, which pointed at a help book that does not exist. The menu groups are read from the menu bar itself (`ShortcutGroup.fromMenu`), so a new or changed shortcut appears there without anyone remembering to list it; the app menu and the standard Edit commands are left out. Only keys with no menu item (the note composer, viewers, the folder switcher) are listed by hand in `ShortcutGroup.contextual`.

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

## Components

### Shared components

- **StatusPill**: symbol + label in a 14% tinted capsule. States: Draft (dashed circle, secondary), Sent (paper
  plane, blue), Resolved (check, green), Needs input (question mark, orange), Orphaned (warning, orange).
- **InlineIconButton**: 22×20 icon button with a tooltip and accessibility label. At rest 55% secondary; full
  secondary when its card is hovered or selected; primary with a soft fill under the pointer. `prominent` makes the
  one primary action accent-filled; destructive turns red only under the pointer.
- **PressableStyle**: buttons shrink to 90% while pressed.
- **FilterBar**: a capsule track of options, each with its symbol and count; only the selected option shows its
  name. The selection is one capsule that slides between options (`matchedGeometryEffect`), counts roll with
  `numericText`, empty options dim. Counts show how much work exists, ignoring search and color filters.
  The notes filters are All, Drafts, Sent, Resolved, and Attention (orange ▲): notes that lost their place plus
  questions back from agents, the same "needs attention" the tree's markers and the Dock badge use. Its count turns
  orange and bold when it is above zero, the one count in the bar that asks for you.
- **KeyCap**: a key drawn as a small rounded cap, for hints next to the controls they describe.
- **EmptyState**: teaches instead of reporting. A 40 pt hierarchical symbol that breathes, a `.title3` title, one
  sentence, up to three numbered steps (arriving 110 ms apart, each fading up 6 pt) on a faint rounded card, and an
  optional action. Never let it size the window: it fills the pane with zero minimums.
- **Notice**: the in-context banner above a viewer. A rounded card tinted by kind (info blue, warning orange, a
  temporary mode in the accent colour) with the symbol in a tinted circle, a bold title, one line of detail, and
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

- **Root switcher** (`RootSwitcher`): one row above the tree names the open folder (accent folder, teal host for
  remote roots, a star if it is a favorite, its open-note count) with "N open" and a chevron that turns over
  while the switcher is up. Clicking opens a 320 pt popover with sections: **Open** (the current one tinted;
  hover shows a star and a close button), **Favorites** (pinned roots, kept even when closed), **Recent** (six
  more on this host), then Open Folder…. Stars bounce when toggled; rows show their parent folder with `~` for
  home, truncated from the start. Replaces the chip strip, which scrolled roots out of sight.
  Keyboard first: the popover opens with a "Filter folders" field focused and the current folder highlighted;
  typing filters (names first, then paths), ↑/↓ move a highlight drawn as an accent ring (the current folder keeps
  its fill, so the two never blur), Return switches or opens, Escape closes (`SwitcherEntry.sections`).
- **Tree note marker**: on a file row, a 14 pt capsule at the row's trailing edge with up to three overlapping
  7 pt dots in the colours of its open notes (most used first, each ringed in the window background so they
  separate) and the count; orange-tinted when something needs attention (an orphan, or an agent's question).
  Folders show only a tertiary count of open notes inside them. Only open work counts: resolved notes vanish from
  the tree. Changes pop in with a short spring. The tree's single column always spans the sidebar so marks align.
- **The way to the open file**: a collapsed folder that holds the open document carries a 7 pt accent dot on its
  icon's lower corner, ringed in the window background (white with no ring on a selected row). It fades in and out
  (0.2 s; instant with Reduce Motion) and leaves once the folder is expanded, when the file's own row is in view.
- **Find in Files results**: before a search, an `EmptyState` hint; then a summary ("6 lines in 2 files", Collapse
  All); one pinned, collapsible group per file (rotating chevron, file icon, name, dimmed folder, count) and one row
  per matching line with its number in a tertiary gutter and every match on an accent wash in bold (smart case for
  text, the pattern itself for regex). Code lines keep the editor's syntax colours under the wash, as Xcode's Find
  navigator shows them (worked out once per row); markdown and plain text stay monochrome, since a lone prose line
  colours as noise. Rows brighten under the pointer. Failures use `Notice`, nothing found uses
  `EmptyState`.
  Choosing Find in Files puts the caret in its field (even when the search is already showing), so typing starts
  the search at once; Escape in the field closes it and the tree returns.
- **Open Quickly**: a 600 pt sheet whose list is exactly as tall as its results (up to 330 pt, then it scrolls), so two matches make a short sheet that shrinks and grows smoothly as you type, as Spotlight's does; empty and error states keep a steady 240 pt. A `.title2` search field; rows with the file type's system icon, the name with
  the typed letters in accent bold (only when they all occur in the name), and the folder dimmed after it; one
  rounded selection that glides between rows (`matchedGeometryEffect`) and shows a `↩` key cap; empty and error
  states use `EmptyState`; a footer with the result count and key hints. Hover never moves the selection (a list
  changing under a resting pointer would steal it from the keyboard).
  Files with open notes carry the tree's marker in the row (`NoteMarkBadge`: their colours as overlapping dots and
  the count, orange when one needs attention), so the files worth jumping to stand out in the list.
- **Connection notice** (sidebar, remote hosts): Not connected (info, Connect); Connecting to asus (info, ssh's
  current stage as the detail, spinner, Details, Cancel); Waiting for your key agent (mode, pulsing key, "Approve
  the request… its prompt may be behind other windows", Cancel); Reconnecting (info, attempt n); Couldn't connect
  (warning, ssh's message, Details, Connect). A healthy connection says nothing; a connected host with a problem
  (missing ripgrep) is a quiet warning. Each stage is rendered offscreen in `ConnectionNoticeTests` for review.
- **Follow mode**: the toolbar crosshair is a plain button whose symbol turns accent-coloured (and bounces)
  while following; a toolbar toggle's solid "on" disc hid it. While a pane is followed, a card tops the sidebar:
  "FOLLOWING" with the agent's `StatusDot`, host (teal) and agent, pane id, and the pane's folder, plus a stop
  button; it slides in and out from the top. Follow problems (Herdr not running, an unknown machine) stay in the
  status line.

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

- **Note card**: colour rail (3 pt, 4 pt when hovered or selected, faded when settled), anchor label with the anchor
  kind's symbol, the comment, the agent's reply, the delivery line, then the action row with Send first and Delete
  apart at the trailing edge.
  Under the anchor label, a text note quotes what it is about, as GitHub review comments show their line: the first
  non-blank line of the anchored text, trimmed, in `.caption` monospaced on a faint rounded well, one line with a
  tail ellipsis (the whole line in its tooltip), in the editor's syntax colours when the file has a grammar. Hidden
  on compact settled cards; regions, cells, and whole-file notes have none.
  Resolved notes (not ones where the agent asked a question) rest as one line: anchor, pill, the first line of the
  comment. Under the pointer or selected they open smoothly to the reply, delivery line, and actions, so finished
  work stays in reach without crowding the open work above it. In the default sort (Position in File), documents
  with open work come first and documents whose notes are all settled follow, each part in path order.
- **A note arrives**: a card for a note that just appeared (made anywhere, or brought back by Undo) glows in its
  own colour at 20% for 1.6 s, then fades over 0.9 s, so the panel answers "where did it go?" the way Things and
  Linear light a new item. Nothing glows on the first load, when everything is new and nothing arrived
  (`NotesPanelModel.arrivals`).
- **The agent's turn** (`AgentMessageBubble`): what an agent said when it resolved a note is a bubble under the
  comment, its small tail pointing up at what it answers, headed by who spoke and how ("claude asks", "codex replied";
  "Agent" when the note was never sent from here). A question is tinted orange with the text in primary, since it
  asks for you; a finished reply is a quiet grey. It arrives on the bouncy curve, growing from its tail, and its text
  is selectable.
- **Sending takes off** (`LaunchingPlane`): when a send starts, from the button or ⌘↩, the Send button's paper plane
  flies up and away, tilting 14° and shrinking as it fades (an ease-in over 0.32 s, like something thrown). A small
  spinner fades into its place after 0.2 s while the packet is in flight; when the send is over, a fresh plane glides
  in from below-left on the bouncy curve, so it reads as "sent, ready for the next one", not the same plane coming
  back. A send that finishes at once (the clipboard) still lets the takeoff play out before the return. Under Reduce
  Motion the plane and the spinner simply cross-fade.
- **Empty filtered lists say why** (`NotesPanelModel.emptyCopy`): a search with no match names the words and offers
  Clear Search (which clears only the search); a colour filter names the colour ("No blue or pink notes"); each tab
  says what belongs there and how notes arrive (Drafts: how to make one; Sent: "Nothing waiting on an agent";
  Resolved: what lands there). An empty Attention tab is good news and says so: "All clear" under a green seal.
  All use `EmptyState`, so they match "No notes yet"; the message cross-fades as the tab changes.
- **Answering a question**: when an agent resolves a note with a question, the card leads its action row with an
  accent Reply (↩), also first in the context menu and the card's accessibility actions. It opens a one-line field
  under the question, already focused, with a Reply button beside it; Return answers, Escape puts it away. Answering
  adds the exchange to the comment ("Agent asked: … / Answer: …") and makes the note a draft again, so the card turns
  into an ordinary draft with Send first. Sending stays a separate, deliberate step: the person sees exactly what goes
  back before it goes. While the field is open the card exposes its children to VoiceOver, so the field is reachable.
  On the card, the labels of an answered exchange are coloured like a conversation: "Agent asked:" in the question's
  orange, "Answer:" in the accent colour, semibold; the stored text (and so the packet) stays plain. The answer is
  added in one write to the comment as it is now, so an edit made meanwhile is kept. If the note stops waiting for an
  answer while the field is open, or the write fails, the field stays with the typed text and an orange line saying
  why, so nothing typed is lost.
- **Document group header**: the file's system icon, its name (middle-truncated), a count capsule, and the host
  only when it is not this Mac.
  The header opens its document on click (a quiet ↗ appears under the pointer, as group headers open their subject in
  Mail and Xcode's issue navigator); right-click offers Open and Reveal in Finder.
- **Same-named files**: when two groups share a file name, each header adds, in `.caption` secondary after the name,
  the shortest run of parent folders that sets it apart ("…/docs", "…/proj"), as editors do for tabs
  (`PathDisambiguator`). Unique names stay bare, and the full path is in the tooltip.
- **Note composer**: title, then an anchor chip tinted with the note's colour; a quote of up to three lines of the
  selected text under a colour rail, so the comment is written against what it is about (code keeps the editor's
  syntax colours, `SyntaxTheme.highlighted`, worked out once per quote; plain text and prose stay a quiet grey); the field with a
  placeholder prompt and a colour-tinted border; the swatches; Cancel and one prominent action ("Add Note" for new
  notes, "Save" when editing); key hints as `KeyCap`s. Choosing a colour re-tints the chip, rail, and border
  together, and the selection ring slides between swatches with `DS.Motion.bouncy`.
  While a new note is empty, starter chips sit under the field (`StarterPhrases`: Explain, Fix, Add a test, Why):
  one click writes the start of the sentence ("Fix this: ") with the caret after it and the field focused, and the
  chips fade up out of the way once there is text.
- **ColorSwatches**: 14 pt gradient dots that grow slightly under the pointer; the selected one wears a ring in its
  own colour, shared across swatches with `matchedGeometryEffect`.
- **Add Note button**: glass pill beside the selection with a dot in the colour the note will get (the last colour
  used) and the label. It springs out of the selection's corner (`DS.Motion.bouncy`, scale from 0.6 anchored
  bottom-trailing), follows a growing selection with `DS.Motion.smooth`, lifts 4% under the pointer, and leaves
  in 0.1 s so it never lingers over text.
- **Agent chip**: where notes go, as a rounded field: a `StatusDot`, the agent in semibold, its task in secondary
  (truncating), the pane in tertiary monospace, a folder badge when the agent works in the explorer's folder, and
  an up/down chevron; it opens the agent menu.
- **Agent chip wraps instead of clipping**: the task sits beside the agent only when it fits whole; otherwise the
  chip grows to two lines (agent, pane, folder badge; then the task in `.caption` secondary). A one-word stub such as
  "Reor…" tells nothing, so it is never shown.
- **Send drafts button**: the panel's primary action, `.glassProminent`, "Send 2" with the count rolling as drafts
  change; disabled with a reason in the tooltip (no agent, no drafts) instead of silently.
  It sends what you see: the open document's drafts, narrowed to the colours the panel is filtered to when a colour
  filter is on; its count and tooltip say so ("Send this document's 2 blue drafts"). Everything at once is the
  explicit Send All Drafts in the ⋯ menu. Nothing hidden from view goes to an agent, and copying a document's
  packet (⇧⌘C, or the ⋯ menu) copies exactly what Send would send. While the filter is on, the button carries
  the filter's colours as dots on a small white capsule ("Send ◉ 2"; white so a blue dot doesn't vanish into the blue
  button), springing in and out with the filter.
- **Delete is undoable, not confirmed**: deleting a note (trash button, context menu, or the Delete key) happens at
  once; a glass toast ("Note deleted", the note's first line, Undo) rises over the bottom of the panel for 6 s
  (held while the pointer is on it), and Edit › Undo (⌘Z) does the same. Undo restores the note with its id,
  image attachments, and send history (`NoteStore.deleteNoteForUndo` / `restore`). A question before every delete
  gets clicked through; a way back doesn't. Every delete path uses the same undoable delete (the composer's trash too), and each
  text editor keeps its own undo history so loading a file can't wipe the window's Undo Delete Note.
  An Undo that fails is never silent: the toast turns to an orange warning ("Undo didn't work", a sentence why),
  offers Try Again and a dismiss button, and stays until dismissed. Every way the toast goes (restored, dismissed,
  replaced by a newer delete) is logged under `notes`, so a note that did not come back leaves a trace.
- **Send toast**: a glass card floating over the bottom of the notes panel that slides up with `DS.Motion.bouncy`.
  Sending: a spinner and "Sending 2 notes…" with the agent. Delivered: a green check that bounces, "Sent 2 notes",
  "to claude · task", and a hairline that drains over 4 s (hovering pauses it) before it leaves on its own.
  Failed: a red mark, the reason, Retry (same notes, same agent), and it stays until dismissed.
- **Note peek**: resting the pointer on highlighted text for 450 ms shows that note in a 320 pt glass card beside
  it (below the text, above when there is no room): colour rail, anchor label, state pill, the comment, the agent's
  reply, and Edit / Resolve (or Reopen) / Show in notes panel. Moving to another note switches at once; the card
  stays while the pointer is on it and leaves 250 ms after the pointer leaves both; scrolling, typing, or a
  selection dismisses it. Orphaned and invalidated highlights never peek.
  The card is read over busy code, so its glass sits on a 88% window-colour fill: the lines behind never cross the
  note's words (glass alone suits controls, not content). A draft or sent note's peek leads with Send to the current
  agent (prominent), then Edit, Resolve, and Show in Notes Panel, matching the panel's cards.
- **Notes search row**: a rounded field (5% fill, hairline border) whose clear button scales in, and a sort
  button whose symbol names the order (numbered list, arrows, palette, dashed circle). Below it, `ColorFilterStrip`:
  one chip per colour in use with its count (shown when two or more colours exist); a chip fills with its colour and
  rings when on, the others dim to 45%, and "Clear" appears. Several colours may be on together.

### Viewers

- **Viewer status bar**: leading, an accent dot while edited, then a breadcrumb from the explorer root to the file
  (host first when remote); each step reveals itself in the tree and brightens under the pointer, and the file
  step reads as primary. Trailing: the selection as "3 lines · 117 characters" (cursor position when nothing is
  selected; exact Ln/Col in the tooltip), the file's open notes as colour dots and a count that opens the notes
  panel, a lock when read-only, and a language chip ("Swift", "Markdown", "HTML").
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
  column header to select the column"), so the bar teaches the next step without becoming a wall of grey text. The
  key caps carry the keys; the sentences never repeat them. Hints follow the state: before a selection
  they teach how to select; with one they show the keys that act on it (esc Clear, ⇧↓ Extend), crossfading
  between the two. Never a full sentence. Used by the CSV grid, the image viewer (Drag a region; esc Clear, Drag again to redraw;
  Click a note to open it once there are notes) and the PDF viewer in Region mode.
- **Rendered code blocks** carry their language in the fill's top-right corner ("Swift", "Python", "Shell"): 10 pt
  medium in the tertiary label colour, spelled the way each community spells it, the fence's word as written when
  unknown, nothing on a bare fence. Quote bars are an opaque grey, so where two paragraphs' pieces of one bar meet
  the bar stays even instead of darkening at the seam.
- **PDF page thumbnails** (`PDFThumbnailColumn`): for documents with more than one page, a sidebar toggle at the start
  of the PDF toolbar slides in a 120 pt column that maps the document and its notes, as Preview's sidebar maps pages.
  Each page is a small sheet with a soft shadow, lifting a little under the pointer; the current page is ringed in the
  accent colour with its number in accent, and the column keeps it in view. A page with open notes carries a badge in
  its corner: up to three of the notes' colours as overlapping dots and their count, popping in on the bouncy curve
  as notes are added. A click goes to the page. Thumbnails render lazily as they scroll in. Off until asked for; the
  toggle draws filled while the column shows.
- **Image viewer canvas**: the picture lies on the under-page grey like a sheet, with a soft shadow (10 pt blur, 2 pt
  drop, 24% black) that stays the same on screen at any zoom. A picture with transparency sits on a quiet
  checkerboard (8-point squares at any zoom; white and 93% grey in light, 20% and 25% in dark), clipped to the
  picture, so its transparent areas are visible instead of blending into the canvas.
- **Rendered images** are set into the page as Bear and Craft set theirs: continuous rounded corners (8 pt, or an eighth
  of the short side for small pictures, so icons stay crisp) and a 0.5 pt hairline in 14% of the label colour, so a
  pale image keeps its edge on a white page. Drawn at display time, so the hairline follows light and dark.
- **Rendered tables** never start a row with a tab: TextKit draws a faint sliver for a tab at the very start of a
  line, which showed as grey marks down the table's left edge. A left-aligned first column is placed by the row's
  first-line indent; only a right- or centre-aligned first column keeps the leading tab its stop needs.
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
  page reached through an ssh host's loopback wears a teal `via asus` chip (`network`), the same mark the status bar
  and the notes panel use. Trailing, in Rendered mode: Element Notes (`rectangle.dashed`, accent-filled while on,
  with the inline hint `esc Leave`), Reload (`arrow.clockwise`, for a file it runs the page and its scripts again
  keeping the scroll place), then the Rendered/Source switch; a live page's Source is its current DOM, read-only.
  While the page loads, a 2 pt accent line (`LoadProgressLine`) grows along the toolbar's bottom edge; at the end it
  fills, then fades after 350 ms, instead of vanishing mid-way.
- **Element notes**: in Element Notes mode the pointer outlines the element under it in the accent colour with a
  small `tag#id` label (an overlay above the page that takes no clicks and adds no text, so text offsets never
  move), and a click opens the note editor at that element at once, no Add Note pill in between; Escape leaves the
  mode, a pick leaves it too. A committed element note draws as a 2 pt outline in its colour with a 12% fill
  (drafts full, sent 70%, resolved 35%, orphaned dashed, a `?` badge while it needs a glance), and carries a 2x crop
  of the element taken before the outline exists. The note card reads `Element [data-testid="save"]`: the last
  compound of a selector that prefers an id, then a `data-testid`, then a `tag:nth-of-type` path, never class
  names. When the page changes, the element is found again by selector, then by text (one match moves the note
  and flags it; several pick the nearest; none orphans it), and a page back exactly as it was returns an orphan to
  a draft.
- **Open Location** (File › Open Location…, ⇧⌘L): a sheet in the Open Quickly family with an address field and a Via
  picker (This Mac, or an ssh host) that explains itself: localhost on another machine is reached through the app's
  ssh connection, and the page is that host's document.
- **Wrapped lines keep their indentation**: when lines wrap, a line's continuation rows start at its own
  indentation plus one four-space step (as Xcode and VS Code wrap), so a wrapped comment or argument list never reads
  as a new line of code. The indent is capped at 40% of the column for deeply nested lines (re-measured when the column's width changes by
  40 pt or more, so narrowing the window never leaves a continuation with no room), follows typing just after
  each edit (never inside it: restyling there moved the caret to the next line on every keystroke), and is a
  paragraph attribute only: the text and every note anchor are untouched.
- **Changed lines** (a pull request's file, milestone 2): rows the pull request added or rewrote are tinted green
  across the whole width (`Theme.changeAddedBackground`, 10%, lighter than a resolved note so a green note on an added
  line still reads), with a 2 pt green bar at the gutter's text edge as VS Code marks changed rows; a red hairline
  across gutter and text marks where lines were taken out. The overview ruler shows hunks in a lane of their own
  under the notes (green bars, red ticks for deletions), clickable. The status bar reads "3 changes" with ⌃/⌄
  steppers, "2 of 3" while stepping; Notes › Next Change (⌥⌘↓) and Previous Change (⌥⌘↑) walk the hunks from the
  caret and wrap, landing each with the find indicator. A reload after a new commit shows "Pull request updated" for
  eight seconds (an Atlassian document says "Updated in Jira or Confluence").
- **Overview ruler** (`OverviewRulerView`): a 12 pt strip at the editor's trailing edge, shown only while the file
  has notes, that maps the whole file as Xcode's issue markers and VS Code's overview ruler do. Each note is a tick in
  its colour at its place (a multi-line note spans its lines): drafts solid, sent at 70%, resolved at 35%, orphaned
  as an outline; open work draws over settled work. A faint band marks the part on screen. Ticks widen under the
  pointer and a click scrolls to the note the way browsing the notes panel does (the keyboard stays put); a click or
  drag elsewhere scrubs the file like a minimap.
- **Stepping through notes**: Notes › Next Note (⌘') and Previous Note (⇧⌘'), the keys Xcode uses for issues, and
  ⌃/⌄ steppers beside the status bar's note count. Open notes go in reading order (text by offset, PDF by page then
  top to bottom, images in the order made); a step goes on from the note last reached, or from the caret once it has
  moved, and wraps at either end. Each step shows the note without selecting it (so Add Note never floats over a note
  that exists), pops the find indicator, and selects its card in the notes panel; the count reads "2 of 5" while a
  stepped-to note is current. Nothing to step to beeps.
- **Landing on a note**: every jump to a range (a ruler tick, a card in the notes panel, a search result) ends with
  AppKit's find indicator over the target, the brief yellow pop Xcode uses, so the eye finds where it landed
  instead of scanning. A note over several lines pops on its first line only; caret moves (no range) don't pop.
- **Indent guides**: a hairline at each indentation level a line sits inside (the step is read from the file, so
  two-space YAML gets two-column guides), spanning all of a line's wrapped rows. Blank lines inside a block take the
  shallower neighbour, so guides run through gaps. The block around the caret (or the block a line like `func x() {`
  opens) is drawn stronger, the way Nova and VS Code mark the active scope. Quiet enough to sit under text: 7–8%
  of the label colour, the active one 22–24%. Settings › Editor turns them off; its preview draws a guide and wraps
  with the editor's hanging indent, so it shows exactly what the editor will do.
  Guides are built for the lines on screen plus 200 either side, read through the editor's own line index
  (`IndentGuides(window:…)`), and rebuilt only after an edit or when scrolling nears that window's edge: about
  0.3 ms per keystroke in a 45,000-line file, where rescanning the whole text took about 38 ms.
- **Current line**: in the focused editor with a bare caret, the caret's line (all of its wrapped rows) gets a
  full-width neutral band (4% black, 5% white in dark), carried across the gutter so number and line read as one
  row; the number turns `labelColor`. No band while text is selected (the selection marks the place) or while the
  window or editor is not focused. It follows the caret instantly, without animation.
- **Gutter note bars**: each note is a 3 pt rounded bar in its colour beside the line numbers, spanning every line
  it covers. Overlapping notes take side-by-side lanes (up to three, 2 pt apart). Strength follows state: open
  notes 85%, resolved 30%, orphaned a dashed outline. Hovering a bar widens it, shows a pointing hand, and opens the
  note's peek; clicking edits the note. The current line's number is primary, the rest tertiary.
- **Go to Line**: a 460 pt palette in the Open Quickly family: a `.title2` field with "of 24" (real lines; the
  empty spot after a final newline is not one), a live preview of the target line between its neighbours with the
  target washed in accent, a hairline position bar showing where it sits in the file, and a footer that explains
  the input ("Past the end, so it goes to the last line, 24"; orange when it cannot be read) with key caps.
- **Conflict sheet**: a tinted icon tile (accent "merge" when the edits don't overlap, orange when they do), the
  file name, one sentence on what happened, and a count ("1 change of yours · 1 change from disk"). The merge view
  folds long unchanged stretches; each change has a coloured side bar and a label (Yours blue, On disk green, Both
  teal); a conflict is an orange card with Yours and On disk side by side, never git markers. Buttons say what they
  do (Save Mine As…, Use Disk Version, Keep Mine, Merge and Save) with tooltips on the consequence. Merge is the
  default when it is safe; with a real conflict nothing is the default, because overwriting someone else's change
  must be a deliberate choice. `ConflictContent` renders without a session for review.
- **Image viewer**: the picture sits centred on the under-page backdrop (`CenteringClipView`). On open, a large
  image shrinks to fit and a small one shows at actual size; the view keeps fitting as the pane settles or
  resizes until the user zooms (pinch, +/−, 100%). Choosing a region looks like a crop tool: the rest of the image
  dims to 42%, the edge is white over a dark outline, white L-handles mark the corners, and a dark pill below the
  region gives its size in pixels (Add Note owns the space above). Note regions are rounded tints with a coloured
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
  While the pages move, a glass `PagePill` ("2 / 5") floats over the bottom centre, counting with numeric text and
  fading 1.2 s after the last page change; never on open and never for a single page.
- **Regions are one style everywhere** (`RegionStyle`, Viewers package): images and PDF pages draw note regions
  and the region being chosen with the same code — rounded tinted notes with a colour tab and a selection halo; the
  crop-tool selection (dimmed surroundings, white edge over a dark outline, outlined white L-handles, a size pill
  below in px for images and pt for PDFs). The PDF overlay is flipped so both share it.
- **CSV grid**: values in the system font; columns whose every value is a number are right-aligned in monospaced
  digits (header too) so magnitudes line up. Headers show the column letter in tertiary monospace and the name in
  semibold. A row note tints its row softly (12%; 5% resolved) and puts a 3 pt colour bar beside the line number,
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
- **Resume where you left off**: with "Reopen the last folder" on, launch reopens that folder and the file that was in
  front (`general.lastDocument`), when it still lives there, with the caret back on the line it was on at quit
  (a caret, not a selection: resuming is not a jump); a deleted file is skipped quietly.
- **Welcome** (`WelcomeView`): with no folder open, the main pane greets instead of asking for a file: the app
  icon (springs in, 0.6 s, once), the name, one line on what the app is for, then the one first step as a
  `.glassProminent` Open Folder… with "On a Host" (a menu of ssh hosts) beside it, and up to four recent folders
  (favorites starred, last opened as relative time). The sidebar's own empty state drops its button for this Mac,
  so there is one first step on screen, not two; the notes panel keeps its three steps for what comes next.
- **Opening and failing**: a document that is still opening shows nothing for 250 ms (local files are there by
  then; a spinner that flashes reads as a glitch), then fades in the file's icon and name with a small spinner and
  "Opening…" ("Opening on asus…" for remote hosts). A failed open says what happened in a sentence (not a Swift
  error) and offers Try Again (`DocumentSession.openFailure`, `retryOpen`).
- **Pick up where you left off** (`OpenWorkList`): under the empty viewer's Open Quickly, up to five files in the
  open folder with notes still in play (drafts, sent, questions back, orphans), most recently touched first. Each
  row: the file's icon, name, its folder inside the root in `.caption` secondary, then counts with the state symbols
  (attention orange, drafts, sent blue); a chevron slides in under the pointer. Rows fade up one after another
  (40 ms apart) on arrival; with Reduce Motion they simply appear. Hidden when nothing is open.

### Colour and motion

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

- **Hooks tab**: four optional, independent integrations, so no Install button is prominent (glass, not glass
  prominent); only Update, on an outdated row, asks for attention. A footer with a shield says what Install touches
  and how to undo it: nothing changes until you press Install, each edited settings file is first copied beside
  itself (`*.gloss-backup-…`, the last three kept), and Remove takes out only what was added.
- **Settings**: every tab is a `.formStyle(.grouped)` form, 600 pt wide, with its own height so the window
  resizes to each tab as System Settings does (General 236, Editor 330, Agents 560, Attachments 380, Hooks 390, the rest 440). Toggles
  carry a second line saying what they do; words match the rest of the app ("folder", never "root"). A setting
  shows its effect where it can: the editor font slider drives a live code preview, with the size in monospaced
  digits beside it. A setting must do something, at once: Editor's font size, wrapping, and indent guides
  restyle every open editor as they change (`Theme.editorSettingsDidChange`), keeping the line at the top of the view
  in place, so the slider can be dragged while watching real code. Attributes only: text, undo, and anchors stay.
  Sections have a header and a footer that explains them; explanations never sit as rows of their own. Live state
  reads as a status line with a coloured dot (MCP: green listening, red with the error). Text people copy into a
  terminal or config is a `SnippetCard`: name (and file, if any) with a Copy button that turns into a green
  "Copied" check for 1.6 s, then the text in a monospaced code box. A command is never wrapped (a break mid-URL
  read as two commands): each line stays whole, the box scrolls sideways, and its trailing edge fades over 20 pt
  to say there is more, as code blocks do on GitHub and Linear.
  Storage reads as what it is for, not where it lives: a `StorageRow` names the contents ("Crops and page
  renders"), shows the size ("Empty" at zero) and a Show in Finder button with the path in its tooltip. Clearing
  anything an agent might still read asks first and says what stays.
  A host is a `HostRow`: a server symbol with its connection state as a dot (green connected, orange connecting,
  red failed, grey idle), the name, and a second line with the address and state (ssh config aliases show only the
  state, with an "ssh config" tag, since their address lives in that file). Hosts added in the app can be edited
  and removed; removal asks first.
- **Integrations** (`key`): one section per service, GitHub and Atlassian. Each has the Status line (dot and
  sentence: "Signed in as colinc86 · repo, user", "Colin Campbell · Jira and Confluence", or the service's own error),
  a `SecureField` for the token (its prompt says "Saved · paste a new one to replace it" once one is), Atlassian's
  site and email fields with the saved values as prompts, and Save (glass), Test Connection and Remove. The footer is
  the trust note, with `lock.shield` as on Hooks: the app only reads with these keys, the agent makes every change,
  and keys live in the Keychain. Saving tests the key first: a key the service refuses is not saved and the sentence
  says so ("…It wasn't saved"); one that cannot be checked (offline) is saved and says it could not be checked.
  Remove asks first when it would close open pull requests, issues or pages. Integration roots offer Copy URL in the
  tree's menu instead of Copy Path, and Open Quickly and Find in Files are off for them (they are browsed, not
  searched).
