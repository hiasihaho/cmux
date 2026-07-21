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
SUITES=(
    webdriver-smoke
    browser-navigation-smoke
    browser-popup-smoke
    pane-search-smoke
    browser-find-smoke
    session-persistence-smoke
    pane-zoom-smoke
    browser-urlbar-smoke
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
FAILED=(); ERRORED=()
started=$(date +%s)

for suite in "${SUITES[@]}"; do
    script="$TESTS_DIR/$suite.sh"
    [ -x "$script" ] || { echo "run-all: $suite is not executable" >&2; ERRORED+=("$suite"); continue; }
    printf '\n\033[1m── %s ──\033[0m\n' "$suite"
    out=$("$script" 2>&1); rc=$?
    echo "$out" | grep -E '^  (PASS|FAIL|SKIP)|^== ' || echo "$out" | tail -5

    line=$(echo "$out" | grep -E "^== $suite:" | tail -1)
    p=$(echo "$line" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+') || true
    f=$(echo "$line" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+') || true
    s=$(echo "$line" | grep -oE '[0-9]+ skipped' | grep -oE '[0-9]+') || true
    TOTAL_PASS=$((TOTAL_PASS + ${p:-0}))
    TOTAL_FAIL=$((TOTAL_FAIL + ${f:-0}))
    TOTAL_SKIP=$((TOTAL_SKIP + ${s:-0}))

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
[ "$TOTAL_SKIP" -gt 0 ] && echo "note: skips are missing preconditions, not passes"
echo "════════════════════════════════════════════"

[ ${#ERRORED[@]} -gt 0 ] && exit 2
[ ${#FAILED[@]}  -gt 0 ] && exit 1
exit 0
