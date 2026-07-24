# macOS UX / comfort reference (measured survey)

A deep, file:line-referenced survey of cmux-mac's **comfort surfaces** —
color language, iconography, drag & drop, context menus, and the Dock —
made 2026-07-24 by four exploration agents reading the macOS sources.
This is the *evidence* document; [UX-PARITY.md](UX-PARITY.md) stays the
*decision* ledger (its rows link here instead of re-describing macOS).
Line numbers drift with upstream merges — treat them as anchors for
`rg`, not gospel.

Sections marked ⏳ are being surveyed; fill them from the agent report
in the same commit that lands them.

---

## 1. Color language

Two shared primitives underpin everything:

- **Accent** (`cmuxAccentNSColor`): dark `#0091FF`, light `#0088FF` —
  `Sources/Sidebar/SidebarAppearanceSupport.swift:78-101`.
- **Hex→display pipeline** (`WorkspaceTabColorSettings.displayNSColor`):
  parses `#RRGGBB`; dark mode runs `brightenedForDarkAppearance` (HSB:
  brightness → `min(1, max(b,0.62)+(1-b)*0.28)`, saturation
  `+(1-s)*0.12`, grays s≤0.08 untouched) —
  `Sources/WorkspaceTabColorSettings.swift:137-162,256-279`.

### 1.1 Workspace group colors (`WorkspaceGroup.customColor`)

- Renders as the **folder icon tint only** — not header background, not
  a rail (`Sources/SidebarWorkspaceGroupHeaderView.swift:103-108,167`).
  Fallback `.secondary` when unset. NOT dark-mode-brightened (raw hex).
- **No GUI palette for groups** even on macOS. Set via socket/CLI
  (`workspace.group.set_color`) or the cwd-config fallback; the header
  context menu offers "Edit Group Config…" which just opens cmux.json.
- Resolution chain: `group.customColor ??
  cmuxConfigStore.resolveWorkspaceGroupConfig(forCwd: anchorCwd)?.color`
  (`Sources/VerticalTabsSidebar+WorkspaceGroups.swift:19-21`).
  Config key: `workspaceGroups.byCwd["<path-or-glob>"].color` (siblings
  `icon`, `contextMenu`, `newWorkspacePlacement`) —
  `Sources/CmuxConfig.swift:159-182`. Match rule: `*`/`?` keys are
  fnmatch globs, else path-prefix; `~` expands; longest normalized key
  wins; local config over global (`:2596-2756`).

**Linux today:** color renders as a tinted ■ swatch before the name
(deviation: macOS tints the icon — GTK symbolic icons need CSS to
recolor, the swatch was the low-machinery choice; revisit). cwd-config
fallback not wired.

### 1.2 Per-workspace colors (`Workspace.customColor`)

- Two render styles via `WorkspaceIndicatorStyle`
  (`Sources/Sidebar/SidebarAppearanceSupport.swift:275-343`):
  **`.leftRail`** — left stripe, 0.95 opacity, force-brightened;
  **`.solidFill`** — whole row background 0.7 opacity (0.35
  multi-selected). Active row uses selection background instead.
- **The palette UI** (workspace row right-click → "Workspace Color"):
  Clear / Choose Custom Color… (hex prompt, format `#RRGGBB`) / 16
  swatches (`Sources/TabItemView+WorkspaceContextMenu.swift:142-174`).
- **Fixed 16-swatch palette** (`originalPRPalette`,
  `Sources/WorkspaceTabColorSettings.swift:20-37`; UserDefaults
  `workspaceColors.palette`, custom entries appended):
  Red `#C0392B` · Crimson `#922B21` · Orange `#A04000` · Amber
  `#7D6608` · Olive `#4A5C18` · Green `#196F3D` · Teal `#006B6B` ·
  Aqua `#0E6B8C` · Blue `#1565C0` · Navy `#1A5276` · Indigo `#283593` ·
  Purple `#6A1B9A` · Magenta `#AD1457` · Rose `#880E4F` · Brown
  `#7B3F00` · Charcoal `#3E4B5E`.
- Per-cwd colors apply at launch via saved layouts / config executor
  (`Sources/CmuxConfigExecutor+WorkspaceLaunch.swift:157`).
