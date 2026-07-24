#!/usr/bin/env bash
# Serve a doc ATLAS for the human-AI collaboration loop: markdown + inline
# mermaid, live-reloading, rendered in a cmux browser pane. ONE generic viewer
# renders any registered atlas (the reusable-harness generalization — wiring,
# adr, and any future atlas share it).
#
#   linux/scripts/atlas-serve.sh <name> [port]     # name: wiring | adr | <dir>
#   linux/scripts/atlas-serve.sh                   # lists registered atlases
#
# Serves the REPO ROOT so the viewer resolves both the docs and cmux's LOCAL
# vendored libs (Resources/markdown-viewer/{mermaid,marked}.min.js) — no CDN.
# Prints the URL to open in a cmux browser pane. The viewer live-reloads, so
# editing a .md updates the rendered graph in place.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Registered atlases: name → directory (repo-relative). A <name> that isn't
# registered is treated as a literal repo-relative directory.
atlas_dir() {
  case "$1" in
    wiring)   echo "docs/linux-port/wiring" ;;
    adr)      echo "docs/linux-port/adr" ;;
    features) echo "docs/linux-port/features" ;;
    poc)      echo "docs/linux-port/poc" ;;
    *)        echo "$1" ;;
  esac
}

name="${1:-}"; port="${2:-8199}"
if [ -z "$name" ]; then
  echo "registered atlases:"
  echo "  wiring    → docs/linux-port/wiring   (component wiring diagrams)"
  echo "  adr       → docs/linux-port/adr      (decision records + decision graph)"
  echo "  features  → docs/linux-port/features (feature board, regenerated on serve)"
  echo "  poc       → docs/linux-port/poc      (proof-of-concept maturity board)"
  echo "usage: atlas-serve.sh <name> [port]"
  exit 0
fi
dir="$(atlas_dir "$name")"

# The features board is generated (machine-local daily manifest feeds it,
# so it's gitignored, not committed — ADR-0011): regenerate on serve so
# the rendered board always reflects the current checkout + last promote.
if [ "$name" = "features" ]; then
  python3 "$ROOT/linux/scripts/features-board.py"
fi
[ -f "$ROOT/$dir/index.json" ] || { echo "atlas-serve: $dir has no index.json" >&2; exit 1; }

URL="http://127.0.0.1:$port/docs/linux-port/atlas/viewer.html?atlas=/$dir"

if curl -sS -m 2 -o /dev/null "http://127.0.0.1:$port/docs/linux-port/atlas/viewer.html" 2>/dev/null; then
  echo "already serving on $port: $URL"
  exit 0
fi
cd "$ROOT"
nohup python3 -m http.server "$port" --bind 127.0.0.1 >/tmp/cmux-atlas-serve.log 2>&1 &
for _ in $(seq 1 20); do
  curl -sS -m 2 -o /dev/null "$URL" 2>/dev/null && break
  sleep 0.3
done
echo "serving '$name' atlas: $URL"
echo "(pid $!, log /tmp/cmux-atlas-serve.log — plain http.server on 127.0.0.1)"
