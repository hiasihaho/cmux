#!/usr/bin/env python3
"""Pin the headless session's virtual monitor to a fixed scale (default 200 %).

mutter derives the scale of gnome-remote-desktop's virtual monitor from the
pixel size the RDP client reports: a Pixel 10 Pro gets 200 %, an iPhone mini
100 % ("alles winzig", hias 2026-11-05). This watches
org.gnome.Mutter.DisplayConfig and applies the wanted scale once the monitor
has been QUIET for a while.

Why the quiet period (2026-11-05, second phone round): a phone browser
reports several sizes within seconds while its toolbars slide away
(1884 → 1857 → 1656 → 1857 px). Each one is a monitor removal + addition in
mutter. Applying a scale in the middle of that storm fought the next resize
and froze the session's input. So: debounce, apply at most once per monitor
appearance, never while the monitor is changing.

Runs as an autostart entry in the test user's session; MOBILE_SCALE overrides
the factor, MOBILE_SCALE_SETTLE the quiet time in seconds.
"""
import os
import sys

import gi
gi.require_version("Gio", "2.0")
gi.require_version("GLib", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

WANTED = float(os.environ.get("MOBILE_SCALE", "2"))
SETTLE_MS = int(float(os.environ.get("MOBILE_SCALE_SETTLE", "2")) * 1000)
BUS_NAME = "org.gnome.Mutter.DisplayConfig"
OBJ_PATH = "/org/gnome/Mutter/DisplayConfig"
IFACE = "org.gnome.Mutter.DisplayConfig"

pending = None          # GLib timeout id of the settle timer
applied_for = None      # mode id we already applied to (once per appearance)


def log(msg):
    print(f"cmux-mobile-scale: {msg}", flush=True)


def apply(proxy):
    global applied_for
    state = proxy.call_sync("GetCurrentState", None, Gio.DBusCallFlags.NONE, -1, None)
    serial, monitors, logical, _props = state.unpack()
    if not monitors or not logical:
        applied_for = None
        return
    connector, _vendor, _product, _mserial = monitors[0][0]
    modes = monitors[0][1]
    current = next((m for m in modes if m[6].get("is-current")), modes[0])
    mode_id, _w, _h, _rate, _pref_scale, supported, _mprops = current
    x, y, scale, transform, primary, _mons, _lprops = logical[0]
    if abs(scale - WANTED) < 0.01 or applied_for == mode_id:
        return
    applied_for = mode_id
    if not any(abs(s - WANTED) < 0.01 for s in supported):
        log(f"scale {WANTED} not offered for {mode_id} (offered {supported}), leaving {scale}")
        return
    config = GLib.Variant(
        "(uua(iiduba(ssa{sv}))a{sv})",
        (serial, 1,  # method 1 = temporary; the next appearance is handled again
         [(x, y, WANTED, transform, primary, [(connector, mode_id, {})])],
         {}),
    )
    proxy.call_sync("ApplyMonitorsConfig", config, Gio.DBusCallFlags.NONE, -1, None)
    log(f"{connector} {mode_id}: scale {scale} -> {WANTED}")


def schedule(proxy):
    global pending
    if pending is not None:
        GLib.source_remove(pending)

    def fire():
        global pending
        pending = None
        try:
            apply(proxy)
        except GLib.Error as e:
            log(f"apply failed: {e}")
        return False

    pending = GLib.timeout_add(SETTLE_MS, fire)


def main():
    proxy = Gio.DBusProxy.new_for_bus_sync(
        Gio.BusType.SESSION, Gio.DBusProxyFlags.NONE, None, BUS_NAME, OBJ_PATH, IFACE, None)

    def on_signal(_proxy, _sender, signal, _params):
        global applied_for
        if signal == "MonitorsChanged":
            applied_for = None   # a change means a (re)appearance: one new attempt
            schedule(proxy)

    proxy.connect("g-signal", on_signal)
    schedule(proxy)
    GLib.MainLoop().run()


if __name__ == "__main__":
    sys.exit(main())
