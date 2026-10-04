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

<anchor line>
[Excerpt:
> <blockquoted excerpt lines>]
[Region: x=<x> y=<y> w=<w> h=<h> (crop attached)]
[Attachment: <absolute path on the agent's machine>]
User comment: "<escaped comment>"

<blank line between notes, two blank lines between files>

Notes: <count>. Mark each resolved with the gloss MCP tool `resolve_note` (ids: <id1>, <id2>, ...) when done.
```

### Anchor line by source

| Source | Anchor line | Excerpt |
| --- | --- | --- |
| text, code, markdown | `Line 42` or `Lines 40-52` | selected lines, blockquoted; over 40 lines → first 20, `> ...`, last 20 |
| csv cells | `Lines 2-4` then `Cells: B2, E4` (`B2:C4` for a full block); rows are the record's first source line | one `> B2 (header): value` per cell, read from the current file |
| csv columns | `Column E "notes"` or `Columns B "distance_km", C "climb_m"` (replaces the line range) | one `> <line>: value` per record, several columns joined by ` \| ` |
| markdown with a rendered-view selection | `Lines 40-52` plus `Selected: "<exact text>"` when the selection is a sub-line span | same |
| image | `Region: x=.. y=.. w=.. h=.. (crop attached)` in original pixel coordinates, origin top-left | none |
| pdf | `Page 3` plus `Region: ...` in page points when a region was drawn | selected text, blockquoted, if any |
| file (whole-file note) | `Whole file` | none |
| element (web, or an html file viewed as a page) | `Element: <css selector>` then `Text: "<collapsed text>"` when the element has text, `Rect: x=.. y=.. w=.. h=.. (crop attached)` in CSS pixels from the page's top-left, `Line <n>` when the page is a file | `Snippet:` with the element's outerHTML blockquoted (at most 2048 characters); an `Attachment:` PNG crop of the element |

### Escaping

- The comment is wrapped in double quotes; escape `\` → `\\`, `"` → `\"`, CR → `\r`, LF → `\n` (Orca's rule, keeps one note on one logical line for the agent).
- Excerpt lines are prefixed with `> `; embedded newlines in a selected span become `\n> `.
- Paths are never quoted. Paths with spaces are fine because they are on their own labeled line.

## Example

```
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
Attachment: /tmp/gloss/a1b2c3/dashboard-region-1.png
User comment: "The legend overlaps the chart here. Move it below."

Notes: 2. Mark each resolved with the gloss MCP tool `resolve_note` (ids: n_01J9X..., n_01J9Y...) when done.
```

### Milestone 2 sources

- `web`: a live page. `File:` is the logical URL as the user sees it (`http://localhost:3000/dashboard`, never the forwarded `127.0.0.1:<port>` form). A text note's anchor line is `Line N` of the page's serialised DOM (rarely meaningful) and its excerpt is the selected text itself, as for a PDF text selection; element anchors as above.
- `pull_request`: `File:` is the virtual path (`/owner/repo/pull/123/changes/Sources/App.swift`), `Resource:` the PR URL, `Path: Sources/App.swift at <head sha>` for a changed file, `Field: description` for the description document, `Comment: <url>` when a note sits inside one review comment.
- `jira`: `File:` is `/jira/PROJ/PROJ-123.md`, `Resource:` the browse URL, `Field: description` or `Comment: <id>` by the note's position.
- `confluence`: `File:` is `/confluence/SPACE/<id> <title>.md`, `Resource:` the page URL, `Version: <n>` the version the note was made against.

The app only ever reads these resources; the agent makes every change with its own GitHub or Atlassian tools, which is why the header names the resource precisely.

## Attachment staging

- Crops and PDF page renders are PNG. Render PDF regions at 2x (144 dpi) for legibility.
- Local target: `~/Library/Application Support/Gloss/attachments/<send-id>/<name>.png`.
- Remote target: upload over SFTP to `/tmp/gloss/<send-id>/` on that host BEFORE delivering the packet, `mkdir -p` semantics via SFTP MKDIR with tolerated FAILURE-if-exists. Record each in `staged_file` with a 7 day `expires_at`; a cleanup task removes expired directories over the exec channel.
- The `Attachment:` path is always the path on the machine where the agent runs. Decide that machine from the target (Herdr pane host, tmux host, OpenCode host), not from where the file was viewed.

## Size rules

- Hook delivery (Claude Code and Codex `additionalContext`) is capped at 10,000 characters. Over that, the hook emits a summary line per note (`<id>: <file>:<anchor> "<first 80 chars of comment>"`) and the instruction to call `get_note` through MCP for the full excerpt.
- Direct delivery (Herdr, tmux, OpenCode, clipboard) has no cap, but excerpts are truncated at 40 lines regardless.

## Resolution contract

MCP tool `resolve_note(id, outcome?: "done"|"skipped"|"needs_input", message?)` flips state to resolved. The packet always ends with the Notes line so agents know the ids. If a transport cannot reach MCP (clipboard to a bare mosh session), the Notes line is still emitted; the user resolves by hand.
