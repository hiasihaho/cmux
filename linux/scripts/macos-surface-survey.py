#!/usr/bin/env python3
"""Survey the macOS cmux app's *enumerable* surface and diff it against the
reviewed coverage ledger — the app-side twin of capabilities-sweep.py.

    linux/scripts/macos-surface-survey.py            # human report
    linux/scripts/macos-surface-survey.py --json     # machine output
    linux/scripts/macos-surface-survey.py --check     # exit 1 on untriaged drift

WHY THIS EXISTS. capabilities-sweep.py catches new *CLI verbs* after a merge.
But macOS also grows commands, panel types, and settings sections that are not
verbs — and those are where "we didn't know macOS had that" hides. Since the
2026-07-22 catch-up merge, the macOS Sources/ live in this same tree, so we can
extract those enumerable sets directly and diff them against a reviewed ledger.

Re-run after every upstream merge (alongside the capabilities sweep). The
extraction is mechanical; the ledger records each item's Linux disposition
(done | gap | later | na). The tool reports:

  * NEW   — a macOS item not in the ledger → a merge added it, triage it.
  * STALE — a ledger item macOS no longer defines → drift, clean it up.
  * a coverage summary per dimension and disposition.

The value is the FIRST two: they are the automated "what changed on macOS"
signal. Everything else is a snapshot the ledger already reviewed.
"""
import json
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
LEDGER = os.path.join(ROOT, "docs", "linux-port", "macos-surface-ledger.json")

# (dimension, source file, extractor). Each extractor returns a set of
# identifiers. Kept deliberately small and mechanical — a brittle regex that
# silently returns [] would fake "no drift", so each asserts a sane minimum.
def _enum_cases(path, enum_marker, minimum):
    """Case identifiers of the first enum whose declaration matches enum_marker,
    splitting comma-joined `case a, b` and stripping raw-value overrides."""
    text = open(os.path.join(ROOT, path)).read()
    lines = text.splitlines()
    out, inside = [], False
    for ln in lines:
        if not inside:
            if re.search(enum_marker, ln):
                inside = True
            continue
        if re.match(r"^\s*\}", ln) and out:
            break
        m = re.match(r"^\s*case\s+(.+)$", ln)
        if not m:
            continue
        for part in m.group(1).split(","):
            ident = part.strip().split("=")[0].split("(")[0].strip()
            if ident and re.match(r"^[A-Za-z_]\w*$", ident):
                out.append(ident)
    if len(out) < minimum:
        sys.exit(f"survey: extractor for {path} found {len(out)} (< {minimum}) "
                 f"— the enum shape changed; fix the regex before trusting this.")
    return set(out)

DIMENSIONS = {
    "commands": lambda: _enum_cases(
        "Sources/KeyboardShortcutSettings.swift", r"enum Action\b.*:", 100),
    "panel_types": lambda: _enum_cases(
        "Sources/Panels/Panel.swift", r"enum PanelType\b.*:", 8),
    "settings_sections": lambda: _enum_cases(
        "Sources/SettingsNavigation.swift", r"enum SettingsNavigationTarget\b.*:", 12),
}


def main():
    as_json = "--json" in sys.argv
    check = "--check" in sys.argv
    ledger = json.load(open(LEDGER))
    report = {}
    untriaged = 0

    for dim, extract in DIMENSIONS.items():
        live = extract()
        reviewed = {k: v for k, v in ledger.get(dim, {}).items()
                    if isinstance(v, dict) and "disposition" in v}
        new = sorted(live - set(reviewed))
        stale = sorted(set(reviewed) - live)
        by_disp = {}
        for k, v in reviewed.items():
            if k in live:
                by_disp.setdefault(v["disposition"], []).append(k)
        untriaged += len(new)
        report[dim] = {
            "macos_total": len(live),
            "reviewed": len(reviewed),
            "new_untriaged": new,
            "stale_ledger_only": stale,
            "coverage": {d: len(v) for d, v in sorted(by_disp.items())},
        }

    if as_json:
        print(json.dumps(report, indent=1))
    else:
        for dim, r in report.items():
            print(f"\n== {dim}: {r['macos_total']} on macOS")
            cov = r["coverage"]
            done = cov.get("done", 0)
            print("   coverage: " + " · ".join(f"{d}={n}" for d, n in cov.items())
                  + f"   (done {done}/{r['macos_total']} = {100*done//max(1,r['macos_total'])}%)")
            if r["new_untriaged"]:
                print("   ⚠ NEW (triage — a merge added these):")
                for k in r["new_untriaged"]:
                    print(f"       {k}")
            if r["stale_ledger_only"]:
                print("   • STALE (macOS no longer defines — clean up ledger):")
                for k in r["stale_ledger_only"]:
                    print(f"       {k}")
        print(f"\nuntriaged drift: {untriaged}"
              + ("" if untriaged else "  — ledger is in sync with macOS"))

    if check and untriaged:
        sys.exit(1)


if __name__ == "__main__":
    main()
