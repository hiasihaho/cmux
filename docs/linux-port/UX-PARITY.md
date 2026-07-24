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

Deep evidence for the comfort families (colors, icons, DnD, context
menus, Dock) lives in [MACOS-UX.md](MACOS-UX.md) (2026-07-24 survey)
— rows here decide, that file describes.

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
| Chrome density | near-zero persistent buttons; nav lives in menus/shortcuts; hold-⌘ reveals hint pills | **4 buttons** (sidebar, split×2, browser) + GNOME primary menu carrying find/zoom/devtools/console/rename/open-folder/close-pane/preferences with their shortcuts (labels auto-localized by GTK); workspace/pane stepping keyboard-only | ✅ dieted 2026-07-23 (was 14) |
| Unread surfacing in chrome | bell button with numeric badge → popover | subtitle text "N unread" + sidebar-header toggle | ❓ close, but a badge count on the toggle would match the tier model |
| "Simulate agent attention" button | — (debug menus are DEBUG-build menus) | behind `CMUX_DEBUG_UI=1` | ✅ 2026-07-23 |
| Presentation modes (standard/minimal) | yes, hover-revealed controls | no | ❌ Later |

## 2. Left sidebar (workspaces)

| Aspect | macOS | Linux port | Verdict |
|---|---|---|---|
| Row content | rich multi-line: unread badge w/ count or agent spinner, pin, media glyphs, title 12.5pt, inline rename, notification subtitle, branch+dir row, PR rows, ports, checklist, progress, color rail | plain text + literal "●  " prefix | ❌ the rich-row system is the sidebar-metadata GAPS row (L); the *badge-with-count* is the S-sized first slice |
| Hover close button | trailing slot cross-fades badge→xmark on hover | hover-revealed ✕ via CSS `row:hover` (2026-07-24; headers get hover-＋); no badge cross-fade yet — there are no badges | ✅ mirror item ② |
| Context menu | full (rename, pin, group, close, colors…) | core slice on rows + headers (2026-07-24, mirror ③) incl. Workspace/Group Color palettes (mirror ④) | 🟡 long tail per MACOS-UX §4 (descriptions, move-to-window, notifications submenu) |
| Workspace colors | 16-swatch palette, rail/fill styles, dark-mode brightening, WCAG text | same 16 swatches, left rail, Clear/Custom, persisted (2026-07-24, mirror ④) | 🟡 fill style + brightening + adaptive text open |
| Drag reorder | yes, with accent drop indicators + multi-select | rows + group headers draggable; accent before/after indicator lines; drop joins/leaves groups; same core as workspace.reorder (2026-07-24, mirror ⑥) | 🟡 multi-select + cross-window open |
| Attention indicator | accent-blue badge; one color, three tiers (flash ring → pane ring → badge) | text dot | ❓ adopt the blue-badge tier language when rows get built |
| New workspace | titlebar + button, double-click empty area, group header + | header-bar button, Ctrl+Shift+O | ✅ reachable; double-click-empty-area is a nice S |
| Groups | full (anchor model, colors/icons, DnD, context menu, palette) | sections, chevron, colors/icons, menus, palette, drag membership — full comfort slice (2026-07-24, mirrors ③④⑥) | ✅ |
| Pins (workspace-level), status lanes | full (⌘;, lanes) | none | ❌ Later (CONCEPTS) |
| Footer (help popover, update pill) | yes | none | ❌ Later; GNOME would put help in the primary menu |

## 3. Surface tabs (per-pane)

| Aspect | macOS (Bonsplit) | Linux (AdwTabBar/View) | Verdict |
|---|---|---|---|
| Placement | top of every pane, 28pt, always present | top of pane, **autohides at 1 tab** | 🎨 autohide is good Adwaita and saves rows — keep |
| Tab icons | per-panel-type SF Symbols + state badges | themed per-type icons + native loading spinner (2026-07-24, mirror ⑤); favicons blocked by the shim-libpng trap (GAPS) | 🟡 |
| Trailing actions | configurable buttons: new terminal, new browser, split right/down | the default four, live (2026-07-24, mirror ⑤) | 🟡 configurability later |
| Drag reorder | within pane + cross-pane move | within-pane drag mirrors into the model (`page-reordered` → the same mutation path as `surface.reorder`); suite drives a REAL pointer drag. Cross-pane drag stays unwired (moves are verb-only) | 🟡 within-pane ✅ 2026-07-23; cross-pane open |
| Close/reopen | per-tab close; reopen-last-closed ⌘⇧T | close only | ❌ reopen is in the keyboard batch (GAPS) |

