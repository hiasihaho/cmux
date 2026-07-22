# cmux.json configuration schema — families and contracts

> Source: https://cmux.com/en/docs/configuration (full schema reference),
> /en/docs/custom-commands, /en/docs/dock (dock.json), /en/docs/textbox.
> Crawled 2026-07-22 via the port's own browser.
> Machine-readable canonical schema:
> https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json
> (source: web/data/cmux.schema.json in the repo — the port can consume it directly).

## File model

- Terminal *rendering* stays in Ghostty config (`~/.config/ghostty/config`;
  cmux adds keys like `sidebar-font-size`, `surface-tab-bar-font-size`,
  `split-divider-color`).
- App-owned settings: `~/.config/cmux/cmux.json` — JSON **with comments and
  trailing commas** (JSONC). Missing file ⇒ cmux writes a commented template.
- Project-scoped: `.cmux/cmux.json` (fallback: `./cmux.json`) — may override
  actions, commands, UI action wiring, and notification hooks, **not** global
  app preferences. First run of a project action prompts for **trust; trust is
  per exact action fingerprint, not per repo**.
- Precedence: global cmux.json > Settings-window values; legacy
  `settings.json` / Application Support files are read-only fallback.
- Reload: **⌘⇧,** or `cmux reload-config` (also re-reads Ghostty config).
- `schemaVersion: 1`; newer versions parse known keys best-effort.
- Schema errors: cmux falls back to the next valid config and shows a
  "cmux.json Schema Error" row in the Command Palette that opens the file.

## Families (every top-level key, with the load-bearing members)

### app
`language` (system + 18 locales) · `appearance` · `appIcon` ·
`windowTitleTemplate` (placeholders `{windowId} {windowToken}
{activeWorkspace} {activeDirectory} {defaultTitle} {appName}`) · `menuBarOnly` ·
`newWorkspacePlacement` (top|afterCurrent|end) ·
`forkConversationDefaultDestination` (right|left|top|bottom|newTab|newWorkspace) ·
`workspaceInheritWorkingDirectory` (default true) · `minimalMode` ·
`keepWorkspaceOpenWhenClosingLastSurface` · `focusPaneOnFirstClick` ·
`preferredEditor` · `openSupportedFilesInCmux` (Cmd-click previews: text,
code, PDF, image, audio, video, Quick Look; header has Open With menu) ·
`openMarkdownInCmuxViewer` · `globalFontMagnification` (percent, whole UI) ·
`reorderOnNotification` (default true — unread workspaces float up) ·
`iMessageMode` · `sendAnonymousTelemetry` · `confirmQuit`
(always|dirty-only|never; legacy `warnBeforeQuit`) · `warnBeforeClosingTab` ·
`warnBeforeClosingTabXButton` · `hideTabCloseButton` ·
`renameSelectsExistingName` · `commandPaletteSearchesAllSurfaces`.

### terminal
`showScrollBar` (auto-suppressed on alt-screen TUIs) · `scrollSpeed` ·
`sessionContentMaxWidth` + `sessionContentAlignment` · `copyOnSelect` ·
`autoResumeAgentSessions` (default true) · `showTextBoxOnNewTerminals` ·
`focusTextBoxOnNewTerminals` · `textBoxMaxLines` (10) ·
`textBoxDefaultSubmitAction` ("text-entry") · `textBoxSubmitActions` (array) ·
`agentHibernation` {enabled, idleSeconds (5), maxLiveTerminals (12)} ·
`rendererRealization` (reclaim off-screen Metal renderer memory,
non-destructive, on by default) · `resumeCommands` (signed command-prefix
approvals, written by the app) · `uploadCommands` (host-scoped scp replacement
rules for SSH file drops: stdout inserted at cursor, first matching enabled
rule wins, non-zero exit inserts nothing).

### notifications
`dockBadge` · `showInMenuBar` · `unreadPaneRing` · `paneFlash` ·
`suppressOnlyFocusedSurface` (default false — see notifications-contract) ·
`agentPermissionPrompt` (true) · `agentTurnComplete`
(whenIdle|always|never) · `agentIdleReminder` (true) · `sound` (named presets
| custom_file | none) · `customSoundFilePath` · `command` (shell hook) ·
`hooksMode` (append|replace) · `hooks` (stdin/stdout JSON policy filters).

### sidebar
`hideAllDetails` · `wrapWorkspaceTitles` · `showWorkspaceDescription` ·
`beta` · `branchLayout` (vertical|inline) · `showNotificationMessage` +
`notificationMessageLineLimit` (12) · `showBranchDirectory` ·
`showPullRequests` · `watchGitStatus` (fs-watch instead of polling) ·
`makePullRequestsClickable` · `openPullRequestLinksInCmuxBrowser` ·
`openPortLinksInCmuxBrowser` · `showSSH` · `showPorts` · `showLog` ·
`showProgress` · `showAgentActivity` (spinner) · `loadingSpinnerPosition` /
`notificationBadgePosition` (leading|trailing) · `showCustomMetadata` ·
`rightMaxWidth`.

