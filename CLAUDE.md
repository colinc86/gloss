# Gloss

Native macOS app: file explorer on the left, viewer on the right, annotate any region of any file and send the notes to Claude Code, Codex, or OpenCode. Replaces what was lost moving from Orca to Warp and Herdr. The product description with scope, data model, and milestone 1 acceptance checks lives at https://claude.ai/code/artifact/01a13d3e-5f5a-491b-b910-b5f1a57cc70c and is mirrored in @docs/PRODUCT.md.

## State (2026-10-04)

Milestone 1 is built, reviewed, and committed on `main`: explorer and viewers, anchored notes, the clipboard, tmux, Herdr, MCP, hook, and OpenCode transports, SSH/SFTP remote editing, the Herdr plugin, and the hardening pass. Milestone 2 (the review browser with element notes and remote dev-server tunnels, GitHub pull requests as roots with tinted changed lines, Jira issues and Confluence pages as read-only Markdown, Settings → Integrations) is built and reviewed on `main`. The acceptance checks in `docs/PRODUCT.md` are ticked with how each was verified; the ones that need a real agent session are left to the user. Open items live only in `docs/PRODUCT.md` and the git log, not here.

## Settled decisions (do not re-litigate)

- Deployment target macOS 26. Swift 6 language mode, strict concurrency. SwiftUI shell, AppKit where SwiftUI falls short (outline view, text editor, PDF, image canvas). Chrome controls live in the toolbar so macOS 26 draws them as glass; sidebar and inspector keep system vibrancy.
- Storage is SQLite via GRDB. Notes are keyed by host + absolute path and never written into the file.
- Hosts are database rows: `local`, aliases imported from `~/.ssh/config` (a toggle in Settings → Hosts), and hosts added in the app with host name, user, port, and identity file that become `ssh -o` options. An alias named like an integration host (`web`, `github`, `atlassian`) is listed as `<name>-ssh` and keeps its real alias in its options for ssh. Nothing about a specific machine or key agent is hard-wired.
- Remote access uses the system `ssh` binary with ControlMaster, SFTP v3 spoken by the app, exec channel for commands, OpenSSH forwarding for the Herdr socket and the MCP port. No pure-Swift SSH library. See the `sftp-over-ssh` skill. The master runs with `LogLevel=DEBUG`; the UI shows ssh's own stages while connecting and names a silent key agent after 20 s instead of spinning. ssh ends lines with CRLF, which Swift reads as one Character: split on any newline.
- Child processes are spawned with `posix_spawn` (close-on-exec defaults, responsibility disclaimed), never Foundation's `Process`.
- Transport priority: Herdr socket, MCP server, Claude Code and Codex hooks, OpenCode HTTP API, tmux, clipboard. See `herdr-api` and `agent-integrations`. Hooks drain draft notes only; drained notes become `sent` and stay reachable through MCP until resolved.
- Packet format is fixed by the `context-packet` skill. Every transport emits the same text.
- The app reads, the agent writes. Integrations (GitHub, Atlassian, live web pages) are virtual hosts (`github`, `atlassian`, `web`) serving read-only `FileSystemProvider`s, so documents, notes, the packet and the MCP tools are not duplicated. The `Integrations` clients issue GET only (a test asserts it); the packet's `Resource:` line names the pull request, issue or page so the agent changes it with its own tools. Keys live in the Keychain, entered in Settings → Integrations; debug builds load them with `--integrations-env` (into memory under `--reset-db`).
- `integrations.env` at the repo root holds real keys: gitignored, never committed, used only to read while testing; test notes go to the clipboard target, never to an agent with GitHub or Atlassian tools.
- Markdown viewer toggles rendered and source; anchors are stored in source coordinates. Text and markdown are editable; images, PDFs, spreadsheets are not.
- Notes are created from a floating "Add Note" button beside the selection in every viewer; ⌘⇧N is a secondary shortcut, never the only path.
- Agent hooks, MCP registration, and the Herdr plugin are installed only from Settings → Hooks, with backups, never silently.
- Not sandboxed, Developer ID signed and notarized (see `docs/RELEASE.md`).

## Layout

- `Gloss/` app target: `App/` (model, routes, launch options), `Explorer/`, `Documents/` (sessions, viewer pane, conflict sheet), `Notes/`, `Services/` (hosts, hooks, send coordinator), `Settings/`.
- `Packages/Core` (ids, schema, note store, anchors, packet builder, local file system), `Packages/Remote` (child processes, ssh config, ControlMaster, SFTP, exec, search, staging), `Packages/Transports` (connection registry, tmux, Herdr, MCP server, hooks installer and script, OpenCode, Herdr plugin bundle), `Packages/Viewers` (text, markdown, image, PDF, CSV, QuickLook, the review browser), `Packages/Integrations` (GET-only GitHub and Atlassian clients, the pull request and Jira/Confluence file systems, ADF to Markdown). Each has its own tests.
- `docs/` product and design notes plus release instructions. `.claude/skills/` holds the verified protocol references; read the relevant one before touching that area.

## Build and test

- There is exactly one copy of the app: Xcode's default DerivedData. Build with plain `xcodebuild` (never `-derivedDataPath`) or `/build`; launch and screenshot per the `run-app` skill (`--host <alias>`, `--root`, `--open`, `--reset-db`, `--follow`). A scripted build can collide with Xcode's ⌘R on code signing; just build again.
- Package tests: `swift test --package-path Packages/<Name>`. Tests that need the environment skip when it is absent: loopback ssh, a running Herdr, tmux, `GLOSS_REMOTE_HOST=<alias>` for real-host checks, and the gitignored `integrations.env` (with `GLOSS_ATLASSIAN_SITE` and `GLOSS_LIVE_PULL_REQUEST=owner/repo#n`) for read-only integration checks. They create only throwaway resources and remove them on every path.
- Use `/verify-transport <name> [host]` before claiming a transport works.

## Working rules

- Verify API signatures with the `apple-api-researcher` agent when unsure; never guess a framework or package API.
- Run `swift-reviewer` on a feature before calling it done.
- Quote every path: the project and scheme names contain spaces.
- Remote and Herdr code must never leave test panes, sessions, buffers, masters, or temp files behind; check with `pgrep -f '^/usr/bin/ssh -o ControlMaster=yes'` after remote work.
- Never write to `~/.claude`, `~/.codex`, or `~/.config/opencode` directly; the in-app installer is the only thing that touches them.
- Keep `docs/PRODUCT.md` in sync when a decision changes, and say so in the commit message.
- Commit only when asked.
