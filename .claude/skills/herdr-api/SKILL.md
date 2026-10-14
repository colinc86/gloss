---
name: herdr-api
description: Verified reference for the Herdr socket API (v0.9.3, protocol 22) as Gloss uses it - socket paths, NDJSON framing, the methods for discovering agent panes, submitting prompts, reading output, subscribing to focus and status events, and the caveats that bite. Read before writing or changing any code under Transports/Herdr or the follow-mode feature.
---

# Herdr socket API

Herdr is a Rust background server that owns PTYs; the TUI is a thin client. It is NOT built on tmux.
Every agent pane carries agent kind, status, cwd, and (for Claude Code and Codex) the session UUID.

## Socket and framing

- Default socket: `~/.config/herdr/herdr.sock`. Named sessions: `~/.config/herdr/sessions/<name>/herdr.sock`.
  Resolution order: `--session` flag, `HERDR_SOCKET_PATH`, `HERDR_SESSION`, default.
- Newline-delimited JSON. Request `{"id":"<string>","method":"...","params":{...}}`. `id` MUST be a string.
- Success `{"id":..,"result":{"type":"...", ...}}`. Error `{"id":..,"error":{"code":"not_found","message":"..."}}`.
- One request per connection: the server closes after replying, except `events.subscribe` which stays open.
- Request line cap 1 MiB; over it the server drops the connection silently.
- Inside a Herdr-managed process these env vars exist: `HERDR_ENV=1`, `HERDR_SOCKET_PATH`, `HERDR_PANE_ID`, `HERDR_TAB_ID`, `HERDR_WORKSPACE_ID`, `HERDR_BIN_PATH`.
- Dump the live schema any time: `herdr api schema --json` (JSON Schema; request params live under `schemas.request.$defs`).

## Methods we use

| Purpose | Method | Params | Notes |
| --- | --- | --- | --- |
| Discover targets | `agent.list` | `{}` or `{"workspace_id":"w1"}` | returns agent panes with kind and status |
| Pane details | `pane.list`, `pane.get` | `{"pane_id":"w1:p1"}` | PaneInfo below |
| Submit a prompt | `agent.prompt` | `{"target":"<pane_id or agent name>","text":"...","wait":{"until":"done","timeout_ms":30000}}` or `wait: null` | bracketed-paste aware, submits with Enter. USE THIS, not `pane.send_text` |
| Run a shell command in a pane | CLI only: `herdr pane run <pane_id> "<cmd>"` | (0.9.3 has no `pane.run` socket method; use `pane.send_text` with a trailing `\n` over the socket) | |
| Read output | `pane.read` | `{"pane_id":..,"source":"visible"|"recent"|"recent_unwrapped"|"detection","lines":80,"format":"text"|"ansi"}` | `visible` never scrolls the user's view; `recent` with lines > viewport can visibly scroll the pane |
| Wait for state | `agent.wait` | `{"target":..,"until":"done"|"idle"|"blocked"}` | |
| Process info | `pane.process_info` | `{"pane_id":..}` | shell pid, foreground pgid, argv, cwd |
| Events | `events.subscribe` | `{"subscriptions":[{"type":"pane.focused"},{"type":"pane.agent_status_changed","pane_id":"w1:p1"}]}` | ack `{"result":{"type":"subscription_started"}}`, then frames `{"event":"pane_focused","data":{...}}` |
| Report metadata | `pane.report_metadata` | `{"pane_id":..,"source":"gloss","title":"...","ttl_ms":3600000}` | display-only badge text, 80 char cap |
| Snapshot | `session.snapshot` | `{}` | one-shot bootstrap of workspaces, tabs, panes, agents |

Subscription `type` uses dots (`pane.focused`); streamed `event` uses snake_case (`pane_focused`).
`pane.agent_status_changed`, `pane.scroll_changed`, `pane.output_matched` require `pane_id`; others are global.

## PaneInfo shape

```json
{"pane_id":"w1:p1","terminal_id":"term_abc","workspace_id":"w1","tab_id":"w1:t1","focused":true,
 "agent":"claude","agent_status":"working","cwd":"/repo","foreground_cwd":"/repo",
 "terminal_title":"bash","revision":42,
 "scroll":{"offset_from_bottom":0,"max_offset_from_bottom":240,"viewport_rows":30},
 "agent_session":{"source":"herdr:claude","agent":"claude","kind":"id","value":"<uuid>"},
 "label":"optional"}
```

`agent_status` is one of `idle | working | blocked | done | unknown`. `agent_session.kind` is `id` (Claude, Codex UUID) or `path` (Pi).
`revision` was a stub (always 0) on 0.7.x; do not use it as a change detector.
Agent kinds include `claude`, `codex`, `opencode`, `gemini`, `cursor`, `copilot`, `pi`, `amp`, `droid`, and more.

## Caveats (verified by the Collie project against 0.7 and 0.8)

- `pane.send_text` writes raw bytes with NO bracketed paste; every newline becomes an Enter. Never use it for packets.
- An `ok` ack means Herdr accepted bytes, not that the TUI acted. Confirm delivery by reading the pane back if it matters.
- `pane.rename` emits no event.
- `tab.close` kills every pane in the tab.
- `recent_unwrapped` has no effect for Claude Code panes (alt-screen, hard wrapped).
- Sending `ctrl+b` literally requires `ctrl+b ctrl+b`.
- (0.9.3, verified 2026-10-01) `pane_focused` event data is `{type, pane_id, workspace_id}` with NO cwd; follow mode must call `pane.get` afterwards. `agent.prompt` returns `{"type":"agent_prompted","agent":AgentInfo}`; a pane waiting on a permission prompt answers with error code `agent_blocked`. `events.subscribe` can emit an `events_lost` error, after which the client must resnapshot and resubscribe. `agent.list` returns `{"type":"agent_list","agents":[AgentInfo]}` where AgentInfo adds `name`, `interactive_ready`, `launch_pending`.

