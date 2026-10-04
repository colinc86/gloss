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

A transport is how a packet reaches a target: Herdr socket, MCP pull, a Claude Code or Codex hook, the OpenCode HTTP API, tmux keystrokes, or the clipboard. Targets are discovered, not configured by hand, wherever a transport can enumerate sessions.

## File explorer

- **Host picker.** Hosts come from `~/.ssh/config` plus `local`. Selecting a host opens or reuses one SSH control connection. Reconnects are automatic after sleep or a network change.
- **Roots.** Each host remembers its recent roots. You can type a path, pick a recent one, or jump to the cwd of a Herdr pane. Multiple roots can be open as tabs in the sidebar.
- **Tree.** Lazy loading per directory, dotfiles toggled, gitignore-aware dimming when a `.gitignore` is present, file type icons. Expanding a remote directory is one SFTP round trip. Reveal in Explorer (⌘⇧J) selects the open document in the tree, expanding folders on the way and opening its folder as a root when none contains it.
- **Unknown file types.** A file whose extension nobody listed (`.jsonl`, a rotated log, a config with its own suffix) opens in the text editor when its first bytes are text and it is under the 2 MB editing limit; only binary or larger files go to QuickLook.
- **Follow mode.** The tree follows the focused Herdr pane: focus an agent on `workbox` and the tree switches to that host and that pane's working directory, connecting the host first if needed, and the agent becomes the send target. Switching machines in Herdr switches the tree the same way. Picking a Herdr or tmux agent in the target picker also opens its working directory. Agent status shows beside the root as a badge.
- **File operations.** New file, new folder, rename, move, duplicate, delete to trash locally, delete with confirmation remotely, reveal in Finder for local, copy path, copy relative path.
- **Search.** Filename filter in the tree. Content search uses ripgrep locally and `rg` or `grep` over the exec channel remotely, with results opening at the matched line. Open Quickly (⌘P) fuzzy-finds any file under the selected root, local or remote (`rg --files` or `find`, skipping `.git` and `node_modules`), ranking file-name and word-start matches first. Queries are plain text unless the `.*` toggle makes them regular expressions; case is ignored unless the query has a capital letter; an invalid regular expression says so instead of showing no matches.
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
| Web page (milestone 2) | WebKit in the app's own review browser: file-backed pages, live URLs, and dev servers on remote hosts through an ssh port forward; links stay in the app | Text range, or a DOM element | File-backed: yes, in source view. Live: no (source shows the current DOM) |
| Pull request file (milestone 2) | The code editor showing the file at the PR's head commit with changed lines tinted and a hunk stepper | Character range with real file line numbers | No |

**Markdown toggle.** The rendered view is built from swift-markdown's syntax tree, which carries a source range for every node. Rendered text is an attributed string whose runs carry those ranges, so a selection in the rendered view maps straight back to source bytes. Notes are stored in source coordinates and appear in both views.

**Editing.** Text and markdown documents are editable in place with undo, find and replace, tree-sitter structural selection, and Go to Line (⌘L, `line` or `line:column`). Syntax highlighting is incremental, so a keystroke re-highlights only what changed. Embedded languages (markdown inline text and fenced code, Rust macro bodies) are highlighted in documents up to 24 KB and corrected in the background after a pause in typing; larger documents skip them so typing stays fast, and highlighting stops above 1 MB. Note anchors shift with edits as they happen.

**Saving.** Local saves are atomic writes. Remote saves write a temp file in the same directory and rename over the original, preserving mode bits. Before any save the app compares current mtime and size (and hash on mismatch) with the values read at open time; on a difference it shows a three-way diff instead of overwriting.

**Live reload.** When a file changes on disk and the document has no unsaved edits, the viewer reloads and re-anchors notes. With unsaved edits, a banner offers reload or keep. Local changes arrive via FSEvents; remote changes by polling mtime every few seconds while the document is open.

## Annotations