- Sidebar selection color separately overridable
  (`sidebarSelectionColorHex`); sidebar can match terminal background.

**Linux today (mirror ④, 2026-07-24):** `TerminalTab.customColor`
persisted; the same 16 hexes (`WorkspacePalette`) in a swatch popover
reachable from the row context menu ("Workspace Color…" — and
"Group Color…" on headers, a picker macOS itself lacks); rendered as a
**left rail** (`box-shadow: inset 4px`, per-color generated CSS classes,
`SidebarColorStyle.sync` in the AttentionStyle idiom). Not mirrored:
the `.solidFill` style, dark-mode brightening, WCAG-adaptive text,
per-cwd config colors.

### 1.3 Attention & status colors

- Attention accent: **`NSColor.systemBlue`**, two tiers —
  notification ring glow 0.35/radius 3, flash ring glow 0.6/radius 6
  (`Sources/Panels/Panel.swift:97-164`).
- **Status lanes** (`Sources/SidebarWorkspaceTaskStatusGlyph.swift:33-44,128-144`):
  todo = neutral outline · working = accent, 0.5 fill · needsAttention
  = `#FF6B33` orange-red, 0.5 fill, stroke 1.4 · review = green, 0.75 ·
  done = `#739E80` muted gray-green, full + white checkmark. Glyph
  draws in the todo-pane header and status popover, **not** on sidebar
  rows; "done" rows dim to 0.6 opacity instead.
- Agent-status spinner is **monochrome** (secondary label color) — no
  semantic color for running/blocked.
- Unread badge fill = accent (overridable
  `sidebarNotificationBadgeColorHex`).

**Linux today:** attention uses `@accent_bg_color` (GNOME accent) — the
recorded deviation from fixed systemBlue (UX-PARITY §10). No lanes.

### 1.4 Semantic colors elsewhere

- Sidebar log-level rows (inactive rows only): info secondary ·
  progress blue · success green · warning orange · error red
  (`Sources/ContentView.swift:14359-14381`).
- PR rows / ports rows are **not** status-colored (single secondary
  tone; stale dimmed 0.5) — deliberate restraint.
- Destructive menu items use `role: .destructive` (system red).
- File-explorer git status ships **5 named themes** (liquidGlass,
  highDensity, terminalStealth, proStudio, finder) mapping
  modified/added/deleted/renamed/untracked to theme-specific system
  colors (`Sources/FileExplorerStore.swift:153-196`).
- Contrast-adaptive foregrounds: sidebar/titlebar text picks black vs
  white by WCAG relative luminance against the composited background
  (`Sources/Sidebar/SidebarAppearanceSupport.swift:113-266`).

---

## 2. Iconography & chrome affordances

SF Symbol renderer: `CmuxSystemSymbolImage` (ignores `.symbolEffect`;
animated symbols use plain `Image(systemName:)`).

### 2.1 Browser toolbar (`Sources/Panels/BrowserPanelView.swift:1097-1126`)

| Control | Symbol | State handling |
|---|---|---|
| Back / Forward | `chevron.left` / `chevron.right` | `.disabled(!canGoBack/Forward)` + 0.4 opacity (`:1165-1186`) |
| Reload ⇄ Stop | `arrow.clockwise` ⇄ **`xmark` while loading** (`:1190`) | context menu: Reload / Hard Refresh |
| Downloads | `arrow.down.circle`; spinner while downloading; `.bounce` on completion; red unseen-count badge | rendered only when active/recent (`BrowserDownloadsToolbarButton.swift:43-67`) |
| URL bar | `lock.fill` on https only (`:1571-1577`); no favicon, no clear button, no zoom/reader | placeholder "Search or enter URL" |
| Screenshot | `camera` → green `checkmark` when copied (`:1227`) | |
| Focus mode | `keyboard`, orange + label when active (`:1280`) | |
| React Grab | `cursorarrow.click.2`, accent when active (`:1325`) | |
| Profiles | `person.crop.circle` (`:1353`); popover rows `checkmark`/`circle` | |
| Theme | `circle.lefthalf.filled` / `sun.max` / `moon` (`BrowserPanel.swift:123-132`) | |
| DevTools | user-configurable, default `wrench.and.screwdriver` (+13 alternates, `BrowserPanelView.swift:12-28`) | |
| Compact mode | `ellipsis` overflow menu when the pane is narrow | |
| PDF | `square.and.arrow.down` / `printer` (PDF views only) | |

