#!/usr/bin/env bash
# Regression test for ephemeral (leave-no-trace) browser panes.
#
# A pane opened with `--profile ephemeral` is born into a fresh in-memory
# WebKit session (webkit_network_session_new_ephemeral): it persists no
# cookies/storage/cache and shares nothing with any other pane. This suite
# proves that by contrast with a PERSISTENT profile, using the same
# set-cookie / close / reopen sequence for both:
#
#   ephemeral   : cookie is GONE in a freshly reopened pane
#   persistent  : cookie SURVIVES a close/reopen (same container)
#
# and additionally that two concurrent ephemeral panes do not share a jar,
# that "ephemeral" is a reserved profile name, and that ephemeral writes no
# profile data directory to disk.
#
#   browser-ephemeral-smoke.sh          # run all assertions, clean up
#   browser-ephemeral-smoke.sh --keep   # leave the instance up
#
# Exit: 0 all passed, 1 an assertion failed, 2 setup problem.
SUITE_NAME="browser-ephemeral-smoke"
APP_ID_SUFFIX="ephemtest"
# 8426 → private display :116 (90 + 8426%50); no other suite maps there.
PAGE_PORT=8426
source "$(dirname "$0")/lib.sh"

# The reserved ephemeral profile id (BrowserProfiles.ephemeralID). Its
# absence on disk is the on-disk "leave no trace" proof below.
EPHEMERAL_UUID="00000000-0000-0000-0000-000000000002"

# Profiles live beside the session file; a previous run's store/data would
# poison the assertions (lib.sh only cleans the session itself).
rm -f "$(dirname "$SESSION")/browser-profiles.json"
rm -rf "$(dirname "$SESSION")/profiles"
suite_cleanup() {
    rm -f "$(dirname "$SESSION")/browser-profiles.json"
    rm -rf "$(dirname "$SESSION")/profiles"
}

WORK=$(mktemp -d)
# The fixture sets/reads a cookie via JS — document.cookie round-trips
# through the pane's cookie jar, which is exactly what ephemeral must NOT
# keep. The max-age matters: a session cookie is never written to
# persistent storage, so the persistent-profile contrast below would fail
# against perfectly correct code without it.
cat > "$WORK/index.html" <<'HTML'
<!doctype html><title>ephemeral fixture</title><body>
<div id="out">none</div>
<script>
function setMark(v) { document.cookie = "ephmark=" + v + "; path=/; max-age=86400"; return v; }
function getMark() {
  const m = document.cookie.match(/ephmark=([^;]*)/);
  return m ? m[1] : "none";
}
document.getElementById('out').textContent = getMark();
</script></body>
HTML
start_fixture_server "$WORK"
start_xvfb
start_instance || exit 2

URL="http://127.0.0.1:$PAGE_PORT/index.html"

# Opens a browser pane in $WS and echoes its surface ref. Args after the
# URL pass straight through (e.g. --profile ephemeral).
open_browser() {
    cx browser open "$1" --workspace "$WS" "${@:2}" | grep -oE 'surface:[0-9]+' | head -1
}
get_mark() { cx browser --surface "$1" eval 'getMark()' 2>/dev/null | head -1; }

# ----------------------------------------------------- reserved name guard
info "'ephemeral' is a reserved profile name"
reserved=$(cx browser profiles create "ephemeral" 2>&1 | grep -ci "reserved")
expect "creating a profile named 'ephemeral' is refused" "1" "$reserved"
listed=$(cx --json browser profiles list | python3 -c '
import json,sys
print(sum(1 for p in json.load(sys.stdin)["profiles"] if p.get("slug")=="ephemeral"))')
expect "the ephemeral profile never appears in the list" "0" "$listed"

# A real persistent profile for the contrast half of every test below.
cx browser profiles create "Persist" >/dev/null 2>&1

WS=$(cx new-workspace --cwd /tmp --background | grep -oE 'workspace:[0-9]+')
cx select-workspace --workspace "$WS" >/dev/null
sleep 2

# ------------------------------------------- ephemeral: cookie leaves no trace
info "an ephemeral pane keeps nothing across close/reopen"
E1=$(open_browser "$URL" --profile ephemeral)
sleep 3
cx browser --surface "$E1" eval 'setMark("EPHEMSECRET")' >/dev/null 2>&1
sleep 1
# Sanity: the cookie must actually be set in-session, or "gone after
# reopen" would pass against a broken fixture that never stored anything.
expect "the ephemeral pane holds its own cookie while open" "EPHEMSECRET" "$(get_mark "$E1")"
cx close-surface --surface "$E1" >/dev/null 2>&1
sleep 2
E2=$(open_browser "$URL" --profile ephemeral)
sleep 3
expect "a freshly reopened ephemeral pane does NOT inherit the cookie" "none" "$(get_mark "$E2")"

# --------------------------------------- persistent contrast: cookie survives
info "a persistent profile DOES keep the cookie across close/reopen"
P1=$(open_browser "$URL" --profile persist)
sleep 3
cx browser --surface "$P1" eval 'setMark("PERSISTSECRET")' >/dev/null 2>&1
sleep 1
expect "the persistent pane holds its cookie while open" "PERSISTSECRET" "$(get_mark "$P1")"
cx close-surface --surface "$P1" >/dev/null 2>&1
sleep 2
P2=$(open_browser "$URL" --profile persist)
sleep 3
expect "the persistent profile's cookie survives the reopen" "PERSISTSECRET" "$(get_mark "$P2")"

# --------------------------------------- two ephemeral panes never share a jar
info "concurrent ephemeral panes are isolated from each other"
D1=$(open_browser "$URL" --profile ephemeral)
D2=$(open_browser "$URL" --profile ephemeral)
sleep 3
cx browser --surface "$D1" eval 'setMark("D1SECRET")' >/dev/null 2>&1
sleep 1
expect "the pane that set the cookie sees it" "D1SECRET" "$(get_mark "$D1")"
expect "a second live ephemeral pane does NOT see it" "none" "$(get_mark "$D2")"

# ------------------------------------------------------ on-disk leave-no-trace
info "ephemeral writes no profile data directory"
eph_dir="$(dirname "$SESSION")/profiles/$EPHEMERAL_UUID"
[ ! -e "$eph_dir" ] \
    && ok "no ephemeral profile data directory on disk" \
    || bad "ephemeral disk trace" "$eph_dir exists"
# The persistent profile, by contrast, DID materialize a data directory —
# confirming the fixture actually exercised persistent storage.
persist_dirs=$(find "$(dirname "$SESSION")/profiles" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
[ "$persist_dirs" -ge 1 ] \
    && ok "the persistent profile did write a data directory ($persist_dirs)" \
    || bad "persistent contrast" "expected >=1 profile dir, got $persist_dirs"

finish
