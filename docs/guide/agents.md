# Connecting agents

Gloss sends notes to coding agents and hears back when they're done. The agent can be on this Mac or on any host you
reach over ssh.

## Set up

Open **Settings › Agents**. It lists this Mac and each connected host, with a row for Claude Code, Codex and
OpenCode, and the Herdr plugin on machines that have Herdr.

Press **Install** beside an agent to register Gloss's MCP server with it, so it can read the notes you send and
resolve them. Nothing changes until you press Install. Gloss saves a backup beside each settings file it edits, and
**Remove** takes out only what it added. The copy button beside each row gives you the same registration to run
yourself.

Any other agent that speaks MCP over HTTP can use the endpoint and snippets at the bottom of the page.

When an update to Gloss changes what an agent's set-up needs, a notice at the bottom right of the window says
which agent needs an update and why. **Open Settings** goes straight to Settings › Agents, where **Update** fixes it.

## Ways a note reaches an agent

A note reaches an agent only when you press Send. Drafts stay in Gloss until then, and agents can't list or read them.

| Route | Works with | Setup |
| --- | --- | --- |
| Herdr | Any agent in a Herdr pane, local or remote | None. Gloss finds Herdr's panes itself |
| MCP | Claude Code, Codex, OpenCode, any MCP client | Install in Settings › Agents. Agents read and resolve the notes you sent |
| OpenCode API | OpenCode started with a fixed port | None |
| tmux | Any agent in a tmux pane | Pick the pane once |
| Clipboard | Anything, including a bare ssh or mosh session | None |

The MCP server listens on `127.0.0.1` (the port is in Settings › Agents). Agents on a remote host reach it through
Gloss's ssh connection, so no server runs there.

## Sending

Pick the target from the send menu in the notes panel. It lists every live agent Gloss can see. Each folder
remembers the agent you last chose for it.

- **Send** beside the agent sends this document's drafts the panel is showing. Its ⋯ menu sends every draft in
  every document, or copies this document's drafts as a packet.
- **Send** on a card sends that note.
- **Select** several cards (⌘-click, ⇧-click, or ⌘A) and press **Send** in the bar above the list.
- **Notes › Send Drafts in Document** (⌘↩) sends the drafts the panel is showing for this document, so filters and
  search decide what goes.
- **Send All Drafts** (⇧⌘↩) sends every draft in every document.
- **Copy Packet for Document** (⇧⌘C) copies the same text instead. Copied notes stay drafts; choose Clipboard
  as the target and press Send when you want them marked sent.

Notes go out as one context packet: each file's path, then each note's location, an excerpt, and your comment. Image
and PDF notes include a cropped PNG, uploaded to the agent's machine when it's remote. The packet ends by asking the
agent to resolve each note.

## Resolving

The agent calls `resolve_note` on Gloss's MCP server with an outcome and a message:

- **done**: the card turns resolved, the highlight fades, and the reply shows on the card.
- **skipped**: resolved, with the agent's reason.
- **needs_input**: the card asks for you in the Attention filter. Reply on the card and send again.

Without MCP, resolve notes yourself with ⇧⌘D or the card's menu.

## When the agent wants you to look

Agents can drive Gloss to show you their work:

- `open_in_viewer` shows a file at a line or a range of lines, a pull request or a page.
- `ask_user` puts a question beside the lines it's about, such as "Does this section read right?" It shows under
  Attention in a bubble headed with the agent's name ("Claude Code asks"), and Gloss opens the file in front of your terminal without taking the keyboard.
  Click **Reply** to answer; your answer becomes a draft, and goes back to the agent when you send it.
- `add_favorite` adds a project folder to your favorites and opens it.

Tell your agent to use them, for example: "when you've written something I should review, ask me about it in
Gloss."

## Herdr

With the Herdr plugin installed (Settings › Agents), a keybinding sends text selected in an agent's pane to Gloss
as a note, and file paths an agent prints open in Gloss at the right line. Settings shows the keybinding snippet to
add to Herdr's config.

**Follow Herdr**, the crosshair button in the sidebar's toolbar (shown once Gloss finds Herdr), makes the explorer and the send target follow whichever agent pane you focus
in Herdr, on any machine. See [Remote hosts](remote-hosts.md#following-herdr).

---

Next: [Remote hosts](remote-hosts.md)
