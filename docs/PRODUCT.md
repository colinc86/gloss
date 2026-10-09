# Gloss: Product Description

Mirror of the living doc at https://claude.ai/code/artifact/01a13d3e-5f5a-491b-b910-b5f1a57cc70c (as of 2026-10-01). The Claude Doc is where comments and edits happen; update this file when a decision there changes.

## Overview

Gloss is a native macOS app that sits beside your terminal and gives coding agents precise, annotated context from any file on any machine. It has a file explorer on the left, a viewer on the right, and a notes panel that turns highlighted regions of a file into messages for Claude Code, Codex, or OpenCode.

It replaces two things lost in the move from Orca to Warp and Herdr:

- **A remote file tree that works everywhere.** Warp's explorer needs a Warp-owned SSH session and fails over mosh or inside tmux. Gloss owns its own SSH connection, so browsing, previewing, and editing remote files work regardless of how the terminal is connected.
- **Annotate anything, send it to any agent.** Orca let you attach notes to a markdown file and send them to an agent in a batch. Gloss extends that to every file type an LLM can consume: text and code by line range, markdown in rendered or source view, images by rectangle, PDFs by page region. Notes go out individually or in bulk, and the agent can mark them resolved.

The app is for one person working across a local Mac and several remote hosts, with agents running in Herdr, tmux, or a bare mosh session. It is not an editor replacement and not a terminal. It is the place you look at things and tell agents what to change.

## Core concepts

| Concept | What it is | Example |
| --- | --- | --- |
| Host | A machine the app can read files from: the local Mac, an SSH host imported from `~/.ssh/config`, or one added in Settings → Hosts | `local`, `workbox` |
| Virtual host (milestone 2) | A read-only source that is not a machine but is browsed, viewed and annotated exactly like one: `github` serves pull requests, `atlassian` serves Jira issues and Confluence pages as Markdown, `web` serves live pages by URL | `github:/colinc86/repo/pull/123`, `atlassian:/jira/PROJ/PROJ-123.md`, `web:https://example.com/docs/` |
| Root | A directory on a host that the explorer is showing | `workbox:/home/colin/proj` |
| Document | One file opened in the viewer, identified by host and absolute path | `workbox:/home/colin/proj/PLAN.md` |
| Anchor | A typed description of a subset of a document | lines 40 to 52; a rectangle in pixel space; page 3 region |
| Note | An anchor plus your comment, with a lifecycle state | "This section contradicts the API doc" |
| Context packet | The plain-text message built from one or more notes, with attachments on disk | the thing the agent actually reads |
| Agent target | A specific agent session the packet can go to, reached through a transport | Claude Code in Herdr pane `w1:p2` on `workbox` |

