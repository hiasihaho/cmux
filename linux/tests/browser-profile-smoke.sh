#!/usr/bin/env bash
# Regression test for browser profiles (roadmap/07): isolated
# cookie/storage spaces per profile, mirroring macOS's BrowserProfileStore.
#
#   browser-profile-smoke.sh          # run all assertions, clean up
#   browser-profile-smoke.sh --keep   # leave the instance up
#
# Exit: 0 all passed, 1 an assertion failed, 2 setup problem.
SUITE_NAME="browser-profile-smoke"
APP_ID_SUFFIX="proftest"
PAGE_PORT=8418
source "$(dirname "$0")/lib.sh"

# Profiles live beside the session file; a previous run's store/data would
# poison the CRUD assertions (lib.sh only cleans the session itself).
rm -f "$(dirname "$SESSION")/browser-profiles.json"
rm -rf "$(dirname "$SESSION")/profiles"
suite_cleanup() {
    rm -f "$(dirname "$SESSION")/browser-profiles.json"
    rm -rf "$(dirname "$SESSION")/profiles"
}

WORK=$(mktemp -d)
# The fixture sets and reads a cookie via JS — document.cookie round-trips
# through the profile's cookie jar, which is exactly what must be isolated.
cat > "$WORK/index.html" <<'HTML'
<!doctype html><title>profile fixture</title><body>
<div id="out">none</div>
<script>
// max-age matters: without it this is a SESSION cookie, which no
// browser ever writes to persistent storage — the restart assertion
// below would fail against perfectly correct code.
function setMark(v) { document.cookie = "profmark=" + v + "; path=/; max-age=86400"; return v; }
function getMark() {
  const m = document.cookie.match(/profmark=([^;]*)/);
  return m ? m[1] : "none";
}
document.getElementById('out').textContent = getMark();
</script></body>
HTML
echo '<!doctype html><title>opener</title><body><button id="btn" onclick="window.open(&quot;/index.html&quot;,&quot;_blank&quot;)">open</button></body>' > "$WORK/opener.html"
start_fixture_server "$WORK"
start_xvfb
start_instance || exit 2

# ---------------------------------------------------------------- CRUD verbs
info "profile verbs (wire format shared with macOS)"
expect "list starts with the built-in default" "1" \
    "$(cx --json browser profiles list | python3 -c '
import json,sys; d=json.load(sys.stdin)
ps=d.get("profiles",[])
print(1 if len(ps)==1 and ps[0].get("built_in_default") and ps[0].get("slug")=="default" else 0)')"

