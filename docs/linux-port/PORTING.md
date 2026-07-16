# cmux Linux Port — AppKit/SwiftUI → GTK4/libadwaita

Status: **Phase 0 ✅ and Phase 1 ✅ (control socket + CLI); Phase 2
(libghostty surface) started.** Code lives in [`linux/`](../../linux/);
the step-by-step log with verification evidence is in
[`PROGRESS.md`](PROGRESS.md).

Goal: keep the Swift core, replace every Apple framework with its GNOME
equivalent. UI is built with
[Adwaita for Swift](https://git.aparoksha.dev/aparoksha/adwaita-swift)
(SwiftUI-like API over libadwaita — a good fit, since ~half of cmux's UI is
SwiftUI), plus direct C interop (`CAdw`/system-library targets) where a widget
isn't wrapped (terminal surface, WebKitGTK).

## What cmux is, structurally

macOS app = Swift + AppKit/SwiftUI shell around **libghostty** (vendored
`ghostty.h`, submodule `ghostty/` → manaflow-ai/ghostty fork). The real build
is `GhosttyTabs.xcodeproj` (SPM `Package.swift` is a legacy stub). Extra deps:
Sparkle (updates), Sentry, PostHog, **Bonsplit** (NSView split/tab engine,
submodule `vendor/bonsplit`), WebKit (browser panels).

## The three big levers

1. **Ghostty already has a GTK4/libadwaita apprt.** On macOS, cmux hands
   libghostty a raw `NSView*` (`ghostty_platform_macos_s.nsview`) and ghostty
   renders via Metal/`CAMetalLayer`. cmux never draws a terminal cell itself.
   On Linux, libghostty renders via OpenGL into a GTK widget — the port swaps
   one platform struct + runtime callbacks and inherits ghostty's own
   input/rendering code. cmux's Metal/IOSurface/CVDisplayLink code is
   **discarded, not ported**.
2. **~2,900 lines vanish.** `TerminalWindowPortal`/`BrowserWindowPortal` exist
   only because AppKit can't composite Metal/WKWebView views inside SwiftUI
   (child-NSWindow overlay hack). GTK composites child widgets natively —
   delete. Same for traffic-light/window-chrome controllers
   (`WindowDecorationsController`, `WindowToolbarController`,
   `WindowDragHandleView`) → `AdwHeaderBar` + CSD.
3. **The control plane is already portable.** The AF_UNIX control socket
   server (`TerminalController`, v1 text + v2 JSON protocols, ~130 verbs) and
   the entire `CLI/cmux.swift` (6.5k lines incl. Claude Code hook integration)
   are Foundation + POSIX sockets. They compile on Linux nearly as-is.

## Subsystem disposition

| Subsystem (files) | macOS tech | Linux replacement | Effort |
|---|---|---|---|
| Terminal surface (`GhosttyTerminalView`) | NSView + Metal/IOSurface, `ghostty_surface_new(nsview:)` | libghostty GTK platform / GL area; reuse ghostty GTK apprt input translation | Medium (seam is narrow, code is big) |
| Splits & tab strips (Bonsplit, `Workspace`, `WorkspaceContentView`) | NSView-based vendor package | `AdwTabView`/`AdwTabBar` + nested `GtkPaned`, or **libpanel** (purpose-built IDE docking) — reimplement `BonsplitController` API (create/close/move/split/focus/treeSnapshot) over it | **Large** |
| Browser panels (`Panels/Browser*`, `CmuxWebView`) | WKWebView + Playwright-style automation (`browser.*` v2 verbs) | **WebKitGTK** (`webkitgtk-6.0`, GTK4) — different delegate/JS/cookie APIs | **Large** |
| Shell UI (`ContentView`, `cmuxApp`, `NotificationsPage`, sidebar) | SwiftUI | Adwaita for Swift (`OverlaySplitView`, `List`, `StatusPage`, …) | Medium |
| App lifecycle (`AppDelegate`, 7.9k lines) | NSApplicationDelegate god-object | `AdwaitaApp`/`GApplication` signals; most menu/dock/window-registration code shrinks | Medium |
| Control socket + CLI (`TerminalController` socket half, `CLI/cmux.swift`) | POSIX/Foundation | Same code; swap `/tmp/cmux.sock` → `$XDG_RUNTIME_DIR/cmux.sock`, `open -a cmux` → `gtk_window_present`/.desktop activation | Small |
| Notifications (`TerminalNotificationStore`) | UNUserNotificationCenter, `NSApp.dockTile.badgeLabel` | `GNotification`/libnotify; badge via Unity LauncherEntry D-Bus (optional); store logic portable | Small–Medium |
| Attention detection | ghostty `GHOSTTY_ACTION_DESKTOP_NOTIFICATION` (OSC 9/777) + CLI `notify` + bell | identical action arrives from libghostty on Linux | Small |
| Notification rings | `CAShapeLayer` stroked overlay | `GtkOverlay` + CSS border/animation | Small |
| Session persistence (`SessionPersistence`) | JSON in `~/Library/Application Support/cmux/` | same JSON schema in `$XDG_DATA_HOME/cmux/` | Small |
| Settings storage | UserDefaults/@AppStorage | GKeyFile/GSettings (or a JSON settings file to stay uniform) | Small |
| Keyboard (`KeyboardLayout`, `kVK_*` tables) | Carbon TIS/UCKeyTranslate, macOS virtual keycodes | GDK keymap/keyvals; rebuild constant tables | Medium |
| Port scanner (`PortScanner`) | `ps -t` + `lsof` | `/proc/net/tcp` + `/proc/<pid>`, or `ss -ltnp` | Small |
| Updater (`Update/*`, Sparkle) | Sparkle appcast | drop — Flatpak/rpm/AppImage channels | Delete |
| Keychain (socket password fallback) | Security.framework | libsecret, or keep file-based store only | Small |
| Sentry/PostHog | Cocoa SDKs | stub out initially; native SDKs exist | Small |
| Legacy `TerminalView.swift` (SwiftTerm) | dead fallback path | drop | Delete |

## Phases

- **Phase 0 — walking skeleton** ✅: Adwaita shell: window, vertical-tab
  sidebar with attention dots, tab CRUD, placeholder content pane. Proves
  toolchain (Swift 6.2 on Fedora) + adwaita-swift pin.
- **Phase 1 — control plane** ✅: AF_UNIX server in the app (v1 verbs + v2
  JSON subset, wire-compatible with macOS), shared `CLI/cmux.swift` compiled
  for Linux (Glibc shims behind `#if`), XDG socket path. Verified end-to-end:
  `cmux notify` lights sidebar attention dots. Remaining for later: password
  auth modes (`SocketControlSettings`), the long tail of v1/v2 verbs
  (send/read_screen/browser.* arrive with their subsystems).
- **Phase 2 — terminal surface** (started): libghostty **builds on Linux**
  from the fork (`zig build -Dapp-runtime=none`, zig 0.15.2), but its C API
  currently exposes only macOS/iOS platform embedding — no GTK variant
  (ghostty's Linux app links the Zig apprt directly). Plan: put a
  `TerminalSurfaceWidget` abstraction in front, ship **VTE-GTK4** first for a
  working terminal, then swap in Ghostty via a Zig C-shim around the fork's
  GTK apprt (or upstream's embedder API when it lands). Wire `SET_TITLE`,
  `PWD`, bell/`DESKTOP_NOTIFICATION` events into the tab model either way.
- **Phase 3 — attention pipeline**: `TerminalNotificationStore` port,
  `GNotification` delivery, sidebar dots + `GtkOverlay` rings, unread counts.
- **Phase 4 — splits & session**: Bonsplit-API reimplementation over
  `AdwTabView` + `GtkPaned` (evaluate libpanel first); session
  snapshot/restore incl. scrollback replay env vars.
- **Phase 5 — browser panels**: WebKitGTK panel + the `browser.*` automation
  verbs subset.
- **Phase 6 — polish/packaging**: keyboard shortcuts UI, settings dialog
  (`AdwPreferencesDialog`), Flatpak manifest, `.desktop` + icon,
  screenshots/README.

## Environment notes (this machine, Fedora 43)

- Swift 6.2 installed system-wide via Fedora's `swift-lang` package (there is
  also a swift.org ubi9 tarball at
  `~/.local/swift-toolchain/swift-6.2.4-RELEASE-ubi9/` from the initial
  bootstrap — redundant now, delete to reclaim ~5 GB if unneeded).
- gtk4-devel 4.20.4 ✓, libadwaita-devel 1.8.5 ✓ (GNOME 49).
- adwaita-swift **pinned to `664cadd`** — its `main` targets the GNOME 50 SDK
  (e.g. `gtk_picture_set_isolate_contents`) and fails against GTK 4.20
  headers. Bump the pin when Fedora ships GNOME 50.
- **GNOME 50 without leaving Fedora 43**: build in a Fedora 44 userland
  (verified: `fedora:44` has gtk4-devel 4.22.4 + libadwaita-devel 1.9.2),
  which also makes `swift-lang` installable without host sudo:

  ```sh
  toolbox create --distro fedora --release 44 cmux-gnome50
  toolbox enter cmux-gnome50
  sudo dnf install swift-lang gtk4-devel libadwaita-devel   # passwordless inside toolbox
  cd ~/cmux/linux && swift build    # $HOME and the Wayland socket are shared,
                                    # so `swift run cmux-adw` opens on the host desktop
  ```

  With that, drop the revision pin and track adwaita-swift `main`. A full VM
  (GNOME Boxes) is only needed to test against a complete GNOME 50 *shell*;
  for building and running the app, toolbox/podman is enough.
- Missing for later phases: `vte291-gtk4-devel` (only if a VTE stopgap is
  wanted), `webkitgtk6.0-devel` (Phase 5), zig matching the ghostty fork's
  build requirements (system zig is 0.16.0).
- License: cmux is AGPL-3.0 — the port must remain AGPL-3.0.

## Reference: the libghostty seam

macOS (`GhosttyTerminalView.swift`): `ghostty_init` →
`ghostty_config_new/load_default_files/finalize` →
`ghostty_app_new(&runtime_config, config)` with callbacks (`wakeup_cb`,
`action_cb`, clipboard cbs) → per tab `ghostty_surface_config_new()` with
`platform_tag = GHOSTTY_PLATFORM_MACOS`, `platform.macos.nsview = <NSView*>` →
`ghostty_surface_new`. Input goes in via `ghostty_surface_key/text/
mouse_pos/mouse_button`; actions come back via `action_cb`
(`NEW_SPLIT`, `SET_TITLE`, `PWD`, `DESKTOP_NOTIFICATION`, search, …).

The Linux port keeps this entire choreography and changes only the platform
struct + the widget the surface renders into.
