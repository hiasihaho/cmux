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
