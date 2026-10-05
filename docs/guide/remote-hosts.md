# Remote hosts

Gloss opens files on other machines with your own `ssh`, your ssh config and your keys. It keeps its own connection
to each host, so it works no matter how your terminal reaches it: mosh, tmux, or a jump host. Nothing is installed
on the remote machine.

## Hosts

- **From your ssh config.** Every `Host` alias without wildcards in `~/.ssh/config` is listed. Turn this off in
  Settings › Hosts.
- **Added in Gloss.** Settings › Hosts takes a name, host name, user, port and key file. Everything else still comes
  from your ssh config.

Open a folder on a host from the first window's **On a Host** menu or the host menu in the sidebar's toolbar. While
connecting, Gloss shows what ssh is doing, and says so if a key agent is waiting for you.

## Working on remote files

Browsing, search, Open Quickly, editing and saving work the same as on this Mac. Saves replace the file in one step
and keep its permissions. If someone (or an agent) changed the file since you opened it, Gloss shows the differences
instead of overwriting.

Gloss reconnects on its own after sleep or a network change.

## Remote dev servers

**File › Open Location…** (⇧⌘L) opens a web page. Choose **Via** a host to reach `localhost` on that machine
through Gloss's ssh connection, so a dev server running only there opens in the review browser. Element notes on
the page belong to that host. See [Integrations](integrations.md#the-review-browser).

## Following Herdr

Click **Follow Herdr**, the crosshair button in the sidebar's toolbar (shown once Gloss finds Herdr). When you focus an agent's pane in Herdr, Gloss switches to that machine
and the pane's working directory, connecting first if needed, and makes that agent the send target. A card at the top of the sidebar shows the agent, its status, the host, pane
and folder, with a button to stop following.

---

Next: [Integrations](integrations.md)
