#!/bin/sh
# Gloss Herdr plugin action.
#   note  - send the selected text (or the pane's cwd) to the app as a draft note
#   open  - open the clicked file:// link or the selected path in the viewer
# On this Mac the app is reached through its URL scheme; on a host it is the app's HTTP endpoint through the
# reverse-forwarded port. Never prints to stderr, never exits non-zero.
set -u
mode="${1:-note}"
context="${HERDR_PLUGIN_CONTEXT_JSON:-}"
[ -n "$context" ] || context='{}'
home="${HOME:-}"
[ -n "$home" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

field() {
    printf '%s' "$context" | python3 -c 'import json,sys
try:
    value = json.load(sys.stdin).get(sys.argv[1])
except Exception:
    value = None
print("" if value is None else value, end="")' "$1" 2>/dev/null
}
encode() {
    printf '%s' "$1" | python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read(), safe=""), end="")' 2>/dev/null
}

cwd=$(field focused_pane_cwd)
[ -n "$cwd" ] || cwd=$(field workspace_cwd)
pane=$(field focused_pane_id)
agent=$(field focused_pane_agent)
text=$(field selected_text)
clicked="${HERDR_PLUGIN_CLICKED_URL:-$(field clicked_url)}"
host=""
[ -r "$home/.config/gloss/host" ] && host=$(head -n 1 "$home/.config/gloss/host" | tr -d '\r\n')
[ -n "$host" ] || host="local"

# Transport: the URL scheme when `open` and the app exist on this machine, else HTTP to the app's server.
transport="${GLOSS_PLUGIN_TRANSPORT:-}"
if [ -z "$transport" ]; then
    if [ "$host" = "local" ] && command -v open >/dev/null 2>&1 && [ "$(uname -s)" = "Darwin" ]; then transport=url; else transport=http; fi
fi

case "$mode" in
open)
    path="$clicked"
    case "$path" in file://*) path=$(printf '%s' "$path" | python3 -c 'import sys,urllib.parse; print(urllib.parse.unquote(urllib.parse.urlparse(sys.stdin.read()).path), end="")' 2>/dev/null) ;; esac
    [ -n "$path" ] || path="$text"
    [ -n "$path" ] || exit 0
    case "$path" in /*) ;; *) path="$cwd/$path" ;; esac
    if [ "$transport" = url ]; then
        url="gloss://open?host=$(encode "$host")&path=$(encode "$path")"
        [ -n "${GLOSS_PLUGIN_DRY_RUN:-}" ] && { printf '%s\n' "$url"; exit 0; }
        open "$url" >/dev/null 2>&1
        exit 0
    fi
    port=""
    for f in "$home/.config/gloss/mcp-port" "$home/Library/Application Support/Gloss/mcp-port"; do
        [ -r "$f" ] && port=$(head -n 1 "$f" | tr -cd '0-9') && [ -n "$port" ] && break
    done
    [ -n "$port" ] || exit 0
    body=$(python3 -c 'import json,sys; print(json.dumps({"host": sys.argv[1], "path": sys.argv[2]}))' "$host" "$path") || exit 0
    [ -n "${GLOSS_PLUGIN_DRY_RUN:-}" ] && { printf '%s\n' "$body"; exit 0; }
    command -v curl >/dev/null 2>&1 || exit 0
    curl -sf -m 3 -X POST -H 'Content-Type: application/json' --data-binary "$body" "http://127.0.0.1:$port/plugin/open" >/dev/null 2>&1
    exit 0
    ;;
note)
    [ -n "$text" ] || exit 0
    if [ "$transport" = url ]; then
        if [ "$(printf '%s' "$text" | wc -c)" -gt 6000 ]; then
            # The app only accepts selection files from its own inbox directory.
            dir="$home/Library/Application Support/Gloss/inbox"
            mkdir -p "$dir" 2>/dev/null || exit 0
            file="$dir/selection-$(date +%s)-$$.txt"
            printf '%s' "$text" > "$file" 2>/dev/null || exit 0
            url="gloss://note?host=$(encode "$host")&cwd=$(encode "$cwd")&pane=$(encode "$pane")&agent=$(encode "$agent")&file=$(encode "$file")"
        else
            url="gloss://note?host=$(encode "$host")&cwd=$(encode "$cwd")&pane=$(encode "$pane")&agent=$(encode "$agent")&text=$(encode "$text")"
        fi
        [ -n "${GLOSS_PLUGIN_DRY_RUN:-}" ] && { printf '%s\n' "$url"; exit 0; }
        open "$url" >/dev/null 2>&1
        exit 0
    fi
    port=""
    for f in "$home/.config/gloss/mcp-port" "$home/Library/Application Support/Gloss/mcp-port"; do
        [ -r "$f" ] && port=$(head -n 1 "$f" | tr -cd '0-9') && [ -n "$port" ] && break
    done
    [ -n "$port" ] || exit 0
    body=$(python3 -c 'import json,sys; print(json.dumps({"host": sys.argv[1], "cwd": sys.argv[2], "pane_id": sys.argv[3], "agent": sys.argv[4], "text": sys.stdin.read().rstrip("\n")}))' "$host" "$cwd" "$pane" "$agent" <<EOT
$text
EOT
    ) || exit 0
    [ -n "${GLOSS_PLUGIN_DRY_RUN:-}" ] && { printf '%s\n' "$body"; exit 0; }
    command -v curl >/dev/null 2>&1 || exit 0
    curl -sf -m 3 -X POST -H 'Content-Type: application/json' --data-binary "$body" "http://127.0.0.1:$port/plugin/note" >/dev/null 2>&1
    exit 0
    ;;
esac
exit 0
