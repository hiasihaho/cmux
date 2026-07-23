#!/usr/bin/env bash
# Runs every suite and summarizes.
#
#   linux/tests/run-all.sh              # all suites
#   linux/tests/run-all.sh find popup   # only suites whose name matches
#
# Exit: 0 everything passed, 1 a suite failed, 2 a suite could not run.
#
# Suites run SEQUENTIALLY on purpose. Each starts its own cmux instance and
# X display, so they are isolated — but they are also heavy, and running
# them in parallel on a loaded machine is how "the shell never spawned"
# flakes appear.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"

# One freshness check up front (each suite's own copy is suppressed): a
# stale binary silently tests yesterday's code and every verdict lies.
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
APP_BIN="$ROOT/.build/debug/cmux-adw"; CLI_BIN="$ROOT/.build/debug/cmux"
if [ ! -x "$APP_BIN" ] || [ ! -x "$CLI_BIN" ]; then
    echo "WARN: binaries missing — cd linux && CMUX_GHOSTTY=1 swift build" >&2
else
    # Newest binary only (see lib.sh warn_if_stale_binary for why —
    # SwiftPM legitimately skips relinking unaffected products).
    newest="$APP_BIN"; [ "$CLI_BIN" -nt "$APP_BIN" ] && newest="$CLI_BIN"
    newer=$(find -L "$ROOT/Sources" -name '*.swift' -newer "$newest" -print -quit 2>/dev/null)
    [ -n "$newer" ] && echo "WARN: binaries predate $(basename "$newer") — this gate tests STALE code; rebuild before trusting verdicts" >&2
fi
export CMUX_TEST_NO_FRESHNESS_WARN=1

# The assertion-count ledger (suites.tsv): a suite that silently loses
# assertions — an early exit that skips half the file — still exits 0
# and reads as green. A drop below the ledger is a FAILURE; update
# suites.tsv in the same commit as any intentional count change. Suites
# with skips are waived (a skip collapses whole assertion blocks).
declare -A LEDGER_EXPECTED
while IFS=$'\t' read -r lname lcount _ldesc; do
    case "$lname" in ''|'#'*) continue ;; esac
    LEDGER_EXPECTED[$lname]="$lcount"
done < "$TESTS_DIR/suites.tsv"

SUITES=(
    webdriver-smoke
    browser-navigation-smoke
    browser-popup-smoke
    pane-search-smoke
    browser-find-smoke
    session-persistence-smoke
    pane-zoom-smoke
    browser-urlbar-smoke
    browser-profile-smoke
    vte-scrollback-smoke
    settings-smoke
    ui-commands-smoke
    tmux-compat-smoke
    browser-ephemeral-smoke
    teams-siblings-smoke
)

if [ $# -gt 0 ]; then
    filtered=()
    for suite in "${SUITES[@]}"; do
        for pattern in "$@"; do
            case "$suite" in *"$pattern"*) filtered+=("$suite"); break;; esac
        done
    done
    SUITES=("${filtered[@]}")
fi
[ ${#SUITES[@]} -gt 0 ] || { echo "run-all: no suites matched" >&2; exit 2; }

TOTAL_PASS=0; TOTAL_FAIL=0; TOTAL_SKIP=0
FAILED=(); ERRORED=(); LEDGER_FAILED=()
started=$(date +%s)

for suite in "${SUITES[@]}"; do
    script="$TESTS_DIR/$suite.sh"
    [ -x "$script" ] || { echo "run-all: $suite is not executable" >&2; ERRORED+=("$suite"); continue; }
    printf '\n\033[1m── %s ──\033[0m\n' "$suite"
    suite_started=$(date +%s)
    out=$("$script" 2>&1); rc=$?
    suite_secs=$(( $(date +%s) - suite_started ))
    echo "$out" | grep -E '^  (PASS|FAIL|SKIP)|^== ' || echo "$out" | tail -5
    echo "   (${suite_secs}s)"
    # Full output survives the summary filter — a red suite's diagnostics
    # are useless if the gate throws them away.
    mkdir -p /tmp/cmux-gate-logs
    echo "$out" > "/tmp/cmux-gate-logs/$suite.log"
    [ "$rc" -ne 0 ] && echo "   full log: /tmp/cmux-gate-logs/$suite.log"

    line=$(echo "$out" | grep -E "^== $suite:" | tail -1)
    p=$(echo "$line" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+') || true
    f=$(echo "$line" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+') || true
    s=$(echo "$line" | grep -oE '[0-9]+ skipped' | grep -oE '[0-9]+') || true
    TOTAL_PASS=$((TOTAL_PASS + ${p:-0}))
    TOTAL_FAIL=$((TOTAL_FAIL + ${f:-0}))
    TOTAL_SKIP=$((TOTAL_SKIP + ${s:-0}))

    executed=$(( ${p:-0} + ${f:-0} + ${s:-0} ))
    expected="${LEDGER_EXPECTED[$suite]:-}"
    if [ -z "$expected" ]; then
        echo "   ledger: $suite has no row in suites.tsv — observed $executed assertions; add one"
    elif [ "${s:-0}" -gt 0 ]; then
        echo "   ledger: count check waived (${s} skipped — skips collapse assertion blocks)"
    elif [ "$executed" -lt "$expected" ]; then
        echo "   ledger: ran $executed assertions but suites.tsv says $expected — silent shrinkage, or update the ledger in the same commit"
        LEDGER_FAILED+=("$suite")
    elif [ "$executed" -gt "$expected" ]; then
        echo "   ledger: grew to $executed assertions (ledger: $expected) — bump suites.tsv"
    fi

    # rc 2 is "could not run" (missing tool, instance never came up) and is
    # reported apart from assertion failures — a broken precondition is not
    # a broken product.
    case $rc in
        0) ;;
        2) ERRORED+=("$suite") ;;
        *) FAILED+=("$suite") ;;
    esac
done

elapsed=$(( $(date +%s) - started ))
echo
echo "════════════════════════════════════════════"
printf 'suites: %d   assertions: %d passed, %d failed' "${#SUITES[@]}" "$TOTAL_PASS" "$TOTAL_FAIL"
[ "$TOTAL_SKIP" -gt 0 ] && printf ', %d skipped' "$TOTAL_SKIP"
printf '   (%dm%02ds)\n' $((elapsed / 60)) $((elapsed % 60))
[ ${#FAILED[@]}  -gt 0 ] && echo "failed:  ${FAILED[*]}"
[ ${#ERRORED[@]} -gt 0 ] && echo "errored: ${ERRORED[*]}  (setup problem — see DEPENDENCIES.md)"
[ ${#LEDGER_FAILED[@]} -gt 0 ] && echo "ledger:  ${LEDGER_FAILED[*]}  (assertion count dropped — see suites.tsv)"
[ "$TOTAL_SKIP" -gt 0 ] && echo "note: skips are missing preconditions, not passes"
echo "════════════════════════════════════════════"

[ ${#ERRORED[@]} -gt 0 ] && exit 2
[ ${#FAILED[@]}  -gt 0 ] && exit 1
[ ${#LEDGER_FAILED[@]} -gt 0 ] && exit 1
exit 0
