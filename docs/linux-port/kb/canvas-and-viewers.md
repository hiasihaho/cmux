# Canvas and the viewer panels (markdown, diff, file preview)

> Sources: https://cmux.com/en/docs/keyboard-shortcuts (Canvas + Diff Viewer
> sections), /en/docs/configuration (markdown.*, fileEditor.*), /en/blog/markdown-viewer,
> /en/docs/changelog (0.64.11, 0.64.15, 0.64.16, 0.64.17). Crawled 2026-07-22
> via the port's own browser.

## Canvas — freeform 2D layout (experimental, 0.64.16+)

"A freeform 2D layout mode where panes float on an infinite, pannable canvas"
— a per-workspace *alternative* to the tiling split tree. Alignment and
distribution commands live in the command palette; a minimap exists (#6105).
Shortcuts (all rebindable; `workspaceCanvasLayout` is a `shortcuts.when`
context key): toggle canvas layout ⌃⌘C · reveal focused pane ⌃⌘R · overview
zoom ⌃⌘O · zoom in/out ⌥⌘= / ⌥⌘- · actual size ⌘0 · tidy into grid ⌃⌘T.

## Markdown viewer

Webview-based renderer (rewritten 0.64.5, contributed by @tobi): rich
formatting, live reload, atomic file replacement, drag-from-file-explorer.
Open: `cmux open README.md`, `cmux markdown open plan.md` (skill), Cmd-click
on .md when `app.openMarkdownInCmuxViewer` is on, or right-sidebar drag.
Defaults: `markdown.fontSize` 15pt, `fontFamily` (empty ⇒ system stack),
`maxWidth` 980px; live zoom ⌘=/⌘-/⌘0. Vim/Emacs scroll keys shared with the
diff viewer (j/k, ⌃D/⌃U, ⌃N/⌃P). Intended use per skills docs: "show plans,
docs, notes, and task lists beside the terminal while work is happening."

## Diff viewer

`cmux diff` or ⌃⌘⇧D opens a CodeView-based diff viewer; large git diffs are
*streamed* before full render (0.64.11). Searchable, uncapped branch-base
picker with smart defaults (0.64.17). **Review comments** (0.64.15): comment
on changed lines, persisted per repo, and "attach the comment set to a
terminal TextBox to hand structured review feedback straight to an agent."
Vim-keyed: j/k smooth step, ⌃D/⌃U half page, ⌃N/⌃P Emacs step, ⇧G bottom,
g g top, `/` file search, ] f / [ f next/previous file.

## File preview / editor

Cmd-click readable local files opens previews in cmux (text, code, PDFs,
images, audio, video, Quick Look) when `app.openSupportedFilesInCmux` is on;
header Open With menu lists the default + compatible apps. Plain-text editor:
`fileEditor.wordWrap`, save with ⌘S, zoom shortcuts, smooth Vim/Emacs nav in
viewers (0.64.18). Escape-hatch: `app.preferredEditor` command +
`fileExplorer.doubleClickAction`. Related one-offs: Xcode-style project
visualizer pane (#4996); "Open Current Directory in Devin/VS Code/Cursor/Zed/
Xcode/Finder" palette commands.

## Port relevance

None of these exist on Linux (CONCEPTS marks viewers/canvas Later). Newly
learned details: canvas is per-workspace with its own `when` context key (so
shortcut handling must be layout-aware), diff review comments are an
agent-handoff mechanism (pairs with TextBox), and the markdown viewer is a
webview (the port's WebKitGTK stack could reuse its own browser panel for it).
