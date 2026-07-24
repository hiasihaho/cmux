---
title: Attention & notifications
area: notifications
kind: inbuilt
mac: full
linux: full
verbs: notification.create, notification.list, notification.jump_to_unread
---

# Attention & notifications

## Purpose

An **inbuilt harness**: the pipeline that turns "an agent needs you" into a
signal — from bell / `cmux notify` / agent hooks, through a notification
store, to escalating attention tiers (flash ring → pane ring → sidebar
badge) and desktop delivery with suppression rules. The port's whole
supervision loop rests on it.

## Usage

```sh
cmux notify --title "Claude" --subtitle Waiting --body "Needs input"
cmux jump-to-unread          # Ctrl+Shift+U
```

## Implementation

`DesktopNotifier.deliver` (one suppression funnel), `AttentionStyle` (the
accent-ring tiers as CSS classes), the notification store; the full
lifecycle mirrors macOS (wiring/05-attention).

## Kind

**inbuilt** — a product framework; measured vs macOS (parity).
