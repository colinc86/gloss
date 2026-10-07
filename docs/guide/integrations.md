# Integrations

Gloss can open GitHub pull requests, Jira issues, Confluence pages and live web pages as documents. You annotate
them like any file and send the notes to your agent.

**Gloss only reads.** Your keys are used for GET requests and nothing else. Your agent makes the changes with its own
tools (`gh`, the GitHub or Atlassian MCP servers, whatever you use); each note's packet has a `Resource:` line naming
the exact pull request, issue or page so it knows where.

Keys are entered in **Settings › Integrations** and kept in your Keychain. **Test Connection** shows which account
the key belongs to and what it can see.

## GitHub

A fine-grained token with read access to **Pull requests** and **Contents** is enough to open pull requests. The
same token fetches Gloss's updates while its repository is private. To file feedback from the app directly, the token
also needs to create issues on Gloss's repository; without that, feedback opens on GitHub instead.

**File › Open Pull Request…** (⌥⌘P) takes a URL or `owner/repo#123`. The pull request opens as a folder:

- `Pull request.md`: the description and metadata.
- `Conversation.md`: review and issue comments.
- `changes/`: each changed file at the head commit, with changed lines tinted. ⌥⌘↓ and ⌥⌘↑ step through changes.
- `pull-N.diff`: the whole diff.

When a new commit is pushed, open files reload and their notes move to follow.

## Jira and Confluence

Enter your Atlassian site, email and API token. **File › Open Jira Issue or Confluence Page…** (⌥⌘I) lists your
issues and spaces, or takes a key or URL.

- In the explorer each issue shows its key and title. An issue opens as Markdown with its fields, description and
  comments. Pasted screenshots show inline (drag over
  one to note part of it, or click it to note all of it), and every
  image or PDF attached is listed under **Attachments**. They're also files in the `<KEY> attachments` folder
  beside the issue: open one to note a region of it.
- A page opens as Markdown with its version and its images inline; its attached images and PDFs are in the page's
  `attachments` folder. Notes follow the page through renames and moves.

## The review browser

HTML files and web pages open in Gloss's own browser. Links to files open the file; links to pages load in place,
with Back and Forward. **File › Open Location…** (⇧⌘L) opens any URL, or a dev server on a remote host through
**Via**.

Turn on **Element Notes** in the toolbar, hover to see each element outlined, and click one to note it. The packet
carries the element's selector, text, HTML and a cropped image. If the page changes, Gloss finds the element again
by selector or text.

---

Back to the [guide index](README.md)
