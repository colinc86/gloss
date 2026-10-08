---
name: agent-integrations
description: Verified facts (as of 2026-10-01) for pushing and pulling context with Claude Code, Codex, OpenCode, and tmux - hook JSON shapes and limits, MCP registration syntax, OpenCode's HTTP server endpoints, tmux bracketed-paste delivery, and what each agent does with image paths. Read before writing any transport other than Herdr, the hook installers, or the MCP server's tool surface.
---

# Agent integrations

**Gloss installs no hooks** (since 2026-10-05, issue #5): a `UserPromptSubmit` hook fires on every prompt, including the one a Herdr or tmux send submits, so it cannot tell "the user chose these" from "a prompt happened". Drafts leave only on Send; agents read and resolve sent notes through MCP. The hook facts below stay for reference (and for removing the old entry, `gloss-notes.sh`).

Everything below was checked against the live docs or binaries on this machine. Re-verify before relying on anything marked "unverified".

## Claude Code

- **UserPromptSubmit hook** (pull): script on stdin gets `{session_id, cwd, hook_event_name, prompt, ...}`. Inject context by printing JSON:
  ```json
  {"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"<text>"}}
  ```
  Limit 10,000 characters per field. Also works for `SessionStart`. Plain stdout (non-JSON) is added as context too, but use the JSON form.
- **Hook install location**: `~/.claude/settings.json` → `hooks.UserPromptSubmit[].hooks[]`. MERGE with existing entries (Herdr's integration writes a `SessionStart` hook and a `moshi-hook` entry already sits on `UserPromptSubmit`). Handler fields: `type`, `command`, `timeout`, `async`. Over the 10,000-char cap Claude Code writes the context to a file and substitutes a path plus a 2,000-char preview. Script lives at `~/.claude/hooks/gloss-notes.sh`.
- **MCP over HTTP**: `claude mcp add --transport http gloss http://127.0.0.1:<port>/mcp` (user scope with `-s user`). Equivalent `.mcp.json` entry: `{"mcpServers":{"gloss":{"type":"http","url":"http://127.0.0.1:<port>/mcp"}}}`.
- **Images**: a prompt that names an absolute image path works; Claude Code reads PNG/JPEG via its Read tool and sees the pixels.
- **No external turn injection** into a live interactive session. Push goes through Herdr or tmux only.
- Session UUIDs are available from Herdr's `agent_session` when the Herdr integration is installed.

## Codex

- **Hooks** are experimental: `~/.codex/hooks.json` (or `[hooks]` in `~/.codex/config.toml`) and `[features] hooks = true` must be set. Events include `SessionStart` and `UserPromptSubmit` (since v0.116). Output shape mirrors Claude Code:
  ```json
  {"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"<text>"}}
  ```
  Plain stdout is also added as developer context. Docs: https://learn.chatgpt.com/docs/hooks
- **MCP**: `codex mcp add gloss --url http://127.0.0.1:<port>/mcp` (verified against `codex mcp add --help`, Codex 0.157.0).
- **Trust**: Codex skips new or changed hooks until the user trusts them with `/hooks` inside Codex (stored as `[hooks.state."<file>:user_prompt_submit:<i>:<j>"] trusted_hash` in `config.toml`). The installer must say so. `[features] hooks = true` is already set on this Mac.
- **Images**: `codex -i <file>` attaches images only at launch. Whether Codex reads an image path mid-session through a tool is unverified; the packet still carries the path and coordinates, and MCP exposes the crop as a resource.

## OpenCode

- `opencode` TUI starts an HTTP server on a random port. `opencode --port 4096` (or `opencode serve --port 4096` headless) fixes it. The TUI's own server answers every outside request with `403 forbidden` (verified 2026-10-04 on 1.18.31); `opencode serve` answers `GET /session` with 200. Gloss finds servers itself: `lsof -nP -a -iTCP -sTCP:LISTEN -c '/opencode/' -F n` lists every OpenCode listener on any port, and the transport keeps those whose `GET /session` succeeds, so there is no setting. Default host 127.0.0.1. Optional basic auth via `OPENCODE_SERVER_PASSWORD`.
- Endpoints (verified against the SDK types, OpenCode 1.18.31): `GET /session?directory=` lists sessions `{id, projectID, directory, title, time{created,updated}}`; `POST /session {parentID?, title?}` creates one; `POST /session/:id/message` with `{parts:[{type:"text",text:"..."},{type:"file",mime:"image/png",url:"file:///abs/path.png",filename?:"..."}]}` sends a turn and waits; `POST /session/:id/prompt_async` takes the same body and returns 204 immediately (use this one). Basic auth: `OPENCODE_SERVER_PASSWORD` with user `OPENCODE_SERVER_USERNAME` (default `opencode`). OpenAPI at `http://localhost:4096/doc` when a server is running.
- Plugins (`~/.config/opencode/plugins/*.js`) cannot inject AI-visible messages yet (open issues #17412, #22831). Do not build on them.
- MCP: `~/.config/opencode/opencode.json` → `"mcp":{"gloss":{"type":"remote","url":"http://127.0.0.1:<port>/mcp","enabled":true}}` (verified against the docs), or `opencode mcp add gloss --url <url>`.

## tmux (no Herdr)

Deliver with bracketed paste so multi-line packets do not submit early:

```
tmux load-buffer -b gloss -            # packet on stdin
tmux paste-buffer -p -b gloss -t <target>   # -p = bracketed paste
tmux send-keys -t <target> Enter
tmux delete-buffer -b cc
```

Over SSH run the same through the exec channel; pipe the packet into `ssh <host> tmux load-buffer -b gloss -`. Discover panes with `tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_current_command} #{pane_current_path}'` and let the user pick once per host; store in `target`. Agent panes usually show `node` (Claude Code), `codex`, or `opencode` as the current command.

## Shared MCP server surface (what every agent sees)

Tools (agents see `sent` notes only; drafts never): `list_pending_notes(host?, path?)`, `get_note(id)`, `resolve_note(id, outcome?, message?, location?)`, `reply_to_note(id, message, asks?, location?)` (a reply, or a question that leaves the note waiting on the user; see the `context-packet` skill for `location`), `list_documents()`, `open_in_viewer(path|url, line?, end_line?, host?)`, `ask_user(path, question, line?, end_line?, text?, host?)` (a sent note with `author` = the client's agent name, no comment, and the question as its first message, waiting on the user; at most 20 open per document), `add_favorite(path, host?)`, `list_favorites()` (host defaults to the session's: a remote registration URL is `http://127.0.0.1:<port>/mcp?host=<alias>`, quoted in the `mcp add` shell line). Resources: `note://<id>/attachment/<n>` serving image/png. Keep tool names stable; the packet's closing line names `resolve_note` literally.

Every route but `/health` needs the server's token (`Authorization: Bearer <token>` or `token=<token>` in the query): the registration URL carries `?token=…` (and `&host=<alias>` remotely), and the port file (`mcp-port`, 0600; `~/.config/gloss/mcp-port` on a host) holds the port on line 1 and the token on line 2 for the hook script and the Herdr plugin. `GET /hook/claude` and `/hook/codex` return the drafts under `cwd` (and `host`) in the UserPromptSubmit JSON shape; `GET /hook/text` returns the same packet as `text/plain` for any other agent's prompt hook (Settings → Agents → Other agents gives the curl line). All three drain what they return to `sent` (recorded as `claude-hook`, `codex-hook`, `prompt-hook`) and answer an empty 200 when there is nothing. The token lives in `~/Library/Application Support/Gloss/mcp-token`. Without it anyone else logged in to a host could reach the forwarded port and read the notes. Requests with an `Origin` or a non-loopback `Host` are refused too.

Remote agents reach the server through a reverse forward on the app's SSH control connection: `ssh -O forward -R <port>:127.0.0.1:<port> <host>`. Use the same port number on both ends so the agent config is identical everywhere.
