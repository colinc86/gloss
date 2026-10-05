# Notes

A note is a place in a file plus what you want done about it. Notes are stored in Gloss, keyed by host and path, and
never written into the file.

## Making a note

Select something, then click the **Add Note** button that appears beside the selection (or press ⌘↩ while it shows).
Write your comment and press Return. Shift-Return adds a line; Escape cancels.

What you can select depends on the viewer:

| Viewer | Select |
| --- | --- |
| Text and code | Any range of characters |
| Markdown | A range in the rendered view or the source; the note shows in both |
| Image | Drag a rectangle |
| PDF | Text, or a region in Region mode |
| CSV | Rows, a cell, a block of cells, scattered cells, or whole columns |
| Web page | Text, or an element: turn on **Element Notes** in the browser's toolbar and click it |
| Anything else | The whole file: Notes › New Note from Selection (⇧⌘N) with nothing selected |

The note composer quotes what you selected, so you write against it. Pick one of six colours to group notes however
you like. Starter phrases (Explain, Fix, Add a test, Why) fill in the beginning of a comment.

## The notes panel

The panel on the right (⌥⌘N) lists the notes for open documents as cards, grouped by file.

- **Filters**: All, Drafts, Sent, Resolved and **Attention**, which holds notes that lost their place and questions
  from agents. When the panel is narrow the bar shows symbols; hover one for its name and count.
- **Colours and search** narrow the list further. Search covers comments, file names and agents' replies.
- **Sort** by position in the file, newest, oldest, colour or state.
- Click a card to show its note in the viewer. Return does the same for the selected card; Delete removes it, with
  Undo.
- Right-click a card to edit, send, copy it as a packet, resolve it, reopen it, or delete it.

⌘' and ⇧⌘' step through the notes in the open document.

## A note's life

| State | Means |
| --- | --- |
| Draft | Written, not sent yet. Edit it as much as you like. |
| Sent | Delivered to an agent. The card says where and when. |
| Resolved | The agent (or you, with ⇧⌘D) marked it done or skipped. Its reply shows on the card. |
| Needs your answer | The agent resolved it with a question, or asked you something about a file on its own. Click **Reply**, answer, and send it. |
| Orphaned | The text it pointed at is gone. Look at it, then fix or delete it. If the text comes back, the note returns to the state it had. |

When a file changes, whether it's open or not, Gloss finds each note's text again and moves the note. If the text
appears in several places, it picks the one whose surrounding lines match; when it can't be sure, the note moves but
is flagged for a look. Only when the text and its surroundings are both gone does a note become orphaned. A resolved
note stays resolved even when the agent rewrites its text. Image notes scale with a resized image; PDF notes search
nearby pages.

Settings › General can count notes waiting for your answer on the Dock icon.

## Link and paths

Two buttons in the viewer's status bar connect the page to the panel. They're also in the Notes menu, as Follow
Page in Notes Panel and Show Paths to Notes.

- **Link** makes the notes panel follow the page. As you scroll, the card for the note nearest the middle of the
  page stays in the middle of the list. While the pointer is over the list, it holds still.
- **Paths** (with link on) outlines every visible note in its colour and draws a curve from it to its card's colour
  bar. Hover a card or a highlight and its path stands out.

They work in every viewer where a note has a place: text, Markdown, PDF, images, spreadsheets and web pages.

---

Next: [Connecting agents](agents.md)
