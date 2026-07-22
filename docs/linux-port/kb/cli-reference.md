# CLI and socket reference — distilled

> Sources: https://cmux.com/en/docs/api (CLI Reference), /en/docs/workspace-groups,
> /en/docs/ssh, /en/docs/remote-tmux, /en/docs/session-restore, /en/docs/browser-automation,
> /en/docs/task-manager, /en/docs/skills, /en/docs/changelog (verbs added over time).
> Crawled 2026-07-22 via the port's own browser.

## Transport contract

- Sockets: Release `/tmp/cmux.sock`, Debug `/tmp/cmux-debug.sock`, tagged
  `/tmp/cmux-debug-<tag>.sock`; override `CMUX_SOCKET_PATH`.
- One newline-terminated JSON request per connection:
  `{"id":"req-1","method":"workspace.list","params":{}}` →
  `{"id":"req-1","ok":true,"result":{…}}`. **v2 only** — legacy
  `{"command":…}` payloads are rejected.
- Access modes (`automation.socketControlMode` / `CMUX_SOCKET_MODE`): `off`;
  `cmuxOnly` (default — only processes spawned inside cmux terminals, checked
  by ancestry); `allowAll` (env override only); plus `password` mode with
  `automation.socketPassword`. Docs advice: "On shared machines, use Off or
  cmux processes only."
- CLI global flags (before the subcommand): `--socket PATH`, `--json`,
  `--window ID`, `--workspace ID`, `--surface ID`,
  `--id-format refs|uuids|both`.

## Environment variables (auto-set in cmux terminals)

`CMUX_SOCKET_PATH`, `CMUX_SOCKET_ENABLE`, `CMUX_SOCKET_MODE`,
`CMUX_WORKSPACE_ID`, `CMUX_SURFACE_ID`, `TERM_PROGRAM=ghostty`,
`TERM=xterm-ghostty`; per-workspace `CMUX_PORT` from
`automation.portBase`/`portRange`.

## Command groups (CLI verb ↔ socket method)

### Workspaces / splits / surfaces
`list-workspaces`↔workspace.list · `new-workspace`↔workspace.create
(supports `--layout` param for programmatic split layouts, #2916) ·
`select-workspace`↔workspace.select · `current-workspace`↔workspace.current ·
`close-workspace`↔workspace.close · `new-split
left|right|up|down`↔surface.split · `list-panels`↔surface.list ·
`list-pane-surfaces`↔pane.surfaces · `focus-panel`↔surface.focus.

### Input / read
`send [--surface id] "text"`↔surface.send_text · `send-key [--surface id]
enter|tab|escape|backspace|delete|up|down|left|right`↔surface.send_key.

### Notifications
`notify --title --subtitle --body`↔notification.create ·
`list-notifications`↔notification.list ·
`clear-notifications`↔notification.clear · panel-parity verbs (0.64.5):
`dismiss`, `mark-read`, `open`, `jump-to-unread` (notification.*).

### Sidebar metadata (for build scripts, CI, agents)
`set-status <key> <text> [--icon --color --priority --workspace]` ·
`clear-status <key>` · `list-status` · `set-progress 0.0–1.0 [--label]` ·
`clear-progress` · `log [--level info|progress|success|warning|error]
[--source] -- text` · `clear-log` · `list-log [--limit]` · `sidebar-state`
(dump cwd, git branch, ports, status, progress, logs). Keys are namespaced so
different tools manage their own entries.

### Utility
`ping`↔system.ping · `capabilities`↔system.capabilities (methods + access
mode) · `identify`↔system.identify (focused window/workspace/pane/surface).

### Feature namespaces discovered across docs/changelog
- `cmux workspace-group …` — 16 subcommands (see kb/sidebar-and-groups.md).
- `cmux browser …` — full automation grammar (kb/browser-and-automation.md);
  also `cmux browser import` (cookie/profile import wizard) and
  `cmux browser disable` switch.
- `cmux ssh user@host [--name --command -p -i -o --no-focus]`;
  `cmux ssh-tmux <dest> [--new-window --port --identity --no-focus]`;
  `cmux ssh-session-attach --split`.
- `cmux claude-teams`, `cmux codex-teams`, `cmux omc`, `cmux omo`, `cmux omx`,
  internal `cmux __tmux-compat` (kb/tmux-compat.md).
- `cmux hooks setup [agent]`, `cmux hooks omp install`, namespaced agent-hook
  commands.
- `cmux surface resume set|show|clear` (custom resume bindings).
- `cmux restore-session` · `cmux reload-config` · `cmux top` (Task Manager
  snapshot; also scriptable) · `cmux diff` (CodeView diff viewer) ·
  `cmux open README.md` / `cmux markdown open` (markdown panel) ·
  `cmux feed tui [--opentui]` · `cmux docs <topic>` (agent-facing manual) ·
  `cmux remotes` (device-registry routes) · `cmux skills`-adjacent installer
  is `skills.sh` / `npx skills add manaflow-ai/cmux`.

## Deep links (external entry points)

`cmux://ssh?host=…&user=…&port=…&title=…&host-key-policy=…&no-focus=…`
(confirmation prompt + trust before connecting; **cannot** pass identity
files, raw options, commands, or forwarding — those live in ~/.ssh/config).
Web fallbacks: `https://cmux.com/deeplink/ssh?…`, `/deeplink/prompt?text=…`,
`/deeplink/rules?name=…&text=…`. Scheme per channel: `cmux://` stable,
`cmux-nightly://`, `cmux-dev://`.

## Client patterns the docs bless

Python: connect AF_UNIX, send `json.dumps(payload)+"\n"`, read one reply.
Shell: `printf '%s\n' "$REQ" | nc -U "$SOCK"`. Build scripts: `cmux notify`
on success/failure. Docs also ship `/llms.txt` and markdown/plain variants of
every docs page for agent consumption (#3410).
