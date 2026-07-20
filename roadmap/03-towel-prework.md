# Towel Prework

Fixes and hardening towel needs before (or alongside) serving as cmux infrastructure.
Ordered by how hard they block the integration phases in
[02-integration-phases.md](02-integration-phases.md). File references are into
`~/dev/towel`.

## Blocking (before T1/T2)

1. **Put towel under git.** `~/dev/towel` is not a version-controlled repo; binaries are
   hand-copied to `~/.cargo/bin` (and the installed `towel-hist` is already one build
   behind `target/release`). Init a repo, and switch installs to `cargo install --path`.

2. **Concurrent DB writes.** cmux means many panes writing `.towel/history.db`
   simultaneously (shell hooks + towel_run). Verify/enable SQLite WAL mode and a busy
   timeout in `towel-hist/src/storage.rs`; add a concurrency test.

3. **Session-log size control.** Real logs reached 17–34 MB (`.towel/sessions/`).
   `config.toml [history] max_output_size` is written by `towel init` but **never
   enforced**, and `towel run` buffers full output unbounded in memory
   (`towel/src/run.rs`). Enforce the cap, and add rotation or zstd compression for
   session logs. Hard prereq for T2 (every pane records).

4. **Fix the `towel_run` command-ID race.** `towel-mcp/src/main.rs` fetches
   `db.recent(1)` after shelling out and assumes that row is its own — wrong as soon as
   two panes run commands concurrently (breaks `towel_annotate` follow-ups). Return the
   row ID from the insert instead (e.g. print it from `towel run`, or insert directly).

5. **`towel run` PTY size.** Hardcoded 24×80 in `towel/src/run.rs`, unlike `ai-session`
   which detects the real size. Inherit the caller's size (or accept `--cols/--rows`) —
   otherwise size-aware programs produce distorted captured output inside cmux panes.

## Important (T3 depends on data quality)

6. **Wire up error/retry extraction.** `extract_error()`/`is_retry()`
   (`towel-hist/src/analysis.rs`) are implemented and unit-tested but only run in
   `towel-hist record --output`, which no real path supplies. `towel run` / MCP
   `towel_run` insert records in `run.rs` without ever calling them, so `error_type`,
   `error_message`, `retry_of_id` stay NULL and `towel_errors`/`towel_retries` return
   empty. Call the analysis in `run.rs` on the captured output before insert. T3's
   failure-attention and notification enrichment rely on this data being real.

7. **Version consistency.** Workspace `Cargo.toml` still says 0.1.0 while `CHANGELOG.md`
   documents 0.4.6. Bump `version.workspace` and keep it in sync — matters once cmux
   checks tool versions.

8. **Parser patterns beyond Claude Code.** The V2 parser
   (`towel-hist/src/pty_parser.rs`) recognizes Claude Code's TUI specifically. For cmux
   panes add: plain human shell sessions (prompt-pattern config), Codex/OpenCode TUI
   patterns, and make the prompt regexes configurable via `config.toml` rather than
   hardcoded.

9. **Document the session-log format as a stable contract.** T2 has cmux writing the
   format directly; freeze header/delimiter/footer semantics in a spec file (essentially
   the "Session Log Format" section of `IMPORTANT-NOTES.md`, promoted to normative), and
   add a towel-side validation test so parser changes can't silently break external
   writers. Consider a `Writer:` header field (e.g. `cmux-linux`) for provenance.

10. **Crashed-session handling.** A log without a footer counts as "active" forever
    (`find_session_content_bounds`). Add staleness detection (e.g. mtime threshold) so
    `towel_sessions include_active` stays truthful. T2 mitigates this for cmux-written
    logs (cmux always writes the footer), but wrapper-written logs keep the issue.

## Nice-to-have (cleanup)

11. **`towel hist` delegation.** The `towel hist` wrapper forwards only
    search/recent/show/export, drops documented flags (`--source`, `--output`,
    `--chain`), omits annotate/stats/successful/failed/unreviewed/errors/retries, and
    invokes `towel-hist` by bare PATH name (unlike `exec`/MCP which resolve the sibling
    binary). Either complete it or remove it and document `towel-hist` as the interface.

12. **`towel exec`** doesn't check `TOWEL_ENABLED` and captures no output — consider
    deprecating in favor of `towel run`.

13. **Dead config keys.** `[layout] default` is written but never read (`towel start`
    ignores it). Either implement or stop writing it — inside cmux, layouts are cmux's
    job anyway, which is a good argument for deleting the feature and slimming towel's
    scope to memory/audit.
