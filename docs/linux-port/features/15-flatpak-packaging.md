# 15 — Flatpak packaging

Goal: one-command install of the Linux port on any machine — the answer
to everything the 2026-08-20 x12vm deployment did by hand (toolbox,
dep lists, desktop entry, renderer pins). Written for a future
**automated build harness**: every learning below is either a pinned
input in `linux/scripts/flatpak-build.sh`, a manifest line in
`linux/flatpak/com.manaflow.cmux.yml`, or a dated probe entry with the
command that produced it — so when cmux or flatpak-builder evolves, a
harness (or agent) can re-run the probes and update the pins instead of
rediscovering the territory.

## The harness contract

- **Executable half**: `linux/scripts/flatpak-build.sh` — subcommands
  `deps` / `build` / `install` / `run` / `verify`. ALL pinned inputs
  (runtime branch, Swift-extension branch, app id) live at the top of
  that script; the manifest pins the module sources (vte tarball +
  sha256). Nothing version-shaped may live anywhere else.
- **This doc is the explanatory half**: why each pin, what was probed,
  what breaks when a pin moves. Update both in the same commit.
- **Re-probe procedure when something evolves** (each probe is one
  command, safe to re-run):
  1. Runtime/extension availability:
     `flatpak remote-ls --user flathub --columns=application,branch | grep -iE 'gnome\.(Platform|Sdk)$|swift'`
  2. Swift version shipped by the extension:
     `FLATPAK_ENABLE_SDK_EXT=swift6 flatpak run --command=sh org.gnome.Sdk//<branch> -c '/usr/lib/sdk/swift6/bin/swift --version'`
     — must satisfy `linux/Package.swift` `swift-tools-version`.
  3. VTE pin: match the version validated on the reference hosts
     (`rpm -q vte291-gtk4` on Fedora N); sha256 from the GNOME tarball.
  4. Build: `flatpak-build.sh install` ; gate: `flatpak-build.sh verify`.
- **Success criteria for a green harness run**: build completes,
  `verify` passes, app launches on Wayland, terminal pane spawns a
  shell, control socket answers `ping` from inside the sandbox.

## Probe log (dated, with evidence)

2026-08-20, host Fedora 43, flatpak 1.16.6, flatpak-builder 1.4.8:

- `org.freedesktop.Sdk.Extension.swift6` EXISTS on Flathub, branches
  24.08 and 25.08. GNOME 49 sits on freedesktop 25.08 → pin 25.08.
- The 25.08 extension ships **Swift 6.3.3** — newer than the host's
  6.2, satisfies our `swift-tools-version: 6.1`. The "can Swift build
  inside flatpak-builder at all" unknown is resolved in principle;
  first full build is this round's remaining evidence.
- GNOME Platform/Sdk 49 AND 50 are on Flathub — the GNOME-50 dual
  target (CMUX_GNOME=50) has a natural flatpak twin later.
- Host quirk: the SYSTEM flathub remote here is `filtered`; all
  operations must use `--user` (the driver script does).
- VTE pin 0.82.3: the version validated by both the Fedora 43 host and
  the x12vm toolbox deployment. sha256
  `6dc6278f6fee30d07d1a03e2ba3335b1ea4e8d2956ceb59d861943115d930a85`.
  (Host also carries a stray /usr/local vte 0.85 that shadows
  pkg-config — the binary links /lib64 0.82.3; do not pin 0.85.)
- WebKitGTK 6.0 is IN the GNOME Platform runtime — browser panes need
  no module.
- Swift runtime libs are NOT in the Platform runtime (extension is
  SDK-only) → bundled into /app/lib + `LD_LIBRARY_PATH=/app/lib`
  finish-arg. A later round can switch to rpath/`$ORIGIN`.
- `GDK_DISABLE=vulkan` ships as a finish-arg default: venus (virtio-GPU)
  Vulkan fences hang GTK teardown in VMs (PROGRESS 2026-08-20, two
  independent stacks). GL-on-virgl is solid; revisit only with evidence.

Round-1 build evidence (same day):

- **First `flatpak-build.sh install` succeeded on the first attempt**:
  vte 0.82.3 module + full SwiftPM fetch + swift build of both products
  under Swift 6.3.3, exported and installed as
  `app/com.manaflow.cmux/x86_64/master` (~346 MB builder state;
  runtimes + build cost ~4 GB of host disk total).
