# kb/ — distilled macOS-cmux product knowledge for the Linux port

> Crawled 2026-07-22 from https://cmux.com (docs, guides, blog, compare,
> changelog) **through the port's own browser stack** — one WebKitGTK surface,
> ~35 navigations, zero verb failures. Companion to CONCEPTS.md (intent),
> PARITY.md (verbs), UX-PARITY.md (presentation): these files hold the
> *contracts, schemas, and workflows* the docs specify, distilled, not dumped.

## Files

| File | One line |
|---|---|
| [claude-with-cmux.md](claude-with-cmux.md) | **Priority**: the intended Claude Code workflow end-to-end — wrapper-based integration, notification policy, resume/fork/reopen, claude-teams shim, omc/omo/omx, skills, Vault, TextBox |
| [tmux-compat.md](tmux-compat.md) | Shim tmux-verb ↔ cmux-verb ↔ Linux-port status table (every needed verb is ✅ on Linux); remote tmux mirror contract |
| [hierarchy-and-terminology.md](hierarchy-and-terminology.md) | Window→Workspace→Pane→Surface→Panel, the "tab"=workspace terminology contract, creation/id table |
| [configuration-schema.md](configuration-schema.md) | Every cmux.json schema family with load-bearing keys; actions/commands/layout trees; dock.json; trust model; schema JSON URL |
| [cli-reference.md](cli-reference.md) | Socket framing, access modes, CLI↔socket verb map, sidebar-metadata verbs, feature namespaces, deep links |
| [notifications-contract.md](notifications-contract.md) | Lifecycle, 3+1 suppression rules, OSC 777/99 formats, hooks stdin/stdout JSON, agent-event policy knobs, integration recipes |
| [session-restore-and-resume.md](session-restore-and-resume.md) | Restore boundary + mechanism, the 17-agent resume matrix verbatim, custom surface-resume bindings and their trust rules |
| [sidebar-and-groups.md](sidebar-and-groups.md) | Workspace-row anatomy (metadata pills, lanes, colors), full workspace-group contract + 16-verb CLI |
| [right-sidebar-instruments.md](right-sidebar-instruments.md) | The five modes (files/find/sessions/feed/dock): Vault, Dock, Feed, Finder, Task Manager |
| [browser-and-automation.md](browser-and-automation.md) | Automation grammar shape, auth story (passkeys + `browser import`), page modes, routing policy, remote proxying |
| [canvas-and-viewers.md](canvas-and-viewers.md) | Canvas freeform layout; markdown/diff/file viewers incl. review-comments→TextBox agent handoff |
| [fork-and-history.md](fork-and-history.md) | Fork Conversation + reopen-closed/focus-history/History pane — two loop features absent from CONCEPTS/PARITY |
| [remote-and-mobile.md](remote-and-mobile.md) | cmux ssh + cmuxd-remote relay architecture, detachable PTY, iOS pairing model |
| [philosophy-and-positioning.md](philosophy-and-positioning.md) | "Primitive, not a solution", super-repo pattern, supervision pitch, compare/agents page positioning |
| [feature-timeline.md](feature-timeline.md) | Changelog-derived timeline of when each big concept landed + upstream's recurring perf battles |

## How to re-crawl

Raw text captures live in the crawling session's scratchpad (not committed).
To refresh, drive any port browser surface:

```bash
export CMUX_QUIET=1
W=$(cmux new-workspace --cwd /tmp --background | grep -oE 'workspace:[0-9]+')
SURF=$(cmux --json browser open https://cmux.com/en/docs/concepts --workspace "$W" | grep -oE 'surface:[0-9]+' | head -1)
cmux browser "$SURF" wait --load-state complete --timeout-ms 15000
cmux browser "$SURF" get text body > page.txt
cmux browser "$SURF" eval "JSON.stringify([...document.querySelectorAll('a')].map(a=>a.getAttribute('href')).filter(h=>h&&h.startsWith('/')))"  # link discovery
```

Always use `/en/` URLs (the site locale-redirects otherwise). Docs pages also
exist as markdown/plain variants plus an `/llms.txt` index for agents
(changelog #3410). The machine-readable settings schema is
`https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json`.
Known dead URL: `/en/docs/agent-integrations` (section header, 404s as a page).
