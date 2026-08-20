# Draft: offer to upstream (manaflow-ai/cmux)

**Status:** draft, not sent. Written 2026-08-21.

**Where it should go:** a GitHub Discussion on `manaflow-ai/cmux` (or an
issue if Discussions are off). NOT a pull request — the point is to offer
Linux-specific artifacts and ask one question, without asking anyone to
adopt or maintain a 40k-line Swift/GTK port.

**Why this shape:** upstream is building a multiplatform v2
(`cmux-tui`: authoritative Rust core, frontends as clients, native macOS
frontend in the private `cmux-lite`). They will not adopt a Swift GUI
layer. What they *would* value is the language-agnostic Linux knowledge —
embedding, packaging, and the traps — and the small shared-code fixes the
port found. Timing matters: that knowledge is worth most while their
Linux GUI plans are still unformed. See COMPARISON.md for the three-way
concept survey behind this reasoning.

**Stamp check — done 2026-08-21** (COMPARISON.md refreshed the same
day): upstream moved 322 commits since the survey, 83 in `cmux-tui/`,
and **no Linux GUI frontend exists** — `frontends/` still holds only
`web`, and the native frontend effort is still the private macOS
`cmux-lite`. Public `cmux.protocol/2` unchanged. So this stays an
"offer", not a "compare notes". At ~30 commits/day, re-check
`cmux-tui/frontends/` if the message sits unsent for more than a few
days.

---

## Message body (paste from here)

**Subject / title:** Linux port of cmux — offering the GTK/Ghostty/Flatpak
groundwork, plus a question about v2's Linux frontend

Hi — I've been running a native Linux port of cmux since July: GTK4 /
libadwaita, VTE and embedded-Ghostty terminals, WebKitGTK browser panes,
speaking the existing socket protocol through the shared `CLI/cmux.swift`.
It's daily-driver software for me (I develop it inside itself), but it is
explicitly *not* at feature parity with the macOS app, and I am **not
proposing you merge it** — a large port in a UI stack you're moving away
from would be a maintenance burden, not a gift. It lives as a friendly
fork: `hiasihaho/cmux`, branch `linux-port`.

I'm writing because a few pieces the port produced are **language-agnostic
Linux groundwork** that would apply to any Linux frontend you build for
the v2 core, and they're yours if useful:

1. **A GTK embedding shim for Ghostty** (`hiasihaho/ghostty`, branch
   `linux-gtk-embed`; built with `zig build lib-gtk -Dapp-runtime=gtk`).
   It exposes a small C API — `ghostty_embed_init`,
   `ghostty_embed_surface_new{,_with_command}`, `…_ensure_started`,
   `…_read_text`, `…_send_text`, `…_write_display`, `…_set_search`,
   `…_reload_config` — so a host app can put real Ghostty surfaces in a
   GTK widget tree, spawn them eagerly for never-shown panes, and drive
   them programmatically. Being a C API, it's consumable from Rust as
   easily as from Swift.

2. **A working Flatpak recipe** for a GTK + Ghostty + WebKit app:
   GNOME 49 runtime, the freedesktop Swift SDK extension, VTE and
   `gtk4-layer-shell` as modules, Ghostty built from source inside the
   sandbox, and host shells through the `org.freedesktop.Flatpak` portal.
   Two findings that cost me builds and would cost anyone else the same:
   Ghostty's own `-Dflatpak=true` (`FlatpakHostCommand`) is what makes
   panes host shells — wrapping the command in `flatpak-spawn --host`
   yourself fails by construction, because Ghostty already runs it on the
   host where there's no portal to call; and a `ReleaseFast` shim
   SIGSEGVs in `ghostty_embed_init` where the default Debug build is
   fine.

3. **A trap catalogue** from porting the product shape to GTK — Vulkan
   fence hangs on virtio-GPU (venus) during widget teardown, pty-write
   readiness vs. async spawn, portal environment truncation, GTK
   reparenting during pane moves. It's in
   `docs/linux-port/PROGRESS.md` and the per-feature docs; happy to
   distil any of it into a form you'd actually want.

I also have a handful of **small fixes to shared code** that the port
surfaced and that apply to macOS too — the one I'd send first is a
`WorkstreamSource` fallback: an unregistered `_source` currently inherits
`claude`'s identity, which makes an unknown emitter indistinguishable
from a known one in the feed. Happy to open that as a small standalone PR
if you'd like it.

**My question:** does the v2 plan include a native Linux GUI frontend,
and if so, is any of the above useful to you? I ask because it changes
what I do next. If Linux GUI is on your roadmap, I'd rather feed you what
I've learned (and eventually look at making my GTK frontend a client of
`cmux.protocol/2` instead of carrying its own control plane) than keep
building a parallel implementation. If it isn't, I'll keep the fork
running for Linux users who want a desktop cmux today, and stay out of
your way.

Either way: thanks for cmux. Porting it was the most enjoyable way to
learn how carefully it's built.

— hias