| Anchor type | Stored fields | Re-anchoring strategy |
| --- | --- | --- |
| Text range | Start and end as line and column, the exact selected text, three lines of context before and after, SHA-256 of the file at anchor time | Exact match on selected text near the old position, then fuzzy match on context, then flag as orphaned |
| Image region | Rectangle in original pixel coordinates, original width and height, image hash | Image unchanged: keep. Dimensions changed: scale proportionally and flag for review |
| PDF region | Page index, bounds in page points, selected text if any, page count | Same page and text present: keep. Otherwise search nearby pages for the text |
| Whole file | Path and file hash | Always valid while the file exists |
| Element (milestone 2) | A CSS selector (id, `data-testid`, or an `nth-of-type` path; never class names), tag, trimmed text, an outerHTML snippet, the rect in page coordinates, the source line for file-backed pages, DOM hash | Selector hit with the same tag: keep (flag for review if the text changed). Otherwise one text match: move and flag. Several: nearest rect, flagged. None: orphaned |

**Creating a note.** Select a range or drag a rectangle, then click the floating Add Note button (or press the shortcut). A popover takes the comment with markdown: Return saves, Shift-Return (or Option-Return) adds a line, Escape cancels. Notes show as colored highlights in the viewer and as cards in the notes panel, grouped by document. The panel filters by state, color, and a text search over note bodies, file names, and resolve messages, and sorts by position in the file, newest, oldest, color, or state; the sort order is remembered.

**Lifecycle.** draft → sent → resolved, plus orphaned. Sent notes record target, transport, and time, and each card shows where its latest send went and when (or why it failed). A resolved card shows the agent's resolve message, and Reopen as Draft (card context menu) takes it back. In the notes panel, Return shows the selected note in the viewer and Delete removes it at once, with Undo in a toast and in Edit › Undo; each card's context menu reveals, edits, sends, copies the note as a packet or its comment or path, resolves, and deletes. Resolved notes were marked done by an agent through MCP or by hand. Orphaned notes lost their anchor and need a glance before resending.

**Scope.** Notes live in the app database, keyed by host and absolute path, never in the file. They persist across restarts and survive agent edits.

## Sending to agents

Send loop: highlight → write a note (draft) → build packet (text, grouped by file) → stage attachments (crops via SFTP) → deliver (Herdr, MCP, hooks, tmux) → agent works → agent resolves via the MCP `resolve_note` tool → note resolved, highlight fades, file reloads.

**Packet format.** See the `context-packet` skill for the normative grammar. One header per file, then one block per note; excerpts blockquoted and truncated head and tail past 40 lines; attachments referenced by absolute path on the machine the agent runs on; closing line names the note ids and the resolve tool.

Milestone 2 adds sources `web`, `pull_request`, `jira` and `confluence`. A live web page's `File:` line is its URL. Pull requests, issues and pages keep their virtual path in `File:` and add a `Resource:` line with the canonical URL (`https://github.com/o/r/pull/123`, `https://<site>/browse/PROJ-123`, the Confluence page URL) plus `Path: Sources/App.swift at 0f3a9c1` for a PR file, `Field: description` or `Comment: <url>` for an issue or PR body, and `Version: 7` for a page, so the agent can act on the real thing with its own tools. Element notes carry `Element: <selector>`, `Text:`, `Rect:`, `Line` when the page is a file, a blockquoted `Snippet:` of the element's HTML, and a PNG crop attachment.

```markdown
File: /home/colin/proj/docs/PLAN.md
Source: markdown

Lines 40-52
Excerpt:
> ## Auth flow
> The client refreshes tokens every 5 minutes...
User comment: "This contradicts the 15 minute TTL in api.md. Pick one and fix both."

File: /home/colin/proj/design/dashboard.png
Source: image
Original size: 2880x1800

Region: x=1204 y=312 w=640 h=220 (crop attached)
Attachment: /home/me/.cache/gloss/attachments/a1b2c3/dashboard-region-1.png
User comment: "The legend overlaps the chart here. Move it below."

Notes: 2. Mark each resolved with the gloss MCP tool when done.
```

**Choosing a target.** The send menu lists every live agent the app can see: Herdr panes on each connected host with agent kind and status, OpenCode servers, and mapped tmux panes. Last used target per root is the default; Cmd-Enter sends to it.

