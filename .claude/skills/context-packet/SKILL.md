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
[Refinement: <refinement_id>. Host: "<escaped host>". <standing directive>] # once on each active document block

Note: <note id>                     # first line of every note: the id resolve_note takes, and where a note begins
[Author: <contributor name>]        # optional, escaped as a header value; immediately after Note
<anchor line>
[Excerpt:
> <blockquoted excerpt lines>]
[Region: x=<x> y=<y> w=<w> h=<h> (crop attached)]
[Attachment: <absolute path on the agent's machine>]
User comment: "<escaped comment>"   # left out only for an agent's own question (ask_user), which has no comment
[Earlier: <N> message(s) (get_note returns the whole thread)]
[Agent (<name>) asked: "<escaped>" | Agent (<name>) replied: "<escaped>"]
[Choices: single | multiple]       # immediately after its question, when metadata exists
[Choice 1: "<escaped label>"
Choice 2: "<escaped label>" ...]
[User replied: "<escaped>" | Contributor (<name>) replied: "<escaped>"]...
[Moved: from <place> to <place>, by <who>. It was: "<escaped old text>"]   # get_note only

<blank line between notes, two blank lines between files>

Notes: <count>. When you've acted on a note, mark it resolved with the gloss MCP tool `resolve_note`, passing the id on its Note line. To answer or ask something without resolving it, use `reply_to_note`.[ The user will review each result, so when you resolve a note, say in its message what you changed, in one sentence.]
```

The closing line's second sentence (naming `reply_to_note`) was added 2026-10-07 and is on every packet, first sends included. The bracketed third sentence (added 2026-10-10) is only on a send that asks the user to review the results (Review When Done): there the resolve message is what the user reads while reviewing, so the agent is asked for one.

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
| Mermaid diagram in markdown (a ```` ```mermaid ```` fence drawn as a picture) | as an embedded image, with `Line <n>` of the opening fence and `Image: Mermaid diagram (<W>x<H>)` in the drawn PNG's pixels (2x the diagram) | none |
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
- Every message body is escaped and quoted as a comment is; agent and contributor names are header values. `Author:` uses the same header escaping, without adding quotation marks.

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
File: /home/me/proj/docs/PLAN.md
Source: markdown

Note: n_01J9X...
Lines 40-52
Excerpt:
> ## Auth flow
> The client refreshes tokens every 5 minutes...
User comment: "This contradicts the 15 minute TTL in api.md. Pick one and fix both."


File: /home/me/proj/design/dashboard.png
Source: image
Original size: 2880x1800

Note: n_01J9Y...
Region: x=1204 y=312 w=640 h=220 (crop attached)
Attachment: /home/me/.cache/gloss/attachments/a1b2c3/dashboard-region-1.png
User comment: "The legend overlaps the chart here. Move it below."

Notes: 2. When you've acted on a note, mark it resolved with the gloss MCP tool `resolve_note`, passing the id on its Note line. To answer or ask something without resolving it, use `reply_to_note`.
```

### Milestone 2 sources

- `web`: a live page. `File:` is the logical URL as the user sees it (`http://localhost:3000/dashboard`, never the forwarded `127.0.0.1:<port>` form). A text note's anchor line is `Line N` of the page's serialized DOM (rarely meaningful) and its excerpt is the selected text itself, as for a PDF text selection; element anchors as above.
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

MCP tool `resolve_note(id, outcome?: "done"|"skipped"|"needs_input", message?, location?)` flips state to resolved. `message` is optional and usually left out: the change speaks for itself, except on a packet whose closing line asks for review, where it says in one sentence what changed. Pass one only to tell the user what the change and thread don't (a decision, a caveat, what was skipped and why); it is added to the thread as the agent's reply. A bare acknowledgement (`done`, `Done.`, `fixed`, `ok`, `okay`, `resolved`, trimmed, any case, trailing `.`/`!`) counts as no message and adds no reply. It is refused while the user has a follow-up they haven't sent. `needs_input` (agents with older instructions) asks instead: the note stays sent, waiting on the user, and the answer is "asked the user (note <id>); the answer comes back when they send it".

`reply_to_note(id, message, asks?, location?)` adds a reply, or a question when `asks` (the note then waits on the user), and never resolves. It is refused for drafts and for resolved notes ("the user reopens it with a follow-up").

`location`, on either: `{line, end_line, text}` (the exact new text; looked for in those lines, then nearest them within 50), `{removed: true, line}` (the note becomes a point at the start of `line`, the line that now sits where the text was), or `{selector}` for an element note. Gloss builds the anchor from the file as it is now; columns and context never come from the agent. A location that doesn't fit is an `isError` answer and nothing is written.

