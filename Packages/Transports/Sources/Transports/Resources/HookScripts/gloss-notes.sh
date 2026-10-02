#!/bin/sh
# Gloss UserPromptSubmit hook for Claude Code and Codex.
# Usage: gloss-notes.sh [claude|codex]
# Asks the app's local server for the pending notes under the session's cwd and prints them as hook context.
# Never prints to stderr, never exits non-zero, never blocks more than a few seconds.
set -u
flavour="${1:-claude}"
tmp=$(mktemp "${TMPDIR:-/tmp}/gloss-hook.XXXXXX" 2>/dev/null) || exit 0
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" 2>/dev/null

home="${HOME:-}"
[ -n "$home" ] || exit 0
port=""
for f in "$home/Library/Application Support/Gloss/mcp-port" "$home/.config/gloss/mcp-port"; do
    if [ -r "$f" ]; then
        port=$(head -n 1 "$f" 2>/dev/null | tr -cd '0-9')
        [ -n "$port" ] && break
    fi
done
[ -n "$port" ] || exit 0

cwd=""
if command -v python3 >/dev/null 2>&1; then
    cwd=$(python3 -c 'import json,sys
try:
    print(json.load(open(sys.argv[1])).get("cwd") or "")
except Exception:
    print("")' "$tmp" 2>/dev/null)
else
    cwd=$(sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$tmp" 2>/dev/null | head -n 1)
fi

command -v curl >/dev/null 2>&1 || exit 0
out=$(curl -sf -m 3 --get --data-urlencode "cwd=$cwd" --data-urlencode "host=${GLOSS_HOST:-local}" \
    "http://127.0.0.1:$port/hook/$flavour" 2>/dev/null) || exit 0
[ -n "$out" ] || exit 0
printf '%s\n' "$out"
exit 0
