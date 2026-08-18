# Findings & requests from the lfm-dl project (2026-08-18)

*Reported by the lfm-dl sessions (Claude + Kimi, hias's ~/olmo project), which
exercised the cmux CLI, the hooks system, and the Linux debug build hard for a
week — as a measurement target, an agent harness, and an event source. Every
item below was hit in practice and is reproducible; file/line pointers
included. Left uncommitted for hias to review and commit.*

## 1. Linux port: `feed.*` verbs unimplemented (blocks the hook-event pipeline)

**Symptom:** `cmux rpc feed.list` → `Error: unknown_method: Method not
implemented in the Linux port yet: feed.list` (same for feed.recent; and
`cmux hooks feed --source <any>` always returns `{}`).

**Why it matters:** the whole agent-hook event pipeline dead-ends on Linux.
The opencode integration (`cmux-feed.js`) installs fine, connects to the
socket, and sends `feed.push` — which the Linux port silently rejects. Agents
appear integrated but no events are queryable. The lfm-dl organism wanted to
use the feed as a universal multi-agent tap (one reader instead of one adapter
per agent); the idea is parked on exactly this.

**Request:** implement the `feed.*` socket verbs in the Linux port. A ready
verification instrument exists: `~/olmo/exp/run feedprobe --watch` during any
live hooked agent session will confirm the fix end-to-end (it polls all
sources and prints the first retained event with its payload).

**Payload note for when it lands:** the plugin caps user messages at 1000
chars, whitespace-collapsed (cmux-feed.js `normalizeText`). For observability
that's fine; for training-data-grade capture, a raw or higher-cap variant
would be worth a flag.

## 2. `bundledOpenCodePluginSource`: repo-fallback walk misses the Linux build layout

**Symptom:** `cmux hooks opencode install` from the Linux debug build →
`Error: bundled opencode-plugin.js not found (Bundle.main, app bundle,
executable, and repo fallbacks)`.

**Root cause:** `CLI/cmux.swift:34151ff` — the repo fallback walks UP at most
4 levels from the executable looking for the project marker, but the Linux
binary lives at `linux/.build/x86_64-unknown-linux-gnu/debug/`, which puts the
repo root on hop 5. Off-by-one for this layout.

**Fix options:** raise the walk bound to 6; or add an explicit relative
candidate `../../../../Resources/opencode-plugin.js`; or honor an env var
(e.g. `CMUX_RESOURCES`).

**Workaround currently in place on this machine:** symlink
`~/cmux/Resources/opencode-plugin.js` next to the debug binary (the
installer's first candidate). Dies with the next clean rebuild.

## 3. Top-level `--help` lists commands the binary rejects (phantom verbs)

**Symptom:** six entries extracted from `cmux --help` answer
`Error: Unknown command '<verb>'` when invoked: `cmux` (self-reference from
the `cmux <path>` usage line), `search`, `text`, `to`, `toggle`, and
**`zoom-pane`**.

**Why it matters:** anything that builds an allowlist from the help output
(the lfm-dl verb oracle did — and its grammar then *permitted* unspellable
commands until repaired) inherits phantoms. `zoom-pane` is the interesting
case: it looks like a real (macOS-implemented?) command that the Linux build
rejects while still advertising it — if so, the help output should be
platform-aware, or the command should answer with a "not on this platform"
message rather than "Unknown command".

**Repro:** `for v in search text to toggle zoom-pane; do cmux $v --help; done`

## 4. Small observations (no action needed, recorded for completeness)

- `cmux hooks <agent> <invalid-event>` exits silently with `{}` — fail-open by
  design presumably, but a stderr hint would speed up integration debugging.
- The per-verb `--help` pages carry usage/flags but no one-line descriptions —
  the lfm-dl side-effect census had to source semantics from the contract
  docs instead. One description line per verb in the help would make the
  binary self-describing for tooling.
- Praise where due: the hook receivers being fail-open, the socket protocol,
  and `--json` coverage made a week of heavy programmatic use essentially
  frictionless. The two platform gaps above were the only walls.

## 5. `cmux open` does not parse `file://` URLs — and exits 0 on the error

`cmux open "file:///abs/path.html"` → `Error: Path does not exist:
/home/hias/olmo/file:///abs/path.html` (scheme treated as a relative path),
**with exit code 0**. Request: parse the scheme (or document file support),
and make errors nonzero — a script cannot detect this failure today.

## 6. Linux port: `markdown.open` unimplemented

`cmux markdown open <path>` → `Error: unknown_method: Method not implemented
in the Linux port yet: markdown.open`. The live-file-watching markdown viewer
is exactly the right surface for locally generated dashboards/reports — second
vote for the Linux port catching up on viewer verbs (alongside feed.*, item 1).
