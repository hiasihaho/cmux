# UX-Parity — how it looks and feels, macOS vs the port

**What this file is:** the presentation/interaction comparison.
[PARITY.md](PARITY.md) says what the port *can do*,
[CONCEPTS.md](CONCEPTS.md) says what features are *for*; this file says
how the two apps *look and behave* — so every visible difference is a
recorded decision, never an accident.

**Verdicts:**
- ✅ **parity** — matches in substance (pixel-identical is not the goal)
- 🎨 **deliberate** — our own way, rationale recorded (GNOME HIG and
  libadwaita idiom are legitimate reasons; muscle-memory-relevant
  *placement* needs a stronger one than *styling*)
- ❓ **drift** — different, nobody decided → each row needs a decision
- ❌ **missing** — macOS has UI we lack; build it or 🎨-justify not to

**Rules:** any commit that changes visible UI updates its row here in
the same commit. ❓ rows graduate to 🎨 (decision recorded) or to a
GAPS row. Sources: code surveys of `Sources/` (macOS) and
`linux/Sources/CmuxAdw/` (Linux), 2026-07-22. The macOS side is
code-derived — no macOS machine here; AWS builders can screenshot-
confirm details when a row's fix lands.

**Guiding line (decided 2026-07-22):** *interaction* parity — what you
can reach and where it logically lives — is near-sacred; *presentation*
is negotiable. A GTK app cosplaying macOS feels wrong on GNOME; a
feature hiding in an unexpected place is a real cost anywhere.

## 1. Window chrome

| Aspect | macOS | Linux port | Verdict |
|---|---|---|---|
| Titlebar | hidden native titlebar; custom 28pt band (workspace title, drag, folder-drag icon); controls cluster beside traffic lights: sidebar toggle, bell+unread badge, new-workspace split button, focus back/fwd | stock Adw header bars on sidebar + content | 🎨 header bars are correct GNOME; band-vs-bar is styling |
| Chrome density | near-zero persistent buttons; nav lives in menus/shortcuts; hold-⌘ reveals hint pills | **14 always-visible buttons** in the content header (incl. 4 nav arrows, debug button) | ❓ **decide: header diet** — keep ~5 core (sidebar, split×2, browser, prefs), move the rest behind a GNOME primary menu + shortcuts |
| Unread surfacing in chrome | bell button with numeric badge → popover | subtitle text "N unread" + sidebar-header toggle | ❓ close, but a badge count on the toggle would match the tier model |
| "Simulate agent attention" button | — (debug menus are DEBUG-build menus) | always-visible header button | ❓ move behind a debug flag/menu |
| Presentation modes (standard/minimal) | yes, hover-revealed controls | no | ❌ Later |

## 2. Left sidebar (workspaces)

| Aspect | macOS | Linux port | Verdict |
|---|---|---|---|
| Row content | rich multi-line: unread badge w/ count or agent spinner, pin, media glyphs, title 12.5pt, inline rename, notification subtitle, branch+dir row, PR rows, ports, checklist, progress, color rail | plain text + literal "●  " prefix | ❌ the rich-row system is the sidebar-metadata GAPS row (L); the *badge-with-count* is the S-sized first slice |
| Hover close button | trailing slot cross-fades badge→xmark on hover | none | ❌ S — daily-use affordance |
| Context menu | full (rename, pin, group, close, colors…) | none | ❌ S–M |
| Drag reorder | yes, with accent drop indicators + multi-select | none (verb only) | ❌ M |
| Attention indicator | accent-blue badge; one color, three tiers (flash ring → pane ring → badge) | text dot | ❓ adopt the blue-badge tier language when rows get built |
| New workspace | titlebar + button, double-click empty area, group header + | header-bar button, Ctrl+Shift+O | ✅ reachable; double-click-empty-area is a nice S |
| Groups, pins, status lanes | full (anchor model, ⌘;, lanes) | none | ❌ Later (CONCEPTS) |
| Footer (help popover, update pill) | yes | none | ❌ Later; GNOME would put help in the primary menu |