Find bar is a separate overlay (`Sources/Find/BrowserSearchOverlay.swift`):
`chevron.up`/`chevron.down`/`xmark`.

**Linux today (state polish landed 2026-07-24):** back/forward dim +
disable without history, reload ⇄ stop swaps while loading, https lock
as the entry's primary icon (`channel-secure-symbolic`); projection
shared with `debug.browser_chrome` and asserted in
`browser-navigation-smoke` (14). Still missing: downloads affordance,
screenshot/devtools/theme buttons, compact overflow.

### 2.2 Surface tab bar

Tab strip is the vendored **Bonsplit** framework (close/add/drag/
overflow live there). cmux supplies per-panel `displayIcon`:
terminal `terminal.fill` · browser **live favicon** (fallback `globe`)
· agent session `sparkles.rectangle.stack` · cloud `cloud.fill` ·
markdown `doc.richtext` · todo `checklist` · custom sidebar
`wand.and.stars` · project `hammer` · file preview by kind
(`doc.text`/`doc.richtext`/`photo`/`play.rectangle`/`doc.viewfinder`).
Browser tabs are the ONLY favicon consumers; the URL bar shows none.

Tab-bar **end-action buttons** (configurable `CmuxSurfaceTabBarButton`,
defaults `Sources/CmuxConfig.swift:943-948`): newTerminal `terminal`,
newBrowser `globe`, splitRight `square.split.2x1`, splitDown
`square.split.1x2`; further built-ins newWorkspace `plus.square`,
newAgentChat `message`, cloudVM `cloud`, mobileConnect `iphone`
(`Sources/CmuxSurfaceTabBarBuiltInAction.swift:44-63`).

**Linux today (mirror ⑤, 2026-07-24):** per-type themed icons on every
tab page (terminal `utilities-terminal-symbolic`, browser
`web-browser-symbolic`, DevTools `applications-engineering-symbolic`),
AdwTabBar's native loading spinner during browser loads, and the macOS
default-four end actions (new terminal/browser tab, split right/down —
`adw_tab_bar_set_end_action_widget`, visible whenever the bar is, i.e.
2+ tabs). `debug.surfaces` reads back each page's actual icon
(`tab_icon`). Favicons: plumbing complete (`notify::favicon`, session
favicon DB) but disabled while the ghostty shim is loaded — its
exported bundled libpng crashes WebKit's UI-process favicon decode
(see GAPS; VTE-only builds get favicons today).

### 2.3 Sidebar rows (`Sources/ContentView.swift` `TabItemView` ~13483)

Leading/inline: custom `GPUSpinner(.macOSSpokes)` agent spinner ·
numeric unread badge (circle/capsule, position configurable) ·
`pin.fill` · media glyphs `speaker.wave.2.fill`/`mic.fill`(orange)/
`video.fill`(green) · **hover-only `xmark` close** that cross-fades
over the badge (`SidebarWorkspaceTrailingStatusSlot.swift:42-49`).
Detail lines: log-level icons (see §1.4) · `arrow.triangle.branch` git
branch · custom-drawn PR open/merged icons · `arrow.clockwise`
reconnect.

Group headers (`SidebarWorkspaceGroupHeaderView.swift`):
`chevron.right`/`chevron.down` collapse · `pin.fill` · icon default
`folder.fill` tinted with group color · **hover-only `plus`**
(new-workspace-in-group) · numeric unread capsule.

**Linux today (2026-07-24):** groups render sections with chevron
(▸/▾ Button), mapped themed icon, color swatch, count, attention dot;
rows carry a **hover-revealed ✕ close** and headers a **hover-revealed
＋** (CSS `row:hover`, same shared v2 paths as the verbs). Still
missing: badges, spinner, media glyphs, detail lines.

### 2.4 Titlebar / window

`Sources/Update/UpdateTitlebarAccessory.swift:1007-1103`: custom
sidebar-toggle glyph (stroked shape) · `bell` + accent numeric badge
(unread) · `plus` split-button with `chevron.down` caret (new
workspace / cloud VM menu) · focus-history `arrow.left`/`arrow.right`
with enabled-state. Notifications page: `bell.slash` empty /
`bell.badge` populated. Toolbar layout segmented control:
`rectangle.split.2x1` Splits / `square.on.square.dashed` Canvas.

