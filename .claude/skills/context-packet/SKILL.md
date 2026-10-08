---
name: context-packet
description: The exact plain-text format Gloss sends to agents (derived from Orca's formatMarkdownReviewNotes and extended for images, PDFs, and whole-file notes), plus attachment staging rules and the closing MCP instruction. Read before touching the packet builder, any transport's delivery code, or the MCP note tools, so every path emits the same shape.
---

# Context packet format

One packet = one message to one agent. It is plain text, grouped by file, one block per note. No JSON, no markdown headers; agents read this better than structured blobs and Orca shipped this shape for a year.

## Grammar

```
File: <absolute path on the agent's machine, or the page URL for source web>
Source: <markdown|text|code|image|pdf|file|web|pull_request|jira|confluence>
[Resource: <canonical URL>]         # pull_request, jira, confluence: the thing the agent edits with its own tools
[Path: <repo path> at <sha>]        # pull_request file; also Field: <name>, Comment: <url>, Version: <n> as they apply
[Original size: <W>x<H>]            # image only
[Pages: <N>]                        # pdf only

Note: <note id>                     # first line of every note: the id resolve_note takes, and where a note begins
<anchor line>
[Excerpt:
> <blockquoted excerpt lines>]
[Region: x=<x> y=<y> w=<w> h=<h> (crop attached)]
[Attachment: <absolute path on the agent's machine>]
User comment: "<escaped comment>"   # left out only for an agent's own question (ask_user), which has no comment
[Earlier: <N> message(s) (get_note returns the whole thread)]
[Agent (<name>) asked: "<escaped>" | Agent (<name>) replied: "<escaped>"]
[User replied: "<escaped>"]...
[Moved: from <place> to <place>, by <who>. It was: "<escaped old text>"]   # get_note only

<blank line between notes, two blank lines between files>

Notes: <count>. When you've acted on a note, mark it resolved with the gloss MCP tool `resolve_note`, passing the id on its Note line. To answer or ask something without resolving it, use `reply_to_note`.
```

The closing line's second sentence (naming `reply_to_note`) was added 2026-10-07 and is on every packet, first sends included.

### Anchor line by source

| Source | Anchor line | Excerpt |
| --- | --- | --- |
| text, code, markdown | `Line 42` or `Lines 40-52` | selected lines, blockquoted; over 40 lines → first 20, `> ...`, last 20 |
| text whose note's text was removed (a point) | `Line 42 (text removed here)` | none, and no `Selected:`: the line holds something else now; the thread's `Moved: … removed … It was:` line carries the old text |
| csv cells | `Lines 2-4` then `Cells: B2, E4` (`B2:C4` for a full block); rows are the record's first source line | one `> B2 (header): value` per cell, read from the current file |
| csv columns | `Column E "notes"` or `Columns B "distance_km", C "climb_m"` (replaces the line range) | one `> <line>: value` per record, several columns joined by ` \| ` |
| markdown with a rendered-view selection | `Lines 40-52` plus `Selected: "<exact text>"` when the selection is a sub-line span | same |
| image | `Region: x=.. y=.. w=.. h=.. (crop attached)` in original pixel coordinates, origin top-left | none |
| image embedded in markdown (Jira, Confluence, a file) | `Line <n>` of the embed, `Image: <src as written> (<W>x<H>)`, then `Region: x=.. y=.. w=.. h=.. (crop attached)` in the picture's pixels, or `Whole image (image attached)`; `Attachment:` the PNG | none |
| pdf | `Page 3` plus `Region: ...` in page points when a region was drawn | selected text, blockquoted, if any |
| file (whole-file note) | `Whole file` | none |
| element (web, or an html file viewed as a page) | `Element: <css selector>`; on a picture (`img`, `svg`, `canvas`, `video`) then `Image: <src> (WxH)` (its `currentSrc`; `data:image/png (inline)` or `blob: (made by the page)` for one the page holds itself; `<svg>`/`<canvas>` for an inline one; W and H in its own pixels) and `Whole image (image attached)` or `Region: x=.. y=.. w=.. h=.. (crop attached)` in those pixels; then `Text: "<collapsed text>"` when the element has text, `Rect: x=.. y=.. w=.. h=..` in CSS pixels from the page's top-left (with ` (crop attached)` when the note isn't on a picture), `Line <n>` when the page is a file | `Snippet:` with the element's outerHTML blockquoted (at most 2048 characters); an `Attachment:` PNG crop of the element, or of the chosen part of the picture |

