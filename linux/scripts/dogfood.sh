#!/usr/bin/env bash
# Closed-loop dogfooding: spawn a Claude Code QA agent INSIDE the running
# cmux Linux port, let it exercise the app from within (via the cmux CLI),
# and collect its report.
#
#   dogfood.sh "focus instructions for this run" [timeout-minutes]
#
# The tester runs in a fresh workspace tab (visible in the app), headless
# (`claude -p`), restricted to Bash/Read/Grep/Glob tools. It writes its
# report to ~/.local/share/cmux/dogfood/report-<stamp>.md; this script
# blocks until the report lands (or the timeout passes) and prints it —
# so an outer agent running it in the background gets woken with the
# findings.
set -euo pipefail

FOCUS="${1:?usage: dogfood.sh \"focus instructions\" [timeout-minutes]}"
TIMEOUT_MIN="${2:-8}"

DIR="${CMUX_DOGFOOD_DIR:-$HOME/.local/share/cmux/dogfood}"
mkdir -p "$DIR"
STAMP=$(date +%Y%m%d-%H%M%S)
REPORT="$DIR/report-$STAMP.md"
PROMPT="$DIR/prompt-$STAMP.md"

cmux ping >/dev/null || { echo "cmux-adw is not running" >&2; exit 1; }

cat > "$PROMPT" <<'PROMPT_EOF'
You are a QA agent running INSIDE the cmux Linux port — the very app you
are testing. Your shell carries CMUX_WORKSPACE_ID/CMUX_SURFACE_ID, so bare
`cmux` commands target your own pane; run `cmux help` for the command list.

Ground rules (violating these disrupts the human's live session):
- NEVER kill, restart, or launch cmux-adw.
- NEVER use select-workspace / focus-window / focus-pane — they steal the
  human's focus. Target explicitly with --workspace/--surface instead.
- Only touch YOUR workspace and panes you create; clean up your scratch
  panes (close-surface) when done.
- Do not modify the repository.

Method: exercise the focus areas below through the cmux CLI from inside.
Verify actual behavior (read-screen the results), don't assume. Note exact
commands for anything broken.

Your final message must be exactly the report, in markdown:
# Dogfood report
## Summary   (2-3 sentences)
## Works     (bullet list of verified-good behavior)
## Bugs      (each: repro commands, expected vs actual)
## Suggestions (optional)

Focus for this run:
PROMPT_EOF
printf '%s\n' "$FOCUS" >> "$PROMPT"

WS_LINE=$(cmux new-workspace --cwd "$HOME/cmux")
WS=$(printf '%s' "$WS_LINE" | sed -n 's/^OK \(workspace:[0-9]*\).*/\1/p')
[ -n "$WS" ] || { echo "could not create workspace: $WS_LINE" >&2; exit 1; }
echo "tester workspace: $WS · report: $REPORT" >&2
sleep 2

CMD="clear; claude -p \"\$(cat $PROMPT)\" --allowedTools Bash Read Grep Glob | tee $REPORT; touch $REPORT.done; cmux notify --title 'Dogfood report ready' --body '$STAMP'"
cmux send --workspace "$WS" "$CMD\\n" >/dev/null

DEADLINE=$(( $(date +%s) + TIMEOUT_MIN * 60 ))
while [ ! -f "$REPORT.done" ]; do
    if [ "$(date +%s)" -ge "$DEADLINE" ]; then
        echo "=== dogfood timed out after ${TIMEOUT_MIN}m — partial state ===" >&2
        cmux read-screen --workspace "$WS" || true
        exit 2
    fi
    sleep 10
done

echo "=== dogfood report ($STAMP) ==="
cat "$REPORT"
