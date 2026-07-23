# tmux compatibility — shim verbs ↔ cmux verbs ↔ Linux-port status

> Sources: https://cmux.com/en/docs/agent-integrations/claude-code-teams,
> /en/docs/agent-integrations/oh-my-{claudecode,opencode,codex}, /en/docs/remote-tmux,
> /en/blog/cmux-claude-teams; port status columns from docs/linux-port/PARITY.md;
> shim dispatch list verified against the shared `CLI/cmux.swift` in this repo.
> Crawled 2026-07-22 via the port's own browser.

Two *distinct* tmux features exist. Do not conflate them:

1. **The tmux shim** (`cmux __tmux-compat`) — a fake local `tmux` binary that
   agent orchestrators (claude-teams, codex-teams, omc, omo, omx) call; it
   translates tmux CLI invocations into cmux socket verbs. Client-side logic
   lives in the **shared CLI** (`CLI/cmux.swift` + `CLI/CMUXCLI+TmuxCompat*.swift`),
   which the Linux port already builds unmodified.
2. **Remote tmux mirroring** (`cmux ssh-tmux`, beta) — cmux attaches to a real
   remote tmux server in control mode (`tmux -CC`) over SSH and reprojects it
   into native UI. Entirely app-side; not shim-related.

## 1. Shim translation table

Documented mappings (claude-code-teams page) plus the full dispatch list
verified in `CLI/cmux.swift` (the docs undersell the shim). Port status is per
PARITY.md as of 2026-07-22.

| tmux command (alias) | cmux operation / socket verb | On Linux port? |
|---|---|---|
| `new-session` (`new`) | create workspace → `workspace.create` | ✅ |
| `new-window` (`neww`) | create workspace → `workspace.create` | ✅ |
| `split-window` (`splitw`) | split pane → `surface.split` | ✅ |
| `send-keys` (`send`) | send text → `surface.send_text` (+ key translation, `c-c`/`enter`/… → `surface.send_key`) | ✅ both verbs |
| `capture-pane` (`capturep`) | read terminal text → `surface.read_text` | ✅ incl. scrollback |
| `select-pane` (`selectp`) | focus pane → `surface.focus` / pane focus | ✅ |
| `select-window` (`selectw`) | focus workspace → `workspace.select` | ✅ |
| `kill-pane` (`killp`) | close surface → `surface.close` | ✅ |
| `kill-window` (`killw`) | close workspace → `workspace.close` | ✅ |
| `list-panes` (`lsp`) | list panes → `pane.list` / `surface.list` | ✅ |
| `list-windows` (`lsw`) | list workspaces → `workspace.list` | ✅ |
| `rename-window` (`renamew`) | rename workspace → `workspace.rename` | ✅ |
| `resize-pane` (`resizep`) | resize pane → `pane.resize` | ✅ (divider-walk impl) |
| `swap-pane` | swap pane contents → `pane.swap` | ✅ |
| `break-pane` | pane → new workspace → `pane.break` | ✅ |
| `last-pane` | toggle previous pane → `pane.last` | ✅ |
| `display-message` (`display`) | format expansion (`#{pane_id}` etc.), answered client-side | ✅ (CLI-local) |
| `set-buffer` / `paste-buffer` / `show-buffer` | buffers persisted in `~/.cmuxterm/tmux-compat-store.json`, paste → `surface.send_text` | ✅ (CLI-local + send) |
| `set-hook` | hooks persisted in tmux-compat-store.json | ✅ (CLI-local) |
| `wait-for` | synchronization primitive, CLI-local | ✅ (CLI-local) |
| `has-session` (`has`) / `show-options` (`show`) / `select-layout` | answered/absorbed client-side | ✅ (CLI-local) |
| `set-option`, `set-window-option`, `source-file`, `refresh-client`, `attach-session`, `detach-client` | accepted as **no-ops** | ✅ (no-op) |

