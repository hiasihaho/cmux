# CONCLUSION — 2026-08-21 23:36 CEST — cmux desk

## 1. What I worked on

**Browser capture (a question that turned into two bugs).**
- `--full-page` had been in the CLI help since 2026-07-21 with the server
  honouring it all along, but the CLI never parsed the flag — every
  "full page" capture was silently a viewport shot. Red-first fix:
  `f8352472b6` (RED test) → `02cae5eb3c` (fix). Measured 3000px doc →
  6000px PNG vs 1324px viewport (device pixels, 2x).
- Full-page captures could hang forever on long documents. Root cause is
  a GPU ceiling — `GL_MAX_TEXTURE_SIZE = 16384`, and Wikipedia's
  *Cuneiform* at 41,382 CSS px needs ~82,700 device px at 2x — and our
  screenshot path had NO server-side deadline. Bounded now: `6c6799715d`.
  Does not reproduce headless: software rendering has no such ceiling
  (I captured 100k px happily before the renderer difference surfaced).
- Written up so it is not re-derived:
  `docs/linux-port/features/16-browser-capture-and-interaction.md`
  (`4b22183d13`) — Part A the ceiling with options and a recommendation
  (tiling), Part B the interaction-recorder design (existing
  user-content-manager channel, identity+timing never values, opt-in).
  Curated pick-up order in NEXT-STEPS.md, GAPS rows point at it.

**Flatpak, from "runs" to "provisions a machine".**
- Ghostty now builds from source inside the sandbox and its panes are
  HOST shells via `-Dflatpak=true` (`14da67ea90`, yesterday's late work
  verified today). Bundle route proven to x12vm: `f6d3cec45a`.
- Skills ship at `/app/share/cmux/skills` **and** the linker ships with
  them (`ab952504b8`) — a flatpak-only machine could not wire them up
  otherwise. Two flatpak constraints learned: links must target the
  HOST-visible path (pane shells cannot see `/app`), and that path is
  unreadable from inside the sandbox (flatpak masks
  `~/.local/share/flatpak` even under `--filesystem=home`), so the
  script enumerates one directory and points at another.
- `cmux: Befehl nicht gefunden` in a pane → shipped
  `install-host-cli.sh` (`88c0ec2e9e`): the flatpak's binary runs
  directly on the host against the runtime libs beside it (host glibc
  2.41 vs runtime 2.42). Deliberately not `flatpak run --command=cmux`,
  which sanitizes the env and drops the pane identity.
- x12vm now provisions in three commands, no checkout anywhere.

**Strategy + team.** Refreshed the three-way COMPARISON stamp against
live upstream (322 commits since the survey, 83 in cmux-tui; no Linux
GUI frontend has appeared) and drafted `docs/linux-port/UPSTREAM-OFFER.md`
(`a9f54e1ee3`) — a Discussion post offering the Linux groundwork, not a
PR of the port. Answered Q-C in thread-sonde5 (presence datum: yes to
measurements, no to a `composer_empty` boolean from the terminal),
confirmed my team-kb record with corrections, and ran a two-way
verification exchange with the ws:16 session on the capture bugs.

## 2. Time (machine evidence, sources named)

- git log on `linux-port`, this desk, 2026-08-21: **9 commits, 00:42 →
  23:35**. Feed `created_at` for my letters brackets the same span.
- Not continuous: work came in blocks — ~00:30–02:00 (browser capture),
  ~10:00–12:30 (feature 16, flatpak bundle + skills to the VM),
  ~18:30 and ~23:00–23:36 (letters, host CLI). Roughly **6 h active**.
- Long unattended stretches inside that: Ghostty-from-source and
  `flatpak build-bundle` runs (~20 min each, four bundles today).

## 3. Handed to tomorrow

- Capture pre-flight guard, then tiling — owner cmux desk; order and
  reasoning in features/16 + NEXT-STEPS "browser-capture track".
- `browser.viewport.set` unimplemented here though agents advise it —
  owner cmux desk (GAPS).
- The upstream offer is DRAFTED, not sent — owner hias; re-check
  `cmux-tui/frontends/` before posting if it sits more than a few days.
- VM's deployed flatpak has one stale cosmetic warning (host-aware PATH
  note fixed in git, ships with the next bundle) — owner cmux desk.
- macos-verify compile check for today's shared CLI change still pending
  (ultmos VM off) — owner cmux desk.

## 4. One lesson

**"Cannot reproduce" is a claim about my probe, not about the bug.** I
could not reproduce the capture hang at 40k, 100k, or 120 megapixels —
because every probe ran under Xvfb software rendering, where the GPU
texture ceiling that causes it does not exist. The sibling session's
report was right the whole time. When a failure involves large
allocations, the renderer is the variable; a headless probe is not a
probe of the user's machine.

*Conclusion-harness opinion (parked, one sentence):* mechanize it — the
`conclusions-YYYYMMDD` workstream is already the durable half, and a
small skill that stamps from `date`, harvests `git log --since`, and
scaffolds the four sections would make the pattern cost nothing.