**Individually or in bulk.** Each note card has its own send button. The panel header's Send (⌘↩) sends the current document's drafts the panel shows (its state tab, colours, and search all apply; with the panel closed, all of the document's drafts) as one packet; Send All Drafts (⇧⌘↩, in the ⋯ menu) sends every draft across documents. What you see is what goes to the agent, and Copy Packet for Document (⇧⌘C) copies the same notes (decided 2026-10-03, for human-in-the-loop control).

**Attachments.** Crops and PDF page renders are PNG. Local targets: Application Support cache. Remote targets: uploaded over SFTP to a per-send temp directory on that host before delivery.

**Resolution.** The packet ends with the resolve instruction. When the agent calls the tool, the card flips to resolved. Without MCP, resolve by hand.

## Integrations

| Transport | Direction | Covers | How it works |
| --- | --- | --- | --- |
| Herdr socket | Push | Any agent in a Herdr pane, local or remote | NDJSON over the Unix socket. `agent.list` discovers targets, `agent.prompt` submits with bracketed paste, `events.subscribe` drives follow mode and status badges. Remote servers reached by forwarding their socket over the app's SSH connection |
| MCP server | Pull and resolve | Claude Code, Codex, OpenCode | Streamable HTTP on localhost. Tools: `list_pending_notes`, `get_note`, `resolve_note`, `list_documents`, and `open_in_viewer` (an agent shows the user a file at a line). Attachments as resources. Port reverse-forwarded for remote agents, whose registration URL carries `?host=<alias>` so paths resolve on their machine; the app writes each agent's config line on request |
| Claude Code hook | Pull | Claude Code | `UserPromptSubmit` hook drains draft notes under the session's cwd into `additionalContext` (10,000 char limit); drained notes become `sent` and stay reachable through MCP until resolved, so they are not re-injected on every prompt. Notes on pull requests, tickets, pages and web pages are under no cwd and are not drained: they reach an agent by Send or `list_pending_notes` |
| Codex hook | Pull | Codex | Same shape via `hooks.json`; experimental, needs the hooks feature flag |
| OpenCode API | Push | OpenCode launched with a fixed port | `POST /session/:id/message` with text and image parts |
| tmux | Push | Any agent in a tmux pane without Herdr | bracketed paste over the exec channel; pane chosen once per host |
| Clipboard | Manual | Anything, including bare mosh or ssh | Packet as text; attachments by path |

**Read integrations (milestone 2).** Settings → Integrations takes API keys that the app uses only to read; every change to a pull request, ticket or page is made by the agent with its own tools (the GitHub and Atlassian MCP servers, `gh`, or whatever the user installed). Keys live in the Keychain, never in the database or a file. Each integration has a Test connection button that reports the signed-in account and what the key can see.

| Integration | Credential | What the app reads | Shown as |
| --- | --- | --- | --- |
| GitHub | Personal access token (read scopes are enough; the client never issues anything but GET) | Pull requests: metadata, description, review and issue comments, changed files at the head commit, the unified diff | A root `github:/owner/repo/pull/N` with `Pull request.md`, `Conversation.md`, `changes/…`, `pull-N.diff`; polled for a new head commit while open |
| Atlassian | Site URL, email, API token | Jira issues (fields, description, comments) and Confluence pages (body and version), converted from the Atlassian document format to Markdown | `atlassian:/jira/PROJ/PROJ-123.md` and `atlassian:/confluence/SPACE/<ancestor ids…>/<id>/<Title>.md` (a page is its id: notes follow it through renames and moves, moving to the page's current path when it is next opened; until then the notes panel shows the path they were made on); polled for a new version while open |
| Web | None | Any URL in the review browser; `localhost` on a remote host through a port forward on the app's ssh connection | `web:<url>`, or a document of the ssh host when proxied |

**Herdr plugin.** Ships with the app and is installed from Settings → Hooks, locally or on a connected host: the bundle is copied to `~/.config/gloss/herdr-plugin/` and linked with `herdr plugin link`. A keybinding (snippet shown in Settings; the app never edits Herdr's config) sends selected pane text to Gloss as a note; a link handler opens `file://` links and `path:line[:col]` locations printed by an agent in the viewer, scrolled to that line (also `file://…#L12`); `gloss://open` and `/plugin/open` take an optional `line`. On this Mac the script calls the app's URL scheme; on a host it posts to the app's `/plugin/note` endpoint through the reverse-forwarded port. Its note links carry a per-user token from `~/Library/Application Support/Gloss/url-token` (0600): the app refuses note links without it, since any web page can open a `gloss://` link and a planted note would reach the agent as the user's words.

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

**Process model.** One app process. SSH connections are child processes supervised by a connection manager actor. MCP server, Herdr clients, and file watchers are structured concurrency tasks.

**Modules.** Swift packages `Core` (models, database, anchors, packet builder), `Remote` (SSH, SFTP, forwarding), `Transports` (Herdr, MCP, hooks, OpenCode, tmux, clipboard), `Viewers`, and the `App` target. Each package has its own tests.

## Data model

| Table | Key columns | Purpose |
| --- | --- | --- |
| `host` | `id`, `name`, `kind` (local, ssh; milestone 2 adds web, github, atlassian with fixed ids `h_web`, `h_github`, `h_atlassian`), `last_connected_at`, `origin` (local, ssh_config, manual), `options_json` (HostName, User, Port, IdentityFile for app-added hosts; `alias` for an ssh config alias listed under another name, e.g. `github` listed as `github-ssh` because the integration host owns `github`; `site` for the `atlassian` host: the site its documents are about — when the saved site changes, that site's documents move under `/previous-sites/<host>` with their notes and its recent roots are forgotten) | Hosts used |
| `root` | `id`, `host_id`, `path`, `last_opened_at`, `pinned` | Recent and pinned roots |
| `document` | `id`, `host_id`, `path`, `kind` (text, code, markdown, image, pdf, csv, file; milestone 2 adds web, whose path is a URL), `last_hash`, `last_mtime`, `last_size` | File identity and conflict fingerprint |
| `note` | `id`, `document_id`, `anchor_json`, `anchor_type`, `body`, `state`, `created_at`, `updated_at`, `color` | Note with typed anchor and state |
| `attachment` | `id`, `note_id`, `kind`, `local_path`, `width`, `height` | Crops and page renders |
| `send` | `id`, `target_json`, `transport`, `packet_text`, `sent_at`, `outcome` | Delivery history |
| `send_note` | `send_id`, `note_id` | Notes per send |
| `staged_file` | `id`, `send_id`, `host_id`, `remote_path`, `expires_at` | Remote uploads for cleanup |
| `target` | `id`, `host_id`, `transport`, `identity_json`, `label`, `last_used_at` | Known agent targets |
| `setting` | `key`, `value` | Preferences |

**Anchor JSON.** Text `{start:{line,col}, end:{line,col}, text, before, after, hash?}`. Image `{x, y, w, h, imageW, imageH, hash?}`. PDF `{page, bounds:{x,y,w,h}, text, pageCount}`. Whole file `{}`. Element (milestone 2) `{selector, tag, text, html, rect:{x,y,w,h}, line?, hash?}` with `anchor_type = element`. `hash` is the SHA-256 of the file at anchor time (optional for backward compatibility; `col` counts UTF-16 units, `page` is 0-based in storage and printed 1-based).

**Note states.** `draft`, `sent`, `resolved`, `orphaned`. draft→sent on delivery; sent→resolved by MCP or by hand; any→orphaned when re-anchoring fails; orphaned→draft when the anchor is fixed.

## Milestone 1

Milestone 1 is the whole product. Done means every check passes on the local Mac and on one remote host over mosh with Herdr running.

**Build order.** Local explorer and viewers → notes and clipboard transport → SSH and SFTP with remote editing → Herdr and MCP → hooks, OpenCode, tmux → Herdr plugin and polish.

**Acceptance checks.** Ticked items were verified at the end of milestone 1 (2026-10-02); the note says how. Items marked "user" need a real agent session or a keybinding and are left for the user to confirm.

- [x] Browse a remote root over an ssh config alias while the only terminal connection to that host is mosh inside tmux — the app's ControlMaster is independent of any terminal; browsed `asus:/home/colin` in the app (Phase 3)
- [x] Open a markdown file, toggle rendered and source, and see the same note highlighted in both views — Phase 2 screenshots
- [x] Edit and save a remote file, have an agent edit the same file, and get a conflict diff instead of a silent overwrite — conflict sheet locally (Phase 2); SFTP conflict detection against asus in `RemoteHostTests`
- [x] Annotate a rectangle on a PNG and send it to Claude Code in a remote Herdr pane; the agent receives the crop path, the coordinates, and the comment, and can view the crop — `AcceptanceRemoteTests.stagedCropReachesARemoteHerdrPane` stages the crop on asus and reads the packet back from a Herdr pane there; the viewing step needs a real agent (user)
- [x] Annotate a PDF page region and send it the same way — same path; PDF region crops are covered by the Viewers tests
- [x] Send three notes across two files as one packet and see all three flip to resolved when the agent calls the MCP tool — `AcceptanceRemoteTests.threeNotesAcrossTwoFilesResolveFromTheHost` resolves them from asus through the reverse-forwarded port
- [x] Focus a different Herdr pane on another host and watch the tree follow it — follow events through the forwarded socket in `RemoteHerdrTests`; the in-app toggle was exercised locally (user: watch it on asus)
- [ ] Type "address my notes" in Claude Code and in Codex with no manual paste and have the hook deliver pending notes — hook script verified live against the app; the install into the real settings is one click in Settings → Hooks (user)
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
- **The browser is for reviewing.** WebKit is the engine; the app is the browser around it. Links to files open the file, links to pages navigate in place with Back/Forward and an address field, `localhost` on a remote host is reached through a port forward on the app's existing ssh connection. There are no bookmarks, saved passwords, extensions or downloads.

**Build order.** Review browser → Integrations tab and GitHub pull requests → Jira and Confluence. Each phase ends with a live check and a review.

**Credentials in development.** `integrations.env` at the repo root holds real keys. It is gitignored and never committed. In testing the keys only read; test notes go to the clipboard target, never to an agent with GitHub or Atlassian tools; a debug-only launch option loads the file into the run's credential store (in memory with `--reset-db`, so a throwaway copy keeps nothing), so no key is ever typed into the app by a script.

**Acceptance checks.** Ticked when verified; the note will say how.

- [x] Open a local HTML file, click a relative link to another file and an absolute link to a web page: the file opens as a document with the explorer following, the page loads in place, and Back returns to the file — verified live on a fixture site with a throwaway database (2026-10-03): about.html and docs/PLAN.md opened as documents, example.com loaded in place as a web document, Back and Forward moved between them with the document following
- [x] Open `http://localhost:3000` on a remote host while the dev server runs only there: the page loads through the app's ssh connection, relative links and hot reload work, and the document is stored against that host so the packet's `File:` line is right on the agent's machine — verified live against asus with a python http.server bound to its 127.0.0.1 (port 8766): opened via Open Location → Via asus, rendered through the master's forwarded port, a relative link stayed inside the tunnel, the document was asus's; `RemoteTests.forwardsALocalPortToARemoteLoopbackServer` covers the forward (hot reload needs a real dev server: user)
- [x] Turn on Element Notes, click a button on a page, write a note, send it to the clipboard: the packet carries the selector, the HTML snippet, the rect and a PNG crop of the element, and the note draws as an outline on the page — verified live on the fixture's Save button: hover label, editor at the element, outline after commit, packet with `Element: [data-testid="save"]`, `Text`, `Rect … (crop attached)`, `Line 8`, `Snippet` and the staged 2x PNG; `ElementNoteTests` and `WebBridgeTests` cover the pieces
- [x] Change the page under an element note (rename the id, keep the text): the note moves and is flagged for review; remove the element: the note is orphaned — `ElementNoteTests` drives rename → flagged under the new selector, removal → orphaned, and the element coming back → draft again; live, removing the button from the file orphaned the note (the page hash now covers the DOM, not only its text, so a renamed id counts as a change)
- [x] Enter a GitHub token and an Atlassian site, email and token in Settings → Integrations, press Test connection on each: the status line names the account and what it can see; a wrong token says so — verified live (2026-10-03) with the keys loaded by `--integrations-env` into a throwaway copy: "Signed in as <login> · <scopes>" and "<name> · Jira and Confluence"; `GitHubClientTests.errorsAreNamed` covers a refused token ("Bad credentials"), a spent rate limit and a missing resource, and `everyRequestIsAGet` that the clients never issue anything but GET
- [x] Open a pull request by URL or `owner/repo#123`: `Pull request.md`, `Conversation.md`, the changed files at the head commit with changed lines tinted and a hunk stepper, and the whole diff appear as a root; a note on a changed line produces `Resource:` and `Path: … at <sha>` in the packet — verified live (2026-10-03) with the saved token on a merged three-file pull request: the picker listed the open pull requests, `owner/repo#2` opened the root with its four entries, the description rendered, a changed Go file opened at the head commit with line 187 tinted, the gutter bar, the ruler mark and "1 of 1" after Next Change; the packet header is covered by `PullRequestPacketTests` (`Source: pull_request`, `Resource:`, `Path: … at f00d123`, `Comment:` for the conversation) and a selection in a read-only editor becoming a note by `ChangeSteppingTests`
- [x] Push a new commit to the PR while a changed file is open: the file reloads, notes re-anchor, and a notice names the new head — `GitHubPullRequestFileSystemTests.watchingSeesANewHead` drives the poll: a new head sha refreshes the snapshot and reports every document changed plus a rescan, after which the session's ordinary reload re-anchors and shows "Pull request updated"; pushing to a real pull request while it is open is the user's check (user)
- [x] Open a Jira issue by key: description and comments render as Markdown with the fields in a header; a note on a description line produces `Resource: …/browse/KEY` and `Field: description` — verified live (2026-10-04) in a throwaway copy with the keys loaded by `--integrations-env`: File › Open Jira Issue or Confluence Page… listed the 50 issues the account is part of and opened one under its `Jira · <PROJECT>` root with the fields, description and comments rendered; the packet lines are covered by `AtlassianFileSystemTests` (resource per line: description, a comment's id, a page's version) and `AtlassianOpenTests.aNoteOnAnIssueNamesTheIssueAndItsField`
- [x] Open a Confluence page by URL: the body renders as Markdown with the version in the header; a note produces `Resource:` and `Version:` — verified live (2026-10-04): the picker's Confluence side listed the site's spaces (team spaces first), a space opened as `Confluence · <SPACE>` with its pages as folders holding the page and its children, a pasted page URL opened the page directly with `version 15` in its header, and a note on a body line copied as `Source: confluence` / `Resource: <page url>` / `Version: 15`
- [ ] Have the agent change a ticket while it is open: the document updates, the notes re-anchor, and the notice names the editor and the new version (user: needs a real agent with Atlassian tools)
- [x] `open_in_viewer` with a PR, issue or page URL opens it (an agent can say "look at this") — pull request and web URLs: `MCPServerTests.openInViewerUsesTheSessionHost` (url → github:/o/r/pull/12/Pull request.md, web:…) and the `gloss://open?url=` route opened a changed file live; issue and page URLs of the saved site resolve to the atlassian host (`AtlassianOpenTests.urlsOfTheSavedSiteRouteToTheAtlassianHost`, `mcpURLsResolveOnlyForTheSavedSite`); another site's URL stays a web page
- [x] Every request the app makes with an integration key during a full live session is a GET — by construction: every client call goes through `GetOnlyHTTP.get`, the only verb the type has (`everyRequestIsAGet` records the methods of a session's requests and asserts `["GET"]`), and the phase C and D live sessions' request logs held only GET lines

## Non-goals, risks, and open questions

**Non-goals for milestone 1.** Not a terminal. Not a git client (status dimming only). Not an IDE (no LSP, debugging, builds). No remote helper daemon. No editing of images, PDFs, spreadsheets. No iOS, no multi-user sync.

**Non-goals for milestone 2.** Not a general browser (no bookmarks, passwords, extensions, downloads). The app never writes to GitHub, Jira or Confluence. No side-by-side diff viewer. No editing of tickets or pages in the app. Absolute `fetch("http://localhost:…")` calls inside a proxied page reach this Mac, not the remote host; relative requests work.

**Risks.**

| Risk | Likelihood | Mitigation |
| --- | --- | --- |
| Rendered markdown selection maps imperfectly inside inline formatting | Medium | Block-granularity anchors when ambiguous; source view for fine edits |
| Remote mtime polling misses rapid agent edits | Low | Hash as well as mtime on save; faster polling while focused |
| Herdr socket forwarding behaves unexpectedly | Low | Fallback: `herdr` CLI over the exec channel |
| Codex hooks stay experimental and change shape | Medium | Codex also has MCP and Herdr |
| Hook context limit (10,000 chars) truncates batches | Medium | Summary plus ids; agent fetches full notes through MCP |
| SFTP bugs on unusual servers | Low | Test on OpenSSH Linux and macOS; exec fallback for reads |
| Large files freeze the text view | Medium | Over 2 MB read-only chunked; refuse over 50 MB in the text viewer |

**Open questions.**

- Should an agent be allowed to create notes through MCP, to ask anchored questions?
- Should notes be exportable as a markdown file in the repo for agents with no transport?
- Herdr plugin: offered from Settings → Hooks (decided during milestone 1), never installed silently.
- Is a menu bar presence useful for quick capture when the main window is closed?
