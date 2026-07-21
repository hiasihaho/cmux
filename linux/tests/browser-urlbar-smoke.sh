#!/usr/bin/env bash
# Regression test for the browser pane address bar.
#
#   browser-urlbar-smoke.sh          # cleans up
#   browser-urlbar-smoke.sh --keep   # leave the instance up
#
# Exit: 0 all passed, 1 an assertion failed, 2 setup problem.
#
# Drives the real widget with xdotool on the suite's private X display —
# the bar's whole point is that a human can type into it, so asserting only
# on the resolver would test the easy half.
SUITE_NAME="browser-urlbar-smoke"
APP_ID_SUFFIX="urltest"
PAGE_PORT=8419
source "$(dirname "$0")/lib.sh"

WORK=$(mktemp -d)
echo '<!doctype html><title>home</title><h1>home</h1>'   > "$WORK/index.html"
echo '<!doctype html><title>page A</title><h1>A</h1>'    > "$WORK/a.html"
echo '<!doctype html><title>results</title><h1>q</h1>'   > "$WORK/search.html"
start_fixture_server "$WORK"

info "starting isolated cmux"
# Point the search fallback at the fixture so a non-URL query stays local
# instead of hitting a real search engine from a test.
INSTANCE_ENV=(CMUX_SEARCH_URL="http://127.0.0.1:$PAGE_PORT/search.html?q=%s")
start_xvfb
start_instance || exit 2

WS=$(cx new-workspace --cwd /tmp --background | grep -oE 'workspace:[0-9]+')
S=$(cx browser open "http://127.0.0.1:$PAGE_PORT/index.html" --workspace "$WS" | grep -oE 'surface:[0-9]+')
cx select-workspace --workspace "$WS" >/dev/null
sleep 3

url() { cx browser --surface "$S" get-url 2>/dev/null; }

# The bar reflects navigations driven from elsewhere.
cx browser --surface "$S" goto "http://127.0.0.1:$PAGE_PORT/a.html" >/dev/null 2>&1
sleep 1
case "$(url)" in
    *"/a.html") ok "socket navigation lands where asked (bar mirrors it)";;
    *) bad "socket navigation" "url is $(url)";;
esac

if ! command -v xdotool >/dev/null 2>&1 || [ "$USE_XVFB" != "1" ]; then
    skip "typing assertions" "needs xdotool and an Xvfb display"
    cx close-workspace --workspace "$WS" >/dev/null 2>&1
    finish
fi

# Click the bar, replace its contents, press Enter.
type_url() {
    DISPLAY="$XDISPLAY" xdotool mousemove 850 70 click 1
    sleep 0.6
    DISPLAY="$XDISPLAY" xdotool key ctrl+a
    sleep 0.2
    DISPLAY="$XDISPLAY" xdotool type --delay 30 "$1"
    sleep 0.4
    DISPLAY="$XDISPLAY" xdotool key Return
    sleep 3
}

# A bare loopback host must become http://, not https:// — the case that
# motivates checking loopback before generic URL parsing, since
# URL("localhost:3000") otherwise reads "localhost" as a *scheme*.
type_url "127.0.0.1:$PAGE_PORT/index.html"
case "$(url)" in
    "http://127.0.0.1:$PAGE_PORT/index.html") ok "typed loopback host resolves to http (not https)";;
    *) bad "loopback heuristic" "url is $(url)";;
esac

# A bare domain gets promoted to https. Uses the fixture host so the test
# stays offline; the assertion is on the scheme, not on reachability.
type_url "127.0.0.1:$PAGE_PORT/a.html"
case "$(url)" in
    *"/a.html") ok "typing navigates the pane";;
    *) bad "typed navigation" "url is $(url)";;
esac

# Text that is not a URL becomes a search.
type_url "hello world"
case "$(url)" in
    *"/search.html?q=hello%20world"|*"/search.html?q=hello+world") ok "non-URL text falls through to search";;
    *) bad "search fallback" "url is $(url)";;
esac

if screenshot "$WORK/urlbar.png"; then
    ok "screenshot captured ($(stat -c%s "$WORK/urlbar.png" 2>/dev/null) bytes)"
else
    skip "screenshot" "no import available"
fi

cx close-workspace --workspace "$WS" >/dev/null 2>&1
finish
