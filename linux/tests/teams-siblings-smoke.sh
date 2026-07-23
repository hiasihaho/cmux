#!/usr/bin/env bash
# The sibling team launchers — `cmux codex-teams`, `cmux omc`, `cmux omx`,
# `cmux omo` — that ride the same tmux-compat substrate as `cmux claude-teams`
# (see tmux-compat-smoke.sh, which pins the substrate itself end-to-end). Each
# launcher's job on the Linux port is to set an agent up so that when it thinks
# it is driving tmux, the calls land on `cmux __tmux-compat` and teammates
# become native cmux splits.
#
# omc/omx and opencode's oh-my-openagent plugin are NOT installed here, so this
# suite CANNOT spawn a real teammate for them — those assertions are honestly
# SKIPPED. `codex` IS now installed, so codex-teams is driven far enough to prove
# it launches its Codex app-server (below); a full authenticated split still
# skips. What the suite verifies is the Linux launcher + shim/app-server SETUP
# path, which is where the port-specific risk lives.
#
# Findings that shaped the suite (each contradicts the naive "every sibling
# writes ~/.cmuxterm/<name>-bin/tmux then fails at exec" assumption, which only
# holds for claude-teams):
#
#   * omc / omx resolve their agent binary BEFORE writing the shim, so with the
#     binary absent they exit at the resolve check ("<x> is not installed") and
#     write NO shim. To exercise the real shim-write we put a harmless fake
#     agent stub (exit 0) first on PATH: the launcher then writes its real shim
#     and execs the stub — no teammate spawned, shim inspectable.
#   * omo resolves `opencode` (not a literal `omo`) and then installs its
#     oh-my-openagent plugin via bun/npm BEFORE writing the shim — a real
#     network side effect — so its shim-write is not driven here (SKIP). Its
#     shim is byte-identical in form to omc/omx (shared createTmuxCompatShim
#     code): `exec "${CMUX_OMO_CMUX_BIN:-cmux}" __tmux-compat "$@"`.
#   * codex-teams writes NO ~/.cmuxterm tmux shim at all; it drives panes
#     through the Codex app-server + watcher. Its "shim" assertion is therefore
#     that no such directory appears (ASSERT). With codex present we also assert
#     it actually launches `codex app-server --listen ws://127.0.0.1:<port>` and
#     the loopback port binds — the mechanism reaching the stage a shim can't.
#     The `codex app-server` child escapes codex-teams' process group and
#     survives its SIGTERM, so the suite reaps it explicitly by that port.
#
# Everything runs against this suite's own isolated instance on a private X
# display; launcher probes use a hermetic $HOME so the real ~/.cmuxterm is
# never touched (the codex probe's HOME only symlinks in `codex`, keeping
# ~/.codex + ~/.cmuxterm isolated and codex unauthenticated). Safe under the
# full gate: with codex absent the app-server assertion honestly SKIPs.
#
#   teams-siblings-smoke.sh [--keep]
#
# Exit: 0 all passed, 1 an assertion failed, 2 setup problem.
SUITE_NAME="teams-siblings-smoke"
APP_ID_SUFFIX="teamsibtest"
PAGE_PORT=8433   # only picks a unique X display (:123); no fixture server served
source "$(dirname "$0")/lib.sh"

# Hermetic scratch: fake agent stubs, per-probe $HOME roots, in-pane script.
WORK="/tmp/cmux-$APP_ID_SUFFIX-work"
rm -rf "$WORK"; mkdir -p "$WORK"
FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"

# Codex app-servers this suite launched. codex-teams starts
# `codex app-server --listen ws://127.0.0.1:<port>` as a child that escapes its
# process group and ignores its SIGTERM, so we reap it explicitly by the loopback
# port it binds. Guard the process-group kill so we can never target our OWN pgid.
CODEX_TEAMS_PORTS=""; CODEX_TEAMS_PGIDS=""
MY_PGID=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
codex_teams_reap() {
    local pgid port pid
    for pgid in $CODEX_TEAMS_PGIDS; do
        [ -n "$pgid" ] && [ "$pgid" != "$MY_PGID" ] && kill -TERM -"$pgid" 2>/dev/null
    done
    for port in $CODEX_TEAMS_PORTS; do
        pid=$(ss -ltnpH 2>/dev/null | grep "127.0.0.1:$port " | grep -oE 'pid=[0-9]+' | cut -d= -f2 | head -1)
        [ -n "$pid" ] && kill "$pid" 2>/dev/null
        rm -f "/tmp/cmux-codex-teams-$port-app-server.log" "/tmp/cmux-codex-teams-$port-watcher.log" 2>/dev/null
    done
}
suite_cleanup() { codex_teams_reap; rm -rf "$WORK"; }