- `verify` green: `/app/bin/cmux --help` runs in the sandbox — proof
  the bundled Swift runtime in /app/lib resolves.
- **Live probe**: `flatpak-build.sh run` (isolated ids) came up; the
  HOST-side CLI reached the sandboxed control socket at
  `$XDG_RUNTIME_DIR/app/com.manaflow.cmux/flatpak.sock` — `ping` →
  PONG, `workspace list` → workspace:1. **Design decision 2 has a
  proven answer**: that path is host-visible with zero extra
  permissions; round 2 should make it the app's default socket path
  when running inside flatpak (`$FLATPAK_ID` is set in-sandbox).
  In-sandbox shell behavior user-confirmed same day (screenshot): the
  pane spawns a sandbox shell (Fedora's `📦 <app-id>` prompt), `pwd` =
  real /home/hias via --filesystem=home. Files reachable, host tools
  absent — the sandbox /usr is the slim GNOME runtime, so the pane is
  not a dev environment until decision 1 (flatpak-spawn --host) lands.
- **Isolation is mandatory, encoded in the driver**: with
  `--filesystem=home` an unisolated launch would register the daily's
  GApplication id and write the daily's session store — and
  dirname(session)/scrollback is pruned on every save (the 2026-07-22
  trap). `flatpak-build.sh run` injects CMUX_APP_ID, a per-app socket,
  and a session file in its OWN directory (`~/.local/state/cmux-flatpak/`).
  A harness must never launch the flatpak without these.
- **Harness lesson — log-watch false positive**: a naive
  `grep -i error:` build watcher fires on Swift compiler diagnostics
  that echo OUR source lines containing the string `"ERROR:` (e.g.
  `return "ERROR: No focused terminal"`). Match `^Error:|error: ` and
  exclude `"ERROR:`-quoted snippets, or gate on the builder's exit
  status instead of log grep.

## Sandbox design decisions (round 2 — the real engineering)

Open, with leading options; none are packaging mechanics:

1. **Host shells.** In-sandbox shells (round 1) see the flatpak world,
   not the host. Real terminals need `flatpak-spawn --host` /
   HostCommand portal — Ptyxis is the reference implementation. Touches
   the VTE spawn path and the ghostty shim spawn path.
2. **Control socket reachability.** Host-side agents, hook scripts, and
   the CLI must reach the socket. Options: socket under
   `$XDG_RUNTIME_DIR/app/com.manaflow.cmux/` (host-visible by default)
   + host CLI knowing that path; or `--filesystem=xdg-run/cmux` and
   keep today's path. Decide together with (1).
3. **State dirs.** `~/.var/app/<id>/` vs today's
   `~/.local/state/cmux/`. Session/scrollback/feed stores and
   `promote.sh` semantics depend on this.
4. **CLI distribution.** The bundled `/app/bin/cmux` works inside the
   sandbox; host-side use needs either `flatpak run --command=cmux` or
   a host-installed CLI binary. Hooks fire on the host side today.
5. **Notifications** already flow through the portal for flatpaks —
   expected to just work, verify in round 2.

## Round-2 evidence (2026-08-20 evening) — host shells land

Probe: `hias@fedora-11:~$` inside a flatpak pane — real host bash, user
PS1, host hostname, driven closed-loop over the socket. Shipped:

- `FlatpakEnv.spawnArgv` — ONE spawn rewrite for all three pane paths
  (shell, respawn, dock panel): `flatpak-spawn --host --watch-bus`,
  explicit `--env` forwarding of pane identity + TERM/COLORTERM.
  `CMUX_FLATPAK_HOST_SHELL=0` keeps sandbox shells.
- In-flatpak defaults: socket `$XDG_RUNTIME_DIR/app/$FLATPAK_ID/cmux.sock`
  (host-reachable, zero permissions), session state in its own
  `cmux-flatpak` dir. Manifest adds `--talk-name=org.freedesktop.Flatpak`.
- Shell resolution + job control: the user's real shell resolves
  HOST-side (`${SHELL:-/bin/bash}` expanded by host sh — the sandbox's
  $SHELL is the runtime's sh). Job control needs a fresh host pty
  (the VTE pty's ctty slot belongs to the sandbox session; `setsid
  --ctty` gets EPERM): util-linux `script` provides it, probed at
  runtime — Fedora splits it into `util-linux-script`, so absence
  degrades to a working shell with bash's job-control warnings.
- Offline deps (round-3 item, landed early): `.flatpak-deps-cache`
  bare-repo mirrors (driver `deps-cache`) + SwiftPM `set-mirror` for
  both .git/non-.git spellings. Mirror dir names MUST equal the
  upstream repo name — SwiftPM derives package identity from the
  mirror URL basename; fingerprint-suffixed names break resolution
  with misleading tools-version errors.

Failure catalog from the build loop (harness-critical, each verified):

1. Module-cache staleness: `type: dir` modules can be served from the
   state-dir cache despite `--force-clean` — verify the change reached
   `/app/bin` (grep a new string) before trusting any probe.
2. `flatpak run` forwards ambient env — launched from a cmux pane the
   sandbox inherits that pane's CMUX_* identity; scrub before run
   (driver does).
3. aparoksha.dev git 504s kill online resolves — hence the mirrors.
4. Combining `--cache-path` WITH mirrors makes SwiftPM collide with
   itself ("already exists unexpectedly") — mirrors only.
5. Killing flatpak-builder leaves stale rofiles-fuse mounts; the next
   run dies "Permission denied" — fusermount3 -u them first.
6. Monitor hygiene: `pgrep -f` on the builder command line matches the
   watching loop itself — use `pgrep -x flatpak-builder`; and grep for
   `error:` false-fires on our own "ERROR: …" string literals echoed in
   compiler diagnostics.
7. Session restore also restores scrollback — probe FRESH workspaces,
   or old probe output masquerades as current behavior.

## Round 3a — Ghostty inside the Flatpak (2026-08-20 night)

The VM deployment could copy a host-built `libghostty-gtk.so` because
host and toolbox were both Fedora 43. That does NOT transfer here: the
GNOME runtime carries an older glibc than Fedora, so the shim must be
BUILT IN THE SANDBOX. Modules added, in order:

- `gtk4-layer-shell` v1.3.0 (meson) — Ghostty's GTK runtime links it and
  the GNOME runtime has no such library. sha256-pinned tarball.
- `ghostty-shim` — Zig 0.15.2 as a sha256-pinned self-contained tarball
  (`02aa270f…`), then `zig build lib-gtk -Dapp-runtime=gtk
  -Dversion-string=1.3.0-dev -Doptimize=ReleaseFast`, installing
  `libghostty-gtk.so` → /app/lib, headers → /app/include, and the
  shell-integration/theme tree → /app/share/ghostty. Sources: the zig
  archive plus a `type: dir` of the ghostty submodule (skipping .git,
  .zig-cache, zig-out). Still DEV-ONLY on one count: zig's package
  manager fetches Ghostty's own dependencies, so the module keeps
  `--share=network` (round 4 vendors them, the same treatment SwiftPM
  already got).
- `cmux-adw` builds with `CMUX_GHOSTTY=1` and `CMUX_GHOSTTY_OUT=/app`.
  That second variable is new: `Package.swift` used to hardcode the
  shim tree at `<repo>/ghostty/zig-out`, which does not exist inside
  the sandbox.
- finish-arg `GHOSTTY_RESOURCES_DIR=/app/share/ghostty`, because the
  app's self-locate walks the repo tree for that directory and there is
  no repo in the sandbox.

Round-3a traps (each cost a build):

- **Do not "improve" the shim build recipe.** Adding
  `-Doptimize=ReleaseFast` (for a 32 MB library instead of 125 MB)
  produced a shim that SIGSEGV'd inside `ghostty_embed_init` on first
  launch — Zig's ReleaseFast drops the safety checks the validated
  Debug recipe runs with. The manifest must mirror
  linux/README.md's recipe exactly; optimize only with evidence.
  Diagnosis path: the app died silently with no stderr, but
  `coredumpctl info` named `/app/lib/libghostty-gtk.so` in frame #0.
- **Ghostty panes bypass the VTE spawn path**, and the fix is NOT ours
  to write. Ghostty ships its own Flatpak host-spawning
  (`FlatpakHostCommand`, src/termio/Exec.zig) behind the build flag
  `-Dflatpak=true`; without it, Ghostty panes are SANDBOX shells. Our
  first attempt — wrapping the surface command in `flatpak-spawn
  --host` the way the VTE path must — fails by construction: Ghostty
  runs that command on the HOST, where flatpak-spawn has no portal to
  reach ("Can't find bus"), so the shell exits instantly and the pane
  answers `unavailable: Surface shell has exited`. The evidence trail
  that identified it: dump the pane's own env — `PATH=/app/bin`, no
  `DBUS_SESSION_BUS_ADDRESS`, no HOME, while a VTE pane in the SAME
  build shows a full sandbox env. So: shim built with `-Dflatpak=true`,
  and cmux passes a command for Ghostty panes ONLY on respawn. The
  asymmetry is deliberate — VTE needs our wrapper, Ghostty must not
  get it.
- **A silent instant exit is usually the app-id collision**, not a
  crash: the flatpak's GApplication id equals the daily's, so launching
  it while the daily runs makes GTK forward activation and exit 0. Always
  probe with `CMUX_APP_ID=com.manaflow.cmux.flatpak` (the driver's `run`
  sets it); a stale socket file with no process means it got further
  than that and died — check coredumpctl.

Related host-side change worth knowing when reading this manifest:
`Package.swift` now AUTO-LINKS the shim when the library is present, so
the Flatpak's VTE-only rounds must pass `CMUX_GHOSTTY=0` explicitly if
they ever want the old behaviour back.

## Permission model (decided direction, hias + desk 2026-08-20)

The question "ship `--filesystem=home` or narrower, maybe per-folder
($pwd-style) mappings?" dissolves once host shells land: pane shells
run on the HOST through the portal, so the user's full dev environment
is available in every pane **regardless of the sandbox's filesystem
grants**. The sandbox then only needs what the APP itself touches
(session/scrollback state, its config, drag-drop via portal). That is
the Ptyxis model, and it means narrow-by-default is nearly free.

Mechanism facts a harness (and docs) should encode:

- finish-args are only DEFAULTS. Users switch per-app without any
  rebuild: `flatpak override --user com.manaflow.cmux
  --nofilesystem=home --filesystem=~/dev` — exactly the "$pwd-scoped"
  idea, native, per-user, reversible (`flatpak override --user --reset
  com.manaflow.cmux`). Flatseal/GNOME Settings are the GUI faces.
- An app can NOT widen its own permissions at runtime — by design.
  "Directly switchable" from inside cmux is therefore out; what we CAN
  ship is detection + guidance (app notices a blocked path/portal and
  prints the exact override command or opens Settings).
- So the deliverable is **advised permission profiles**, documented as
  one-liners and encoded in the driver script:
  `dev` (today's breadth: filesystem=home — zero friction),
  `standard` (narrow: no home; host shells carry dev work; app state
  in its own dirs), `paranoid` (standard minus network, sandbox-only
  shells via CMUX_FLATPAK_HOST_SHELL=0). Manifest ships `standard`
  once round-3 narrowing is verified; `dev` is one override away.

## Round map

- **Round 1 (this): scoping.** VTE-only, debug config (the validated
  configuration), network during build, `--filesystem=home`,
  in-sandbox shells. Deliverable: manifest + driver + this doc +
  first build/verify evidence.
- **Round 2: sandbox design.** Decisions 1–5 above; host shells and
  socket reachability are the gate to "daily-usable flatpak".
- **Round 3: ghostty + compliance.** libghostty-gtk built in-manifest
  (zig as build module — the zig-free copy trick from the VM run does
  not apply to Flathub-clean builds), SwiftPM offline sources
  (pregenerated JSON), release config, icon + metainfo, narrowed
  permissions.
- **Round 4: automation.** CI/harness runs `flatpak-build.sh deps
  build verify` on every release tag; bundle artifact
  (`flatpak build-bundle`) attached to releases alongside the dmg.

## Known deviations from Flathub rules (all deliberate, round-mapped)

- `--share=network` in build-args (SwiftPM fetch) → round 3.
- `--filesystem=home` breadth → round 2.
- Debug build configuration → round 3.
- No icon/metainfo yet → round 3.