A transport is how a packet reaches a target: Herdr socket, the OpenCode HTTP API, tmux keystrokes, or the clipboard. MCP is the way back: agents read the notes they were sent and resolve them. A note leaves the app only when the user presses Send (decided 2026-10-05, issue #5). Targets are discovered, not configured by hand, wherever a transport can enumerate sessions.

## File explorer

- **Host picker.** Hosts come from `~/.ssh/config` plus This Mac. The picker is the Hosts section at the top of the folder dropdown above the tree (decided 2026-10-07; the sidebar's host dropdown and, briefly, a host chip in the title went): every host, then the folders of the one picked, its Open item and Manage Hosts. Picking This Mac or a connected ssh host lists its folders there; Web shows the Web section, GitHub and Atlassian open their pickers, and an ssh host not connected connects and opens its home. Selecting a host opens or reuses one SSH control connection. Reconnects are automatic after sleep or a network change.
- **Web.** The host picker always lists Web. Picked, the explorer shows an address field and the pages visited: Pinned, then Recent (title and address, the host a page was reached through when it was not the open web), the page in the viewer selected; a double-click or Return opens a page (arrows only move the selection), its menu pins, unpins or removes it, and Return in the field opens the first page left when the text is not an address. A page is recorded (up to 200 unpinned, oldest forgotten first) when it is opened or navigated to, whether typed or followed from a link; showing a page already open again does not reorder the list (decided 2026-10-06).
- **Addresses.** The window's title is its address bar: a click, or File › Open Location… (⇧⌘L), turns it into a field holding the page's address or the file's path. Return opens a web address (a URL; or a bare host with a port, `localhost`, an IP address, a path after it, or a top-level domain that is not also a file extension, so `example.com` is a page and `README.md` is not), an absolute, `~/` or relative path (relative to the open document's folder; a folder opens as a root, a file as a document), or a pull request, issue or page URL as its document when that integration is set up; anything else shakes the field and says so. A small menu in the field picks the machine: this Mac, or an ssh host (by default the open document's). A loopback page goes through that host; an outside page goes through it only when the host was picked in the menu. The explorer's Web section and Open Quickly take addresses the same way (decided 2026-10-06; this replaced the Open Location sheet and the address field in the browser's toolbar).
- **Roots.** Each host remembers its recent roots. You can type a path, pick a recent one, or jump to the cwd of a Herdr pane. Multiple roots can be open as tabs in the sidebar.
- **Tree.** Lazy loading per directory, dotfiles toggled, gitignore-aware dimming when a `.gitignore` is present, file type icons. Expanding a remote directory is one SFTP round trip. Reveal in Explorer (⌘⇧J) selects the open document in the tree, expanding folders on the way and opening its folder as a root when none contains it.
- **Unknown file types.** A file whose extension nobody listed (`.jsonl`, a rotated log, a config with its own suffix) opens in the text editor when its first bytes are text and it is under the 2 MB editing limit; only binary or larger files go to QuickLook.
- **Follow mode.** The tree follows the focused Herdr pane: focus an agent on `workbox` and the tree switches to that host and that pane's working directory, connecting the host first if needed, and the agent becomes the send target. Switching machines in Herdr switches the tree the same way. Picking a Herdr or tmux agent in the target picker also opens its working directory. Agent status shows beside the root as a badge. The Follow button sits at the left of the folder dropdown above the tree, as tall as it, and is lit, a white crosshair on an accent fill, while following (decided 2026-10-07; it was in the sidebar's toolbar); Go › Follow Herdr does the same with the sidebar closed.
- **File operations.** New file, new folder, rename, move, duplicate, delete to trash locally, delete with confirmation remotely, reveal in Finder for local, copy path, copy relative path.
- **Search.** Filename filter in the tree. Content search uses ripgrep locally and `rg` or `grep` over the exec channel remotely, with results opening at the matched line. Open Quickly (⌘P) fuzzy-finds any file under the selected root, local or remote (`rg --files` or `find`, skipping `.git` and `node_modules`), ranking file-name and word-start matches first. Above the files it lists the visited pages matching by title or address, and a query that can only be an address gets a first row that opens it (one that may as well be a file name, `AppModel.swift`, is offered after the files, unselected); with no folder open, or a pull request, project or space in front, it offers only those. Queries are plain text unless the `.*` toggle makes them regular expressions; case is ignored unless the query has a capital letter; an invalid regular expression says so instead of showing no matches.
- **Freshness.** Local trees watch FSEvents. Remote trees refresh on focus, on manual refresh, and on a timer while a directory is visible.

## Viewers and editing

| File type | Viewer | Selectable unit | Editable |
| --- | --- | --- | --- |
| Text and code | TextKit 2 editor with tree-sitter highlighting | Character range, shown as line and column | Yes |
| Markdown | Toggle between rendered and source | Source range, mapped from either view | Yes, in source view |
| Images (PNG, JPEG, HEIC, GIF, WebP, SVG) | Zoomable image view with region overlay | Rectangle in original pixel space | No |
| PDF | PDFKit | Text selection or page region | No |
| CSV and TSV | Grid view | Rows (line range), a cell, a block, scattered cells, or whole columns; stored as a text anchor over the records' lines plus a cell list | No in milestone 1 |
| Everything else | QuickLook | Whole file | No |
| Web page (milestone 2) | WebKit in the app's own review browser: file-backed pages, live URLs, and dev servers on remote hosts through an ssh port forward; links stay in the app | Text range, a picture or a region of one (a click or a drag, no mode, as in Markdown), or any DOM element (Pick Element, ⇧⌘E, with ↑/↓ to the parent or child) | File-backed: yes, in source view. Live: no (source shows the current DOM) |
| Pull request file (milestone 2) | The code editor showing the file at the PR's head commit with changed lines tinted and a hunk stepper | Character range with real file line numbers | No |

**Markdown toggle.** The rendered view is built from swift-markdown's syntax tree, which carries a source range for every node. Rendered text is an attributed string whose runs carry those ranges, so a selection in the rendered view maps straight back to source bytes. Notes are stored in source coordinates and appear in both views. A ```` ```mermaid ```` block is drawn as its diagram, by a copy of Mermaid bundled with the app (never fetched), in Mermaid's light or dark theme to match the view; a diagram Mermaid can't draw stays code with Mermaid's error under it. A diagram takes notes as an embedded picture does, and the packet calls it `Mermaid diagram` (decided 2026-10-08, #16).

**Editing.** Text and markdown documents are editable in place with undo, find and replace, tree-sitter structural selection, and Go to Line (⌘L, `line` or `line:column`). Syntax highlighting is incremental, so a keystroke re-highlights only what changed. Embedded languages (markdown inline text and fenced code, Rust macro bodies) are highlighted in documents up to 24 KB and corrected in the background after a pause in typing; larger documents skip them so typing stays fast, and highlighting stops above 1 MB. Note anchors shift with edits as they happen.

**Saving.** Local saves are atomic writes. Remote saves write a temp file in the same directory and rename over the original, preserving mode bits. Before any save the app compares current mtime and size (and hash on mismatch) with the values read at open time; on a difference it shows a three-way diff instead of overwriting.

**Live reload.** When a file changes on disk and the document has no unsaved edits, the viewer reloads and re-anchors notes. With unsaved edits, a banner offers reload or keep. Local changes arrive via FSEvents; remote changes by polling mtime every few seconds while the document is open.

## Annotations

| Anchor type | Stored fields | Re-anchoring strategy |
| --- | --- | --- |
| Text range | Start and end as line and column, the exact selected text, three lines of context before and after, SHA-256 of the file at anchor time | Exact match on the selected text; among several, the one whose surrounding lines match the stored context, nearest the old position on a tie (flagged for review unless its context clearly wins). Then fuzzy match on context, keeping a phrase's columns when its first and last words survive. Then orphaned. Run on reload, when a document opens (a file changed while closed), and when a packet reads a closed file |
| Image region | Rectangle in original pixel coordinates, original width and height, image hash | Image unchanged: keep. Dimensions changed: scale proportionally and flag for review |
| Embedded image | The picture's source as the Markdown writes it, which embed of it (0 for the first), the region in its own pixels with its width, height and hash (the whole picture for a whole-image note), and a text anchor on the `![]()` that embeds it | The embed re-anchors as text does; if it no longer names the picture, the note is orphaned |
| PDF region | Page index, bounds in page points, selected text if any, page count | Same page and text present: keep. Otherwise search nearby pages for the text |
| Whole file | Path and file hash | Always valid while the file exists |
| Element (milestone 2) | A CSS selector (id, `data-testid`, or an `nth-of-type` path; never class names), tag, trimmed text, an outerHTML snippet, the rect in page coordinates, the source line for file-backed pages, DOM hash; on a picture also the region in its own pixels (all of it for a whole-picture note) and its address | Selector hit with the same tag: keep (flag for review if the text changed). Otherwise one text match: move and flag. Several: nearest rect, flagged. None: orphaned |

**Creating a note.** Select a range or drag a rectangle, then click the floating Add Note button (or press the shortcut). A popover takes the comment with markdown: Return saves, Shift-Return (or Option-Return) adds a line, Escape cancels. Notes show as colored highlights in the viewer and as cards in the notes panel, grouped by document. The panel filters by state, color, and a text search over note bodies, file names, and resolve messages, and sorts by position in the file, newest, oldest, color, or state; the sort order is remembered. The page draws what the panel lists: with the panel shown, its tab, colors and search choose the highlights too; with it closed, every note is drawn. Show Resolved Notes (remembered; in the sort menu and View) off hides resolved notes from every tab but Resolved and from the page, except questions back from agents. Separate Resolved Notes (remembered; under it in both menus, 2026-10-08) lists open notes above resolved ones, the two apart. A note revealed or selected from elsewhere that the filters hide brings itself into the list.

**Link and paths.** Two toggles in the viewer's status bar (and the Notes menu) tie the notes panel to the page. Linked, the panel follows the page as it scrolls, keeping the card of the note nearest the middle of the page in the middle of the list, so the notes on screen are the notes in view. With paths on as well, each visible note is outlined in its colour and joined by a curve to the colour bar of its card, so on a document with many notes every highlight visibly leads to its card. It works in every viewer where a note has a place: text and code, Markdown, PDF, images, spreadsheets, and web pages' element notes.

**Lifecycle.** draft → sent → resolved, plus orphaned. Sent notes record target, transport, and time, and each card shows where its latest send went and when (or why it failed). A note is a thread (decided 2026-10-07): its comment, then the user's follow-ups, the agent's replies and questions, and moves, in order; the card shows the latest turn and expands to the whole thread. A resolved card shows the agent's resolve message, and Reopen as Draft (card context menu) takes it back. In the notes panel, Return shows the selected note in the viewer and Delete removes it at once, with Undo in a toast and in Edit › Undo; each card's context menu reveals, edits, sends, copies the note as a packet (it stays a draft) or its comment or path, resolves, and deletes. Resolved notes were marked done by an agent through MCP or by hand. Orphaned notes lost their anchor and need a glance before resending.

**Scope.** Notes live in the app database, keyed by host and absolute path, never in the file. They persist across restarts and survive agent edits.

## Sending to agents

Send loop: highlight → write a note (draft) → build packet (text, grouped by file) → stage attachments (crops via SFTP) → deliver (Herdr, OpenCode, tmux, clipboard) → agent works → agent resolves via the MCP `resolve_note` tool, or replies or asks with `reply_to_note` → note resolved (highlight fades, file reloads) or the thread goes on with the user's follow-up.

**Packet format.** See the `context-packet` skill for the normative grammar. One header per file, then one block per note; excerpts blockquoted and truncated head and tail past 40 lines; attachments referenced by absolute path on the machine the agent runs on; closing line names `resolve_note` and `reply_to_note` (the ids are on each note's `Note:` line).

Milestone 2 adds sources `web`, `pull_request`, `jira` and `confluence`. A live web page's `File:` line is its URL. Pull requests, issues and pages keep their virtual path in `File:` and add a `Resource:` line with the canonical URL (`https://github.com/o/r/pull/123`, `https://<site>/browse/PROJ-123`, the Confluence page URL) plus `Path: Sources/App.swift at 0f3a9c1` for a PR file, `Field: description` or `Comment: <url>` for an issue or PR body, and `Version: 7` for a page, so the agent can act on the real thing with its own tools. Every note starts with `Note: <id>`, the id `resolve_note` takes, so an agent never matches ids to notes by position (decided 2026-10-06; the ids used to be listed in the closing line). Element notes carry `Element: <selector>`, `Text:`, `Rect:`, `Line` when the page is a file, a blockquoted `Snippet:` of the element's HTML, and a PNG crop attachment. A note on a picture adds `Image: <src> (WxH)` and `Whole image` or `Region: x= y= w= h=` right after `Element:`, as an embedded picture's note does, and its crop is of that part (decided 2026-10-06).

```markdown
File: /home/colin/proj/docs/PLAN.md
Source: markdown

Note: n_01J9X...
Lines 40-52
Excerpt:
> ## Auth flow
> The client refreshes tokens every 5 minutes...
User comment: "This contradicts the 15 minute TTL in api.md. Pick one and fix both."


File: /home/colin/proj/design/dashboard.png
Source: image
Original size: 2880x1800

Note: n_01J9Y...
Region: x=1204 y=312 w=640 h=220 (crop attached)
Attachment: /home/me/.cache/gloss/attachments/a1b2c3/dashboard-region-1.png
User comment: "The legend overlaps the chart here. Move it below."

Notes: 2. When you've acted on a note, mark it resolved with the gloss MCP tool `resolve_note`, passing the id on its Note line. To answer or ask something without resolving it, use `reply_to_note`.
```

The closing line's second sentence, naming `reply_to_note`, is on every packet since 2026-10-07, first sends included.

**Choosing a target.** The send menu lists every live agent the app can see: Herdr panes on each connected host with agent kind and status, OpenCode servers, and mapped tmux panes. Each folder remembers the agent last chosen in it, or picks the agent working in it: when the folder comes to the front or opens at launch (waiting for discovery when agents are still being found; a later refresh keeps whatever target is set), the app selects the remembered agent when its session is live, else a live agent of the same transport working in the folder (a tmux pane that changed directory or command, a restarted Herdr pane), else a live agent whose directory is the folder or inside it (the folder itself first, then delivery priority). The clipboard and OpenCode's "New session" rows are never picked unless chosen; follow mode pairs folders and panes itself; with no match the current choice stays. Folders are keyed by their normalized path (symlinks resolved on this Mac); Cmd-Enter sends to it (except while text is selected and the Add Note button shows, when Cmd-Enter adds the note).

**Individually or in bulk.** Each note card has its own send button. Selecting several cards (⌘-click, ⇧-click, ⌘A) brings up a bar that sends, resolves, reopens, recolours, copies or deletes them together, each action taking only the notes it applies to (decided 2026-10-05, issue #8). With nothing selected, the header's own Send sends this document's drafts as ⌘↩ does, with Send All Drafts and Copy Packet for Document in its ⋯ menu (back 2026-10-06: #8 had removed it, and sending every draft needed ⌘A first). Notes › Send Drafts in Document (⌘↩) sends the current document's drafts the panel shows (its state tab, colours, and search all apply; with the panel closed, all of the document's drafts) as one packet; Send All Drafts (⇧⌘↩) sends every draft across documents. What you see is what goes to the agent, and Copy Packet for Document (⇧⌘C) copies the same notes (decided 2026-10-03, for human-in-the-loop control).

**Attachments.** Crops and PDF page renders are PNG. Local targets: Application Support cache. Remote targets: uploaded over SFTP to a per-send temp directory on that host before delivery.

**Resolution.** The packet ends with the resolve instruction. When the agent calls the tool, the card flips to resolved. Without MCP, resolve by hand.

**Threads** (decided 2026-10-07). Threads exist only over MCP; nothing about them is written into the file.

- Either side can close a thread, and a follow-up reopens it. A follow-up stays in the app until the user presses Send, like a draft: Send, Send All Drafts and the Drafts tab count notes with an unsent follow-up, and the note keeps its id, so the agent's `resolve_note` and `reply_to_note` keep working.
- The agent gets only the recent turns: a sent-again note's block has its comment, then `Earlier: N messages (get_note returns the whole thread)`, the agent's last message (`Agent (claude) asked:` or `replied:`), and every `User replied:` since. A first send has no thread lines. `get_note` returns every turn the agent was given, with `Moved:` lines naming the old place and text.
- An agent's question (`reply_to_note` with `asks`, `ask_user`, or the old `needs_input`) leaves the note sent and waiting on the user, under Attention and on the Dock, until they send a follow-up. It never resolves the note.
- `resolve_note` is refused while the user has written a follow-up they haven't sent: the agent hasn't heard what they said since.
- Moves are automatic, visible, and undoable. An agent passes `location` when its change replaced or removed the note's text: `{line, end_line, text}` (the exact new text, found within those lines, else nearest them within 50 lines), `{removed: true, line}` (the note becomes a point at the start of `line`, the line that now sits where the text was), or `{selector}` for an element on a web page. Gloss works out the anchor from the file as it is now, read from its host; it refuses while the open copy has unsaved edits ("the user is editing this file"), and a web page is read from its open copy. A refused move writes nothing, so a retry is clean. Gloss also finds removals and rewritten text by itself and says "Removed" or "Edited" (keeping the original place from before either); an agent's move that follows straight after takes that line over, so a thread shows one move, the agent's ("Edited by Claude Code", "Removed by Codex"). Restore Original puts a moved note back. Notes on images, PDFs, pictures and whole files can't move.

**MCP tools.**

| Tool | What it does |
| --- | --- |
| `list_pending_notes(host?, path?)` | Sent notes not yet resolved, with `waiting=user` or `waiting=agent` and the thread's message count |
| `get_note(id)` | One note as a packet, with its whole thread and attachment URIs |
| `resolve_note(id, outcome?, message?, location?)` | Resolves it (`done` or `skipped`). The message is optional and normally left out; it is for what the change and thread don't say (a decision, a caveat, what was skipped and why), and a bare "Done." or "fixed" adds no reply (decided 2026-10-07). `needs_input` asks the user instead and answers "asked the user…" |
| `reply_to_note(id, message, asks?, location?)` | Adds a reply, or a question when `asks`; the note stays open. Refused for drafts and resolved notes ("the user reopens it with a follow-up") |
| `ask_user(path, question, line?, end_line?, text?, host?)` | A new note by the agent whose thread opens with its question, waiting on the user; at most 20 open per document |
| `list_documents()` | Documents with sent notes, counts per state and `waiting_on_user` |
| `open_in_viewer`, `add_favorite`, `list_favorites` | Point the user at a file or range; keep a project folder at hand |

## Integrations

| Transport | Direction | Covers | How it works |
| --- | --- | --- | --- |
| Herdr socket | Push | Any agent in a Herdr pane, local or remote | NDJSON over the Unix socket. `agent.list` discovers targets, `agent.prompt` submits with bracketed paste, `events.subscribe` drives follow mode and status badges. Remote servers reached by forwarding their socket over the app's SSH connection |
| MCP server | Read and resolve | Claude Code, Codex, OpenCode | Streamable HTTP on localhost. Agents see only notes the user has sent; drafts are never listed, read or resolved. Tools (see **MCP tools** above): `list_pending_notes`, `get_note`, `resolve_note`, `reply_to_note` (an agent answers or asks on a note without resolving it, and can move it), `list_documents`, `open_in_viewer` (an agent shows the user a file at a line or a range of lines), `ask_user` (an agent asks the user about a place in a file; the question arrives as a note under Attention and the answer goes back when the user sends it), `add_favorite` and `list_favorites` (an agent keeps a project folder at hand in the explorer). Attachments as resources. Port reverse-forwarded for remote agents, whose registration URL carries `?host=<alias>` so paths resolve on their machine; the app writes each agent's config line on request |
| OpenCode API | Push | OpenCode launched with a fixed port | `POST /session/:id/message` with text and image parts |
| tmux | Push | Any agent in a tmux pane without Herdr | bracketed paste over the exec channel; pane chosen once per host |
| Clipboard | Manual | Anything, including bare mosh or ssh | Packet as text; attachments by path |

**Read integrations (milestone 2).** Settings → Integrations takes API keys that the app uses only to read; every change to a pull request, ticket or page is made by the agent with its own tools (the GitHub and Atlassian MCP servers, `gh`, or whatever the user installed). Keys live in the Keychain, never in the database or a file. Each integration has a Test connection button that reports the signed-in account and what the key can see.

| Integration | Credential | What the app reads | Shown as |
| --- | --- | --- | --- |
| GitHub | Personal access token (read scopes are enough; the client never issues anything but GET) | Pull requests: metadata, description, review and issue comments, changed files at the head commit, the unified diff | A root `github:/owner/repo/pull/N` with `Pull request.md`, `Conversation.md`, `changes/…`, `pull-N.diff`; polled for a new head commit while open |
| Atlassian | Site URL, email, API token | Jira issues (fields, description, comments, attached images and PDFs) and Confluence pages (body, version, attached images and PDFs), converted from the Atlassian document format to Markdown with images inline | `atlassian:/jira/PROJ/PROJ-123.md` and `atlassian:/confluence/SPACE/<ancestor ids…>/<id>/<Title>.md` (a page is its id: notes follow it through renames and moves, moving to the page's current path when it is next opened; until then the notes panel shows the path they were made on); polled for a new version while open |
| Web | None | Any URL in the review browser; `localhost` on a remote host through a port forward on the app's ssh connection | `web:<url>`, or a document of the ssh host when proxied |

**Herdr plugin.** Ships with the app and is installed from Settings → Agents, locally or on a connected host: the bundle is copied to `~/.config/gloss/herdr-plugin/` and linked with `herdr plugin link`. A keybinding (snippet shown in Settings; the app never edits Herdr's config) sends selected pane text to Gloss as a note; a link handler opens `file://` links and `path:line[:col]` locations printed by an agent in the viewer, scrolled to that line (also `file://…#L12`); `gloss://open` and `/plugin/open` take an optional `line`. On this Mac the script calls the app's URL scheme; on a host it posts to the app's `/plugin/note` endpoint through the reverse-forwarded port. Its note links carry a per-user token from `~/Library/Application Support/Gloss/url-token` (0600): the app refuses note links without it, since any web page can open a `gloss://` link and a planted note would reach the agent as the user's words. Its open links carry the token too: an `open` link to a file or an ssh host without it asks the user to confirm, since a page could otherwise open (and render) a file it just downloaded or make the app connect to a host.

**Herdr follow mode.** Subscribes to `pane.focused` and `pane.agent_status_changed` on every connected Herdr server. The focused pane's `foreground_cwd` becomes the root and the pane becomes the send target. Remote: `~/.config/herdr/herdr.sock` forwarded to a local socket on the existing control connection. Herdr's socket API has no notion of machines (each server only knows its own panes), so which server the Herdr client is showing comes from its state files, `~/.local/state/herdr/client/endpoint-selection.json` and `endpoints.json`, watched with FSEvents; a machine's ssh `target` is matched to the app host of the same name, which is connected on demand, and only that server's focus events reach the tree. Without those files every server's events apply.

## Architecture and technology

Architecture: the Mac runs one app process (Explorer, Viewers, Notes + anchors, Packet builder, SQLite store, MCP server, Transports, SSH manager, plus local Herdr and agent panes). One SSH control connection per remote host carries SFTP, the exec channel, the forwarded Herdr socket, and the reverse-forwarded MCP port, so remote agents in Herdr panes pull notes and resolve them with nothing installed on the host.

| Area | Choice | Why |
| --- | --- | --- |
| Language and UI | Swift 6, SwiftUI shell, AppKit for outline view, text editor, PDF, image canvas | Native feel, performance, system integration |
| Deployment target | macOS 26 | Other machines still on 26 |
| Remote connection | System `ssh` with a ControlMaster socket per host under `$TMPDIR/gl/<short host id>` (ssh's bind-time suffix rules out `%C`); the master runs without BatchMode so a key agent can prompt; the UI reports ssh's own verbose stages while connecting | Inherits ssh config, keys, agent, ProxyJump. Pure-Swift SSH libraries lack config and agent support |
| Remote file access | SFTP v3 spoken by the app over the `sftp` subsystem | Exact protocol with stat, rename, atomic save; no remote shell assumptions |
| Remote commands | Exec channel on the same connection | Search, git status, tmux, Herdr CLI, staging |
| Forwarding | OpenSSH forwarding on the control connection | Remote Herdr socket to a local path, local MCP port to the host |
| Storage | SQLite via GRDB | One file under Application Support |
| Markdown | swift-markdown, custom attributed-string renderer | Source ranges per node |
| Syntax highlighting | tree-sitter via SwiftTreeSitter | Highlighting and structural selection |
| MCP | Official MCP Swift SDK, stateful HTTP server transport | No bridge process |
| Herdr client | Hand-written NDJSON client | Simple protocol |
| Other viewers | PDFKit, NSImageView with overlay, QLPreviewView | System frameworks |
| Distribution | Developer ID signed, notarized, no App Sandbox | Needs ssh, ssh config, localhost listener |
| Updates | Sparkle 2, appcast and releases on GitHub | The update dialog, signature checks and in-place install every Mac app user knows |

**Process model.** One app process. SSH connections are child processes supervised by a connection manager actor. MCP server, Herdr clients, and file watchers are structured concurrency tasks.

**Modules.** Swift packages `Core` (models, database, anchors, packet builder), `Remote` (SSH, SFTP, forwarding), `Transports` (Herdr, MCP, agent installs, OpenCode, tmux), `Viewers`, and the `App` target. Each package has its own tests.

## Data model

| Table | Key columns | Purpose |
| --- | --- | --- |
| `host` | `id`, `name`, `kind` (local, ssh; milestone 2 adds web, github, atlassian with fixed ids `h_web`, `h_github`, `h_atlassian`), `last_connected_at`, `origin` (local, ssh_config, manual), `options_json` (HostName, User, Port, IdentityFile for app-added hosts; `alias` for an ssh config alias listed under another name, e.g. `github` listed as `github-ssh` because the integration host owns `github`; `site` for the `atlassian` host: the site its documents are about — when the saved site changes, that site's documents move under `/previous-sites/<host>` with their notes and its recent roots are forgotten) | Hosts used |
| `root` | `id`, `host_id`, `path`, `last_opened_at`, `pinned` | Recent and pinned roots |
| `document` | `id`, `host_id`, `path`, `kind` (text, code, markdown, image, pdf, csv, file; milestone 2 adds web, whose path is a URL), `last_hash`, `last_mtime`, `last_size` | File identity and conflict fingerprint |
| `note` | `id`, `document_id`, `anchor_json`, `anchor_type`, `body`, `state`, `created_at`, `updated_at`, `color`, `resolve_outcome`, `resolve_message`, `previous_state` (the state before orphaning), `author` (the agent that asked, for an agent's question), `resolve_agent` (the agent that resolved it through MCP, which its reply is headed with), `waiting_on_user` (an agent's question is open), `original_anchor_json` and `original_anchor_type` (where it was before its first move, for Restore Original) | Note with typed anchor and state; `body` is the original comment only |
| `note_message` | `id` (`m_` ULID), `note_id` (cascade delete), `author` (`user`, the agent's name, or NULL for Gloss), `kind` (`comment`, `question`, `reply`, `moved`), `body`, `meta_json` (for `moved`: `{from, to, removed}` anchors), `created_at`, `sent_at` (NULL for a follow-up not sent yet) | A note's thread after its comment (migration `v11-note-threads` split the old `Agent asked:`/`Answer:` bodies into it) |
| `attachment` | `id`, `note_id`, `kind`, `local_path`, `width`, `height` | Crops and page renders |
| `send` | `id`, `target_json`, `transport`, `packet_text`, `sent_at`, `outcome` | Delivery history |
| `send_note` | `send_id`, `note_id` | Notes per send |
| `staged_file` | `id`, `send_id`, `host_id`, `remote_path`, `expires_at` | Remote uploads for cleanup |
| `target` | `id`, `host_id`, `transport`, `identity_json`, `label`, `last_used_at` | Known agent targets |
| `setting` | `key`, `value` | Preferences |
| `web_page` | `url` (the document key), `host_id` (`h_web`, or the ssh host whose loopback served it), `title`, `last_visited_at`, `pinned`; keyed by `url` and `host_id` | Pages visited, for the explorer's Web section and Open Quickly |

**Anchor JSON.** Text `{start:{line,col}, end:{line,col}, text, before, after, hash?}`. Image `{x, y, w, h, imageW, imageH, hash?}`. PDF `{page, bounds:{x,y,w,h}, text, pageCount}`. Whole file `{}`. Embedded image `{source, occurrence, region:{x,y,w,h,imageW,imageH,hash?}, embed:<text anchor>}` with `anchor_type = embedded-image`. Element (milestone 2) `{selector, tag, text, html, rect:{x,y,w,h}, line?, hash?, region?:{x,y,w,h,imageW,imageH}, imageSource?}` with `anchor_type = element` (`region` and `imageSource` only on a picture). `hash` is the SHA-256 of the file at anchor time (optional for backward compatibility; `col` counts UTF-16 units, `page` is 0-based in storage and printed 1-based).

**Note states.** `draft`, `sent`, `resolved`, `orphaned`. draft→sent on delivery; sent→resolved by MCP or by hand; draft or sent→orphaned when re-anchoring fails (a resolved note stays resolved: the agent rewriting its text is the expected outcome); orphaned→the state it had before when the anchor is found again or placed by hand (decided 2026-10-05, issue #6); sent→draft by hand (Back to Draft, issue #13), keeping the send history; the agent may have read it but can't resolve a draft. orphaned→resolved by the agent when the note was sent before its text went (removing the text is often what the note asked for), or by hand; `list_pending_notes` lists such notes as orphaned with "(text no longer found)", and a resolved note stays resolved if its text comes back (decided 2026-10-06). resolved→sent by a follow-up (draft if the note was never sent); sent stays sent while the agent replies or asks, with `waiting_on_user` set by a question and cleared when a follow-up is sent (decided 2026-10-07).

## Milestone 1

Milestone 1 is the whole product. Done means every check passes on the local Mac and on one remote host over mosh with Herdr running.

**Build order.** Local explorer and viewers → notes and clipboard transport → SSH and SFTP with remote editing → Herdr and MCP → OpenCode, tmux → Herdr plugin and polish.

**Acceptance checks.** Ticked items were verified at the end of milestone 1 (2026-10-02); the note says how. Items marked "user" need a real agent session or a keybinding and are left for the user to confirm.

- [x] Browse a remote root over an ssh config alias while the only terminal connection to that host is mosh inside tmux — the app's ControlMaster is independent of any terminal; browsed `asus:/home/colin` in the app (Phase 3)
- [x] Open a markdown file, toggle rendered and source, and see the same note highlighted in both views — Phase 2 screenshots
- [x] Edit and save a remote file, have an agent edit the same file, and get a conflict diff instead of a silent overwrite — conflict sheet locally (Phase 2); SFTP conflict detection against asus in `RemoteHostTests`
- [x] Annotate a rectangle on a PNG and send it to Claude Code in a remote Herdr pane; the agent receives the crop path, the coordinates, and the comment, and can view the crop — `AcceptanceRemoteTests.stagedCropReachesARemoteHerdrPane` stages the crop on asus and reads the packet back from a Herdr pane there; the viewing step needs a real agent (user)
- [x] Annotate a PDF page region and send it the same way — same path; PDF region crops are covered by the Viewers tests
- [x] Send three notes across two files as one packet and see all three flip to resolved when the agent calls the MCP tool — `AcceptanceRemoteTests.threeNotesAcrossTwoFilesResolveFromTheHost` resolves them from asus through the reverse-forwarded port
- [x] Focus a different Herdr pane on another host and watch the tree follow it — follow events through the forwarded socket in `RemoteHerdrTests`; the in-app toggle was exercised locally (user: watch it on asus)
- [~] ~~Type "address my notes" in Claude Code and in Codex with no manual paste and have the hook deliver pending notes~~ — withdrawn 2026-10-05 (issue #5): the hook also fired on the prompt a send submits and shipped every other draft, so drafts now leave only on Send
- [x] Send a note to an OpenCode session through its HTTP API with an image part — verified against a real `opencode serve` (reply received)
- [x] Send a note to an agent in a plain tmux pane with no Herdr — verified live, locally and on asus
- [x] Copy a packet to the clipboard and paste it into a bare mosh session — clipboard verified (Phase 2); pasting into mosh is the terminal's job
- [x] Edit a file that has notes, reopen it after the agent rewrote the section, and see notes re-anchor or show as orphaned — Core re-anchoring tests and Phase 2 in-app check
- [x] Quit, relaunch, reconnect to the remote host automatically, and find every note where it was — the most recent root on any host is reopened at launch, connecting the host; notes are keyed by host and path in SQLite
- [ ] Press a Herdr keybinding with text selected in an agent pane and see it arrive in the app as a note — plugin linked and its URL verified; binding the key in Herdr's config is the user's step (snippet in Settings)
- [x] Open a QuickLook-only file, such as a `.numbers` document, and attach a whole-file note — Phase 2

## Milestone 2

Milestone 2 (scoped 2026-10-03) runs the same loop, select → note → send → see the reply, over things that are not files on a disk: web pages the agent builds, GitHub pull requests, and Jira tickets and Confluence pages. Three decisions shape it:

- **The app reads, the agent writes.** The app fetches and renders with the user's own API keys and never calls a write endpoint. Packets name the exact resource (URL, PR and head commit, issue key and field, page id and version) so the agent changes the real thing with its own tools. What the app shows is always the live resource, so after the agent edits a ticket the note's document updates and the note re-anchors or flags itself, exactly as a file does today.
- **Integrations are hosts.** A pull request, a Jira project or a Confluence space is a root on a virtual host with a tree the explorer already knows how to show; its documents open in the existing viewers (Markdown for descriptions, tickets and pages; the code editor for changed files), and notes are keyed by host and path like any other. Nothing about documents, anchors, the notes panel, the packet or the MCP tools is duplicated.
- **The browser is for reviewing.** WebKit is the engine; the app is the browser around it. Links to files open the file, links to pages navigate in place with Back/Forward and the window title as the address field, `localhost` on a remote host is reached through a port forward on the app's existing ssh connection. Pages visited are listed in the explorer's Web section, where they can be pinned (decided 2026-10-06); there are no saved passwords, extensions or downloads.

**Build order.** Review browser → Integrations tab and GitHub pull requests → Jira and Confluence. Each phase ends with a live check and a review.

**Credentials in development.** `integrations.env` at the repo root holds real keys. It is gitignored and never committed. In testing the keys only read; test notes go to the clipboard target, never to an agent with GitHub or Atlassian tools; a debug-only launch option loads the file into the run's credential store (in memory with `--reset-db`, so a throwaway copy keeps nothing), so no key is ever typed into the app by a script.

**Acceptance checks.** Ticked when verified; the note will say how.

- [x] Open a local HTML file, click a relative link to another file and an absolute link to a web page: the file opens as a document with the explorer following, the page loads in place, and Back returns to the file — verified live on a fixture site with a throwaway database (2026-10-03): about.html and docs/PLAN.md opened as documents, example.com loaded in place as a web document, Back and Forward moved between them with the document following
- [x] Open `http://localhost:3000` on a remote host while the dev server runs only there: the page loads through the app's ssh connection, relative links and hot reload work, and the document is stored against that host so the packet's `File:` line is right on the agent's machine — verified live against asus with a python http.server bound to its 127.0.0.1 (port 8766): opened via Open Location → Via asus (the sheet the address bar has since replaced), rendered through the master's forwarded port, a relative link stayed inside the tunnel, the document was asus's; `RemoteTests.forwardsALocalPortToARemoteLoopbackServer` covers the forward (hot reload needs a real dev server: user)
- [x] Turn on Element Notes, click a button on a page, write a note, send it to the clipboard: the packet carries the selector, the HTML snippet, the rect and a PNG crop of the element, and the note draws as an outline on the page — verified live on the fixture's Save button: hover label, editor at the element, outline after commit, packet with `Element: [data-testid="save"]`, `Text`, `Rect … (crop attached)`, `Line 8`, `Snippet` and the staged 2x PNG; `ElementNoteTests` and `WebBridgeTests` cover the pieces
- [x] Change the page under an element note (rename the id, keep the text): the note moves and is flagged for review; remove the element: the note is orphaned — `ElementNoteTests` drives rename → flagged under the new selector, removal → orphaned, and the element coming back → draft again; live, removing the button from the file orphaned the note (the page hash now covers the DOM, not only its text, so a renamed id counts as a change)
- [ ] Click a picture on a page (one inside a link too): Add Note shows beside it and the note's crop is the whole picture; drag across an `object-fit` picture: the region's outline sits on that part and the packet has `Image:` and `Region:`; in Pick Element, ↑ steps from a picture to its card — `WebBridgeTests` (click, cover drag, stepping) and `ElementNoteTests` (region crop and anchor) cover the pieces; the live check is pending
- [x] Enter a GitHub token and an Atlassian site, email and token in Settings → Integrations, press Test connection on each: the status line names the account and what it can see; a wrong token says so — verified live (2026-10-03) with the keys loaded by `--integrations-env` into a throwaway copy: "Signed in as <login> · <scopes>" and "<name> · Jira and Confluence"; `GitHubClientTests.errorsAreNamed` covers a refused token ("Bad credentials"), a spent rate limit and a missing resource, and `everyRequestIsAGet` that the clients never issue anything but GET
- [x] Open a pull request by URL or `owner/repo#123`: `Pull request.md`, `Conversation.md`, the changed files at the head commit with changed lines tinted and a hunk stepper, and the whole diff appear as a root; a note on a changed line produces `Resource:` and `Path: … at <sha>` in the packet — verified live (2026-10-03) with the saved token on a merged three-file pull request: the picker listed the open pull requests, `owner/repo#2` opened the root with its four entries, the description rendered, a changed Go file opened at the head commit with line 187 tinted, the gutter bar, the ruler mark and "1 of 1" after Next Change; the packet header is covered by `PullRequestPacketTests` (`Source: pull_request`, `Resource:`, `Path: … at f00d123`, `Comment:` for the conversation) and a selection in a read-only editor becoming a note by `ChangeSteppingTests`
- [x] Push a new commit to the PR while a changed file is open: the file reloads, notes re-anchor, and a notice names the new head — `GitHubPullRequestFileSystemTests.watchingSeesANewHead` drives the poll: a new head sha refreshes the snapshot and reports every document changed plus a rescan, after which the session's ordinary reload re-anchors and shows "Pull request updated"; pushing to a real pull request while it is open is the user's check (user)
- [x] Open a Jira issue by key: description and comments render as Markdown with the fields in a header; a note on a description line produces `Resource: …/browse/KEY` and `Field: description` — verified live (2026-10-04) in a throwaway copy with the keys loaded by `--integrations-env`: File › Open Jira Issue or Confluence Page… listed the 50 issues the account is part of and opened one under its `Jira · <PROJECT>` root with the fields, description and comments rendered; the packet lines are covered by `AtlassianFileSystemTests` (resource per line: description, a comment's id, a page's version) and `AtlassianOpenTests.aNoteOnAnIssueNamesTheIssueAndItsField`
- [x] Open a Confluence page by URL: the body renders as Markdown with the version in the header; a note produces `Resource:` and `Version:` — verified live (2026-10-04): the picker's Confluence side listed the site's spaces (team spaces first), a space opened as `Confluence · <SPACE>` with its pages as folders holding the page and its children, a pasted page URL opened the page directly with `version 15` in its header, and a note on a body line copied as `Source: confluence` / `Resource: <page url>` / `Version: 15`
- [ ] Have the agent change a ticket while it is open: the document updates, the notes re-anchor, and the notice names the editor and the new version (user: needs a real agent with Atlassian tools)
- [x] `open_in_viewer` with a PR, issue or page URL opens it (an agent can say "look at this") — pull request and web URLs: `MCPServerTests.openInViewerUsesTheSessionHost` (url → github:/o/r/pull/12/Pull request.md, web:…) and the `gloss://open?url=` route opened a changed file live; issue and page URLs of the saved site resolve to the atlassian host (`AtlassianOpenTests.urlsOfTheSavedSiteRouteToTheAtlassianHost`, `mcpURLsResolveOnlyForTheSavedSite`); another site's URL stays a web page
- [x] Every request the app makes with an integration key during a full live session is a GET — by construction: every client call goes through `GetOnlyHTTP.get`, the only verb the type has (`everyRequestIsAGet` records the methods of a session's requests and asserts `["GET"]`), and the phase C and D live sessions' request logs held only GET lines

## Updates and feedback

Scoped 2026-10-04. Gloss is released from its GitHub repository (`colinc86/gloss`) and keeps itself up to date the way other Mac apps do.

- **Updates are Sparkle's.** Gloss › Check for Updates… (also in Help) and a daily check that Settings › General can turn off. When a newer version exists, Sparkle's dialog shows its release notes (the GitHub release's description) with Install Update, Remind Me Later and Skip This Version; installing replaces the app in place and relaunches it. Every release is notarized, and its zip is signed with the project's EdDSA key, which Sparkle checks before installing. `scripts/release.sh` builds, notarizes, publishes the release and lists it in `appcast.xml` at the repository root (see `docs/RELEASE.md`). Debug builds never check.
- **While the repository is private**, the feed and the release files are read through the GitHub API with the key from Settings › Integrations; without a key there are no updates and a manual check says why. When the repository goes public the feed moves to a public URL and updates need no key.
- **Feedback is a sheet.** The ladybug in the toolbar (and Help › Report a Bug or Request a Feature…) asks for Bug or Feature Request, a title and a description, and offers to include the app and macOS versions, shown before sending; nothing else about the machine is attached. With a GitHub key that can create issues it is filed as an issue on Gloss's repository, labelled `bug` or `enhancement`; otherwise, or when GitHub refuses the key, the same report opens on GitHub's new-issue form, filled in. A marker in the body lets the repository's `label-reports` workflow label reports from people without push access, whose requested labels GitHub drops.
- **The one write.** Filing feedback is the only write the app makes to GitHub, and only to its own repository, from its own client (`IssueReporter`); the integrations clients stay GET-only.

**Acceptance checks.**

- [ ] `scripts/release.sh 0.1.0 notes.md` publishes a notarized `v0.1.0` with its zip and lists it in `appcast.xml`
- [ ] A release build of 0.0.9 with the GitHub key saved finds 0.1.0, shows its notes, installs it and relaunches as 0.1.0
- [ ] Without a key, Check for Updates says updates need GitHub connected; a scheduled check stays quiet
- [ ] Turning off automatic checks in Settings › General stops the daily check
- [ ] A bug report sent from the sheet arrives as an issue labelled `bug`; without a key, Continue in Browser opens the filled-in form

## Link and paths

Scoped 2026-10-05. **Acceptance checks.**

- [x] Link on: scrolling a note-heavy Markdown file keeps the card of the note nearest the middle of the page centred in the notes panel — verified live on `docs/DESIGN.md` with 18 notes, rendered view; `NoteLinkTests` covers the choice of note
- [x] Paths on: each visible note is outlined and joined to its card's rail, follows scrolling, and disappears for a card scrolled out of the list — verified live on the same file and on a 120-row CSV with row notes; `NoteLinkTests` covers the outline and the curve, `NoteGeometryTests` what the editor reports
- [ ] PDF regions and text, image regions and a web page's element notes get paths too (user: needs notes made by hand in those viewers)

## Issues from 0.1.1 (2026-10-05)

Six reports filed from the app's feedback sheet. **Acceptance checks.**

- [x] #8 Bulk actions: selecting notes brings up a bar with Send, Resolve, Reopen as Drafts, Colour, Copy as Packet and Delete for the selection, each taking only the notes it applies to; deleting several is one Undo; the Notes menu's Selected commands act on the whole selection — `NoteBulkActionTests`, `NoteDeleteUndoTests.aBulkDeleteIsOneUndo`; live on a throwaway copy: Select All, bar with four, Resolve all, Delete, one selected bar, Delete and Undo
- [ ] #12 Notes step back once sent: drafts fill their text, sent notes are an underline, resolved a faint dotted one, the same ladder on every surface; hovering a note or selecting its card brings it back — `NoteStateLadderTests` (user: scroll a document with notes in every state)
- [ ] #10 An agent set-up an update made outdated (the old prompt hook) shows a toast at launch with Open Settings, which opens Settings › Agents; dismissing it holds until something else changes — `AgentsUpdateNoticeTests` (user: launch with the old hook in place)
- [ ] #13 Back to Draft puts a sent note (or several) back to a draft, keeping its send history; the agent can't resolve it until sent again — `NoteStoreTests.aSentNoteCanBeUnsent`, `MCPServerTests.agentsNeverSeeDrafts`
- [ ] #14 Edit… edits a note in its card whether or not it is on screen, and won't overwrite a comment that changed meanwhile — `NoteInlineEditTests`
- [ ] Escape puts the Add Note button away and cancels the composer — `DocumentNotesTests.escapeDismissesTheAddNoteButtonAndTheComposer`
- [ ] Notes on a picture embedded in Markdown (a local file, a Jira issue, a Confluence page, a pull request's file): in the rendered view a drag over the picture chooses a region, a click the whole picture; the note is drawn on the picture, sends a PNG crop of the region (the picture itself for a whole-image note) and an `Image:` block, and follows the embed through edits — `EmbeddedImageAnchorTests`, `EmbeddedImageRegionTests` (user: a real issue with a pasted screenshot)
- [ ] #9 Quitting and opening again brings back the folders, the document in front where you were reading (rendered or source), Back and Forward, and the notes panel; Settings › General chooses Everything, The last folder, Nothing, or As my Mac does (“Close windows when quitting an application”) — `WorkspaceRestoreTests` (user: quit and reopen with several folders, one on a remote host)
- [ ] #16 A ```` ```mermaid ```` block in the rendered view is drawn as its diagram, in light and dark; a broken one shows its code and Mermaid's error; a region note on a diagram sends a crop and reads `Image: Mermaid diagram (WxH)` — `MermaidDiagramTests`, `EmbeddedImageAnchorTests` (user: a flowchart and a sequence diagram, both appearances)
- [ ] Settings › General › App Icon shows 16 styles (graphite and frost in each note color, starburst, blueprint, rainbow, pixel); the pick is the Dock and app-switcher icon while Gloss runs and is remembered; Graphite Yellow, the bundled icon, hands the Dock back to the system — `AppIconStyleTests`, live: Starburst in the Dock
- [ ] #11 Paths leave the note's right edge level and meet the middle of the card's colour bar at a right angle — `NoteLinkTests` (user: compare with the wireframe)
- [ ] #7 The notes filter bar never wraps: at the panel's narrowest it drops the selected title, then the counts (the selected option keeps its count; Attention keeps an orange dot) — `FilterBar` density rows (user: narrow the panel)
- [ ] #3 Back and forward through documents across folders and hosts: Go › Back (⌃⌘←) and Forward (⌃⌘→) and the toolbar's chevrons, with their menus of recent places; a document closed since opens again with its folder; a deleted local file is skipped — `DocumentHistoryTests` (user: hop between two folders and a remote host)
- [ ] #4 Agent control: `ask_user` puts a question on lines of a file, opens it in front of the terminal without taking the keyboard, shows as "claude asks" under Attention, and a follow-up answers it and goes back on Send; `add_favorite` pins and opens a folder; `open_in_viewer` selects a range — `MCPServerTests.agentsAskAndKeepFavorites`, `NoteStoreTests.anAgentQuestionIsAnsweredWithAFollowUp`, `AgentControlTests` (user: from a real Claude Code session)
- [ ] #2 Jira and Confluence images: an issue's images and PDFs are files in `<KEY> attachments/` beside it and a page's in its folder's `attachments/`, shown inline in the rendered Markdown (Jira by file name, Confluence by file id) and listed under the issue's Attachments; each opens in the image or PDF viewer for region notes; downloads stay GET and never send the key to another host — `AtlassianAttachmentTests` (user: a real issue with a pasted screenshot)
- [ ] #6 Notes keep their place: 25 notes on one document survive an agent rewrite (inserted preamble, a deleted section, a rewritten sentence, a reordered section) with every surviving note on its own text and the lost ones orphaned or flagged, never silently moved; identical lines in different sections keep their own notes; a file changed while closed re-anchors on open; a packet for a closed file quotes it as it is now; a sent note found again stays sent — `ReAnchorTortureTests`, `NoteStoreTests.aRecoveredOrphanKeepsItsState`, `DocumentNotesTests.openingAChangedFileReanchorsItsNotes`, `aPacketForAClosedChangedFileUsesTheTextAsItIsNow` (live: 20 notes, one sent to a real Claude Code, the agent edits the file — user)
- [ ] #5 Drafts leave only on Send: with 20 drafts on a file, sending one through Herdr or tmux to a real Claude Code leaves 19 drafts, and the agent's session holds only the one; Copy as Packet leaves notes as drafts; an agent's `list_pending_notes` lists no drafts; Settings › Agents shows Update on a machine with the old prompt hook and Update removes it with a backup — `SendCoordinatorTests.sendingOneNoteChangesOnlyThatNote`, `copyingLeavesDrafts`, `MCPServerTests.agentsNeverSeeDrafts`, `HookInstallerTests.installRegistersMCPAndRemovesTheOldHook`

## Note threads (2026-10-07)

**Acceptance checks.**

- [ ] A follow-up on a sent note makes it sendable again; Send carries `Earlier:`, the agent's last message and the follow-up, keeps the note's id, and stamps the follow-up sent (one written while the send is under way stays unsent) — `SendCoordinatorTests.sendingAFollowUpStampsItAndKeepsTheID`, `aFollowUpWrittenDuringASendStaysUnsent`, `PacketBuilderTests.aFollowUpCarriesTheRecentTurns` (user: the clipboard packet on a throwaway copy)
- [ ] `reply_to_note` with `asks` turns the card orange under Attention and on the Dock; a reply without it leaves the note open; a follow-up on a resolved note reopens it — `MCPServerTests.agentsReplyAskAndMoveNotes`, `NoteThreadStoreTests`
- [ ] `resolve_note` is refused while a follow-up is unsent; `needs_input` asks rather than resolves — `MCPServerTests.agentsReplyAskAndMoveNotes`
- [ ] `location {line, end_line, text}` moves the highlight to the agent's new text, the card says "Edited by Claude Code" with the old text, and Restore Original puts it back; a location that doesn't match is refused and nothing is written — `MCPServerTests.agentsReplyAskAndMoveNotes`, `AnchorRelocatorTests` (user: live on a throwaway copy)
- [ ] `location {removed: true, line}` leaves a caret where the text was with "Removed by Claude Code"; deleting a note's text by hand leaves one with "Removed" — `AnchorRelocatorTests`, `ReAnchorerTests` (user: live on a throwaway copy)
- [ ] `get_note` returns the whole thread with `Moved:` lines, without unsent follow-ups — `PacketBuilderTests.theWholeThreadShowsMoves`, `SendCoordinatorTests.sendingAFollowUpStampsItAndKeepsTheID`
- [ ] Notes made with an older build (asked and answered bodies, a pending `needs_input` question) open as threads — `ThreadMigrationTests` (user: restart on a database from 0.2.0)

## Non-goals, risks, and open questions

**Non-goals for milestone 1.** Not a terminal. Not a git client (status dimming only). Not an IDE (no LSP, debugging, builds). No remote helper daemon. No editing of images, PDFs, spreadsheets. No iOS, no multi-user sync.

**Non-goals for milestone 2.** Not a general browser (no bookmarks, passwords, extensions, downloads). The app never writes to GitHub, Jira or Confluence (feedback filed on Gloss's own repository is the one exception; see Updates and feedback). No side-by-side diff viewer. No editing of tickets or pages in the app. Absolute `fetch("http://localhost:…")` calls inside a proxied page reach this Mac, not the remote host; relative requests work.

**Risks.**

| Risk | Likelihood | Mitigation |
| --- | --- | --- |
| Rendered markdown selection maps imperfectly inside inline formatting | Medium | Block-granularity anchors when ambiguous; source view for fine edits |
| Remote mtime polling misses rapid agent edits | Low | Hash as well as mtime on save; faster polling while focused |
| Herdr socket forwarding behaves unexpectedly | Low | Fallback: `herdr` CLI over the exec channel |
| SFTP bugs on unusual servers | Low | Test on OpenSSH Linux and macOS; exec fallback for reads |
| Large files freeze the text view | Medium | Over 2 MB read-only chunked; refuse over 50 MB in the text viewer |

**Open questions.**

- ~~Should an agent be allowed to create notes through MCP, to ask anchored questions?~~ Yes (decided 2026-10-05, issue #4): `ask_user` creates a question anchored to lines or text, shown like an agent's question on a sent note; at most 20 open per document.
- Should notes be exportable as a markdown file in the repo for agents with no transport?
- Herdr plugin: offered from Settings → Agents (decided during milestone 1), never installed silently.
- Is a menu bar presence useful for quick capture when the main window is closed?