### Escaping

- The comment is wrapped in double quotes; escape `\` → `\\`, `"` → `\"`, CR → `\r`, LF → `\n` (Orca's rule, keeps one note on one logical line for the agent).
- The other line breaks (VT, FF, NEL U+0085, LS U+2028, PS U+2029) are escaped as `\u{XXXX}` in quoted values.
- Excerpt lines are prefixed with `> `; embedded newlines in a selected span become `\n> `. Every kind of line break above starts a new `> ` line.
- Header values (`File:`, `Resource:`, detail lines such as `Path:`, `Attachment:`, `Element:`, cell descriptions, a summary line's path) are printed as they are unless they contain a line break; then the whole value is escaped as a comment is. A file name with a newline (legal in git) must never start a line of its own.
- Paths are never quoted. Paths with spaces are fine because they are on their own labeled line.

### Thread lines (decided 2026-10-07)

A note is a thread: its comment (`note.body`), then messages (`note_message`): the user's follow-ups, the agent's replies and questions, and moves. `PacketThread` picks what a block carries:

- **A send** (`PacketThread.recent`, also Copy as Packet): the agent's last message, then every user message after it and every follow-up not sent yet (one written before the agent's last reply arrived goes after that reply, never into the count). A question the user hasn't answered (no sent user message after it) goes first, even when a status reply came after it. Older turns are counted on `Earlier:` (`1 message`, `3 messages`), left out when 0. Moves are left out, since the anchor lines say where the note is now, except the latest removal while the note still sits at the point where its text was: its `Moved: … removed` line goes first, because the line the note now points at isn't what it was about. A note with no agent message carries all its follow-ups. **A first send has no thread lines**, so it is the packet as before.
- The send marks sent exactly the follow-ups the packet carried, with the words it carried: one written or changed while the delivery is under way stays unsent for the next send.
- **`get_note`** (`PacketThread.full`): every sent turn in order, plus `Moved:` lines; no `Earlier:`; a follow-up the user hasn't sent never appears.
- `Moved: from lines 3-4 to line 9, by claude. It was: "<old text>"`, or for a removal `Moved: lines 3-4 removed, by claude.` with the same `It was:`. The place is `line N` / `lines A-B` for text, else the anchor summary (`element(#legend)`). `by` is the agent's name, `Gloss` for a removal Gloss found itself, or `the user` for Restore Original Place. `It was:` is left out when the old anchor has no text.
- Every message body is escaped and quoted as a comment is; the agent's name is a header value.

```
Note: n_01J9X...
Line 8
Excerpt:
> pollInterval = 60
User comment: "Poll less often."
Earlier: 3 messages (get_note returns the whole thread)
Agent (claude) asked: "One minute for all alerts, or only severe ones?"
User replied: "Only severe ones."
```

A note whose text was removed, sent again while it still sits where the text was:

```
Note: n_01J9Z...
Line 3 (text removed here)
User comment: "Retry less."
Moved: lines 3-4 removed, by claude. It was: "retry twice"
Agent (claude) replied: "Dropped the retry."
User replied: "Put a comment there instead."
```

## Example

