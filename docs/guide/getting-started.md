# Getting started

## Install

Gloss needs macOS 26 or later.

1. Download `Gloss-x.y.z.zip` from the [latest release](https://github.com/colinc86/gloss/releases/latest).
2. Unzip it and move **Gloss.app** to your Applications folder.
3. Open it. Gloss is signed and notarized, so macOS opens it without any extra steps.

## Open a folder

The first window offers **Open Folder…** (⇧⌘O) and, when your ssh config lists hosts, **On a Host** to open a
folder on another machine. Folders you've opened before are listed underneath, and Gloss reopens the last one when it
starts (Settings › General).

The explorer on the left shows the folder as a tree. Each open folder is a tab at the top of the sidebar.

- **Open Quickly** (⌘P) finds any file under the folder by name.
- **Find in Files** (⇧⌘F) searches file contents with ripgrep (or `grep` on a host without it). Results open at
  the matching line.
- **Filter Files** (⌥⌘J) narrows the tree by name. **Show Hidden Files** (⇧⌘.) shows dotfiles.
- Right-click a file or folder to create, rename, duplicate, move or delete, copy its path, or reveal it in Finder.

Local folders update as files change. Remote folders refresh when you come back to the window and every few seconds
while a folder is open.

## Viewing and editing

Click a file to open it. Gloss picks the viewer by file type:

| File | Viewer | Editable |
| --- | --- | --- |
| Text and code | Editor with syntax highlighting | Yes |
| Markdown | Rendered or source (⇧⌘M) | Yes, in source |
| Images | Zoomable image | No |
| PDF | PDF viewer with page thumbnails | No |
| CSV and TSV | Grid | No |
| HTML | The review browser, rendered or source | Yes, in source |
| Anything else | Quick Look | No |

**Back** and **Forward** (⌃⌘← and ⌃⌘→, or the chevrons at the top left) step through the documents you've shown,
across folders and hosts. Hold a chevron to jump several steps.

Files you edit save with ⌘S (⌥⌘S saves all). When a file changes on disk while it's open, Gloss reloads it; if you
have unsaved edits, it asks first. If the file changed since you opened it, saving shows the differences instead of
overwriting the other change.

## Staying up to date

Gloss checks for updates once a day and shows what's new before you choose to install. You can check now with
Gloss › Check for Updates…, or turn the daily check off in Settings › General.

While Gloss's repository is private, updates need a GitHub token that can read it. Add one in
**Settings › Integrations** (see [Integrations](integrations.md#github)).

## Reporting a bug

Click the ladybug in the toolbar. Choose Bug or Feature Request, give it a title and a description, and send. With a
GitHub token that can create issues, it's filed directly; otherwise it opens on GitHub ready to submit. Gloss offers to
include the app and macOS versions and shows them before sending; nothing else about your Mac is attached.

---

Next: [Notes](notes.md)
