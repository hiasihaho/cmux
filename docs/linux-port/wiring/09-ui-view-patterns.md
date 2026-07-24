# UI / view patterns — how to build comfort UI in this port

The port-side playbook for anyone implementing UX comfort (context
menus, hover affordances, colors, DnD — the MACOS-UX.md mirror list).
Everything here was paid for during the workspace-groups build
(2026-07-24, PROGRESS); this page is the distilled "how", so you don't
re-derive it from the evidence log.

## The toolkit and its boundaries

The UI is **adwaita-swift** (declarative wrapper over GTK4/libadwaita;
pinned checkout under `linux/.build/checkouts/adwaita-swift`). What it
gives you: `List` (GtkListBox with `id:`-keyed diffing + a
`selection: Binding<UUID>`), `HStack`/`VStack`, `Text` (+
`.useMarkup()` for Pango markup), `Button` (label or icon), `Image()
.iconName(...)`, `EitherView`, `Menu`/`MenuSection`/`MenuButton`,
`.keyboardShortcut`, `.style(cssClass)`, `.tooltip`.

What it does NOT expose (as of the pinned rev): per-row gesture
controllers (right-click), popover menus on arbitrary widgets,
GtkDragSource/GtkDropTarget, hover controllers. **The sanctioned way
around it is the raw-C escape hatch**, pattern in
`Sources/CmuxAdw/UICommands.swift` (`UIDialogs`): call GTK/libadwaita C
functions directly (`adw_alert_dialog_new`, `g_signal_connect_data`
with a retained context box, …). Context menus and DnD will be built
this way — attach controllers to widgets obtained either from a
registry (the `SurfaceRegistry`/`AttentionStyle` pattern) or by walking
from the window (`mainWindowWidget()`).

## The five rules (violate any of these and you get a paid-for bug back)

1. **Snapshot boundary.** Views below a `List` receive immutable value
   snapshots plus closure action bundles — never store references. The
   sidebar's projection is `SidebarRows.project(tabs, groups) →
   [SidebarRowModel]` (`Model.swift`), computed in the scene body
   (pure!) and passed by value. This is the Linux expression of the
   macOS snapshot-boundary pitfall (CLAUDE.md).

2. **Structure-stable rows.** The ListBox differ updates row content
   in place by `id`. A row whose top-level VIEW TYPE changes between
   renders (Text ⇄ HStack) silently keeps its stale widget. Every row
   that can change kind must keep one top-level structure — wrap the
   variants in `EitherView` (a ViewStack keyed by the condition — the
   supported structure-switch container). Paid for by the
   "header rendered the anchor's old title with no chevron" bug
   (PROGRESS 2026-07-24).

3. **No state mutation in body computations.** Projections called from
   the scene body must be pure. Mutations belong in event handlers
   (Button actions, dialog callbacks) or the control handler. Same
   family as the macOS 100%-CPU spin loops.

4. **Selection-echo guard.** Socket-driven model mutations make the
   ListBox emit selection signals that are NOT user clicks. The
   selection binding ignores them while `SocketDispatchGuard.active`
   (`CmuxApp.selectionBinding`). Any new interactive control that can
   fire during a socket dispatch needs the same guard.

5. **One mutation path per behavior** (shared-behavior rule). UI
   affordances route through the SAME v2 implementations the socket
   verbs use — see `ControlCommandHandler.ui*` methods (menu) and
   `toggleGroupCollapsed` (chevron): build params, call the private
   `v2Group*` function, ignore the JSON string result. New context-menu
   items should follow exactly this shape; almost every macOS menu item
   already has a Linux v2 implementation to call.

## Renderer guards must match the renderer

If a projection/validator gates what reaches a rendering grammar
(Pango markup, CSS), encode the RENDERER'S grammar, not a plausible
superset — `validatedHex` accepts exactly 3/4/6/8 hex digits because
that is what Pango parses (QA regression, PROGRESS 2026-07-24). Always
markup-escape user strings before concatenating into markup
(`SidebarRows.markupEscaped`); labels render with `.useMarkup()` only
where markup is intended (headers), plain `Text` elsewhere.

## Testing UI honestly

- Share the view's projection with a debug verb
  (`debug.sidebar_rows` ← `SidebarRows.project`) so suite assertions
  assert the rendered surface, not a parallel model.
- Drive real input with xdotool on the suite's Xvfb (menu → dialog →
  type → Enter was verified this way); screenshot via `scratch.sh
  shot`, live-watch via `scratch.sh watch` (ADR-0010).
- Keyboard-path assertions beat verb-only assertions for anything a
  human reaches by hand (the ui-commands-smoke lesson).

## Iconography & color notes for implementers

- Themed icons: `Image().iconName("folder-symbolic")`; the SF-Symbol →
  GTK mapping table lives in `SidebarRows.gtkIconName` — extend it
  there (single source for view + debug verb).
- Colors in labels: Pango `<span foreground="#RRGGBB">` via
  `.useMarkup()`. Row backgrounds/rails (the macOS workspace-color
  styles) will need per-row CSS classes + a regenerated provider — the
  `AttentionStyle.install/sync` pattern is the template (application-
  level provider, widget-class writes only, no model state).
- GNOME accent (`@accent_bg_color`) is the recorded stand-in for
  macOS's fixed systemBlue (UX-PARITY §10).

## Where the macOS behavior specs live

[MACOS-UX.md](../MACOS-UX.md) — colors, icons with state handling, the
full DnD map, every context menu, the Dock model, and the proposed
mirror order. Caveat recorded there: the surface-tab strip's own drag
reorder + right-click menu live in the vendored **Bonsplit** framework;
`vendor/bonsplit` is an uninitialized submodule on this checkout — run
`git submodule update --init vendor/bonsplit` (from a macOS checkout of
record) if strip-level details are ever needed; otherwise mirror from
observed behavior.