## 4. Terminal panes

| Aspect | macOS | Linux port | Verdict |
|---|---|---|---|
| Focus indication | **unfocused splits dimmed** (Ghostty unfocused-split-fill/opacity) | unfocused panes of a split fade to 0.78 opacity (`.cmux-unfocused`, AttentionStyle); asserted via `debug.surfaces` css_classes, not just screenshots | ✅ 2026-07-23 |
| Unread ring | persistent blue rounded ring inside pane w/ unread notification | persistent accent outline (`.cmux-unread`) while a surface's notification is unread; suite-asserted | ✅ 2026-07-23 (UX batch) |
| Find overlay | floating corner-snapping draggable bar (field, n/m, up/down, x) | Ghostty's built-in overlay (Ghostty panes); VTE none | 🎨 Ghostty overlay is native and fine; VTE gap recorded in PARITY |
| TextBox docked below terminal | yes | no | ❌ GAPS (CONCEPTS) |

## 5. Browser panes

| Aspect | macOS | Linux port | Verdict |
|---|---|---|---|
| Address bar | top of pane, hideable; back/fwd/reload cluster + pill (lock badge, inline autocomplete, suggestions) + trailing tools (focus mode, screenshot, React Grab, **profile popover**, theme, devtools) with overflow collapse | back/fwd/reload cluster + entry + trailing **profile popover** (2026-07-23). Popover lists profiles, pane's own marked; picking one opens the same page as a new split in that container — WebKit's `network-session` is construct-only, so in-place switching is impossible (macOS swaps the data store under the view). Profile create/rename stay CLI-side for now | 🟡 core ✅; suggestions/lock/tool cluster open |
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
| Flash | blue ring stroke, 0.9s scripted blink, suppressed when unread ring present | accent-ring double blink ~0.9s (CSS outline, `AttentionStyle`), registry-resolved per tick (also fixed the opacity version's latent use-after-free) | ✅ 2026-07-23; macOS's flash-vs-ring suppression rule not yet mirrored |
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
| Suppression rules | window focused / workspace active / panel open | all three (2026-07-23), one decision path (`DesktopNotifier.deliver`) with outcome breadcrumbs replacing three inline copies of the first rule | ✅ |

## 10. Visual language

| Aspect | macOS | Linux port | Verdict |
|---|---|---|---|
| Icons | SF Symbols, 7–14pt, template | GTK symbolic stock | 🎨 correct per platform; keep a mapping table when building rows |
| Accent | cmux blue #0088FF/#0091FF; attention = systemBlue | stock Adwaita accent | 🎨 follow GNOME accent; use *one* accent for all attention tiers like macOS does |
| Chrome theming | tinted from live terminal background | stock Adwaita | 🎨 deliberate — GNOME theming contract; revisit only if users ask |
| Metrics | 28pt bars, radius 6/8/10, sparse 0.14–0.2s animations | stock Adwaita metrics | 🎨 |

## Decision queue (the ❓ rows, for the human)

The original five (header diet, omnibar, attention tiers, debug button,
suppression rules) were all decided per recommendation and implemented
2026-07-23 — see Recorded decisions. Currently open:

1. **Unread badge count on the sidebar-header toggle** (small, with the
   sidebar-rows work).
2. **Flash-vs-ring suppression** — macOS suppresses the flash when an
   unread ring is already present; mirror when the rings have lived a
   while.

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
- 2026-07-23 — **The five-decision batch, per recommendation** (user
  approval "lets do the ux batch per your recommendations"):
  header diet (4 buttons + primary menu; nav keyboard-only), omnibar
  nav cluster + profile popover (switch-by-split, construct-only
  session), one-accent attention tiers on the GNOME accent
  (`@accent_bg_color` — deliberately not macOS's fixed blue), debug
  button behind `CMUX_DEBUG_UI=1`, full desktop-alert suppression
  contract. All screenshot-verified under Xvfb before landing.
