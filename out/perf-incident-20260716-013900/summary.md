Symptom: Cmd+Shift+P, then Open Diff Viewer, takes too long before the viewer becomes visible.
User impact: The delay interrupts navigation and may grow when many workspaces contain diffs.
Source: User report and tagged local reproduction.
Target surface: macOS.
Build/tag: trajdf at 5417bf875b.
Reproduction workload: Tagged app with 40 workspaces, each rooted in an independent dirty sample Git repository; exercise the exact command-palette action cold and warm.
Expected bad behavior: A measurable delay occurs between selecting Open Diff Viewer and the first visible viewer or loading state.
Invariant: Selecting Open Diff Viewer must reveal its surface promptly while repository work continues asynchronously.
Owner: CLI diff-viewer session preparation and ContentView command-palette indexing. The persistent Rust sidecar was idle during the UI delay.
Baseline: Palette shortcut response 958.3 ms, query response 419.5 ms, and Enter to first focused browser 2056.1 ms.
Fixed cold: Palette visible with results in 172.7 ms, Enter response in 165.3 ms, first focused browser in 705.2 ms, and final rendered file in 2672.3 ms.
Fixed warm: Palette visible with results in 158.2 ms, Enter response in 19.2 ms, first focused browser in 357.2 ms, and final rendered file in 1423.5 ms.
Fix proof: Exact shortcut measurements are in fixed-cold-exact.json and fixed-warm-exact.json. Screenshots show the loading skeleton before the final rendered sample.txt diff.
Mechanism: Open the lightweight browser page before preparing the Rust session and renderer, replace recursive 709-file asset checks with content-keyed manifests, hard-link assets into a cold cache when possible, and preserve the command-palette corpus and Nucleo index until its fingerprint changes.
