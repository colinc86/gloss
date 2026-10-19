<p align="center">
  <img src="docs/media/icon.png" width="128" height="128" alt="Gloss app icon">
</p>

<h1 align="center">Gloss</h1>

<p align="center">
  <b>Mark up any content and send it to your agent.</b><br>
  <a href="https://github.com/colinc86/gloss/releases"><img alt="Latest release" src="https://img.shields.io/github/v/release/colinc86/gloss?include_prereleases&label=release&color=f5b942"></a>
  <img alt="macOS 26 or later" src="https://img.shields.io/badge/macOS-26%2B-555">
</p>

<p align="center">
  <picture>
    <source media="(prefers-reduced-motion: reduce)" srcset="docs/media/hero.png">
    <img src="docs/media/hero.gif" width="880" alt="Selecting a sentence in a Markdown file, adding a note to it, and sending it to an agent, beside a note already sent and one the agent has resolved with a reply. Each highlight on the page is joined by a curve to its card in the notes panel.">
  </picture>
</p>

Gloss adds context to content. Highlight anything, write a note, and send it to your coding agent.

- **Notes on anything.** Code, Markdown, images, PDFs, spreadsheets and web pages, down to a page's elements, or a whole file at once.
- **Readable Markdown.** Text at a comfortable line length, and tables that grow with the window, their columns wrapping to fit.
- **Local or remote.** Files on your Mac or on any host you reach over ssh.
- **Integrations.** GitHub pull requests, Jira issues and Confluence pages.
- **Talk it through.** Each note is a thread: the agent replies, or asks you a question, sometimes with choices.
- **Refine.** The agent reads a document for what's unclear and asks until it understands, then makes the changes.
- **Iterate and review.** Iterate on your content and review changes made by your agent.
- **Share for review.** Share a document and its notes through iCloud Drive. Others add notes; you send them to your agent.
- **Any agent, any terminal.** Claude Code, Codex or OpenCode, through [Herdr](https://herdr.dev), tmux, OpenCode or the clipboard.

## Install

Gloss needs macOS 26 or later.

1. Download the newest release from [Releases](https://github.com/colinc86/gloss/releases). Releases marked
   Pre-release are betas. Gloss keeps itself up to date from then on.
2. Open **Settings › Agents** and add the MCP to the agent of your choice.

## How it works

Drag to select text, an area of an image, or another visual element, and write a note about it.

<p align="center">
  <img src="docs/media/note-text.png" width="410" alt="A sentence in a Markdown file highlighted, with the note composer open beneath it and a comment typed.">
  <img src="docs/media/note-image.png" width="420" alt="A region dragged around a chart's legend in a picture, with the note composer open beside it and a comment typed.">
</p>

<details>
<summary>What the agent receives</summary>

```text
File: /home/me/acme-weather/docs/PLAN.md
Source: markdown

Note: n_01J9XQ4M2T8V6K3R5W7Y9ZB1CD
Line 8
Excerpt:
> We should cache the forecast results for ten minutes at most, and less for severe-weather alerts.
User comment: "Alerts can't wait ten minutes. Give them their own TTL, at most one minute."

Note: n_01J9XQ7B8R2N4P6S8T0VA3K7QM
Line 20
Image: dashboard.png (1440x880)
Region: x=1004 y=96 w=400 h=220 (crop attached)
Attachment: /home/me/.cache/gloss/attachments/s_01J9XQ9C4H6M8P0R2T4V6X8Z0B/1-dashboard-region-A3K7QM.png
User comment: "The legend overlaps the chart here. Move it below."

Notes: 2. When you've acted on a note, mark it resolved with the gloss MCP tool `resolve_note`, passing the id on its Note line. To answer or ask something without resolving it, use `reply_to_note`.
```

</details>

Turn on **Review When Done** in the Send menu to review the results. Each note the agent resolves stays highlighted
until you've looked at it. **Review** steps through them, showing what the agent says it changed, and you accept
each one or follow up.

### Refine a document

Choose **Notes › Refine This Document** and the agent reads it for anything ambiguous or left open. It asks
questions beside the text they're about, some with choices to pick from. Answer them and press Send at the end of
each round. The agent keeps asking until it has no more questions and has made its changes. End it whenever you
like; its questions stay as ordinary notes.

<!-- Picture to add: docs/media/refine.png, width 640. Alt: "A Refinement notice above a Markdown document, and an
agent's question beside a sentence offering three choices, one picked." -->

### Make it yours

Pick a syntax theme for light mode and another for dark in **Settings › Themes**, edit one, or import one from Xcode,
TextMate or VS Code. In a narrow window beside your terminal, Gloss switches to a compact layout with the notes in a
tray under the document.

<!-- Pictures to add: docs/media/themes.png and docs/media/compact.png, width 420 each, side by side. Alts: "The
Themes settings with a dark theme chosen and its code preview." and "Gloss in a narrow window, with one note in the
tray under the document." -->

### Share a review

Click **Share** in the toolbar to share the document in front with its sent notes; drafts stay on your Mac.
**Collaborate…** puts a live review in iCloud Drive and invites people to it, and **Send a Copy…** sends a copy that
stays separate. The people you share with read the document as you last shared it, add notes and answers,
and send them to you. Only you send them on to your agent. Sharing between two Macs is new in the 0.6 betas and
still being tested.

## What agents can do with Gloss

Gloss exposes an MCP server. Agents can:

- **Read your notes.** `list_pending_notes`, `get_note` and `list_documents` show the notes you've sent it. Notes you
  haven't sent stay private.
- **Answer them.** `resolve_note` checks a note off as done or skipped, with a reply that shows on its card. When you
  send with Review When Done, the agent says what it changed, and the note waits for you to accept it.
  `reply_to_note` answers without closing the note, or asks you something back. Each note is a thread: answer with
  a follow-up and send it, and the agent sees what it asked and what you said.
- **Move them.** When an agent rewrites or deletes the text a note is on, it can say where the change is, and the
  highlight moves there. The card shows what moved, and you can put it back.
- **Show you things.** `open_in_viewer` opens a file at the lines it means, or a pull request, Jira issue,
  Confluence page or web page.
- **Ask you something.** `ask_user` puts a question beside the text it's about, with choices to pick from when they
  help. Your answer goes back when you send it.
- **Refine with you.** In Refinement, the agent asks in rounds and calls `finish_refinement` once it has no more
  questions and has made its changes.
- **Keep folders at hand.** `add_favorite` and `list_favorites` manage the folders in your explorer.

## Feedback

Click the ladybug in the toolbar, or choose **Help › Report a Bug or Request a Feature…**. With a GitHub key that can
create issues, Gloss files the report itself; otherwise it opens GitHub's issue form, filled in. You can also
[open an issue](https://github.com/colinc86/gloss/issues/new/choose) directly.

## Build from source

Open `Gloss.xcodeproj` in Xcode 26 and run the Gloss scheme. [CONTRIBUTING.md](CONTRIBUTING.md) covers signing,
the tests and the guidelines. Report security problems privately, as [SECURITY.md](SECURITY.md) describes.

## License

MIT. See [LICENSE](LICENSE). The licenses of the packages Gloss is built on are in Help › Acknowledgments.
