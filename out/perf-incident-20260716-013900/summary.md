Symptom: Cmd+Shift+P, then Open Diff Viewer, takes too long before the viewer becomes visible.
User impact: The delay interrupts navigation and may grow when many workspaces contain diffs.
Source: User report and tagged local reproduction.
Target surface: macOS.
Build/tag: trajdf at 259ea6223f9f5490bb632dc8aa799526e26b530c.
Reproduction workload: Tagged app with many workspaces, each rooted in a dirty sample Git repository; exercise the exact command-palette action cold and warm.
Expected bad behavior: A measurable delay occurs between selecting Open Diff Viewer and the first visible viewer or loading state.
Invariant: Selecting Open Diff Viewer must reveal its surface promptly while repository work continues asynchronously.
Owner: Pending source and runtime trace confirmation.
Fix proof: Pending.
