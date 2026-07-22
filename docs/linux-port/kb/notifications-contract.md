# Notifications — the full behavioral contract

> Sources: https://cmux.com/en/docs/notifications, /en/docs/configuration
> (notifications.* / automation.*), /en/docs/ssh (remote notify), /en/blog/cmd-shift-u,
> /en/blog/unread-shortcuts. Crawled 2026-07-22 via the port's own browser.

## Lifecycle

Received (appears in panel, desktop alert fires unless suppressed) → Unread
(badge on workspace tab) → Read ("cleared when you view that workspace") →
Cleared (removed from panel). Marking read is *view-driven*; manually marked
unread state is **sticky** "until you interact with the terminal" (0.64.5) —
navigation and focus alone don't clear it.

## Suppression rules (desktop alerts)

Suppressed when: (1) the cmux window is focused, (2) the sending workspace is
active, (3) the notification panel is open. Modifier:
`notifications.suppressOnlyFocusedSurface` (default false) — when on, a banner
is auto-withdrawn only if its surface is the *exact focused surface*; a banner
for a non-focused surface in the visible workspace stays up until that surface
is focused/clicked/dismissed. Also: `automation.suppressSubagentNotifications`
(default true) hides nested Codex/Claude child-agent noise (events remain in
Feed); remote (SSH) notification spam gets a per-host cooldown.

Side effects on delivery (all individually gated by settings/hooks):
record in panel, mark workspace unread, reorder workspace toward the top
(`app.reorderOnNotification`), desktop banner, sound, custom command,
pane flash, unread pane ring, Dock badge count, menu bar extra.

## Ingestion channels

1. **CLI/socket**: `cmux notify --title T [--subtitle S] --body B` ↔
   `notification.create`; plus create_for_caller / for_surface / for_target.
2. **OSC 777** (RXVT, simple): `printf '\e]777;notify;My Title;Message body\a'`
   — title+body only.
3. **OSC 99** (Kitty, rich): `ESC ] 99 ; <params> ; <payload> ESC \` with
   params `i=` (notification id), `e=`, `d=0|1` (done flag — 0 more chunks
   follow, 1 final), `p=title|subtitle|body` (which part this chunk carries).
   Docs examples verbatim: simple `\e]99;i=1;e=1;d=0:Hello World\e\\`;
   rich = three prints with `p=title`, `p=subtitle`, then `d=1;p=body`.
   (Full param semantics are the Kitty desktop-notification spec; the docs
   only show these shapes.) Feature table: OSC 99 adds subtitle +
   notification id over OSC 777. Docs guidance: 777 for simple, 99 for
   subtitle/ids, CLI for easiest.
4. **Agent hooks**: per-agent integrations (`cmux hooks setup`) and the Claude
   wrapper feed turn-complete / permission-request / idle events into the same
   pipeline; Claude's `PushNotification` tool is bridged too.
5. **tmux passthrough**: `allow-passthrough on` + wrapped OSC (kb/tmux-compat.md).

## Agent-event policy knobs

`notifications.agentPermissionPrompt` (true) · `agentTurnComplete`
whenIdle|always|never (whenIdle waits for background tasks/scheduled wakeups
to drain) · `agentIdleReminder` (true; ~60 s after turn end, suppressed while
background work pending) · per-category agent notification settings "gated on
genuinely background work" (0.64.18 #7129).

## Custom command

`notifications.command` runs via `/bin/sh -c` on every scheduled notification
with env `CMUX_NOTIFICATION_TITLE` / `_SUBTITLE` / `_BODY` (say/afplay/append
to log are the documented examples). Independent of the sound picker.

## Notification hooks (policy filters in cmux.json)

`notifications.hooks`: array of `{id, command, timeoutSeconds}`. Off unless at
least one enabled hook exists. Each hook gets the full policy JSON on stdin
and returns (possibly modified) JSON on stdout; cmux applies returned text and
effects — filter banners, keep/skip history, run sounds, stop later hooks.

Wire shape (v1):

```json
{
  "version": 1,
  "notification": {"workspaceId": "…", "surfaceId": "…",
                    "title": "…", "subtitle": "…", "body": "…"},
  "context": {"cwd": "…", "configPath": "…", "hookId": "…",
               "appFocused": false, "focusedPanel": false},
  "effects": {"record": true, "markUnread": true, "reorderWorkspace": true,
               "desktop": true, "sound": true, "command": true, "paneFlash": true}
}
```

Inheritance: global cmux.json + project `.cmux/cmux.json` files from parent
dirs down to the workspace; project hooks require the project-trust prompt;
`notifications.hooksMode: replace` in a project ignores inherited hooks.
Failure/timeout/invalid JSON ⇒ default behavior + a hook-failure alert.
Feed approval banners pass through the same hooks (disabling `desktop` keeps
the Feed item while suppressing the banner). Hook execution is non-blocking.

## Triage surface

Panel: **⌘I** (docs page also mentions ⌘⇧I opening it — the settings table
says showNotifications = cmd+i; treat ⌘I as canonical). Click a notification
to jump to its workspace. **⌘⇧U** jump-to-latest-unread: switches workspace,
focuses the exact pane, flashes it, marks it read, raises the owning window.
**⌃⌘U** mark-current-oldest-unread + jump next (cycling without clearing).
**⌥⌘U** toggle read/unread. **⌘⇧H** flash focused panel (`trigger_flash`).
Workspace-group headers aggregate unread badges; group menu can mark
read/unread and clear notifications (#6535).

## Documented integration recipes

- Shell `notify-after` wrapper fn (exit-code aware notify).
- Python/Node one-liners writing OSC 777 to stdout.
- Claude Code hooks JSON (~/.claude/settings.json Stop + PostToolUse:Task →
  `cmux notify`), with the guard `[ -S /tmp/cmux.sock ] || exit 0`.
- GitHub Copilot CLI `~/.copilot/config.json` hooks (userPromptSubmitted /
  agentStop / errorOccurred / sessionEnd) calling `cmux set-status` +
  `cmux notify` + `cmux clear-status`; repo-level `.github/hooks/notify.json`.