### workspaceGroups
`newWorkspacePlacement` (afterCurrent|top|end) · `byCwd` — map of cwd patterns
(longest-match; `*`/`?` ⇒ fnmatch glob with `~` expansion; else path prefix,
matched against the **anchor workspace's cwd**) to per-group customization.

### workspaceColors
`indicatorStyle` (leftRail|solidFill|rail|border|wash|lift|typography|
washRail|blueWashColorRail) · `selectionColor` · `notificationBadgeColor` ·
`colors` (the full named palette — 16 built-ins; deleting keys removes picker
entries, adding extends it) · legacy `paletteOverrides` / `customColors`.

### sidebarAppearance
`matchTerminalBackground` · `tintColor` · `lightModeTintColor` /
`darkModeTintColor` · `tintOpacity` (0.03; terminal transparency belongs to
Ghostty `background-opacity`/`background-blur`).

### automation
`socketControlMode` (off|cmuxOnly|automation|password|allowAll|… legacy
aliases) · `socketPassword` · `claudeCodeIntegration` (true) ·
`claudeBinaryPath` · `workspaceAutoNaming` (opt-in AI naming) ·
`autoNamingAgent` ("auto" or agent slug) · `ripgrepBinaryPath` ·
`suppressSubagentNotifications` (true) · `ampIntegration` ·
`cursorIntegration` · `geminiIntegration` · `kiroIntegration` ·
`kiroNotificationLevel` (minimal|standard|verbose) · `portBase` (9100) ·
`portRange` (10) — workspace `CMUX_PORT` assignments.

### ui
`newWorkspace` {action, contextMenu (aka rightClick)} — plus-button wiring ·
`surfaceTabBar.buttons` — replaces the default surface tab bar button list;
entries are action IDs or button objects {action, title, icon, tooltip}.

### agentChat
`url` (default http://127.0.0.1:7739; /healthz probed) · `startCommand` ·
`keys` · `fonts` — a machine-local Agent Chat GUI server opened in a browser
workspace by a built-in action.

### browser
`defaultSearchEngine` (17 named + custom) · `customSearchEngineName` /
`customSearchEngineURLTemplate` (`{query}` or `%s`) · `showSearchSuggestions` ·
`theme` · `discardHiddenWebViews` (true) + `hiddenWebViewDiscardDelaySeconds`
(300) · `askWhereToSaveDownloads` · `openTerminalLinksInCmuxBrowser` ·
`interceptTerminalOpenCommandInCmuxBrowser` · `hostsToOpenInEmbeddedBrowser` ·
`urlsToAlwaysOpenExternally` · `insecureHttpHostsAllowedInEmbeddedBrowser`
(localhost defaults) · `showImportHintOnBlankTabs` · `reactGrabVersion`.

### markdown / fileEditor / fileExplorer
`markdown.fontSize` (15) / `fontFamily` / `maxWidth` (980) ·
`fileEditor.wordWrap` · `fileExplorer.doubleClickAction`
(preview|defaultEditor|preferredEditor).

### shortcuts
`showModifierHoldHints` · `bindings` (string | two-item chord array | null/""/
"none"/"clear"/"unbound"/"disabled" to unbind; numbered actions store `1` and
match 1–9) · `when` — **VS Code-style per-action context predicates**: boolean
keys `sidebarFocus, browserFocus, markdownFocus, filePreviewTextEditorFocus,
terminalFocus, commandPaletteVisible, terminalFindVisible,
workspaceCanvasLayout`; typed keys `sidebarMode` (files|find|sessions|feed|
dock), `paneCount`, `workspaceCount`; operators `! && || () == != =~ < <= > >=
in [a,b]`. A binding fires (and conflicts) only when its clause holds.
The full default binding list (~90 action ids in 9 groups) is on the
configuration page; the port's shortcut work should read the action-id list
from there or from the schema JSON.

## actions / commands (custom-commands page)

- `commands`: array of reusable entries — simple (`name`, `command`, `confirm`,
  `keywords`, run in the focused terminal) or workspace commands (`workspace`
  {name, cwd, color, env, setup, layout}).
- Layout tree: split nodes {direction horizontal|vertical, split 0.1–0.9,
  children[2]} and pane nodes {pane:{surfaces:[…]}}; surface = {type
  terminal|browser, name, command, cwd, env, url, focus}. Cwd resolution:
  `.`/omitted ⇒ workspace cwd; `./x` relative; `~/x` home; absolute as-is.
- `actions` (nightly registry): stable IDs shared by surface tab bar, Command
  Palette, and action-level shortcuts. Types: `builtin`, `command`
  (target currentTerminal|newTabInCurrentPane), `agent`, `workspaceCommand`,
  `workspace` (inline definition + `restart`: new|ignore|recreate|confirm;
  auto-offered in the plus-button menu, `newWorkspaceMenu` opts in/out).
  Fields: title, subtitle/description, keywords, palette (default true),
  shortcut, confirm, icon ({type symbol|emoji|image}). Built-in IDs
  `cmux.newTerminal`, `cmux.newBrowser`, `cmux.splitRight`, `cmux.splitDown`
  can be overridden — changing behavior behind every shared entrypoint.
- "Save Workspace as Layout" (plus-button right-click, or ⌃⌘S) captures the
  current workspace's splits/directories/running agents/browser tabs into the
  actions block; "Default for New Workspace" sets `ui.newWorkspace.action`
  (project-local wins).

## dock.json (separate file, same trust model)

`.cmux/dock.json` (project, nearest parent, nested trees) >
`~/.config/cmux/dock.json` (global). Object with `controls`:
`[{id, title, command, cwd?, height?, env?}]` — each control is a command in
its own Ghostty-backed terminal section of the right sidebar; controls without
`height` share remaining space; project configs prompt for trust.
