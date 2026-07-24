#!/usr/bin/env python3
"""Generate the features-board atlas (ADR-0011): measured status columns
over authored feature pages.

    linux/scripts/features-board.py            # write features/_board.md + index.json
    linux/scripts/features-board.py --check    # exit 1 on unknown verbs / generator error

Each page in docs/linux-port/features/NN-<slug>.md carries front matter:

    ---
    title: Browser tabs per pane
    area: browser
    mac: full | partial | none        # feature-level judgment (authored)
    linux: full | partial | none      # feature-level judgment (authored)
    verbs: a.b, c.d                   # socket methods the feature maps to
    ---

The generator computes per-verb reality from SOURCE via capslib (same
parsing as capabilities-sweep.py): Linux-dispatched, macOS-present
(advertised ∪ CLI-sent), and DAILY-present from the promote manifest
(`promote-daily.json` in the cmux state dir, stamped by promote.sh).
Where an authored claim contradicts measurement (linux: full but a
mapped verb isn't dispatched), the row gets a ⚠ — surfacing the
contradiction is the board's job.

_board.md and index.json are GENERATED and gitignored — machine-local
state (the daily manifest) feeds them, so they are regenerated rather
than committed; atlas-serve.sh regenerates on serve. Only unknown verb
names (typos: matching neither side) hard-fail, so --check gates in any
checkout without local state.
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import capslib

FEAT = os.path.join(capslib.ROOT, "docs", "linux-port", "features")
GLYPH = {"full": "✅", "partial": "🟡", "none": "❌", "": "—"}


def parse_front_matter(text, fn):
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not m:
        raise SystemExit(f"features-board: {fn} has no front matter")
    fm = {}
    for line in m.group(1).splitlines():
        k, _, v = line.partition(":")
        fm[k.strip()] = v.strip()
    fm["verbs"] = [v.strip() for v in fm.get("verbs", "").split(",") if v.strip()]
    return fm


def load_pages():
    pages = []
    for fn in sorted(os.listdir(FEAT)):
        if re.match(r"^\d{2}-.*\.md$", fn):
            pages.append((fn, parse_front_matter(open(os.path.join(FEAT, fn)).read(), fn)))
    return pages


def daily_manifest():
    state = os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state"))
    path = os.path.join(state, "cmux", "promote-daily.json")
    try:
        return json.load(open(path))
    except (OSError, ValueError):
        return None


def verb_marks(verbs, in_set):
    n = sum(1 for v in verbs if v in in_set)
    return n, len(verbs)


def main():
    check = "--check" in sys.argv
    served = capslib.linux_served()
    mac = capslib.mac_methods()
    manifest = daily_manifest()
    daily = set(manifest["methods"]) if manifest else None
    pages = load_pages()

    # Typo guard: a verb matching neither server NOR the shared CLI is a
    # misspelling. cli_sent() belongs here (not in the mac column) — it
    # proves the name exists, not that macOS serves it.
    unknown = sorted({v for _, fm in pages for v in fm["verbs"]}
                     - served - mac - capslib.cli_sent())
    if unknown:
        print("features-board: unknown verbs (typo? not in Linux dispatch nor macOS):")
        for v in unknown:
            print(f"  {v}")
        sys.exit(1)

    # ---- _board.md ------------------------------------------------------
    daily_src = (f"promoted {manifest['date']} @ {manifest['git_sha'][:10]}"
                 if manifest else "no promote manifest — run promote.sh")
    lines = [
        "# Features board",
        "",
        "**GENERATED** by `linux/scripts/features-board.py` — do not edit.",
        "Status columns are *measured* from source and the promote manifest;",
        "descriptions live in the authored per-feature pages (ADR-0011).",
        "",
        f"- **dev** = the checkout's dispatch tables (what `swift build` builds)",
        f"- **daily** = the running daily instance ({daily_src})",
        "- mac/linux glyphs are the pages' authored judgment; ⚠ = it",
        "  contradicts the per-verb measurement — trust the verbs, fix the page",
        "- **Unique** column: ★ verb-verified (mapped verbs absent from macOS),",
        "  ★ᵃ authored-only (no verb to measure), ⚠ = claims unique but macOS",
        "  serves the mapped verbs — a FALSE claim.",
        "",
        "Three kinds (ADR-0014): **product** = leaf user features; **inbuilt**",
        "= product subsystems that are themselves frameworks (measured vs macOS",
        "the same way); **meta** = the dev tooling we built to develop/measure/",
        "verify the port (measured by existence + `--check`, NOT vs macOS).",
    ]
    by_kind = {"product": [], "inbuilt": [], "meta": []}
    for fn, fm in pages:
        by_kind.get(fm.get("kind", "product"), by_kind["product"]).append((fn, fm))

    uniques = []   # (fn, fm, note) — port-unique product/inbuilt features

    def measured_table(section_pages):
        """The mac/Unique/Linux/verbs table — for product + inbuilt (both
        map to socket verbs and are compared against macOS)."""
        rows = ["| Feature | Area | macOS | Unique | Linux | Verbs (dev) | Verbs (daily) |",
                "|---|---|---|---|---|---|---|"]
        for fn, fm in section_pages:
            verbs = fm["verbs"]
            dev_n, total = verb_marks(verbs, served)
            mac_n, _ = verb_marks(verbs, mac)
            warn = ""
            if fm.get("linux") == "full" and dev_n < total:
                warn = " ⚠"
            if fm.get("linux") == "none" and dev_n == total and total:
                warn = " ⚠"
            uniq_cell = ""
            if fm.get("mac") == "none":
                if not verbs:
                    uniq_cell = "★ᵃ"; uniques.append((fn, fm, "authored — no verb to measure"))
                elif mac_n == 0:
                    uniq_cell = "★"; uniques.append((fn, fm, "verb-verified — macOS serves none of its verbs"))
                else:
                    uniq_cell = "⚠ false"; uniques.append((fn, fm, f"CLAIM SUSPECT — macOS serves {mac_n}/{total} of its verbs"))
            if daily is not None and verbs:
                daily_n, _ = verb_marks(verbs, daily)
                daily_cell = f"{daily_n}/{total}" + (" ◐ dev ahead" if daily_n < dev_n else "")
            else:
                daily_cell = "?" if verbs else "–"
            dev_cell = f"{dev_n}/{total}" if verbs else "–"
            rows.append(
                f"| [{fm['title']}]({fn}) | {fm.get('area', '')} "
                f"| {GLYPH.get(fm.get('mac', ''), '?')} | {uniq_cell} "
                f"| {GLYPH.get(fm.get('linux', ''), '?')}{warn} "
                f"| {dev_cell} | {daily_cell} |")
        return rows

    if by_kind["product"]:
        lines += ["", "## Product features (leaf, vs macOS)", ""] + measured_table(by_kind["product"])
    if by_kind["inbuilt"]:
        lines += ["", "## Inbuilt harnesses (product frameworks, vs macOS)", ""] + measured_table(by_kind["inbuilt"])

    # Meta harnesses: dev tooling — not user features, not measured by verbs.
    # Measured by "does its --check pass / does the script exist" and what it
    # detects; no Unique-vs-macOS column (comparing our dev tooling to macOS's
    # product is a category error).
    if by_kind["meta"]:
        lines += ["", "## Meta harnesses (dev tooling we built)", "",
                  "The harness that develops, measures, and verifies the port — "
                  "not shipped features. Compared to macOS by *nature* (some, like "
                  "the test gate, mirror cmux's own tooling; some, like the drift "
                  "sweeps, are port-specific), so no vs-macOS column.", "",
                  "| Harness | Area | What it detects / does | Verify | ADR |",
                  "|---|---|---|---|---|"]
        for fn, fm in by_kind["meta"]:
            chk = f"`{fm['check']}`" if fm.get("check") else "–"
            adr = f"[{fm['adr']}](../adr/{fm['adr']}-*.md)" if fm.get("adr") else "–"
            # link to the exact adr file if resolvable
            if fm.get("adr"):
                import glob as _g
                hit = _g.glob(os.path.join(capslib.ROOT, "docs", "linux-port", "adr", f"{fm['adr']}-*.md"))
                if hit:
                    adr = f"[{fm['adr']}](../adr/{os.path.basename(hit[0])})"
            lines.append(f"| [{fm['title']}]({fn}) | {fm.get('area','')} "
                         f"| {fm.get('detects','')} | {chk} | {adr} |")

    # ---- Unique to cmux-adw (product + inbuilt only) --------------------
    lines += ["", "## Unique to cmux-adw (not in macOS)", ""]
    if uniques:
        lines.append("Product/inbuilt features the port has that macOS cmux does "
                     "not — `mac: none`, cross-checked against the measured macOS "
                     "verb set where verbs exist:")
        lines.append("")
        for fn, fm, note in uniques:
            lines.append(f"- **[{fm['title']}]({fn})** ({fm.get('area','')}) — {note}")
    else:
        lines.append("*No `mac: none` feature pages yet.*")

    lines += ["", "## Verb detail", ""]
    for fn, fm in pages:
        if not fm["verbs"]:
            continue
        lines.append(f"### {fm['title']}")
        lines.append("")
        lines.append("| Verb | macOS | Linux dev | daily |")
        lines.append("|---|---|---|---|")
        for v in fm["verbs"]:
            d = ("?" if daily is None else ("✓" if v in daily else "✗"))
            lines.append(f"| `{v}` | {'✓' if v in mac else '✗'} "
                         f"| {'✓' if v in served else '✗'} | {d} |")
        lines.append("")

    board = "\n".join(lines) + "\n"

    # ---- index.json (grouped: board, then product / inbuilt / meta) ------
    index = [{"atlas": "Features board"},
             {"file": "_board.md", "title": "◆ Feature board (generated)"}]
    for kind, glyph in (("product", "▪"), ("inbuilt", "◆"), ("meta", "⚙")):
        index += [{"file": fn, "title": f"{glyph} {fm['title']}"} for fn, fm in by_kind[kind]]
    index_json = json.dumps(index, ensure_ascii=False, indent=2) + "\n"

    if check:
        print(f"features-board: OK ({len(pages)} pages, no unknown verbs)")
        return
    open(os.path.join(FEAT, "_board.md"), "w").write(board)
    open(os.path.join(FEAT, "index.json"), "w").write(index_json)
    print(f"wrote {FEAT}/_board.md + index.json "
          f"({len(pages)} features, daily: {'manifest ' + manifest['git_sha'][:10] if manifest else 'unknown'})")


if __name__ == "__main__":
    main()