**Linux today:** bell (no badge count — subtitle text instead), `+`
new-tab, sidebar toggle icon, notifications back-arrow. No focus
history, no split-button, no layout control.

### 2.5 Custom-drawn (no themed-icon equivalent — needs bespoke GTK work if mirrored)

Sidebar-toggle glyph · GPUSpinner agent spinner · task-status pie
glyph · PR open/merged icons · attention flash ring (Linux already has
its CSS-outline equivalent) · numeric unread badges.

---

## 3. Drag & drop

Four drag types; one central routing arbiter
(`DragOverlayRoutingPolicy`, `Sources/DragOverlayRoutingPolicy.swift:191`)
decides which overlapping target captures a drag.

| Type | Declared | Payload | Carries |
|---|---|---|---|
| `com.splittabbar.tabtransfer` | Info.plist:197 | `BonsplitTabDragPayload` {tab id/kind, sourcePaneId, sourceProcessId} | surface tabs (terminal/browser/file-preview; also synthesized from Vault session rows) |
| `com.cmux.sidebar-tab-reorder` | Info.plist:207 | `SidebarTabDragPayload` | sidebar workspace rows + group headers |
| `com.cmux.filepreview.transfer` | runtime-only | — | distinguishes file-preview pane drags |
| file URLs / text / images | system | — | Finder drops, page drops |

### 3.1 Surface-tab drags
- Onto a terminal pane (`TerminalPaneDropTargetView`): edge zones →
  horizontal/vertical **split**, center → **insert into that pane's tab
  strip** (`PaneDropRoutingSupport.swift:96-111`). Blue zone-overlay
  rectangles animate the target (`PaneDropZoneOverlayAnimator`).
- Onto a browser pane: same moves; a live-surface tab dropped there can
  route into the **Dock split store**
  (`BrowserPaneDropTargetView.swift:277-293`).
- Onto the sidebar: into an existing workspace row
  (`SidebarBonsplitWorkspaceRowDropModifier`) or between rows / footer →
  **new workspace** (`SidebarBonsplitTabWorkspaceDropOverlay`).
- The in-strip tab reorder + the strip's own right-click menu live in
  the vendored **Bonsplit** framework, not in Sources/.
- **Vault**: dragging a past agent-session row onto a pane inserts a
  terminal that RESUMES that session (mirrors the bonsplit payload,
  `Sources/SessionIndexView.swift:2569-2644`).

### 3.2 Sidebar reorder / groups / cross-window
- Workspace rows and group headers are drag sources
  (`ContentView.swift:12870`, `VerticalTabsSidebar+WorkspaceGroups.swift:119`).
- **Into/out of groups by drag: yes** — dropping into a group's member
  run adds membership, dropping at a top-level boundary removes it
  (`TabManager.reorderSidebarWorkspace` usesTopLevelRows/explicitGroupId,
  `ContentView.swift:15206-15286`).
- **Group reorder by header drag: yes** (top-level row space).
- **Cross-window workspace moves: yes**; group anchors are refused
  cross-window — the group stays intact (`:15027,15110`).
- Feedback: accent drop-indicator lines (group-scoped vs top-level),
  dragged row dims to ~0.6, auto-scroll near edges.

### 3.3 External drops
- Window-level `FileDropOverlayView` routes Finder file URLs to the
  focused terminal; terminals accept files/text/URLs/images and can
  **upload** to remote/SSH workspaces
  (`GhosttyTerminalView.swift:3341-3350,7867`).
- File-drop-as-text vs open-preview is a policy with a **Shift-toggled
  alternate** (`FileDropDefaultBehavior`, key `fileDrop.defaultBehavior`).
- Browser panes decide file drops between in-app preview and delivery
  to the hosted WKWebView (`BrowserPaneFileDropRouting.swift`).
- Reverse direction: the workspace's detached folder icon can be
  dragged OUT to Finder (`DetachedFolderDragIcon.swift:178-187`).

