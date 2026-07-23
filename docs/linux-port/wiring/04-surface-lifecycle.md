# ⑤ Model → view → surfaces

The port is **model-driven**: socket verbs and UI actions mutate a plain
value model, and an Adwaita scene re-renders the widget tree to match.
Live terminals and web views are *reparented, never recreated* — the
registry holds them across every re-render.

## The core loop

```mermaid
flowchart TB
    verb["socket verb / UI action"] -->|"mutate"| model["the model<br/>tabs: [TerminalTab]<br/>(Model.swift — value types)"]
    model -->|"@State change"| scene["CmuxApp.scene<br/>(Adwaita re-render)"]
    scene --> stack["TerminalStackWidget<br/>reconcile GtkStack"]
    stack --> panes["per workspace:<br/>build the split tree"]
    panes --> reg["SurfaceRegistry<br/>(holds live widgets)"]
    reg -.->|"reparent, not rebuild"| panes

    style model fill:#2ea04322,stroke:#2ea043
    style reg fill:#1f6feb22,stroke:#1f6feb
```

**Rule:** the model is the truth; the widget tree is a projection. A verb
never pokes a widget directly — it changes the model and lets the scene
reconcile. That is what keeps UI and socket callers from ever disagreeing
about, say, which surface a pane shows.

## The object model

```mermaid
flowchart TD
    tab["TerminalTab (workspace)<br/>id · title · layout · focusedSurfaceId · zoomedSurfaceId"]
    tab --> layout["PaneNode (split tree)<br/>.leaf | .split(orientation, first, second)"]
    layout --> leaf["PaneLeaf (a pane)<br/>paneId · surfaces[] · selectedIndex"]
    leaf --> surf["PaneSurface<br/>surfaceId · kind · workingDirectory"]
    surf --> kind["SurfaceKind<br/>.terminal | .browser(url) | .inspector(target)"]
```

Mirrors macOS's Bonsplit layout tree and `SessionWorkspaceLayoutSnapshot`.
A pane holds *several* surfaces behind a tab strip (popups land as tabs,
not forced splits) — the single-surface accessors (`leaf.surfaceId`,
`leaf.kind`) mean "the surface this pane is currently showing".

## Four backends, one registry

```mermaid
flowchart TB
    reconcile["reconcile a leaf"] --> which{"surface kind /<br/>build flags"}
    which -->|"terminal + shim"| g["GhosttySurfaceFactory<br/>(CMUX_GHOSTTY, default)"]
    which -->|"terminal, --vte"| v["VTE (VteTerminal)"]
    which -->|browser| b["BrowserSurfaceFactory<br/>(WebKitWebView)"]
    which -->|inspector| i["InspectorSurfaceFactory<br/>(reparented WebKit inspector)"]
    g --> reg["SurfaceRegistry.shared"]
    v --> reg
    b --> reg
    i --> reg
    reg --> containers["containers[surfaceId]<br/>= the pane's GtkWidget"]
    reg --> backends["ghosttys / terminals /<br/>browsers keyed by surfaceId"]

    style g fill:#2ea04322,stroke:#2ea043
```

The registry is the single home for live widgets. `doctorReport`
(`debug.surfaces`) reads it — backend, realized/mapped, container
refcount, parent type, and now **css_classes** (so the attention system
is assertable). Everything downstream keys off `surfaceId`.

## PaneTabs reconcile — the tricky part

```mermaid
flowchart TB
    rec["PaneTabsView.reconcile(pane)"] --> drop["surface left this pane?<br/>detachIfLive → close_page<br/>(isReconciling guards it)"]
    rec --> respawned["same id, NEW container?<br/>(respawn) → close stale page"]
    rec --> append["new surface? unparent + append<br/>(append refuses a parented widget — silently!)"]
    rec --> order["reorder_page to model index<br/>(guarded: it emits page-reordered)"]
    rec --> select["set selected page"]

    drag["user drags a tab"] -.->|"page-reordered<br/>(NOT while isReconciling)"| mutate["reorderSurfaceTab →<br/>same path as surface.reorder"]

    style drag fill:#8957e522,stroke:#8957e5
```

Two subtleties the code comments flag: closing a page *destroys* its
child (kills a Ghostty shell), so a moving surface is **detached** first,
not closed; and `reorder_page`/`close_page` both emit signals that would
echo back into the handlers — hence the `isReconciling` flag around every
programmatic mutation.
