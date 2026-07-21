# 07 — Browser profiles on Linux (containerized cookie/storage spaces)

Planned 2026-07-21. Status: **designed, not started** — deliberately
parked until after the upstream catch-up merge, because upstream already
ships this feature on macOS and the merge tells us the exact surface to
mirror.

## What it is

Per-profile isolation of everything a site can persist: cookies, cache,
localStorage/IndexedDB, service workers, TLS state. "Work" panes see each
other's logins; "private-x" panes see nothing of them. Plus ephemeral
panes that never touch disk.

## Parity check (the reason this doc exists)

First drafted as a Linux-first feature — then verified against
`upstream/main` and **macOS cmux already has it**, our stale checkout
just predates it (the third time an "ahead of macOS" claim died on
inspection; check before claiming). The macOS shape, which we mirror:

- `BrowserProfileDefinition`: `id: UUID`, `displayName`, `createdAt`,
  `isBuiltInDefault`; a socket-safe `slug` derived from the name
  (`"default"` for the built-in profile).
- `BrowserProfileStore`/`Repository` (in
  `Packages/macOS/CmuxBrowser/…/Profiles/`): create / rename / delete /
  clearProfileData / noteUsed, `lastUsedProfileID`; the built-in default
  maps to the *shared* default store rather than a per-profile one.
- Per-profile `WKWebsiteDataStore(forIdentifier:)` **and** a per-profile
  history file.
- Session persistence: the browser panel snapshot carries
  `profileID: UUID?`.
- UI: `BrowserProfilePopover` — the icon in the browser pane's toolbar.
- Automation: `BrowserProfileAutomation` — socket verbs for
  list/create/rename/delete, `--profile` on browser open; CLI resolves a
  profile by slug, name, or id.

## Linux mapping

WebKitGTK 6.0 has the same concept under a different name:

| macOS | Linux |
|---|---|
| `WKWebsiteDataStore(forIdentifier: id)` | `webkit_network_session_new(data_dir, cache_dir)` keyed by profile id |
| `WKWebsiteDataStore.default()` | the default `WebKitNetworkSession` (what every pane uses today) |
| nonPersistent store | `webkit_network_session_new_ephemeral()` |
| `WKWebView` init with store | construct-only `network-session` property → `g_object_new_with_properties` (same pattern as `related-view`) |

Directories: `~/.local/share/cmux/profiles/<uuid>/` +
`~/.cache/cmux/profiles/<uuid>/` (respecting `CMUX_SESSION_PATH`-relative
placement for test instances, like `scrollback/`).

Design points:

- One `WebKitNetworkSession` per profile per process, in a registry; all
  panes of a profile share it (that is what makes them one container).
- Popups inherit the opener's session automatically via `related-view` —
  the correct container semantic, for free.
- v3 session schema: `BrowserSnapshot` gains `profile: String?` (UUID);
  absent = default, so old files stay valid. Ephemeral panes restore
  with their URL but deliberately without state.
- CLI mirrors upstream verbs verbatim: `cmux browser profiles`,
  `browser profile create/rename/delete/clear`, `--profile <slug|id>` on
  `browser open`/`open-split`.
- UI comes last (popover in the pane header, like macOS); the verb layer
  is the useful 80%.

## To verify during implementation

- Whether a persistent `WebKitNetworkSession` stores cookies in its data
  directory automatically or needs
  `webkit_cookie_manager_set_persistent_storage` — docs ambiguous, one
  test settles it.
- Whether `is-controlled-by-automation` views (WebDriver) can carry a
  non-default session, or automation stays default-profile-only.
- macOS also isolates *history* per profile; Linux has no history file
  yet, so nothing to isolate — note in PARITY when that changes.

## Honest scope note

This is isolation in the Firefox-Multi-Account-Containers sense —
separate cookie/storage/cache spaces in one process tree. It is **not**
an OS-level sandbox (no namespaces, no separate user). If podman-grade
isolation is ever wanted, that is a different roadmap item.

## Test plan

Fixture server sets a cookie in profile A; assert profile B's pane does
not send it (and vice versa), ephemeral pane leaves no directory behind,
profile round-trips a restart via the v3 field, popup from a profiled
pane lands in the same profile.