cx browser profiles create "Work Stuff" >/dev/null 2>&1
slug=$(cx --json browser profiles list | python3 -c '
import json,sys
for p in json.load(sys.stdin)["profiles"]:
    if not p["built_in_default"]: print(p["slug"]); break')
expect "create + slug derivation" "work-stuff" "$slug"

dup=$(cx browser profiles create "work stuff" 2>&1 | grep -ci "already exists")
expect "duplicate names are rejected (case-insensitive)" "1" "$dup"

cx browser profiles rename work-stuff "Client A" >/dev/null 2>&1
renamed=$(cx --json browser profiles list | python3 -c '
import json,sys
for p in json.load(sys.stdin)["profiles"]:
    if not p["built_in_default"]: print(p["slug"]); break')
expect "rename re-derives the slug" "client-a" "$renamed"
cx browser profiles rename client-a "Work" >/dev/null 2>&1

# ------------------------------------------------------------- isolation
info "cookie isolation between profiles"
WS=$(cx new-workspace --cwd /tmp --background | grep -oE 'workspace:[0-9]+')
cx select-workspace --workspace "$WS" >/dev/null
sleep 2
SW=$(cx browser open "http://127.0.0.1:$PAGE_PORT/index.html" --workspace "$WS" --profile work | grep -oE 'surface:[0-9]+' | head -1)
SD=$(cx browser open "http://127.0.0.1:$PAGE_PORT/index.html" --workspace "$WS" | grep -oE 'surface:[0-9]+' | head -1)
sleep 3
cx browser --surface "$SW" eval 'setMark("WORKSECRET")' >/dev/null 2>&1
sleep 1
in_work=$(cx browser --surface "$SW" eval 'getMark()' 2>/dev/null | head -1)
in_default=$(cx browser --surface "$SD" eval 'getMark()' 2>/dev/null | head -1)
expect "the work pane sees its cookie" "WORKSECRET" "$in_work"
expect "the default pane does NOT" "none" "$in_default"

# A second pane of the SAME profile must share the jar — that sharing is
# what makes a profile one container rather than per-pane isolation.
SW2=$(cx browser open "http://127.0.0.1:$PAGE_PORT/index.html" --workspace "$WS" --profile work | grep -oE 'surface:[0-9]+' | head -1)
sleep 3
in_work2=$(cx browser --surface "$SW2" eval 'getMark()' 2>/dev/null | head -1)
expect "a second work pane shares the container" "WORKSECRET" "$in_work2"

# ------------------------------------------------------- popup inheritance
info "window.open stays inside the opener's profile"
SP=$(cx browser open "http://127.0.0.1:$PAGE_PORT/opener.html" --workspace "$WS" --profile work | grep -oE 'surface:[0-9]+' | head -1)
sleep 3
cx browser --surface "$SP" click '#btn' >/dev/null 2>&1
sleep 3
POPUP=$(cx --json list-panes --workspace "$WS" | python3 -c '
import json,sys
refs=[r for p in json.load(sys.stdin)["panes"] for r in p["surface_refs"]]
print(refs[-1])')
in_popup=$(cx browser --surface "$POPUP" eval 'getMark()' 2>/dev/null | head -1)
expect "the popup sees the work container's cookie" "WORKSECRET" "$in_popup"

# ------------------------------------------------------ delete guard rails
info "delete guard rails"
inuse=$(cx browser profiles delete --profile work 2>&1 | grep -ci "in use")
expect "deleting an in-use profile is refused" "1" "$inuse"
builtin_del=$(cx browser profiles delete --profile default 2>&1 | grep -ci "built-in\|cannot")
expect "deleting the built-in default is refused" "1" "$builtin_del"

# ------------------------------------------------- restart: profile + cookies
info "profile survives a restart (assignment AND cookie jar)"
kill_instance
start_instance || exit 2
sleep 3
WSB=$(cx list-workspaces | grep -oE 'workspace:[0-9]+' | sed -n '2p')
cx select-workspace --workspace "$WSB" >/dev/null
sleep 4
# Restore order is not guaranteed, so classify every browser pane by its
# cookie: the work panes must still see the mark, the default pane must
# still not — that pairing IS the isolation surviving the restart.
marks=$(cx --json list-panes --workspace "$WSB" | python3 -c '
import json,sys
print(" ".join(r for p in json.load(sys.stdin)["panes"] for r in p["surface_refs"]))')
work_count=0; none_count=0
for r in $marks; do
    v=$(cx browser --surface "$r" eval 'typeof getMark === "function" ? getMark() : "pending"' 2>/dev/null | head -1)
    case "$v" in
        WORKSECRET) work_count=$((work_count+1));;
        none) none_count=$((none_count+1));;
    esac
done
[ "$work_count" -ge 1 ] && [ "$none_count" -ge 1 ] \
    && ok "restored panes kept their containers ($work_count work, $none_count default)" \
    || bad "restart isolation" "work=$work_count default=$none_count (want >=1 each)"

# The profile store itself survived too.
expect "profile list survives the restart" "work" \
    "$(cx --json browser profiles list | python3 -c '
import json,sys
for p in json.load(sys.stdin)["profiles"]:
    if not p["built_in_default"]: print(p["slug"]); break')"

# -------------------------------------------------------- delete when free
info "delete once no pane uses it"
# Close the whole restored workspace: takes every work pane with it.
cx close-workspace --workspace "$WSB" >/dev/null 2>&1
sleep 2
cx browser profiles delete --profile work >/dev/null 2>&1
expect "profile gone from the list" "0" \
    "$(cx --json browser profiles list | python3 -c '
import json,sys
print(sum(1 for p in json.load(sys.stdin)["profiles"] if not p["built_in_default"]))')"
leftover=$(find "$(dirname "$SESSION")/profiles" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
expect "and its data directory removed" "0" "$leftover"

finish
