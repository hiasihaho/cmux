---
title: Browser automation
area: browser
kind: inbuilt
mac: full
linux: full
verbs: browser.eval, browser.snapshot, browser.click, browser.wait
---

# Browser automation

## Purpose

An **inbuilt harness**: the framework that lets an agent (or the human)
drive a browser pane — navigate, snapshot the accessibility tree, click by
ref, fill forms, wait for state, eval JavaScript. It is the substrate the
port's whole browser-agent story rests on, mirroring macOS's automation
surface verb-for-verb.

## Usage

```sh
cmux browser <surface> snapshot --interactive
cmux browser <surface> click e5 --snapshot-after
cmux browser <surface> wait --url-contains /dashboard
```

## Implementation

WebKitGTK `call_async_javascript_function` with a main-world→isolated-world
fallback for strict-CSP sites; the full verb suite shares one envelope
(`BrowserAutomation.swift`, roadmap/06). Proven on real SPAs (pocketyoga:
563/563 poses) and guarded by `browser-navigation-smoke` + `webdriver-smoke`.

## Kind

**inbuilt** — a product framework, not a leaf feature; measured vs macOS
like any product surface (the verbs above are macOS-parity).
