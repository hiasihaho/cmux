# Dependencies — cmux Linux port

Everything needed to build, run and test the port, with the versions this
was actually developed against. Written with a container in mind: the
sections map onto install steps, and each entry says *why* it is needed so
a future reader can tell what is safe to drop.

**Keep this current** when a new library, tool or env var becomes
required — same commit as the change, like PARITY.md.

Reference host: **Fedora 43** (GNOME 49, Wayland).

## Build — required

| Dependency | Version here | Why |
|---|---|---|
| Swift toolchain | 6.2 (`swift-lang` Fedora pkg) | the port is Swift. swiftly does **not** support Fedora; the swift.org ubi9 tarball also works |
| GTK 4 | 4.20.4 | `pkgConfig: "gtk4"` |
| libadwaita | 1.8.5.1 | UI shell; also the `CAdw` module that exposes AdwTabView/AdwCarousel to Swift |
| VTE (GTK4 build) | 0.82.3 | `pkgConfig: "vte-2.91-gtk4"`, module `CVte` — the fallback terminal backend |
| WebKitGTK 6.0 | 2.52.4 | `pkgConfig: "webkitgtk-6.0"`, module `CWebKit` — browser panes, automation, inspector, session state |
| pkg-config, gcc, make | — | module maps resolve through pkg-config; gcc builds the C probes in `linux/tests/` |

```sh
sudo dnf install -y swift-lang gtk4-devel libadwaita-devel \
    vte291-gtk4-devel webkitgtk6.0-devel pkgconf-pkg-config gcc make
```

Build from **`linux/`**, never the repo root (the root `Package.swift` is
a macOS stub):

```sh
cd linux && CMUX_GHOSTTY=1 swift build
```

`CMUX_GHOSTTY=1` is load-bearing: a plain `swift build` produces a
VTE-only binary and silently overwrites the shim-linked one on disk.

## Build — embedded Ghostty (default terminal backend)

| Dependency | Version here | Why |
|---|---|---|
| Zig | 0.15.2 (`~/.local/zig/zig-x86_64-linux-0.15.2`) | builds `libghostty-gtk.so` from the `ghostty` submodule |
| ghostty submodule | fork `hiasihaho/ghostty`, branch `linux-gtk-embed` | the GTK embedding shim |

Always pass `-Dversion-string=1.3.0-dev`: the fork's `xcframework-<sha>`
tags break ghostty's git-describe version detection and it panics.

Without this the app still runs — `CMUX_TERM=vte` falls back to VTE — but
Ghostty is the default and the richer path (scrollback, find overlay).

## GNOME 49 vs 50

adwaita-swift `main` targets GNOME 50 and breaks against GTK 4.20 headers,
so the GNOME 49 build pins revision `664cadd`. `CMUX_GNOME=50` selects
`main`; `linux/scripts/build-gnome50.sh` runs that build in a Fedora 44
podman container (artifacts in `.build-gnome50/`). A container image
should probably pick one and state it, rather than carry both.

## Test / QA

| Dependency | Why | Without it |
|---|---|---|
| `python3` | fixture HTTP servers and JSON assertions in every suite | suites cannot run |
| `curl` | fixture readiness polling, WebDriver HTTP calls | suites cannot run |
| `iproute` (`ss`) | pre-flight port cleanup — a previous `--keep` run holds ports | suites fail for unrelated-looking reasons |
| `WebKitWebDriver` (`webkitgtk6.0`) | `webdriver-smoke.sh` | that suite skips/fails |
| **`xorg-x11-server-Xvfb`** | a private, always-mapped X display for test instances | **see below** |
| `ImageMagick` (`import`, `magick`) | screenshots of the app under Xvfb | no visual verification |
| `gcc` + `gtk4-devel`/`webkitgtk6.0-devel` | the standalone C probes (`inspector-probe.c`, `popup-probe.c`, `find-probe.c`) | probes cannot be rebuilt |

```sh
sudo dnf install -y python3 curl iproute xorg-x11-server-Xvfb ImageMagick
```

### Why Xvfb is not optional for the suites

A Ghostty surface spawns its shell on **first map**. On a real desktop
that depends on whether the test instance's window is actually on screen —
so terminal assertions become sensitive to occlusion, focus and load. On
2026-07-21 that produced a stretch where a newly created workspace's shell
never started and the app logged nothing, while the same binary passed
minutes earlier.

A virtual display removes the variable, and gives screenshots as a side
effect:

```sh
Xvfb :99 -screen 0 1400x900x24 &
env -u WAYLAND_DISPLAY DISPLAY=:99 GDK_BACKEND=x11 \
    CMUX_APP_ID=... CMUX_SOCKET_PATH=... CMUX_SESSION_PATH=... cmux-adw &
DISPLAY=:99 import -window root shot.png
```

`GDK_BACKEND=x11` **and** unsetting `WAYLAND_DISPLAY` are both required —
GTK4 prefers Wayland whenever that variable is set, and would ignore
`DISPLAY` entirely.

## Runtime environment variables

| Variable | Effect |
|---|---|
| `CMUX_APP_ID` | GApplication id — what makes a dev/test instance isolated from the daily |
| `CMUX_SOCKET_PATH` | control socket path (default `$XDG_RUNTIME_DIR/cmux.sock`) |
| `CMUX_SESSION_PATH` | session JSON path (default `$XDG_DATA_HOME/cmux/session-linux.json`) |
| `CMUX_TERM=vte` | force the VTE backend instead of embedded Ghostty |
| `CMUX_GHOSTTY=1` | **build-time**: link the Ghostty shim |
| `CMUX_GNOME=50` | **build-time**: target GNOME 50 (adwaita-swift `main`) |
| `CMUX_WEBDRIVER=1` | opt in to W3C WebDriver automation — **never default**, it lets any local driver drive the process |
| `WEBKIT_INSPECTOR_SERVER` | inspector server for WebDriver attach mode; bind `127.0.0.1` only |
| `GHOSTTY_RESOURCES_DIR` | shell integration resources; the binary self-locates this, override only when embedding oddly |

## Notes for a container image

- The socket and session paths must be writable; default to
  `CMUX_SOCKET_PATH=/tmp/...` inside a container rather than relying on
  `XDG_RUNTIME_DIR`.
- GPU is optional — the app runs under Xvfb with software rendering
  (`llvmpipe`); expect Vulkan loader chatter in the log, not an error.
- The `ghostty` submodule needs `git submodule update --init --recursive`
  and a Zig toolchain; a leaner image could ship VTE-only
  (`CMUX_TERM=vte`) and skip Zig entirely, at the cost of the default
  terminal backend.
- Nothing here needs privileged mode.
