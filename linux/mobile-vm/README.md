# cmux mobile test VM — harness

A reproducible phone-test environment for the cmux mobile path, built on the
Fedora host with libvirt: an **Ubuntu 26.04 / GNOME 50** VM in the adminvm
devbox "minimal GNOME" shape, the mobile spike installed as a **flatpak**, one
**headless gnome-remote-desktop session per test user** (no GDM screen — the
Guacamole login lands directly in the running app), and **Guacamole on the
host** with real touch forwarding and the ☰ menu tab.

This is the gift for the Hetzner/Incus session: everything below the VM
boundary is theirs (image, network, bootstrap); everything inside the VM
and on the Guacamole side is here, as scripts they can lift into their
playbook. Written 2026-11-05 against the spec pasted by hias (images:
ubuntu/26.04/cloud, GNOME 50 without Recommends, virtio-gpu, flatpak on
org.gnome.Platform//49).

## Files

| file | runs on | does |
|---|---|---|
| `vm.sh` | host | lifecycle: `image` (cloud image → pool), `create` (overlay + cloud-init + virt-install), `flatpak` (spike bundle), `runtime` (GNOME 49 runtime bundle from the host — Flathub is ≈230 KB/s from here, the Ubuntu archive 9 MB/s), `provision`, `guac`, `ip/ssh/start/stop/status/destroy`, `all` |
| `provision.sh` | VM, root | apt minimal GNOME + gnome-remote-desktop, flatpak runtime + spike bundle, per-user headless RDP session with the spike as autostart; idempotent |
| `guac.sh` | host | Guacamole pod (guacd + web, podman rootless), one connection per user → headless port, `enable-touch`, menu-hint extension |
| `cmux-mobile-scale.py` | VM, user session | pins the virtual monitor to 200 % on every monitor change |
| `menu-hint/` | — | Guacamole extension: ☰ edge tab toggling the menu; menu capped so the tab stays free |
| `../flatpak/com.manaflow.cmux.mobile.yml` | host | manifest for the spike (`MobileWorkflow` from `linux/poc/mobile-carousel`), same pins as the cmux manifest |

Pinned inputs live at the top of `vm.sh` (image URL, memory, users,
ports, DEV-ONLY password) and in the manifest (runtime 49, swift6 25.08,
vte 0.82.3). Nothing version-shaped anywhere else.

## Run

```sh
cd ~/cmux-mobile
linux/mobile-vm/vm.sh all            # ≈ 15 min first time (image 860 MB, GNOME apt, runtime 1 GB)
# or step by step: image → create → flatpak → provision → guac
sudo firewall-cmd --add-port=8080/tcp   # phone on the WLAN; remove again after
```

Phone: `http://<host LAN IP>:8080/guacamole`, login `poc`/`poc`, open
"mobile — cmux mobile (touch)". Guacamole menu via the ☰ tab on the right
edge → input mode **Touchscreen** → fingers arrive as touch (two-finger
scroll, pinch) instead of a mouse.

Re-run `provision` after changing `provision.sh` or the bundle; re-run
`guac` after changing users/ports/menu-hint. `destroy` keeps the base
image, so a fresh VM is a two-minute `create`.

## What the headless session is

`gnome-headless-session@<user>.service` (shipped by gnome-remote-desktop)
runs a GNOME session for that user with no seat; `gnome-remote-desktop
--headless` inside it serves RDP on the user's own port (3390 + index)
with credentials from `grdctl --headless rdp set-credentials` — these
are separate from the Linux password. The session persists across
client disconnects, the spike (autostart) keeps running, and reconnecting
shows it as left. The system "Remote Login" mode (GDM greeter) is NOT
used: it takes over a local session of the same user (bit us on the
Fedora host 2026-11-04) and always shows the greeter.

## Traps recorded while building this

- **pasta gives the pod the host's own LAN IP** — a Guacamole connection
  to `<LAN IP>:3389` from inside the pod hits the pod itself ("Server
  refused connection"). For a HOST-side RDP target use 169.254.1.2
  (`host.containers.internal`); the VM target here is unaffected.
- **Touch over RDP needs both ends**: Guacamole `enable-touch=true`
  (RDPEI, since 1.4, default off) and gnome-remote-desktop ≥ 49 (Debian
  13's 48.1 cannot; GNOME 50 can).
- **Flatpak bus name**: the spike must run with
  `MOBILE_APP_ID=com.manaflow.cmux.mobile` (wrapper sets it) — a flatpak
  may only own names under its app id, otherwise GApplication fails with
  a bare "ServiceUnknown".
- **ostree min-free-space-percent**: 3 % of a 1.5 TB disk is 45 GB; on a
  99 %-full host the EXPORT fails after a complete build. `vm.sh flatpak`
  sets the local repo's reserve to 0.
- **Guacamole menu on phones**: no Ctrl+Alt+Shift, the left-edge swipe
  collides with Android's back gesture → menu-hint tab. Tapping it again
  closes the menu; the menu is capped to `100% − 36px` so the tab stays
  reachable.
- **mutter 50.1 crashes on a title-bar double-tap over libei touch**
  (reproduced twice 2026-11-05: segfault in libmutter right after
  gnome-remote-desktop logs "Bug: ei_touch_up: device is not emulating";
  the session dies, Guacamole shows nothing). Mitigations in the harness:
  `action-double-click-titlebar=none` for the test users, the spike starts
  fullscreen (`MOBILE_FULLSCREEN=1`), the session unit has
  `Restart=always`, and guac.sh offers a mouse-emulation twin connection.
  Everything else over touch worked (two-finger scroll, taps). Candidate
  for a GNOME bug report with a backtrace. Second round (hias): any
  touch on an EMPTY header-bar spot crashes too — that is GTK asking the
  compositor for a window move. The spike now claims such presses in a
  capture-phase gesture on every header bar (buttons still work), so no
  move request ever leaves the app.
- **Scale**: mutter offers 200 % only when the virtual monitor's height
  is EVEN (verified 2026-11-05 with a FreeRDP client replaying a browser
  resize storm: 1884/1856 → 2.0 on offer, odd 1857 → only [1.0]). A phone
  reporting an odd height under dynamic sizing (iPhone mini) therefore
  lands at 100 % ("alles winzig"). Two parts fix it: `cmux-mobile-scale.py`
  (autostart per user) applies `MOBILE_SCALE` (default 2) over
  org.gnome.Mutter.DisplayConfig, debounced to fire once the monitor has
  been quiet ~2 s (applying mid-resize froze the session — that was the
  earlier "frozen desktop", NOT the spike's header guard); and
  `GUAC_FORCE_SIZE=WxH` on guac.sh pins an even resolution so 200 % is
  always offered, at the cost of per-device dynamic fit. Fractional
  scaling (`experimental-features=['scale-monitor-framebuffer']`) is on
  but does not rescue an odd height.
- **The spike re-requests fullscreen on every monitor change**: a headless
  session has no monitor until a client connects, and each resize is a
  monitor remove+add, so a one-shot fullscreen at startup came up
  windowed. The spike now hooks GdkMonitors items-changed.
- **Testing with a mouse-emulated pointer**: the bottom toggle of the
  spike moves between panes (key row hidden on the preview); aim by
  screenshot, not by memory.

## Open

- Verify on the VM: touch reaches GTK (placeholder page reports
  `touch: ja`), pinch in WebKit, edge-strip swipe as a real finger
  gesture.
- Software rendering only (virtio-gpu, no venus): acceptable for the UX
  verdict, not a performance statement.
- The real product delivery is cmux-adw's mobile mode (POC 0004 step 3),
  which replaces the spike flatpak with the cmux flatpak + a breakpoint.
