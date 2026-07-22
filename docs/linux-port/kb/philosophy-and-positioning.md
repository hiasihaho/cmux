# Philosophy and positioning — how upstream frames the product

> Sources: https://cmux.com/en/blog/zen-of-cmux, /en/blog/cmux-home,
> /en/blog/claude-code-best-worktree-manager, /en/blog/gpl (title), /en/compare,
> /en/compare/multiple-claude-code-agents-parallel, /en/agents/claude-code,
> /en/guides, /en/blog/introducing-cmux (title), /en/blog/show-hn-launch (title).
> Crawled 2026-07-22 via the port's own browser.

## The Zen: "a primitive, not a solution"

Load-bearing quotes: "cmux is a primitive, not a solution. It gives you a
terminal, a browser, notifications, workspaces, splits, tabs, and a CLI to
control all of it." … "Nobody has figured out the best way to work with
agents yet … Give a million developers composable primitives and they'll
collectively find the most efficient workflows faster than any product team
could design top-down."

Direct consequence (cmux-home post): **worktrees will never be built in**.
"cmux should bend to your workflow instead of forcing one on you." cmux-home
is the reference pattern — a small Rust TUI launching Claude/Codex workspaces
from command templates, "built entirely on cmux primitives. Fork it and make
it yours." This philosophy explains why customization (actions, layouts,
plus-button, Dock, custom sidebars) is the product's growth surface rather
than opinionated features.

## The super-repo pattern (worktree-manager post)

One control checkout ("super repo", e.g. cmuxterm-hq) encodes the team's whole
engineering OS: where real repos live, how worktrees are created, how repos
pair, per-workspace setup scripts, PR/review/merge rules, reusable skills,
and "the rules agents follow to avoid stepping on each other." Claude
Code/Codex are "better worktree managers than most built-in worktree
managers" because they read repo rules, run scripts, create/clean worktrees
across repos, fix conflicts, push, open PRs, and merge after gates pass.
Named flows: task-worktree-pr, autoreview. cmux's role is only "giving the
workflow a surface": custom commands, CLI/socket, skills, plus-button.

## The supervision pitch (compare pages, agents pages)

Positioning sentence: cmux is strongest for "native macOS performance, visible
multitasking, notification rings, keyboard shortcuts like Cmd+Shift+U and
Cmd+Control+U, and no lock-in to one agent runtime."

The parallel-agents guide's comparison table (distilled): one-terminal-tab
(weak visibility) < tmux panes (medium) < manual worktrees (strong isolation,
manual visibility) < **cmux workspaces** (works with any repo setup, strong
visibility) and **cmux claude-teams** for teammate sessions. Key claims:
isolation is *your* choice (branch/worktree/checkout/repo per task — cmux
doesn't create them); "cmux does not replace Claude Code, Codex, or
OpenCode … cmux adds workspaces, notifications, and socket automation around
the terminal session"; ⌘⇧U is "the core supervision shortcut."

Compare set (17 targets): Conductor, Superset, Cursor, Devin, VS Code, Zed,
Warp, Ghostty, iTerm2, Kitty, Alacritty, WezTerm, tmux, OpenCode, Herdr,
Windsurf/Devin-Desktop + a best-of roundup. Per-agent landing pages exist for
claude-code, codex, opencode, gemini-cli, aider, amp, cursor-cli — all
following the same five-point pitch (organized parallel sessions,
notification rings, teams-as-native-panes where applicable, iOS companion,
scriptable CLI+socket).

## Product facts

Free and open source for macOS; relicensed AGPL-3.0 → **GPL-3.0**
(March 2026). Built on libghostty ("the engine behind Ghostty") + additions.
By Manaflow. Launched 2026-02-12; #2 on Show HN, shared by Mitchell
Hashimoto. macOS 14+. Sparkle auto-updates; Nightly channel + separate
`cmux-nightly://` scheme; Founders Edition bundles iOS beta early access.

## Port relevance

The port's own docs philosophy ("closed loop", dev-instance, dogfood) is a
direct instance of the Zen. When making Linux UX calls, prefer exposing a
primitive + CLI verb over baking a workflow — that is what upstream would do,
and it is why the socket surface (which the port mirrors well) is the
product's real API.