**VERIFIED 2026-07-22 (late):** a real `cmux claude-teams` run on the port
spawned a teammate as a native split, captured its output, and shut it
down cleanly. Two server additions were needed beyond this table:
`surface.current` and `system.identify`'s `focused` block (PARITY, and
`linux/tests/tmux-compat-smoke.sh`). The historical prediction below
stands confirmed.

**Implication for the port:** every socket verb the shim needs exists on Linux.
`__tmux-compat` itself is shared-CLI code that already compiles on Linux.

**The launchers are NOT homogeneous (corrected 2026-07-23, dogfood batch 1
against `CLI/cmux.swift`).** Only three use the tmux shim, and differently:

| Launcher | Integration | Shim written? |
|---|---|---|
| `claude-teams` | writes shim, then execs `claude` (verified ✅ end-to-end) | yes, before exec |
| `omc` / `omx` | resolve the agent binary FIRST, then write the shim | yes — but not if the binary is absent (early exit) |
| `omo` | resolves `opencode`, installs the oh-my-openagent plugin (bun/npm side effect), then shim | yes, after the plugin install |
| `codex-teams` | **Codex app-server + watcher** over a loopback WebSocket (`CMUX_CODEX_TEAMS_APP_SERVER_URL`); tracks the pane codex runs in | **no tmux shim at all** |

So "they all ride the same shim surface" was wrong for codex-teams — it
is a different integration entirely. What is still *unverified* is the
real teammate-becomes-a-split behavior for all four (the agent binaries
are not installed here; `teams-siblings-smoke.sh` verifies only the
setup path — see GAPS).

Shim environment contract (for the shim-writing launchers): `TMUX` = fake
socket path encoding current cmux workspace+pane; `TMUX_PANE` = fake pane
id mapped to the current cmux pane; `CMUX_SOCKET_PATH` = the real control
socket. Shim binary dirs: `~/.cmuxterm/{claude-teams,omc,omo,omx}-bin/tmux`.

## 2. Remote tmux mirroring (`cmux ssh-tmux`, Beta-Features flag)

Layout projection — note the *inverted nesting* (in cmux a pane holds a row of
tabs; in tmux a window holds a split of panes):

| tmux | cmux |
|---|---|
| session | dedicated workspace in the sidebar |
| window | tab in that workspace |
| pane | pane in a native split **inside that tab** |

Mechanics: cmux spawns `ssh … tmux -CC attach` over an SSH ControlMaster
connection and owns the control-mode protocol itself (`%begin`/`%end`
correlation, `%output` → dedicated terminal surfaces). Input forwards via
`send-keys`; UI splits/closes run `split-window`; tab drag-reorder runs
`swap-window`; client sized to the rendered grid via `refresh-client -C`;
paste/drop goes through `paste-buffer -p` (real bracketed paste, single-line
only); requires tmux ≥ 3.2 (cwd tracking uses control-mode subscriptions).
Remote tmux owns reflow; cmux never reflows locally. Programmatic splits on a
mirrored workspace report *accepted with no surface id* (pane arrives async);
splits carrying un-honorable options (command, cwd, divider position, left/up)
are rejected before mutating the remote session.

Socket verbs (gated on the beta flag; dash-prefixed host/identity rejected as
SSH-option-injection defense):

| Method | Params | Purpose |
|---|---|---|
| `remote.tmux.sessions` | host, port?, identity_file? | list sessions on host |
| `remote.tmux.attach` | host, session, create? | attach control client |
| `remote.tmux.mirror` | host, port?, identity_file?, activate? | mirror every session → workspaces; returns ssh command when interactive auth needed |
| `remote.tmux.detach` | host, session | detach; remote keeps running |
| `remote.tmux.state` | host, session | diagnostics |

Mirrors are **not** restored on relaunch; transient SSH drops auto-reconnect
with capped exponential backoff.

**Port status:** remote.tmux.* is entirely unimplemented on Linux and PARITY
does not track it; CONCEPTS marks SSH/remote-tmux out of scope for now.

## 3. tmux passthrough for notifications (using real tmux inside cmux)

`.tmux.conf`: `set -g allow-passthrough on`, then
`printf '\ePtmux;\e\e]777;notify;Title;Body\a\e\\'`.