**Linux today:** no drag-and-drop of any kind (pane tab reorder exists
via `onTabReordered` only). GTK4 has full DnD APIs (GtkDragSource/
GtkDropTarget, GdkContentProvider); adwaita-swift exposes little of it,
so this family means raw-GTK work on our side.

## 4. Context menus

The complete macOS map (labels abridged; each menu's source file is
its anchor — `rg` the label text there for exact lines):

- **Workspace row** (`TabItemView+WorkspaceContextMenu.swift`): ~30
  items — Pin/Unpin · group sub-section (New Empty Group, New Group
  from Selection/Workspace, **Move to Group** submenu, Remove from
  Group) · todo sub-section (Status lanes submenu, Mark Done, Add
  Checklist Item, Open Todo Pane) · Rename/Remove custom name ·
  Description edit/clear · Reconnect/Disconnect · **Workspace Color**
  submenu (Clear / Custom hex / 16 swatches) · Move Up/Down/Top ·
  **Move to Window** submenu · Close / Close Others / Below / Above ·
  Mark read/unread · Notifications submenu · Copy ID/Link · Show in
  Finder.
- **Group header** (`SidebarWorkspaceGroupHeaderView.swift:299-408`):
  New Workspace in Group · Rename Group… · Pin/Unpin · Mark group (or
  all members) read/unread · Clear latest notifications · Edit Group
  Config… (opens cmux.json) · Docs · Ungroup · **Delete Group**
  (destructive).
- **Terminal pane** (`GhosttyTerminalView.swift:7204+`): Trigger Flash ·
  Copy/Translate · Paste · Split H/V (with shortcut hints) · **Fork
  Conversation (To…)** · Reset Terminal · Reconnect · Copy IDs/Link.
- **Browser page** (`CmuxWebView.swift:2101+`): retargets Open-in-new-
  window → **Open Link in New Tab**, adds Open in Default Browser,
  in-app image/file download handlers, Screenshot Page/Section, Move
  Tab to New Workspace, Enter/Exit Focus Mode. Reload button
  right-click: Reload / Hard Refresh.
- Plus: notification rows (Open/read/unread/Dismiss), menu-bar extra,
  file explorer (Open/Reveal/Copy Path/Open With…), file preview, task
  manager (Kill Process…), checklist items, Vault session rows (Resume
  in New Tab, Copy Resume Command…), "+"-button menus (Layouts,
  templates, focus history), Cloud VM menu, detached-folder path menu.
- **Hover comfort**: row close buttons, group-header "+", notification
  Clear, checklist Remove — all hover-revealed; **⌘-hold shows
  shortcut-hint pills** over sidebar rows.

**Linux today (mirror ③, 2026-07-24):** workspace rows and group
headers have right-click menus (the core slice above — window-level
button-3 gesture, widget-pick to the row, popover of flat buttons;
`SidebarContextMenu.swift`). Content is the `SidebarContextMenuModel`
projection shared with `debug.sidebar_menu`. Not yet mirrored: the
long-tail items (descriptions, move-to-window, notifications submenu,
color submenu — waits on mirror ④), terminal/browser-page menus.

## 5. The Dock (right sidebar)

**Corrects CONCEPTS.md's legacy one-liner.** The Dock is NOT a set of
"controls" (buttons): it is a **window-global secondary split area** —
a right-sidebar Bonsplit tree of full terminal/browser panes that stays
present while you switch workspaces (the "instruments panel" beside the
work: log tails, lazygit, test watchers, docs pages). Beta,
off-by-default (`rightSidebar.beta.dock.enabled`).

- **"Controls" are only JSON seed entries** (`DockControlDefinition`:
  `id/title/type/command/url/cwd/height/env`). A terminal control runs
  its command in a **non-interactive login shell and falls back to an
  interactive shell in place when it exits** (`docs/dock.md:9`) — the
  detail that makes TUIs livable. Config is optional; the Dock is fully
  buildable in-app (empty Dock is a supported state).
- **Two stores, one rendered:** the shipped right-sidebar Dock is
  per-window and reads only the GLOBAL `~/.config/cmux/dock.json`; the
  "project `.cmux/dock.json` wins" precedence belongs to a legacy
  per-workspace store the sidebar does not mount
  (`Sources/DockScope.swift`, `AppDelegate+WindowDock.swift:8-45`).