The closing line names both tools: `resolve_note` when the agent has acted, `reply_to_note` to answer or ask without resolving. Each note's id is the first line of its block (decided 2026-10-06; it used to be a list in the Notes line, matched to notes by position), so an agent resolves exactly the note it just read. The packet ends with the Notes line: the count and how to resolve. If a transport cannot reach MCP (clipboard to a bare mosh session), it is still emitted; the user resolves by hand.

## Refinement and choices (2026-10-12)

An active document's file block adds exactly one line after all shared file metadata and before its first Note:

```text
Refinement: rf_example. Host: "local". Read this document for ambiguous or open-ended content. Apply the user's sent answers and make the changes, then keep refining by asking questions with ask_user or reply_to_note (asks: true). Wait for the user to send answers. When you have no more questions and your changes are complete, call finish_refinement with this document's host, path, refinement_id, and a short summary.
```

The ID is correlation metadata; the escaped quoted host and enclosing File identify its document. Several documents can refine independently. Group file blocks by Document ID when available, including when distinct hosts have the same path. Every send, preview, copy and MCP full packet uses the builder. Preview/copy/read do not change mode, rounds or delivery. Ending removes undelivered directives; a packet already handed over cannot be retracted. Ordinary packets retain their exact existing grammar/bytes and Review's closing sentence still applies.

Options belong to their question message. After `Agent (<name>) asked: "..."`, emit `Choices: single` or `Choices: multiple`, followed by numbered `Choice N: "<escaped label>"` lines. Labels use the same quoted escaping as bodies and can never forge protocol lines. Keep the option lines with an unanswered question retained ahead of a status reply and with each historical question in the full sent thread. Option lines are metadata, not additional messages in the Earlier count. Answers remain ordinary `User replied:` text or, when a contributor name is present, `Contributor (<name>) replied:` text; unsent answers never appear in `get_note`.

`ask_user` and `reply_to_note` with `asks: true` accept optional `choices` (2–12 distinct trimmed nonblank strings, max 200 characters each) and `multi` (boolean, defaults false; true requires choices). Plain replies refuse those fields. Freeform is always available, with no mandatory Other option. Selection stages one editable user answer for that question; it does not send. A direct edit detaches the generated draft as a custom answer, protected from later choice clicks.

Entry sends only an ordinary visible whole-file request asking the agent to read the entire saved document. Refinement persists per document until the user ends it or the agent calls `finish_refinement(path, host?, refinement_id, summary)`. After applying sent answers and making changes, resolve the question/work notes acted on. Only finish when no current-iteration questions or unsent answers remain; historical questions and results awaiting review do not block. Summary is nonblank, at most 500 characters. Finish disables the directive and stores summary/time without resolving notes, accepting review or changing iterations. Same completed generation is idempotent; stale/ended generations refuse. Round advances once on the first question after a successfully delivered answer batch, never on preview, failure or unrelated sends.

## Collaboration attribution (2026-10-13)

`PacketNote.contributor`, when present, emits `Author: <name>` immediately after `Note: <id>`, before the anchor. This is a note-level header, not file metadata, an authenticated identity or permission to act. Omitted contributor attribution emits no Author line and changes no ordinary packet bytes. `headerValue` preserves names literally unless they contain a recognized line break; then it escapes the value on one logical line without surrounding quotes.

A human turn with `contributorName` emits `Contributor (<header-escaped name>) replied: "<body escaped as a comment>"`. An unnamed human turn retains `User replied:`. Agent turns retain `Agent (<name>) asked:` or `replied:`; UI via-owner labels do not introduce a new agent packet grammar. Recent/full turn selection, unanswered-question retention, option metadata, move lines and Earlier message counts are unchanged. Resource details applying only to one note are inserted after its first two lines: after Author when present, otherwise after the anchor, as `PacketBuilder.fileBlock` does.

~~~text
File: /home/me/acme/PLAN.md
Source: markdown

Note: n_01J9X000000000000000000000
Author: Morgan
Whole file
User comment: "Clarify the timeout."
Contributor (Morgan) replied: "Use five minutes."
User replied: "Keep the existing retry behavior."

Notes: 1. When you've acted on a note, mark it resolved with the gloss MCP tool `resolve_note`, passing the id on its Note line. To answer or ask something without resolving it, use `reply_to_note`.
~~~

For a contributor containing LF, `Morgan\nNote: forged` is the value on a single Author line, not a new Note. Turn bodies stay quoted and escaped; named-turn speaker headers use the same line-break escaping. The implementations and golden behavior are covered by `CollaborationStoreTests.packetCarriesContributorWithoutForgingLines` and the ordinary/refinement packet tests.

A participant's Send publishes to the shared review, never directly to an agent. The owner's explicit delivery is the MCP-visibility boundary. On owner-authorized reads, packets and attachment resources use the exact delivered snapshot: later private body/color/answer/image edits do not become visible and do not withdraw the previous delivery. Posted input and unsent answers stay out of agent packets until owner Send. File/Resource still identify the owner's original resource, not a recipient's read-only captured package.