```
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

### Milestone 2 sources

- `web`: a live page. `File:` is the logical URL as the user sees it (`http://localhost:3000/dashboard`, never the forwarded `127.0.0.1:<port>` form). A text note's anchor line is `Line N` of the page's serialised DOM (rarely meaningful) and its excerpt is the selected text itself, as for a PDF text selection; element anchors as above.
- `pull_request`: `File:` is the virtual path (`/owner/repo/pull/123/changes/Sources/App.swift`), `Resource:` the PR URL, then by the note's position: `Path: Sources/App.swift at <head sha7>` for a changed file; in `Pull request.md`, `Field: description` on the description's lines, `Comment: <review comment url>` inside a review comment, nothing more on the fact lines; in `Conversation.md`, `Comment: <comment url>` inside a comment, `Field: conversation` elsewhere.
- `jira`: `File:` is `/jira/PROJ/PROJ-123.md`, `Resource:` the browse URL, then by position: `Field: summary` on the title line, `Field: description` in the Description section, `Comment: <browse url>?focusedCommentId=<id>` inside a comment; every line but a comment's also gets `Updated: <ISO 8601 time>`, the issue's last update when the packet was built.
- `confluence`: `File:` is `/confluence/SPACE/<ancestor page ids…>/<page id>/<Title>.md`, `Resource:` the page URL, `Version: <n>` the page's version when the packet was built.

Lines that hold for every note of one file go in its header; a line that differs between them (each on its own comment) goes in that note's block, right under its `Line N` (after its `Note:` line).

The app only ever reads these resources; the agent makes every change with its own GitHub or Atlassian tools, which is why the header names the resource precisely.

## Attachment staging

- Crops and PDF page renders are PNG. Render PDF regions at 2x (144 dpi) for legibility.
- Local target: `~/Library/Application Support/Gloss/attachments/<send-id>/<name>.png`.
- Remote target: upload over SFTP to `~/.cache/gloss/attachments/<send-id>/` on that host BEFORE delivering the packet. The root is made 0700 and checked to be a real directory owned by the user (never `/tmp`: on a shared host a predictable directory there can be made first by someone else). Record each in `staged_file` with a 7 day `expires_at`; a cleanup task removes expired directories over the exec channel.
- The `Attachment:` path is always the path on the machine where the agent runs. Decide that machine from the target (Herdr pane host, tmux host, OpenCode host), not from where the file was viewed.

## Size rules

- There is no hook delivery (removed 2026-10-05, issue #5): a packet reaches an agent only when the user sends it. Agents see only sent notes through MCP; drafts never leave the app.
- Direct delivery (Herdr, tmux, OpenCode, clipboard) has no cap, but excerpts are truncated at 40 lines regardless.

## Resolution contract

MCP tool `resolve_note(id, outcome?: "done"|"skipped"|"needs_input", message?, location?)` flips state to resolved; `message` is added to the thread as the agent's reply. It is refused while the user has a follow-up they haven't sent. `needs_input` (agents with older instructions) asks instead: the note stays sent, waiting on the user, and the answer is "asked the user (note <id>); the answer comes back when they send it".

`reply_to_note(id, message, asks?, location?)` adds a reply, or a question when `asks` (the note then waits on the user), and never resolves. It is refused for drafts and for resolved notes ("the user reopens it with a follow-up").

`location`, on either: `{line, end_line, text}` (the exact new text; looked for in those lines, then nearest them within 50), `{removed: true, line}` (the note becomes a point where the text was), or `{selector}` for an element note. Gloss builds the anchor from the file as it is now; columns and context never come from the agent. A location that doesn't fit is an `isError` answer and nothing is written.

The closing line names both tools: `resolve_note` when the agent has acted, `reply_to_note` to answer or ask without resolving. Each note's id is the first line of its block (decided 2026-10-06; it used to be a list in the Notes line, matched to notes by position), so an agent resolves exactly the note it just read. The packet ends with the Notes line: the count and how to resolve. If a transport cannot reach MCP (clipboard to a bare mosh session), it is still emitted; the user resolves by hand.
