#!/usr/bin/env python3
"""Pretty-print `claude -p --output-format stream-json --verbose` for the
dogfood pane: show each tool call and text block live, and write the final
assistant message (the report) to the path in argv[1].

Reads JSONL on stdin. Live activity goes to stdout (the pane); the clean
report goes to the report file so the harness still saves plain markdown.
"""
import json
import sys

report_path = sys.argv[1] if len(sys.argv) > 1 else None
last_text = ""

def show(line):
    print(line, flush=True)

def clip(s, n=100):
    s = " ".join(str(s).split())
    return s if len(s) <= n else s[: n - 1] + "…"

for raw in sys.stdin:
    raw = raw.strip()
    if not raw:
        continue
    try:
        ev = json.loads(raw)
    except json.JSONDecodeError:
        continue

    typ = ev.get("type")
    if typ == "system" and ev.get("subtype") == "init":
        show(f"  ▸ session start · model {ev.get('model', '?')} · "
             f"tools: {', '.join(ev.get('tools', [])[:6])}")
        continue

    if typ == "assistant":
        for block in ev.get("message", {}).get("content", []):
            btype = block.get("type")
            if btype == "text" and block.get("text", "").strip():
                last_text = block["text"]
                for para in last_text.strip().split("\n"):
                    if para.strip():
                        show(f"  💬 {clip(para, 160)}")
            elif btype == "tool_use":
                name = block.get("name", "?")
                inp = block.get("input", {})
                if name == "Bash":
                    show(f"  $ {clip(inp.get('command', ''), 160)}")
                elif name in ("Read", "Grep", "Glob"):
                    tgt = inp.get("file_path") or inp.get("pattern") or inp.get("path") or ""
                    show(f"  🔎 {name} {clip(tgt)}")
                else:
                    show(f"  ⚙ {name} {clip(inp)}")
        continue

    if typ == "user":
        for block in ev.get("message", {}).get("content", []):
            if block.get("type") == "tool_result":
                content = block.get("content", "")
                if isinstance(content, list):
                    content = " ".join(
                        c.get("text", "") for c in content if isinstance(c, dict)
                    )
                first = clip(content, 120)
                if first:
                    show(f"    → {first}")
        continue

    if typ == "result":
        show("  ▸ session complete")
        # The final assistant text is the report.
        report = ev.get("result") or last_text
        if report_path and report:
            with open(report_path, "w") as f:
                f.write(report)
