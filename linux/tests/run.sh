#!/usr/bin/env bash
# The harness front door. Flags only, no prompts — safe for agents and CI.
#
#   run.sh                                # full gate (run-all.sh), freshness-checked
#   run.sh find popup                     # gate on suites matching any pattern
#   run.sh --list                         # every suite: ledger count + coverage line
#   run.sh --suite ui-commands [--keep]   # one suite (-smoke suffix optional)
#   run.sh --suite vte-scrollback --repeat 10       # flake hunter: N timed runs
#   run.sh --suite session-persistence --until-fail # run until red (default --max 50)
#   run.sh --build [...]                  # CMUX_GHOSTTY=1 swift build first
#
# Exit codes: gate/single runs pass through (0 ok, 1 assertions failed,
# 2 setup). Flake hunter: 0 every iteration green, 1 a red iteration was
# found (its full log path is printed), 2 setup.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; }

SUITE=""; REPEAT=1; UNTIL_FAIL=0; MAX=50; KEEP=0; BUILD=0; LIST=0
PATTERNS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --list) LIST=1 ;;
        --suite) SUITE="${2:?--suite needs a name}"; shift ;;
        --repeat) REPEAT="${2:?--repeat needs a count}"; shift ;;
        --until-fail) UNTIL_FAIL=1 ;;
        --max) MAX="${2:?--max needs a count}"; shift ;;
        --keep) KEEP=1 ;;
        --build) BUILD=1 ;;
        -h|--help) usage; exit 0 ;;
        --*) echo "run.sh: unknown flag $1" >&2; usage >&2; exit 2 ;;
        *) PATTERNS+=("$1") ;;
    esac
    shift
done

if [ "$LIST" = 1 ]; then
    while IFS=$'\t' read -r name count desc; do
        case "$name" in ''|'#'*) continue ;; esac
        printf '%-28s %4s  %s\n' "$name" "$count" "$desc"
    done < "$TESTS_DIR/suites.tsv"
    exit 0
fi

if [ "$BUILD" = 1 ]; then
    echo "run.sh: CMUX_GHOSTTY=1 swift build …"
    (cd "$TESTS_DIR/.." && CMUX_GHOSTTY=1 swift build) || exit 2
fi

# No --suite: the gate, with any patterns passed through.
if [ -z "$SUITE" ]; then
    if [ "$REPEAT" != 1 ] || [ "$UNTIL_FAIL" = 1 ]; then
        echo "run.sh: --repeat/--until-fail need --suite (flake-hunting the whole gate would bury the signal)" >&2
        exit 2
    fi
    exec "$TESTS_DIR/run-all.sh" ${PATTERNS[@]+"${PATTERNS[@]}"}
fi

script="$TESTS_DIR/$SUITE.sh"
[ -x "$script" ] || script="$TESTS_DIR/$SUITE-smoke.sh"
[ -x "$script" ] || { echo "run.sh: no suite named '$SUITE' (try --list)" >&2; exit 2; }
suite_name="$(basename "$script" .sh)"

# Plain single run.
if [ "$REPEAT" = 1 ] && [ "$UNTIL_FAIL" = 0 ]; then
    if [ "$KEEP" = 1 ]; then exec "$script" --keep; else exec "$script"; fi
fi

# Flake hunter: timed iterations, full log kept for every red one. A
# green run's output is discarded — the signal is the verdict + duration.
[ "$KEEP" = 1 ] && { echo "run.sh: --keep and --repeat don't mix (each iteration must tear down)" >&2; exit 2; }
runs="$REPEAT"
[ "$UNTIL_FAIL" = 1 ] && runs="$MAX"
logdir="/tmp/cmux-flakehunt"
mkdir -p "$logdir"
fails=0; durations=()
echo "flake hunt: $suite_name × $runs$([ "$UNTIL_FAIL" = 1 ] && echo ' (stop at first red)')"
for i in $(seq 1 "$runs"); do
    t0=$(date +%s)
    out=$("$script" 2>&1); rc=$?
    dur=$(( $(date +%s) - t0 ))
    durations+=("$dur")
    tally=$(echo "$out" | grep -E "^== $suite_name:" | tail -1 | sed "s/^== $suite_name: //")
    printf 'iter %02d/%02d: rc=%d  %s  (%ds)\n' "$i" "$runs" "$rc" "${tally:-no tally line}" "$dur"
    # The first iteration may print the stale-binary warning; one is enough.
    export CMUX_TEST_NO_FRESHNESS_WARN=1
    if [ "$rc" -ne 0 ]; then
        fails=$((fails + 1))
        log="$logdir/$suite_name-iter$i.log"
        echo "$out" > "$log"
        echo "         red — full log: $log"
        [ "$UNTIL_FAIL" = 1 ] && break
    fi
done
sorted=$(printf '%s\n' "${durations[@]}" | sort -n)
n=$(echo "$sorted" | wc -l)
min=$(echo "$sorted" | head -1)
max=$(echo "$sorted" | tail -1)
med=$(echo "$sorted" | sed -n "$(( (n + 1) / 2 ))p")
echo "── $n runs, $fails red, duration min/med/max ${min}s/${med}s/${max}s"
[ "$fails" -gt 0 ] && exit 1
exit 0
