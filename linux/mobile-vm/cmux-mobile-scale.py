#!/usr/bin/env python3
"""Pin the headless session's virtual monitor to a fixed scale (default 200 %).

mutter derives the scale of gnome-remote-desktop's virtual monitor from the
pixel size the RDP client reports: a Pixel 10 Pro gets 200 %, an iPhone mini
100 % ("alles winzig", hias 2026-11-05). This watches
org.gnome.Mutter.DisplayConfig and re-applies the wanted scale whenever the
monitor changes (connect, rotate, resize). Runs as an autostart entry in the
test user's session; MOBILE_SCALE overrides the factor.
"""
import os
import sys

import gi
gi.require_version("Gio", "2.0")
gi.require_version("GLib", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

WANTED = float(os.environ.get("MOBILE_SCALE", "2"))
BUS_NAME = "org.gnome.Mutter.DisplayConfig"
OBJ_PATH = "/org/gnome/Mutter/DisplayConfig"
IFACE = "org.gnome.Mutter.DisplayConfig"


def log(msg):
    print(f"cmux-mobile-scale: {msg}", flush=True)


def apply(proxy):
    state = proxy.call_sync("GetCurrentState", None, Gio.DBusCallFlags.NONE, -1, None)
    serial, monitors, logical, _props = state.unpack()
    if not monitors or not logical:
        return
    connector, vendor, product, mserial = monitors[0][0]
    modes = monitors[0][1]
    current = next((m for m in modes if m[6].get("is-current")), modes[0])
    mode_id, _w, _h, _rate, _pref_scale, supported, _mprops = current
    x, y, scale, transform, primary, _mons, _lprops = logical[0]
    if abs(scale - WANTED) < 0.01:
        return
    if not any(abs(s - WANTED) < 0.01 for s in supported):
        log(f"scale {WANTED} not offered for {mode_id} (offered {supported}), leaving {scale}")
        return
    config = GLib.Variant(
        "(uua(iiduba(ssa{sv}))a{sv})",
        (serial, 1,  # method 1 = temporary (the next connect re-applies anyway)
         [(x, y, WANTED, transform, primary, [(connector, mode_id, {})])],
         {}),
    )
    proxy.call_sync("ApplyMonitorsConfig", config, Gio.DBusCallFlags.NONE, -1, None)
    log(f"{connector} {mode_id}: scale {scale} -> {WANTED}")


def main():
    proxy = Gio.DBusProxy.new_for_bus_sync(
        Gio.BusType.SESSION, Gio.DBusProxyFlags.NONE, None, BUS_NAME, OBJ_PATH, IFACE, None)

    def on_signal(_proxy, _sender, signal, _params):
        if signal == "MonitorsChanged":
            try:
                apply(proxy)
            except GLib.Error as e:  # a config can race the next change; the next signal retries
                log(f"apply failed: {e}")

    proxy.connect("g-signal", on_signal)
    try:
        apply(proxy)
    except GLib.Error as e:
        log(f"initial apply failed: {e}")
    GLib.MainLoop().run()


if __name__ == "__main__":
    sys.exit(main())
