---
name: herdr-core-api
description: Verified reference for herdr-core (hc 0.1.21, protocol generation 1) and Herdr.app as Gloss uses them - the socket, JSON-RPC line framing, terminal.list/get/send, events.subscribe, error kinds, machines, and where focus comes from. Read before changing anything under Transports/HerdrCore or herdr-core follow mode.
---

# herdr-core (verified 2026-11-16 against hc 0.1.21)

herdr-core (`hc`, binary `~/.local/bin/herdr-core`) runs programs in terminals that stay alive. Herdr.app
(`/Applications/Herdr.app`, CLI `~/.local/bin/herdr-app`) is the window on top of it. It replaces Herdr 0.9.3
(`~/.config/herdr/herdr.sock`, see `herdr-api`). Both may be installed; they don't share anything.

## Socket and framing
- `~/.local/state/herdr-core/<session>/<session>.sock`. The session is `default` unless `HC_SESSION` says otherwise.
  `XDG_STATE_HOME` replaces `~/.local/state`.
- The protocol is JSON-RPC 2.0, one message per line. `hello` is optional for plain calls; `{framed:true}` switches
  the connection to binary frames, which only `terminal.attach` needs. Gloss never uses framed mode.
- Errors look like `{"error":{"code":-32000,"message":"no terminal \"t99\"","data":{"kind":"not_found","hint":"see `hc ls --all`"}}}`.
  Kinds: `not_found`, `blocked`, `status_mismatch`, `finished`, `unavailable`, `needs_target`, `unknown_method`, ….
- `hc schema` prints the whole API as OpenRPC.

## Methods Gloss uses
- **`terminal.list {all?, labels?}`** → `{terminals[], machines[], hidden_finished}`. It covers every live terminal
  on this Mac **and on every connected machine**. Remote addresses look like `studio/t3`.
- **`terminal.get {terminal}`** returns one Terminal.
- **`terminal.send {terminal, text, force?, if?, wait?, timeout?, caller?}`** → `{turn, status, started, wait}`.
  - It pastes the text and presses Enter, after a person's half-typed draft is sent or cleared (at most 60 s after
    their last key), else after about 3 s of quiet.
  - It refuses a `blocked` program unless `force`.
  - Gloss passes **no `caller`**, so the text arrives untagged. A caller turns on `<hc from=…>` notes.
  - It is routed to the terminal's machine over the core's own ssh line.
  - A live check typed into a `cat` terminal arrived verbatim in about 1 s.
- **`events.subscribe {terminal?, children_of?, labels?}`** first replies `{seq, terminals[], channel:null}`. After
  that, notifications arrive on the same connection:
  - `{"method":"event","params":{"type":…,"terminal":"office/t8","seq":…,"data":{…}}}`. Types: created, lost,
    restarted, keep, finished, removed, status, turn, title, labels, size, doc. A `status` event's
    `data.status` is the new Status, or null.
  - `{"method":"heartbeat"}` every 15 s.
  - `{"method":"missed"}` followed by a fresh snapshot when the subscriber falls behind.
- `server.status` returns `{version, live, finished, …}`. `machine.list` lists the machines.
- `terminal.run {argv, name, no_parent, no_notify, rm}` and `terminal.kill` are for tests only. Use a throwaway
  `cat`, never a real agent.

## Terminal fields
- `address`, `name`, `state` (`live` or `finished`), `cwd` (the launch folder), `title`, `labels`, `argv`, `turn`.
- `foreground {name, argv, cwd}` is the program in front now. Claude Code's `name` is its version (`2.1.325`), so
  read `argv[0]` as well.
- `status {state: idle|working|done|blocked|error, app, msg, kind}` comes from the program's OSC 7501 reports.
  Plain programs have `status: null`.
- Herdr.app adds the labels `where` (`"Gloss / 1"`), `herdr.space`, `herdr.tab`, `herdr.seen`.
- Gloss counts a terminal as an agent when `status.app` is set, or `argv[0]`/`name` is a known agent
  (`HCTerminal.knownAgents`).

## Machines
- `{name, target (the ssh destination, usually a ~/.ssh/config alias), state: connecting|connected|needs_login|unreachable, version, host, id}`.
- Gloss maps a machine to a host by `target` = an ssh entry's alias, then by name (`AppModel.host(for:in:)`).
  Machines with no Gloss host are not listed; the agent menu says how to add them.

## Focus (follow mode)
- The core has no notion of focus. `herdr-app status` prints JSON with `agent` (the focused agent's address),
  `focused_pane`, `space` and `tab`.
- Herdr.app rewrites `~/.config/herdr-app/view.json` when the selected space, tab or pane changes.
  `HerdrAppFocusWatcher` watches its modification time and asks `herdr-app status` then, and every 3 s.

## Mods
Herdr.app mods are JavaScript in `~/.config/herdr-app/mods/<name>/`; key bindings are in `keys.json`. The guide is
`~/.config/herdr-app/AGENTS.md` and the API is `herdr.d.ts`. `focused()` gives `{terminal, agent, cwd, selection}`,
but the selection comes as cell coordinates, not text. Gloss ships no mod yet.
