---
name: verify-transport
description: Live end-to-end check of one delivery transport (herdr, mcp, claude-hook, codex-hook, opencode, tmux, clipboard) against the real tools installed on this machine or a remote host, reporting what was sent, what arrived, and what to fix. Invoke as /verify-transport <name> [host].
argument-hint: "<herdr|mcp|claude-hook|codex-hook|opencode|tmux|clipboard> [host]"
user-invocable: true
context: fork
agent: transport-verifier
---

Verify the `$0` transport end to end on host `$1` (default: local). Use the `herdr-api`, `agent-integrations`, and `context-packet` skills for the exact protocol. Follow the recipe for the named transport, then report: the exact packet sent, evidence it arrived (pane read-back, hook stdout, HTTP response, clipboard contents), and any fix needed in the app code. Never leave test panes, buffers, or temp files behind.

Recipes:

- **herdr**: `herdr status` must show the server running. `herdr agent list --json`; pick an idle agent pane or, if none, split a pane and start `claude` in it. Send a two-note packet with `agent.prompt` over the socket (nc -U), wait up to 60s, read back with `pane.read source=recent`, confirm both file headers appear. Close any pane you created.
- **mcp**: launch the app (run-app skill) with `--reset-db`, create a note via the URL scheme, then `curl` the MCP endpoint: initialize, `tools/list`, `tools/call list_pending_notes`, `tools/call resolve_note`. Confirm the note's state flips in the SQLite db under `$TMPDIR`.
- **claude-hook**: run the hook script directly with a synthetic `UserPromptSubmit` JSON on stdin and a pending note in a throwaway db; confirm it prints `hookSpecificOutput.additionalContext` under 10,000 chars. Then confirm `~/.claude/settings.json` contains the hook entry without having clobbered other hooks.
- **codex-hook**: same with `~/.codex/hooks.json` and `[features] hooks = true` in `~/.codex/config.toml`.
- **opencode**: start `opencode serve --port 4096` in the background, `GET /session`, create a session if needed, `POST /session/:id/message` with a text part and an image part, confirm 200 and a reply. Kill the server.
- **tmux**: create a detached session `gloss-verify`, load-buffer + paste-buffer -p + Enter, `capture-pane -p` to confirm the packet text, then `kill-session`.
- **clipboard**: send to clipboard, `pbpaste` and diff against the expected packet.