## 3. Surface tabs (per-pane)

| Aspect | macOS (Bonsplit) | Linux (AdwTabBar/View) | Verdict |
|---|---|---|---|
| Placement | top of every pane, 28pt, always present | top of pane, **autohides at 1 tab** | 🎨 autohide is good Adwaita and saves rows — keep |
| Tab icons | per-panel-type SF Symbols (terminal.fill, globe, doc.richtext…) + state badges (dirty, loading, audio, notification) | text only | ❌ S–M — icons carry real signal (what's in this tab) |
| Trailing actions | configurable buttons: new terminal, new browser, split right/down | none | ❌ S (`adw_tab_bar_set_end_action_widget`) |
| Drag reorder | within pane + cross-pane move | drag possible but **desyncs the model** | ❌ **GAPS Now** (bug) |
| Close/reopen | per-tab close; reopen-last-closed ⌘⇧T | close only | ❌ reopen is in the keyboard batch (GAPS) |

## 4. Terminal panes

| Aspect | macOS | Linux port | Verdict |
|---|---|---|---|
| Focus indication | **unfocused splits dimmed** (Ghostty unfocused-split-fill/opacity) | none | ❌ **S, high value** — the port's biggest orientation gap in splits |
| Unread ring | persistent blue rounded ring inside pane w/ unread notification | none | ❌ with the tier system |
| Find overlay | floating corner-snapping draggable bar (field, n/m, up/down, x) | Ghostty's built-in overlay (Ghostty panes); VTE none | 🎨 Ghostty overlay is native and fine; VTE gap recorded in PARITY |
| TextBox docked below terminal | yes | no | ❌ GAPS (CONCEPTS) |

## 5. Browser panes

| Aspect | macOS | Linux port | Verdict |
|---|---|---|---|
| Address bar | top of pane, hideable; back/fwd/reload cluster + pill (lock badge, inline autocomplete, suggestions) + trailing tools (focus mode, screenshot, React Grab, **profile popover**, theme, devtools) with overflow collapse | bare full-width GtkEntry, always visible, no buttons | ❓ **decide: omnibar build-out** — minimum worth doing: back/fwd/reload + profile button (verbs all exist); pill styling optional |
| Find-in-page | floating corner-snap bar | revealer bar under URL bar (entry, n/m, up/down, x) | 🎨 revealer is the GTK idiom; controls match |
| Zoom | menu/shortcut, no on-screen chip | verb only, no chip | ✅ chip-less matches; shortcuts missing → keyboard work |
| DevTools | WebKit inspector, WebKit-owned dock state | **our own DevTools split pane** (reparented inspector) | 🎨 arguably better: inspector is a real pane (tabs, splits, socket-drivable) |
| JS console | ⌥⌘C → reveal inspector + private `showConsole` selector — **no custom console UI** | ✅ Ctrl+Shift+J / `browser devtools console` → DevTools pane revealed + focused, reuse-not-stack; no public WebKitGTK tab flip exists (macOS needs private API for it too) | ✅ 2026-07-22, with recorded 🎨 shortcut deviation |
| Focus mode / design mode / React Grab | yes | no | ❌ Later |

## 6. Splits, zoom, flash

| Aspect | macOS | Linux port | Verdict |
|---|---|---|---|
| Dividers | hairline, ±8pt hit area, resize cursors | GtkPaned wide handles | 🎨 both fine; fractions persist on both |
| Pane zoom | ⇧⌘↩, renders only zoomed pane, no badge | same model, verb + shortcut | ✅ |
| Equalize splits | ⌃⌘= | missing | ❌ keyboard batch (GAPS) |
| Flash | blue ring stroke, 0.9s scripted blink, suppressed when unread ring present | opacity dips ×2 | ❓ adopt accent ring when tier system lands; opacity flash works meanwhile |
| Canvas layout | freeform 2D mode | none | ❌ Later (CONCEPTS) |

## 7. Discovery & command surfaces

| Aspect | macOS | Linux port | Verdict |
|---|---|---|---|
| Command palette | ⇧⌘P in-window overlay; ⌘P workspace switcher | none | ❌ GAPS (L) — the headline gap |
| Menu bar | full NSMenu tree (every action reachable) | none | 🎨 GNOME apps don't have menu bars — but then discoverability must come from elsewhere: |
| Shortcuts discovery | hold-⌘ hint pills; Settings; menu items show shortcuts | tooltips only | ❌ **S: GtkShortcutsWindow** (Ctrl+?) — the GNOME-native answer |
| Global hotkeys / global search | system-wide show-hide + search | none | ❌ Later |

## 8. Settings

| Aspect | macOS | Linux port | Verdict |
|---|---|---|---|
| Structure | 18-section NavigationSplitView, searchable, 820×540 | AdwPreferencesWindow, 1 page, 3 settings | ✅ scope-appropriate today; grows with features |
| Shortcut editor | full rebinding UI + chords | none | ❌ GAPS (shortcut rebinding row) |
| cmux.json editor window | dedicated window | none (file is shared + documented) | ✅ for now |

## 9. Notifications

| Aspect | macOS | Linux port | Verdict |
|---|---|---|---|
| Surfaces | bell popover + sidebar page + per-row badges + pane ring + menu-bar count + dock badge | sidebar page swap + row prefix + desktop | 🟡 page ✅; the tier system is the gap (rows above) |
| Row look | rounded cards, unread dot, time, 3-line body, workspace caption, hover clear | single text line "● Title: sub — body" | ❌ S — card rows are a cheap Adw.ActionRow win |
| Suppression rules | window focused / workspace active / panel open | workspace active | ❓ implement the other two (documented contract, CONCEPTS) |

## 10. Visual language

| Aspect | macOS | Linux port | Verdict |
|---|---|---|---|
| Icons | SF Symbols, 7–14pt, template | GTK symbolic stock | 🎨 correct per platform; keep a mapping table when building rows |
| Accent | cmux blue #0088FF/#0091FF; attention = systemBlue | stock Adwaita accent | 🎨 follow GNOME accent; use *one* accent for all attention tiers like macOS does |
| Chrome theming | tinted from live terminal background | stock Adwaita | 🎨 deliberate — GNOME theming contract; revisit only if users ask |
| Metrics | 28pt bars, radius 6/8/10, sparse 0.14–0.2s animations | stock Adwaita metrics | 🎨 |

## Decision queue (the ❓ rows, for the human)

1. **Header diet** — prune the 14-button header to ~5 + primary menu?
2. **Omnibar build-out** — add back/fwd/reload + profile button to the URL bar?
3. **Attention tier language** — adopt macOS's one-color three-tier system (flash ring → pane ring → badge) using the GNOME accent?
4. **Debug button** — move "Simulate agent attention" behind a debug flag?
5. **Suppression rules** — add the two missing desktop-alert suppression cases?

## Recorded decisions

- 2026-07-22 — **Interaction parity sacred, presentation negotiable**
  (session decision; the guiding line above).
- 2026-07-22 — **DevTools-as-pane stays** (🎨): a real pane beats
  WebKit's own dock management — tabs, splits, socket-drivable.
- 2026-07-22 — **Tab-bar autohide stays** (🎨): Adwaita idiom, saves a
  28px row in the 1-tab common case.
- 2026-07-22 — **JS console binds Ctrl+Shift+J, not macOS's ⌥⌘C** (🎨):
  Ctrl+Shift+C is terminal copy on Linux, and Ctrl+Shift+J is
  Chrome/Firefox console muscle memory. Interaction parity kept (one
  keystroke, same semantics), presentation adapted to platform.
