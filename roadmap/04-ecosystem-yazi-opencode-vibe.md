# Ecosystem Additions: yazi, OpenCode, Vibe

Follow-up analysis (2026-07-17) of two earlier local projects that slot naturally into
the cmux roadmap: the **yazi** terminal file manager (from the terminal-environment
experiments) and the **OpenCode vibe-coding project** (`~/dev/opencode`). Neither was
part of the original towel analysis in [02-integration-phases.md](02-integration-phases.md);
both extend it.

## Where these come from

- **yazi** — installed system-wide (`/usr/bin/yazi`), config at
  `~/.config/yazi/yazi.toml` (custom mpv opener using the **Kitty graphics protocol**,
  `--vo=kitty`). Bundled as *the* file manager in the `~/dev/nixos-gpu-terminal` ISO
  ("file manager with image previews") — the boots-into-Ghostty live-ISO project.
- **OpenCode vibe project** — `~/dev/opencode` (Jan 2026): voice-driven coding for the
  OpenCode agent. Working PoC: `packages/vibe-daemon` (Bun daemon: Whisper.cpp STT for
  EN/DE/ES, Piper TTS, OpenWakeWord "Hey OpenCode") + `.opencode/plugin/vibe.ts`
  (OpenCode plugin that receives transcriptions over WebSocket `ws://127.0.0.1:5050` and
  injects them into the TUI prompt). Full design in
  `~/dev/opencode/VIBE-IMPLEMENTATION-PLAN.md`.
- Related: `~/dev/KB-opencode` (OpenCode knowledge base), `~/dev/opencode-mimo`
  (tool-call translator configs + a `mimo-debug.ts` plugin logging
  `tool.execute.before/after` events — relevant below).

## E1 — yazi as a file-manager pane kind

cmux's pane model already abstracts surface kinds (`SurfaceKind` `.terminal`/`.browser`
in `linux/Sources/CmuxAdw/Model.swift`). A "files" pane is the cheapest possible third
kind: **it's just a terminal pane running yazi** — no new surface backend needed.

- Add a `workspace.files` control verb / shortcut that opens a split running `yazi` in
  the workspace's current directory. cwd is already tracked live via OSC 7
  (`SessionStore` persists it), so the file pane always opens *where the agent works*.
- **The embedded-Ghostty backend makes this shine:** Ghostty implements the Kitty
  graphics protocol, so yazi image previews — and the existing mpv/`--vo=kitty` video
  opener — work inside cmux panes. In VTE panes they silently degrade; one more argument
  for the Ghostty-default stack.
- Integration hook worth investigating: yazi's DDS/IPC layer (`ya emit`, local events)
  can announce selections/cd events — a selected file could open in an editor in the
  adjacent pane via the cmux socket. Verify the current yazi IPC surface before
  designing this (fast-moving project).
- Fits the original cmux concept: reviewing what an agent changed (open the touched file
  next to the agent pane) is a daily workflow, currently done by typing paths.

Effort: verb + shortcut is trivial (a day); DDS-based cross-pane actions are a separate,
later step.

## E2 — OpenCode as a first-class agent (plugin bridge)

cmux's agent features are Claude-Code-shaped today (claude-hook in
`CLI/cmux.swift:5710+`). The macOS TODO already lists Codex/OpenCode integrations.
The Linux port can get OpenCode parity cheaply, because **OpenCode has a proven local
plugin system** (vibe.ts and mimo-debug.ts both work) with exactly the hooks needed:

1. **`cmux.ts` OpenCode plugin** (~50 lines, modeled on the existing claude-hook
   semantics): on `session.idle`/completion → `cmux notify` / `notify_target`; on
   session start → map session to `CMUX_WORKSPACE_ID`/`CMUX_SURFACE_ID` (env is already
   injected into every pane). Result: attention dots + desktop notifications for
   OpenCode agents, same as Claude.
2. **`towel.ts` OpenCode plugin** — the sleeper hit: the `tool.execute.before/after`
   hooks (demonstrated by `~/.config/opencode/plugin/mimo-debug.ts.disabled`) see every
   bash command the agent runs, with args and result. Logging these via
   `towel-hist record` gives **Level-1-quality structured history without any MCP
   cooperation and without PTY parsing** — for OpenCode, this beats towel's own
   `towel_run` mechanism. It also sidesteps the "V2 parser is Claude-Code-shaped"
   limitation ([03-towel-prework.md](03-towel-prework.md) #8) for OpenCode panes
   entirely.

Effort: both plugins are small TypeScript files distributed via a project's
`.opencode/plugin/`; no cmux core changes beyond what T1 already adds.

## E3 — Vibe voice control for cmux (later, differentiator)

The vibe-daemon is deliberately agent-agnostic: audio in → Whisper → transcription out
over WebSocket. cmux could consume it directly: a small client in the app (or even a
shell helper) receiving transcriptions and forwarding them via the existing
`cmux send` / `send-key` verbs to the focused pane — wake word ("Hey cmux") →
speak → text lands in the active agent's prompt, TTS reads the agent's answer back on
`notify`. Voice control was independently on the nixos-gpu-terminal wishlist too; this
is the reusable implementation.

Realistic prerequisites: vibe-daemon was a Phase-6.0 PoC (Jan 2026) — check
`packages/vibe-daemon/IMPLEMENTATION-STATUS.md` and rebuild against current deps before
promising anything. Park behind T1–T3; revisit when the core integration is proven.

## Suggested ordering vs. the main phases

| Item | Slot in after | Why |
|------|--------------|-----|
| E1 yazi pane verb | T1 | trivial, immediately useful, showcases Ghostty backend |
| E2 `cmux.ts` plugin | T1 | agent parity, reuses T1 env injection |
| E2 `towel.ts` plugin | T1–T2 | best-quality towel data for OpenCode panes |
| E1 DDS cross-pane actions | T3 | needs design + yazi IPC verification |
| E3 vibe voice | after T3 | PoC-stage dependency, differentiator not foundation |
