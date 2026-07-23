#!/usr/bin/env bash
# Serve the wiring atlas for the human-AI collaboration loop: markdown +
# inline mermaid, live-reloading, rendered in a cmux browser pane.
#
#   linux/scripts/wiring-serve.sh [port]      # default 8199
#
# It serves the REPO ROOT so the viewer resolves both the docs
# (docs/linux-port/wiring/*.md) and the LOCAL vendored libraries
# (Resources/markdown-viewer/{mermaid,marked}.min.js) — no CDN, robust on
# any network. Prints the URL to open in a cmux browser pane:
#
#   cmux new-workspace --cwd ~/cmux --background     # a scratch workspace
#   cmux browser open "<printed url>" --workspace <that workspace>
#
# The viewer polls the current doc every 1.5s, so editing a .md updates the
# rendered graph in place — the human watches, comments, the agent iterates.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PORT="${1:-8199}"
URL="http://127.0.0.1:$PORT/docs/linux-port/wiring/viewer.html"

# Reuse an already-running server on this port rather than failing.
if curl -sS -m 2 -o /dev/null "http://127.0.0.1:$PORT/docs/linux-port/wiring/viewer.html" 2>/dev/null; then
    echo "already serving: $URL"
    exit 0
fi

cd "$ROOT"
nohup python3 -m http.server "$PORT" --bind 127.0.0.1 >/tmp/cmux-wiring-serve.log 2>&1 &
for _ in $(seq 1 20); do
    curl -sS -m 2 -o /dev/null "$URL" 2>/dev/null && break
    sleep 0.3
done
echo "serving wiring atlas: $URL"
echo "(server pid $!, log /tmp/cmux-wiring-serve.log — plain http.server on 127.0.0.1)"