# Agent binaries are absent here, so the resolver only ever sees system dirs it
# always appends (/usr/bin, /bin, ...) — none of which hold codex/omc/omx, and
# `opencode` lives in ~/.opencode/bin which the resolver does NOT scan. So a
# hermetic $HOME + this PATH makes every "agent missing" probe deterministic.
CLEAN_PATH="/usr/bin:/bin"

# Runs a launcher with the agent-pane env scrubbed and a hermetic HOME so a
# shim, if written, lands under $home/.cmuxterm and never the real one. Pass
# socket "-" for launchers that resolve before touching the socket (omc/omx/
# omo); pass $SOCK for codex-teams, which resolves its focused pane first.
# Sets LR_OUT / LR_CODE.
run_launcher() { # <home> <path> <socket|-> <verb> [args...]
    local home="$1" path="$2" sock="$3"; shift 3
    local -a envv=(-u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID -u CMUX_SOCKET \
                   -u CMUX_SOCKET_PATH HOME="$home" PATH="$path")
    [ "$sock" != "-" ] && envv+=(CMUX_SOCKET_PATH="$sock")
    LR_OUT=$(env "${envv[@]}" "$CLI" "$@" 2>&1); LR_CODE=$?
}

make_fake() { printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/$1"; chmod +x "$FAKEBIN/$1"; }

start_xvfb
start_instance || exit 2

# --------------------------- launchers dispatch + degrade gracefully (absent)
# A recognized launcher reaches its own runXXX and reports the missing agent;
# an unrecognized command would print a usage/unknown error instead. Self-
# guards: if the agent binary is unexpectedly resolvable on some host, SKIP
# rather than fail. Also asserts no shim junk is left when it cannot proceed.
info "sibling launchers dispatch to their runner and degrade gracefully when the agent binary is absent"
assert_graceful() { # <label> <verb> <home> <socket|-> <grep-pattern> <shim-dir-name>
    local label="$1" verb="$2" home="$3" sock="$4" pat="$5" shimname="$6"
    run_launcher "$home" "$CLEAN_PATH" "$sock" "$verb"
    if [ "$LR_CODE" -ne 0 ] && printf '%s' "$LR_OUT" | grep -qi "$pat"; then
        ok "$label dispatches to its runner and reports the missing agent (exit $LR_CODE)"
    elif [ "$LR_CODE" -eq 0 ] || printf '%s' "$LR_OUT" | grep -qiE 'unknown|unrecognized|^usage:'; then
        bad "$label graceful-missing" "unexpected: $(printf '%s' "$LR_OUT" | head -1)"
    else
        skip "$label graceful-missing" "agent binary looks resolvable on this host; got: $(printf '%s' "$LR_OUT" | head -1)"
    fi
    if [ -e "$home/.cmuxterm/$shimname/tmux" ]; then
        bad "$label leaves no shim when it cannot proceed" "wrote $shimname"
    else
        ok "$label leaves no shim when it cannot proceed"
    fi
}
assert_graceful "omc" omc "$WORK/h/omc-miss" "-"     "omc is not installed" "omc-bin"
assert_graceful "omx" omx "$WORK/h/omx-miss" "-"     "omx is not installed" "omx-bin"
assert_graceful "omo" omo "$WORK/h/omo-miss" "-"     "opencode"             "omo-bin"

# ------------------------------------ the shim omc/omx write redirects to compat
# With a resolvable (harmless, exit-0) agent stub first on PATH, the launcher
# reaches its shim-write, writes the real shim, then execs the stub — proving
# the setup path without spawning a teammate. The written shim must forward to
# `cmux __tmux-compat`, the substrate tmux-compat-smoke.sh pins.
info "omc/omx write a tmux shim that redirects tmux verbs to cmux __tmux-compat"
assert_shim() { # <label> <verb> <home> <shim-dir-name>
    local label="$1" verb="$2" home="$3" shimname="$4"
    make_fake "$verb"
    run_launcher "$home" "$FAKEBIN:$CLEAN_PATH" "-" "$verb"
    local shim="$home/.cmuxterm/$shimname/tmux"
    if [ -x "$shim" ]; then
        ok "$label writes $shimname/tmux"
    else
        bad "$label writes $shimname/tmux" "not written (exit $LR_CODE): $(printf '%s' "$LR_OUT" | head -1)"
        return
    fi
    if grep -q '__tmux-compat' "$shim"; then
        ok "$label shim redirects tmux verbs to cmux __tmux-compat"
    else
        bad "$label shim redirects to cmux __tmux-compat" "shim body lacks __tmux-compat"
    fi
}
assert_shim "omc" omc "$WORK/h/omc-shim" "omc-bin"
assert_shim "omx" omx "$WORK/h/omx-shim" "omx-bin"

# ------------------------------------------ codex-teams: app-server, not a shim
info "codex-teams rides the substrate through the Codex app-server/watcher, not a ~/.cmuxterm tmux shim"
run_launcher "$WORK/h/cxt" "$CLEAN_PATH" "$SOCK" codex-teams
if [ "$LR_CODE" -ne 0 ] && printf '%s' "$LR_OUT" | grep -qi codex; then
    ok "codex-teams dispatches to runCodexTeams and degrades gracefully (codex absent)"
else
    skip "codex-teams graceful path" "codex resolvable or unexpected: $(printf '%s' "$LR_OUT" | head -1)"
fi
if [ -e "$WORK/h/cxt/.cmuxterm/codex-teams-bin" ]; then
    bad "codex-teams writes no ~/.cmuxterm tmux shim" "unexpected codex-teams-bin directory"
else
    ok "codex-teams writes no ~/.cmuxterm tmux shim (app-server mechanism)"
fi

# --------------------- codex present: codex-teams launches the Codex app-server
# codex is installed now, so codex-teams gets PAST binary resolution into its real
# mechanism: it spawns `codex app-server --listen ws://127.0.0.1:<port>` and waits
# on an initialize handshake before starting the root agent. We run it under a
# $HOME that only symlinks `codex` in (so ~/.codex + ~/.cmuxterm stay isolated and
# codex is unauthenticated), launched backgrounded with /dev/null stdin (the root
# codex then EOFs out), watch for the app-server's loopback port to bind, then
# reap. A real subagent split still needs an authenticated interactive codex —
# that stays an honest skip below.
info "codex present: codex-teams launches the Codex app-server on a loopback ws — the stage a tmux shim never reaches"
CODEX_BIN=$(command -v codex 2>/dev/null || true)
if [ -z "$CODEX_BIN" ]; then
    skip "codex-teams launches the Codex app-server" "codex is not installed"
elif ! command -v setsid >/dev/null 2>&1; then
    skip "codex-teams launches the Codex app-server" "setsid unavailable to isolate/reap the app-server process group"
else
    CXHOME="$WORK/h/cx-present"; mkdir -p "$CXHOME/.local/bin"
    ln -sf "$CODEX_BIN" "$CXHOME/.local/bin/codex"   # resolver scans $HOME/.local/bin
    CX_OUT="$WORK/cx-present.out"
    before_logs=$(ls /tmp/cmux-codex-teams-*-app-server.log 2>/dev/null)
    setsid env -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID -u CMUX_SOCKET -u CMUX_SOCKET_PATH \
        HOME="$CXHOME" PATH="$CLEAN_PATH" CMUX_SOCKET_PATH="$SOCK" \
        "$CLI" codex-teams </dev/null >"$CX_OUT" 2>&1 &
    cx_pid=$!
    cx_pgid=$(ps -o pgid= -p "$cx_pid" 2>/dev/null | tr -d ' ')
    [ -n "$cx_pgid" ] && CODEX_TEAMS_PGIDS="$CODEX_TEAMS_PGIDS $cx_pgid"
    cx_newlog=""
    for _ in $(seq 1 30); do
        sleep 0.5
        for f in $(ls /tmp/cmux-codex-teams-*-app-server.log 2>/dev/null); do
            printf '%s\n' "$before_logs" | grep -qxF "$f" || { cx_newlog="$f"; break; }
        done
        [ -n "$cx_newlog" ] && break
        grep -qi "not found" "$CX_OUT" 2>/dev/null && break
    done
    cx_port=$(printf '%s' "$cx_newlog" | grep -oE '[0-9]+' | head -1)
    [ -n "$cx_port" ] && CODEX_TEAMS_PORTS="$CODEX_TEAMS_PORTS $cx_port"
    if [ -n "$cx_port" ] && ss -ltnpH 2>/dev/null | grep -q "127.0.0.1:$cx_port "; then
        ok "codex-teams launches codex app-server on a loopback ws (127.0.0.1:$cx_port — past binary resolution)"
    elif grep -qi "not found" "$CX_OUT" 2>/dev/null; then
        skip "codex-teams launches the Codex app-server" "codex not resolvable in the probe HOME"
    else
        skip "codex-teams launches the Codex app-server" "app-server did not bind within timeout (codex may require login); see $CX_OUT"
    fi
    codex_teams_reap
fi

# ---------------------------- the shim, run AS tmux in a pane, resolves via compat
# The strongest link: take the omc shim the launcher actually wrote, drop it on
# PATH as `tmux` inside a live pane (whose CMUX_* env is the identity
# __tmux-compat resolves against), set the fake TMUX a launcher exports, and run
# a tmux verb. `tmux -V` is answered locally by the shim; `tmux list-panes`
# forwards to `cmux __tmux-compat list-panes` and must resolve the pane.
info "the omc shim, executed as tmux inside a pane, resolves the current pane through __tmux-compat"
SHIM_OMC="$WORK/h/omc-shim/.cmuxterm/omc-bin"
T=$(first_surface_ref workspace:1)
if [ -n "$T" ] && [ -x "$SHIM_OMC/tmux" ] && wait_for_shell "$T"; then
    RT_OUT="$WORK/shim-rt.out"; rm -f "$RT_OUT"
    cat > "$WORK/shim-rt.sh" <<EOS
#!/bin/bash
export PATH="$SHIM_OMC:\$PATH"
export CMUX_OMC_CMUX_BIN="$CLI"
export TMUX="/tmp/cmux-omc/\${CMUX_WORKSPACE_ID:-default},0,0"
echo "VER:\$(tmux -V 2>&1)"
echo "PANES:\$(tmux list-panes -F '#{pane_id}' 2>&1 | grep -c '^%')"
echo "RT_DONE"
EOS
    cx send --surface "$T" "bash $WORK/shim-rt.sh > $RT_OUT 2>&1\n" >/dev/null 2>&1
    for _ in $(seq 1 30); do grep -q RT_DONE "$RT_OUT" 2>/dev/null && break; sleep 1; done
    expect "omc shim answers 'tmux -V' locally" "VER:tmux 3.4" "$(grep '^VER:' "$RT_OUT" 2>/dev/null)"
    panes=$(grep '^PANES:' "$RT_OUT" 2>/dev/null)
    if [ -n "$panes" ] && [ "$panes" != "PANES:0" ]; then
        ok "omc shim resolves the current pane via cmux __tmux-compat ($panes)"
    else
        bad "omc shim resolves the current pane via cmux __tmux-compat" "got '${panes:-<no output>}'"
    fi
else
    skip "omc shim tmux-verb translation" "no live pane shell (Ghostty maps its shell on first window map)"
fi

# ------------------------------------------------------------- honest skips
# A real teammate split needs the agent binary installed AND (for codex) an
# authenticated, interactive session — beyond what this environment can drive.
info "skips: a real teammate split needs the agent installed and (for codex) an authenticated interactive session"
skip "omc spawns a teammate split"         "omc (oh-my-claude-sisyphus) is not installed"
skip "omx spawns a teammate split"         "omx (oh-my-codex) is not installed"
skip "omo spawns a teammate split"         "opencode is present but its oh-my-openagent plugin install (bun/npm) is a real side effect; not driven"
skip "codex-teams spawns a teammate split" "codex is installed and its app-server launches (asserted above), but a real subagent split needs an authenticated, interactive codex session driving a subagent — not exercised"
skip "omo writes its tmux shim"            "omo installs its plugin via bun/npm before the shim-write; shim form is shared code, verified via omc/omx"
skip "codex-teams shim redirects to __tmux-compat" "codex-teams has no tmux shim; it drives panes through the app-server watcher"

finish
