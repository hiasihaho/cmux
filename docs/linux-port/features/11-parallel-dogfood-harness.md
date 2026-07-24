---
title: Parallel-dogfood harness
area: dev-tooling
kind: meta
detects: scope overlap between packages (refuses to dispatch); scope-compliance of each branch
check: pkg-harness.sh check
adr: 0001
---

# Parallel-dogfood harness

## Purpose

A **meta harness**: runs several agents on **disjoint** work packages at
once (one claude-teams teammate per package), each in its own git worktree +
scratch cmux instance + browser profile, integrated through a local bare
repo — so parallel branches merge conflict-free by construction and the
human's checkout is never touched until a deliberate promote.

## Usage

```sh
pkg-harness.sh init --from ~/cmux
pkg-harness.sh add <id> --scope "…" [--build]
pkg-harness.sh check            # refuse to dispatch on scope overlap
pkg-harness.sh tag/panes/review # ADR-0009/0013: address agents by name/tag
pkg-harness.sh collect / integrate
```

## Implementation

Static scope-disjointness is the safety property; build-isolation shares the
ghostty shim + a reflinked `.build` so code packages build incrementally
(~30s). Proven across two real batches (PROGRESS 2026-07-23/24).

## Kind

**meta** — dev tooling; measured by its `check`/`--check` guards, not by
shipping verbs. No macOS equivalent (it's a port-development invention).
