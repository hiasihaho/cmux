# ⑥ Attention pipeline

How "an agent needs you" travels from a source to a pixel. One accent
color, three escalating tiers, plus desktop delivery gated by a
suppression funnel — mirroring macOS's contract on GNOME.

## Sources → store → tiers

```mermaid
flowchart TB
    bell["terminal bell<br/>(VTE bell / ghostty bell-ringing)"] --> store
    notify["cmux notify<br/>notification.create*"] --> store
    hooks["agent Stop/Notification hooks"] --> notify
    store["notification store<br/>notifications: [TerminalNotification]"]

    store --> t1["tier 1 — flash ring<br/>surface.trigger_flash<br/>(AttentionStyle.flash, ~0.9s)"]
    store --> t2["tier 2 — unread ring<br/>.cmux-unread on the pane<br/>(persistent while unread)"]
    store --> t3["tier 3 — sidebar dot +<br/>header 'N unread'"]
    store --> desk["desktop alert<br/>(GNotification)"]

    style store fill:#1f6feb22,stroke:#1f6feb
```

Tiers 1–2 are **CSS classes** on the pane container, installed once as an
app-level provider (`AttentionStyle`) using `@accent_bg_color` — so the
rings follow the user's GNOME accent, the recorded deviation from macOS's
fixed blue. Because they are widget-class writes, `AttentionStyle.sync`
runs from the scene body every render and covers *every* mutation path
(bell, notify, mark-read, dismiss, clear, focus moves) in one place.

## The dimming + ring sync (one pass)

```mermaid
flowchart LR
    sync["AttentionStyle.sync(notifications, tabs)"] --> unread["unread = surfaces with<br/>an unread notification"]
    sync --> dim["dimmed = split panes<br/>that are NOT the focused one"]
    unread --> apply["for each registered container:"]
    dim --> apply
    apply --> c1[".cmux-unread ↔ unread"]
    apply --> c2[".cmux-unfocused ↔ dimmed<br/>(opacity 0.78)"]
```

Split dimming is macOS's `showsInactiveOverlay: isSplit && !isFocused` —
a workspace with one pane dims nothing. Both are assertable through
`debug.surfaces` css_classes (the suites drive real state and read the
classes back, no screenshots needed).

## The desktop suppression funnel

```mermaid
flowchart TB
    deliver["DesktopNotifier.deliver(tabId, selection, …)"] --> r1{"tabId == selected<br/>workspace?"}
    r1 -->|yes| s1["suppressed(workspace_active)"]
    r1 -->|no| r2{"main window<br/>has focus?"}
    r2 -->|yes| s2["suppressed(window_focused)"]
    r2 -->|no| r3{"notifications panel<br/>open?"}
    r3 -->|yes| s3["suppressed(panel_open)"]
    r3 -->|no| send["send GNotification"]

    s1 -.-> log["stderr breadcrumb:<br/>'cmux: desktop notify &lt;outcome&gt;'"]
    s2 -.-> log
    s3 -.-> log
    send -.-> log

    style send fill:#2ea04322,stroke:#2ea043
```

All three documented rules live in **one** decision path
(`DesktopNotifier.deliver`), replacing three drift-prone inline copies of
the first rule. The breadcrumb is deliberate: the suite asserts the
funnel ran without observing the desktop. Withdrawal
(`g_application_withdraw_notification`) fires when the notification is
read or its workspace closes.

## Triage

Selecting a workspace marks its notifications read (read = viewed, a
documented behavior). **Ctrl+Shift+U** jumps to the first workspace with
attention; the notifications page (sidebar swap) lists them newest-first
with jump-on-click.