- **Trust:** only project-scoped configs are gated (they can run
  commands) — content-fingerprint trust, re-prompts on change
  (`DockSplitStore+Config.swift:161-176`, the `exclamationmark.shield`
  prompt).
- **Wiring: no `dock.*` verb family.** Driven via generic verbs:
  `right_sidebar <toggle|show|hide|focus|set|mode|state>`, and
  `pane.create`/`surface.create` with `--placement dock` (results carry
  `dock_surface_id`/`dock_pane_id`, `placement:"dock"`; alias workspace
  id `D0CCD0CC-…-000000000001` = "the caller window's Dock").
- **Not persisted:** the Dock tree does not survive restart — the JSON
  reseeds each launch/window; only sidebar visibility/width persist.
- Right-sidebar modes: ⌃1 files · ⌃2 find · ⌃3 vault · ⌃4 feed ·
  **⌃5 dock**; ⌘⌥B toggles the sidebar. Dock panes' shortcuts retarget
  New Terminal/Split into the Dock while it owns focus; Dock and main
  area have mutually exclusive focus with dimmed rings.
- Attention: Dock surfaces feed the notification store but render no
  unread badges of their own (`hasUnreadNotification: false`
  hardcoded).

**Minimal viable Linux Dock** (survey's judgment, endorsed): a
toggleable right panel reading the same `dock.json` `controls[]`,
launching terminal controls as a **simple vertical stack** of panes
(login-shell wrap + interactive-shell fallback, `cwd`/`env`), empty
state with a create affordance, trust prompt for any project-scoped
config. Defer: browser panes, arbitrary tiling, drag-in/out,
multi-window routing, `--placement dock` verbs.

---

## Proposed mirror order (recommendation — awaiting the human's decision)

Ranked by comfort-per-effort for the port, using the surveys above:

1. ✅ **S — browser chrome state polish** (landed 2026-07-24):
   back/forward disabled+dimmed without history, reload⇄stop swap
   while loading, https `lock`.
2. ✅ **S — hover affordances** (landed 2026-07-24): sidebar row
   hover-close ✕, group-header hover-＋ — pure CSS `row:hover` reveal,
   no motion controller needed; buttons always present so rows stay
   structure-stable.
3. ✅ **S–M — context menus** (landed 2026-07-24): right-click popovers
   on workspace rows (Rename/Close Others/New Group⇄Remove from
   Group/Copy ID/Close) and group headers (New in Group/Rename/Pin/
   Collapse/Ungroup/Delete), all through shared v2 paths; menu content
   projected via `debug.sidebar_menu`.
4. ✅ **M — workspace colors** (landed 2026-07-24): the exact 16-swatch
   macOS palette in a popover (context menu → Workspace Color… /
   Group Color…), left-rail row rendering via generated per-color CSS
   classes, Clear + strict-hex Custom…, persisted in session v3. The
   group swatch→icon-tint switch remains open (minor).
5. ✅ **M — tab icons + end-action buttons** (landed 2026-07-24):
   per-type themed icons + native loading spinner on AdwTabPage, the
   macOS default four end actions on the tab bar. Favicons are wired
   but OFF in shim builds — the ghostty shim exports its bundled libpng
   and WebKit's UI-process favicon decode SEGVs into it (coredump-
   proven; GAPS row for the shim-side symbol-visibility fix).
6. **M–L — drag & drop family**, staged: sidebar workspace reorder →
   group membership by drag → tab-onto-pane split/insert → file drops
   onto terminals. Raw GtkDragSource/GtkDropTarget work.
7. **L — the Dock**, minimal-viable per §5.

Not recommended to mirror: ⌘-hold hint pills (GNOME answer is the
GtkShortcutsWindow already queued in UX-PARITY), macOS dock-tile badge,
canvas layout control.

## Cross-references

- [UX-PARITY.md](UX-PARITY.md) — the decision ledger these facts feed.
- [features/04-workspace-groups.md](features/04-workspace-groups.md) —
  groups comfort status on Linux.
- [GAPS.md](GAPS.md) — "Workspace groups: comfort remainder" row and
  the UX-parity ❌ cluster.
- [CONCEPTS.md](CONCEPTS.md) — dock/canvas/feed family concepts.