## Verified on 0.9.3 (2026-10-02, Gloss tests)

- `agent.prompt` only accepts panes Herdr already detects as agent panes; otherwise `agent_not_found`. Detection is by the foreground process name against the agent manifests (a binary named `claude` in the foreground is enough; `herdr agent explain <pane>` shows the rule). `pane.report_agent` sent from outside the pane is accepted but the pane then answers `agent_not_ready` ("no longer the pane foreground process"), so only the agent's own process tree may report.
- `pane.split {direction:"right"|"down", workspace_id?, cwd?, ratio?}` returns `{"type":"pane_info","pane":{...}}`; `pane.close {pane_id}` returns `{"type":"ok"}`. Type into a fresh pane only after a second or so: text sent while the shell is still starting is lost.
- `events.subscribe` acks `{"type":"subscription_started"}`; subscription types verified: `pane.created|closed|updated|focused|moved|exited|agent_detected|output_matched|agent_status_changed|scroll_changed`, plus workspace/tab/worktree/layout events.
- `herdr agent list` (no `--json` flag exists) prints the same envelope as the socket; `herdr --machine <profile> agent list` does the same for a remote profile.
- Copying `/bin/cat` to another name is killed by the platform-binary check on macOS; a stand-in agent for tests must be compiled.

## CLI equivalents

Every method has a CLI form that returns the same JSON, useful over an SSH exec channel when socket forwarding is unavailable:

```
herdr agent list --json
herdr agent prompt <target> "<text>" [--wait --until done --timeout 120000]
herdr agent read <target> --source recent-unwrapped --lines 120
herdr pane run <pane_id> "<command>"
herdr status            # client/server versions, socket path
herdr api schema --json
```

## Remote Herdr

`herdr --remote <host>` runs a FULL Herdr server on the remote host; the socket API is local to that host.
Reach it from the Mac by forwarding the remote Unix socket over the app's own SSH control connection:

```
ssh -o ControlPath=<cp> -O forward -L <local-sock-path>:/home/<user>/.config/herdr/herdr.sock <host>
```

Use `-o StreamLocalBindUnlink=yes` on the master so a stale local socket file is replaced. Fallbacks, in order: `herdr agent list --json` over the exec channel, then `herdr --machine <profile> agent list --json` locally when `herdr machine list --json` has a profile for that host (profile `devbox` exists on this Mac).
Herdr's own `[remote] manage_ssh_config` only affects Herdr's attach connection; it does not interfere with ours.

## Machines (verified on 0.9.3, 2026-10-02)

The socket API has no machine methods: each server knows only its own panes, and switching machines in the client
fires nothing on the local socket. The client persists its choice under `~/.local/state/herdr/client/`
(`$XDG_STATE_HOME/herdr/client` when set): `endpoint-selection.json` is `{"version":1,"selected_profile":null}` for
this Mac or a profile naming the machine id (serialized from a Rust enum, `{"ssh":"<id>"}` or `"ssh:<id>"`), and
`endpoints.json` lists `{"id","label","target","session","enabled"}` per saved ssh machine, where `target` is the
ssh destination (the alias from `~/.ssh/config`). `herdr machine list --json` prints the same with a `selected`
flag. `HerdrMachineWatcher` watches that directory; follow mode connects the app host named like `target` and
gates focus events to the selected server.

## Plugins

Verified on 0.9.3 (2026-10-02): `herdr plugin link <dir>` validates the manifest and warns when top-level
`platforms` is missing; `herdr plugin action list` / `herdr plugin action invoke <plugin>.<action>` run actions
from the CLI; actions get `HERDR_PLUGIN_CONTEXT_JSON` with `workspace_cwd`, `focused_pane_cwd`, `focused_pane_id`,
`focused_pane_agent`, `focused_pane_status`, `invocation_source`, plus `selected_text` for selection invocations and
`clicked_url` / `HERDR_PLUGIN_CLICKED_URL` for link handlers (Control-click). Herdr creates
`~/.local/state/herdr/plugins/<id>` and `~/.config/herdr/plugins/config/<id>` on first use and does not remove them on
unlink. Commands are argv arrays run without a shell from the plugin directory.

A plugin is a directory with `herdr-plugin.toml` (`id`, `name`, `version`, `min_herdr_version`, `[[actions]]`, `[[panes]]`, `[[link_handlers]]`, `[[events]]`).
Actions receive `HERDR_PLUGIN_CONTEXT_JSON` with workspace, tab, pane, agent, selected text, and clicked URL.
Bind in config.toml: `[[keys.command]] key = "prefix+n" type = "plugin_action" command = "<plugin.id>.<action>"`.
Develop locally with `herdr plugin link <path>`; `herdr plugin list --json` to confirm.

## Agent integrations Herdr installs

`herdr integration install claude|codex|opencode` writes hooks (Claude: `~/.claude/hooks/herdr-agent-state.sh` + settings.json entries; Codex: `~/.codex/hooks.json` + `[features] hooks = true`; OpenCode: `~/.config/opencode/plugins/herdr-agent-state.js`). These report session identity to Herdr, which is how `agent_session` gets populated. Do not overwrite them when writing our own hooks; merge.

## Local test recipe

```
herdr status                                  # server running? socket path
printf '{"id":"1","method":"agent.list","params":{}}\n' | nc -U ~/.config/herdr/herdr.sock
printf '{"id":"2","method":"session.snapshot","params":{}}\n' | nc -U ~/.config/herdr/herdr.sock | jq .
```
