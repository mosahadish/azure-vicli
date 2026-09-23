# How it works and development

_Part of the [azure-vicli](../README.md) docs._

## How it stays fast

- **One pass for the list.** The data provider connects once per
  organization, requests the assigned and created listings together, and
  runs each PR's thread and build lookups concurrently under a bounded gate,
  fetching threads once per PR. Results keep listing order so the dashboard
  never reshuffles.
- **One provider process per session.** The first provider call starts
  `azure-cli.py --serve` and every later call reuses it over stdin/stdout,
  so no keypress pays python's start-up cost or re-reads the config file
  (see [Architecture](#architecture)).
- **Nothing blocks on open.** The reviewer's file list, commit log, threads
  and diffs all load through background jobs behind placeholder rows.
- **Content prefetch.** Resting the cursor on a PR warms its branches, then
  fills a shared cache with the file list, the commit log, every file's diff
  from a single `git diff` over the range, and the comment threads. After
  each list load a warm-all pass does the same for every open PR, four at a
  time, in the order Actionable, created by me, Drafts, Signed off, Waiting,
  with one repository-wide fetch per clone only when something changed.
- **Polling that stays out of the way.** One list poll and one thread poll
  per minute, never overlapping themselves, and a half-second hover debounce.

The cache is keyed by PR id and its last-activity timestamp, so a push
invalidates it automatically. It holds 24 PRs by default. Every number in
this section - the poll interval, the hover debounce, the warm-all
concurrency, the cache size, the thread-cache TTL - is a
[`setup({timing=...})`](configuration.md#setup-options) tunable; `WARM_RANK` (the warm-all ordering, Actionable/Created/Drafts/
Signed off/Waiting) is the one knob still hard-coded, in
`lua/azure-cli/dashboard.lua`.

## Architecture

The Lua side is a proper Neovim plugin tree (`require()`-based, installable
with lazy.nvim/packer - see [Install](../README.md#install)):

```
lua/azure-cli/
  init.lua        setup(), open_dashboard()/open_review(id)/open_workitems(), standalone flag
  config.lua      setup() defaults (incl. every surface's `keys`) + merge/validate, provider_cmd()
  keys.lua        resolves a surface+action to the configured key(s); binds, renders ? popup lines
  ui.lua          shared winbar formatting (UI.winbar), the column-width solver (UI.layout), floats, highlight links
  shell.lua       shared housekeeping: flash, config file, browser/clipboard, JSON state files, failed-job summary
  state.lua       the one shared table every surface reads/writes (list/content caches, daemon state, ...)
  migrate.lua     one-time data-file rename, M.ensure(old, new)
  cache.lua       per-PR content cache + prefetch pipeline
  notify.lua      desktop toast notifications + in-editor flash notifications
  merge.lua       the complete-PR dialog shared by the dashboard's and the reviewer's gm
  log.lua         in-session error log (M.record/M.summary) + :AzureCli log
  editor.lua      floating comment editor (drafts, @ mentions)
  rpc.lua         shared azure-cli.py --serve daemon client
  dashboard.lua   PR dashboard
  review/
    init.lua               reviewer
    nav.lua                 reviewer-feature module: gd/gr/gf/g-slash, the peek view
    comments.lua            reviewer-feature module: edit/delete own comments
    commits.lua             reviewer-feature module: per-commit diffs
    range.lua                reviewer-feature module: range comments
    batch.lua                reviewer-feature module: batched review
    since.lua                reviewer-feature module: changes since my last review
    filelist.lua             file-list layout: status letters, +/- stats, directory grouping
  workitems/
    dashboard.lua   work-items dashboard
    view.lua        work-item detail view
plugin/azure-cli.lua   defines :AzureCli (see Commands) - no side effects beyond that
standalone/init.lua    the launcher's Neovim entry point: adds the plugin root
                       to 'runtimepath', calls setup(), applies the standalone
                       colour palette, opens the dashboard in the current window
azure-cli.py           headless data provider + launcher + daemon (repo root)
azure-cli, azure-cli.cmd   one-line launchers (repo root)
```

```
azure-cli.py (python, via         headless data provider + launcher + daemon
the azure-cli/azure-cli.cmd
launchers, running standalone/init.lua)
  --list  ───────────────▶ dashboard.lua      PR dashboard (Neovim)
  --threads/--post/...            │  <CR>            ▼
  (PR-action subcommands) ◀───────┤               review/init.lua   reviewer
  --wi-list/--wi-detail/          │  W                │ gd/gr/gf, comments, votes
  --wi-state/--wi-edit            ▼                   ▼
  (work-item subcommands) ◀── workitems/         azure-cli.py    REST via urllib (threads, comments,
                             dashboard.lua,                      votes, complete, work items,
                             view.lua                            prefetch) - via rpc.lua's daemon
                                │                                 client, no bash in the loop
                          cache.lua    shared content cache + prefetch pipeline
                          notify.lua   desktop toast notifications
                          rpc.lua      shared azure-cli.py --serve daemon client
                          keys.lua     resolves every binding above to its configured key(s)
                          ui.lua       shared winbar formatting + the dashboard's column-width solver
                          shell.lua    flash, config file, browser/clipboard, JSON state files, job errors
                          review/comments.lua  edit/delete your own comments
                          review/commits.lua   per-commit diffs
                          review/range.lua     range comments
                          review/batch.lua     batched review
                          review/filelist.lua  file-list layout (status/stats/grouping)
```

Every one of those provider calls (`--list`, `--threads`/`--post`/..., `--wi-*`,
the branch-prefetch jobs) goes through `rpc.lua`'s `M.run`, a drop-in
replacement for `vim.fn.jobstart`. The first call in a session starts
`azure-cli.py --serve` once and keeps it running for the rest of the
session; every call after that sends a small JSON request over its stdin
instead of spawning a fresh python process, and gets a JSON response back
over its stdout, so python's start-up cost (plus re-reading
`azure-cli.yml`) isn't paid on every single keypress. `M.run` falls back to a plain
`vim.fn.jobstart` automatically whenever the daemon isn't usable (disabled,
not started yet and failed to start, or mid-restart after a crash), so
nothing about how a caller uses it changes; git commands (diffs, `git grep`,
code navigation, ...) never go through the daemon - only calls to
`azure-cli.py` itself do. `require()` caches every module above, so
`rpc.lua`'s daemon state, `cache.lua`'s content cache and
`notify.lua`'s opt-out flag are naturally shared across every surface
through `lua/azure-cli/state.lua` - see that file's own header comment. See
"How it stays fast" above and rpc.lua's own header comment for the full
daemon lifecycle/fallback rules and wire protocol.

| File | Role |
|---|---|
| `azure-cli.py` | Data provider: classifies PRs, gathers thread/mention/build status, emits NDJSON for `--list`, re-queues builds, prints PATs/identity, runs every PR-action subcommand (`--threads`, `--post`, `--vote`, `--complete`, ...), every work-item subcommand (`--wi-list`, `--wi-detail`, `--wi-state`, `--wi-edit`) and the branch prefetch modes (`AZVICLI_PREFETCH=1`/`all`); `--serve` runs all of the above as a long-lived daemon instead of one process per call (see below); with no flags, launches Neovim via `standalone/init.lua`. Standard-library-only python (urllib for REST, no third-party packages). |
| `azure-cli`, `azure-cli.cmd` | One-line launchers so `azure-cli.py` stays a single executable token (`$AZVICLI_EXE`) for git-bash/cmd.exe. |
| `standalone/init.lua` | The launcher's Neovim entry point (`nvim -u standalone/init.lua`) - stands in for a whole init.vim, so it's the one place that adds the plugin root to `'runtimepath'` by hand; sets the standalone colour palette and marks the session standalone (`azure-cli.set_standalone(true)` - dashboard.lua's quit key reads this to decide `qa!` vs closing a tab) before opening the dashboard in the current window. |
| `plugin/azure-cli.lua` | Defines `:AzureCli` (see [Commands](commands-and-keys.md#commands)) - loaded automatically by any plugin manager; no side effects beyond the command definition. |
| `lua/azure-cli/init.lua` | Plugin entry point: `setup()`, `open_dashboard()`/`open_review(id)`/`open_workitems()`, the standalone flag. |
| `lua/azure-cli/config.lua` | `setup()`'s defaults and merge/validation for every option (`keys` - see [Keys](commands-and-keys.md#keys) - plus `python`/`config`/`timing`/`hide_ancient_days` - see [setup() options](configuration.md#setup-options)), plus `provider_cmd()`/`provider_argv(...)`/`plugin_root()`/`config_path()` (resolve `azure-cli.py`'s location/interpreter, build a job's argv, and resolve the config file path - shared by every surface below instead of each re-deriving them). |
| `lua/azure-cli/keys.lua` | Resolves a surface+action to the user's configured key(s) and binds it (`M.bind`); renders a `?` popup line or a lone "key: hint" chip from the same resolution (`M.line`/`M.label`) so neither ever hard-codes a key name. |
| `lua/azure-cli/ui.lua` | Shared UI building blocks: the pure, vim-free `UI.winbar`/`UI.layout` (see "Pull request dashboard" and "Reviewer" below), plus the one floating-window builder (`UI.open_float`, sized by `UI.big_dims`), `UI.plain_window`, `UI.filter_prompt` and `UI.link_hl` (every surface's highlight groups, linked with `default = true` so a colorscheme wins). |
| `lua/azure-cli/shell.lua` | The small housekeeping helpers every surface needs and each one used to keep a private copy of: `notify` (notify.lua's flash), `config_path`/`open_config_file` (the `gO` key), `open_url`/`yank_url` (browser and clipboard), `read_json`/`write_json` (the saved-state files under Neovim's data directory, with `migrate.lua` folded in) and `job_error` (a failed provider job's full text to `log.lua`, its one-line summary back to the caller). |
| `lua/azure-cli/state.lua` | The one shared table every surface reads/writes - `require()` caching is what makes one table naturally shared across every requirer. |
| `lua/azure-cli/migrate.lua` | `M.ensure(old_path, new_path)`: copies a data file's content into its new name the first time the new one doesn't exist yet, then leaves the old one alone - used by the dashboard and reviewer for their saved-state files under Neovim's data directory. |
| `lua/azure-cli/dashboard.lua` | PR dashboard: rendering, badges, hover and warm-all prefetch, optimistic actions - runs `azure-cli.py` for every PR action/prefetch job (`PROVIDER_CMD`, from `config.lua`) through `rpc.lua`, no bash in the loop. |
| `lua/azure-cli/review/init.lua` | Reviewer: file list, diffs, comments, optimistic writes, code navigation and peek view - `EXT.provider` builds the `azure-cli.py` argv every write/fetch runs, sent through `EXT.rpc`/`ctx.rpc` (`rpc.lua`). |
| `lua/azure-cli/cache.lua` | Per-PR content cache shared by dashboard and reviewer, and the prefetch pipeline that fills it - its own provider calls (the threads fetch) go through `rpc.lua` too; git stays direct. |
| `lua/azure-cli/notify.lua` | OS-level toast notifications (Windows/Linux/macOS), rate-limited, `require()`'d by the dashboard; also `M.flash` - the in-editor floating status notifications (see [setup() options](configuration.md#setup-options)' `notifications`). |
| `lua/azure-cli/merge.lua` | The complete-PR dialog (merge type, work-item/branch toggles, build/threads/votes summary and warnings) that both the dashboard's `gm` and the reviewer's `gm` open; its `MERGE_TYPES` list, `build_label`, `warnings` and `lines` are pure and shared with the winbar. |
| `lua/azure-cli/log.lua` | The in-session error log every provider-failure path records into (`M.record`) and shows a one-line summary from (`M.summary`); `M.open` is [`:AzureCli log`](commands-and-keys.md#commands). |
| `lua/azure-cli/editor.lua` | The floating comment editor (see [Reviewer](reviewer.md#reviewer)'s "Comment editor") - drafts, title formatting, `@` mention translation. |
| `lua/azure-cli/rpc.lua` | Shared client for the `azure-cli.py --serve` daemon - one daemon per Neovim session, `require()`'d by every file above; `M.run(argv, opts)` is a `vim.fn.jobstart`-compatible drop-in that routes a provider call to the daemon when it's usable and falls back to a plain job otherwise. |
| `lua/azure-cli/review/nav.lua` | Reviewer-feature module (see "Extending the reviewer" below): code navigation without an LSP - `gd` (go to definition, ranked by `def_score`), `gr` (find references), `gf` (open this file at the PR's revision), `g/` (search the changed files), the two-float peek view and the read-only revision buffers you keep navigating from, with `<BS>` walking back one jump. Loaded **first** of the review modules: `review/{commits,followup,since}.lua` reach the peek and those buffers through the `ctx` fields filled in from its return value. |
| `lua/azure-cli/review/comments.lua` | Reviewer-feature module (see "Extending the reviewer" below): edit/delete your own PR comments, from the K popup or the Overview page. |
| `lua/azure-cli/review/commits.lua` | Reviewer-feature module: per-commit diffs - `gc`'s commit list, a commit's changed files, and a single commit's diff for one of them. |
| `lua/azure-cli/review/range.lua` | Reviewer-feature module: visual-mode `c` comments on a selected range of lines instead of just one. |
| `lua/azure-cli/review/batch.lua` | Reviewer-feature module: batched review - `gB` queues comments/replies instead of sending them right away, `gQ` lists the queue, `gS` submits it all with a vote. |
| `lua/azure-cli/review/since.lua` | Reviewer-feature module: `gi` toggles showing only changes since your last review. |
| `lua/azure-cli/review/followup.lua` | Reviewer-feature module: `gu` opens a picker of every thread you started, tagged changed/unchanged/n/a for whether anything landed nearby since your last review. |
| `lua/azure-cli/review/filelist.lua` | The file list's layout: `M.build` (pure) groups files by directory, trims their common prefix, and formats each row's status letter/+-stats/comment count; `M.render` writes it into the list buffer. `EXT.refresh_file_list` (review/init.lua) is the only caller - every row->file lookup goes through the model it returns instead of indexing `files` by row. |
| `lua/azure-cli/workitems/dashboard.lua`, `lua/azure-cli/workitems/view.lua` | Work-item dashboard and detail view - run `azure-cli.py` for every work-item fetch/action (`--wi-list`/`--wi-detail`/`--wi-state`/`--wi-edit`), the same `PROVIDER_CMD` pattern `dashboard.lua` uses, through `rpc.lua`; no bash in the loop. |
| `lua/azure-cli/workitems/states.lua` | Pure `work_items.states:` rank/highlight mapping (see [Work items](work-items.md#work-items)), shared by `workitems/dashboard.lua`/`workitems/view.lua`; falls back to the pre-`states:` hard-coded tables when the provider sends no `states` field. |
| `install.sh` | Dependency check/install for the standalone launcher (Neovim, git, python). The config template is written by `lua/azure-cli/firstrun.lua` through `azure-cli.py --init-config` on the first launch. |

State that survives restarts lives in Neovim's data directory: the per-PR
"seen" snapshot for the unread badge, per-thread read counts, and persistent
comment text filters.

## Development

```
bash tests/run.sh   # whole test suite: Lua/shell checks + python unit tests
```

There's no build step - `azure-cli.py` runs directly under python, and the
Lua/shell files are interpreted as-is. Requires bash, git, luajit and
python3.

Most files use CRLF line endings; edit them byte-wise. The Lua files can be
syntax-checked with `luajit -bl` on a CR-stripped copy and the scripts with
`bash -n`. `azure-cli.py` and `tests/test_*.py` are plain LF. Build outputs
(`__pycache__/`) are ignored by git; prefetch markers and the `.userid`
cache live under Neovim's/the platform's cache directory (see
`AZVICLI_PREFETCH_DIR` in [Environment variables](configuration.md#environment-variables)),
not inside the repo.

`tests/run.sh` is the whole test suite (bash, git, luajit and python3; a
real `nvim` on PATH enables the stricter Neovim load check and the headless
smokes - see below): a `luajit -bl` syntax check and a global-name scan
(catches a `local` read before its declaration - easy to do by accident in
these long, forward-referencing files) over every file under `lua/`,
`plugin/` and `standalone/` (globbed, not a hand-written list, so a new
module is picked up automatically), `bash -n` over every shell script (and
the `azure-cli` launcher), twenty-one Lua unit tests under `tests/`,
`python3 -m unittest discover` over `tests/test_*.py`, and five headless
`nvim` smokes:

| Test | Covers |
|---|---|
| `test-split.lua` | `cache.lua`'s `split_diff`/`parse_diff` against per-file `git diff` output, over a real multi-file range of this repo's own history (`--no-renames` throughout - see the file's own header comment for why a rename's single-file vs. whole-diff hunks aren't guaranteed identical otherwise, independent of split_diff/parse_diff correctness) |
| `test-prefetch.lua` | The prefetch pipeline end to end (caching, coalescing concurrent calls, refetch on thread-count change, the failure path, eviction, the ignore_ws `":iws"` bucket and its whitespace-only-file placeholder, a named string variant bucket and a `range` override for it - what `gi`'s "changes since my last review" uses - kept warm alongside the plain/iws ones and evicted with the rest), with a shimmed `vim.fn.jobstart` against a scratch git repo and a stub provider `--threads` |
| `test-nav.lua` | `review/nav.lua`'s `def_score` definition heuristic (extracted verbatim by pattern) against real code lines, and `git grep` output parsing |
| `test-decorate.lua` | The revision-buffer decoration line walk (extracted verbatim by pattern) against a real diff, both sides |
| `test-worddiff.lua` | `cache.lua`'s `word_diff` pairing and token-diff (single-token change, unequal block sizes, a whole-line rewrite, a whitespace-only change, the byte-size cap) |
| `test-notify.lua` | `notify.lua`'s toast backend selection, XML/PowerShell/AppleScript escaping, the `AZVICLI_TOASTS` opt-out (via `state.lua`, `require()`d through `LUA_PATH` - see `tests/run.sh`), and same-title rate-limit coalescing, with a shimmed `vim.fn.jobstart`/`timer_start`; also `M.flash`'s queueing (up to `MAX_FLASH` at once, a push past that evicting the oldest), an error also going through `vim.notify` unconditionally, dismiss ordering/timing against a shimmed `vim.fn.timer_start`/`timer_stop` and a fake `vim.api` window/buffer, and `setup({notifications="notify"})` turning it into a plain `vim.notify` pass-through, with a shimmed `vim.api` |
| `test-editor.lua` | `editor.lua`'s pure helpers: draft keying/storage over a plain table, `@Name` → `@<guid>` mention translation (longest match first, an unknown name left untranslated), the window title every call site builds, and the 3-to-8-line auto-grow height rule |
| `test-log.lua` | `log.lua`'s `M.summary` (first non-empty line for plain text, the last non-empty line - with an HTTP-flavoured exception's class prefix stripped, a plain one kept - for a python traceback, truncation to width) and `M.record`/`M.entries` (oldest-first, the most recent 200 kept) |
| `test-rpc.lua` | `rpc.lua`'s `M.run`/`M.status`: a provider argv is routed to the daemon with the right JSON request (argv tail + env), a non-provider (git) argv falls straight through to `jobstart`, chunked/partial daemon stdout is reassembled into complete lines and dispatched to the right pending request by id (including two responses landing in the same chunk out of submission order), the buffered on_stdout/on_stderr line shape (trailing `""`, no trailing `""`, a lone `""` for empty output), a daemon exit fails every pending request and the next call restarts it exactly once before falling back for the cooldown window, the per-request timeout (plus a late response after it being dropped), and `AZVICLI_NO_DAEMON=1` - with a shimmed `vim.fn.jobstart`/`chansend`/`timer_start`/`nvim_create_autocmd` and a minimal JSON codec |
| `test-review-comments.lua` | `review/comments.lua`'s pure helpers: the line-to-comment mapping over a synthetic popup rendering, and optimistic edit/delete apply-and-revert against a synthetic thread table with a fake `run_write` that succeeds or fails |
| `test-review-commits.lua` | `review/commits.lua`'s pure helpers: parsing an Overview commit row and pulling a sha out of one, finding the commit under the cursor scoped to the "Commits (who pushed):" block, parsing `git show --name-status` output (including a rename), and root-commit detection from `git rev-list --parents` output |
| `test-review-range.lua` | `review/range.lua`'s pure helpers: resolving a visual selection to a `{side, start, stop}` range over a synthetic diff map (forward/reversed selections, a single-line collapse, mixed-side and non-commentable ends), and the `--post` argv it builds, with and without an `endLine` |
| `test-review-batch.lua` | `review/batch.lua`'s pure helpers: the winbar tag text, queueing/removing/serialising items, the argv a queued item submits with, and submission order/vote timing against a fake `run_write` (a failed item staying queued while the rest confirm, and the vote going out last and only when chosen) |
| `test-review-since.lua` | `review/since.lua`'s pure helpers: ISO-8601 timestamp normalisation (fraction padding, numeric UTC-offset folding across a day/month/year boundary) and comparison, picking my last review point out of a synthetic thread list (including a vote-only "system" comment, and "no comments at all"), picking the base iteration to diff from out of a synthetic iterations list (including "every iteration is newer than my last review"), and the `since:<short-sha>`/`:iws` variant and range string composition |
| `test-review-followup.lua` | `review/followup.lua`'s pure helpers: selecting "my" anchored/unanchored threads out of a synthetic flat thread list (first-comment authorship, someone else's thread excluded, file-level/PR-level threads routed to "unanchored"), parsing `git diff --unified=0` hunk headers (add-only, delete-only, a modify, an omitted single-line count), the new-side overlap/window check, the old-side -> new-side line-mapping rule (shift accumulation across several hunks, a line inside a deleted range returning nil), classification ("n/a" for a target-side thread, "unchanged" for no nearby/no hunks at all, "changed" otherwise), row formatting and changed-first/path/line sorting, and the summary-line/row-map builder (singular/plural iteration and thread counts, the "Unanchored" section only appearing when there is one) |
| `test-keys.lua` | `config.lua`'s `setup()` merge/validate (override, unbind via `false`, a multi-key action, per-surface `prefix`, an unknown action/surface name erroring clearly) and `keys.lua`'s `resolve`/`bind`/`line`/`label` against it |
| `test-merge.lua` | `merge.lua`'s pure helpers: `build_label` for every build state (queued included), `warnings` (a green build/no conflict/zero threads is clean, an unknown thread count is not a warning, singular/plural threads), and `lines` for a full spec and a bare one (toggle states, merge-type cycling, the `?` placeholders, the warning line only when there is one) |
| `test-migrate.lua` | `migrate.lua`'s `M.ensure`: old present/new absent copies the old file's content into the new one verbatim (line-for-line, multi-line included), new already present leaves it untouched and never even needs to read the old file, and neither existing is a harmless no-op - with a shimmed `vim.fn.filereadable`/`readfile`/`writefile` against a tiny in-memory fake filesystem |
| `test-states.lua` | `workitems/states.lua`'s pure `M.build`/`M.rank`/`M.hl`: the fallback (no `states:` configured) reproduces the built-in per-name rank/highlight tables exactly, a configured list's position→rank and position→highlight-group rules (1st/2nd/last/second-to-last/others), an unconfigured state ranking last with a neutral colour, and a duplicate name in the list keeping its first position |
| `test-config.lua` | `config.lua`'s `setup()` options beyond `keys` (already `test-keys.lua`'s): `python`/`config` precedence (env `AZVICLI_PY` > `setup()` > probe; `setup({config=...})` always wins) and validation, `M.config_path()`, the `AZVICLI_PREFETCH_DIR`/`AZVICLI_HIDE_ANCIENT_DAYS` defaults `provider_cmd()` sets (never overwriting an ambient value), `timing`/`hide_ancient_days` defaults/partial-override/validation, `cached_prs`/`threads_ttl_seconds` actually landing on a real `cache.lua` instance via `setup()` (pre-seeded into `package.loaded` so `config.lua`'s own internal `require("azure-cli.cache")` resolves to the same table the test inspects), and `collapsed_sections` defaults/override/reset/empty-table/validation |
| `test-ui.lua` | `ui.lua`'s pure `UI.winbar` (context/tags/help joining, blank entries skipped) and `UI.layout` (growing to ideal by weight, `grow` columns soaking up leftover width, the lowest-priority-first drop order when even the minimums don't fit, an undroppable column surviving regardless) |
| `test-review-filelist.lua` | `review/filelist.lua`'s pure `M.diff_stats` (add/del counts from a parsed-diff map) and `M.build` (directory grouping and sorting, common-prefix trimming - including "no common prefix" and a lone file still getting its own header row - the row_to_file/file_to_row/ordered_files maps, status-letter/stats/thread-count row formatting including the uncached "(?)" and no-status-yet cases, and the AzureCliFileDir/Added/Deleted/Renamed highlight assignment, "M" deliberately getting none) |
| `test_provider.py` | `azure-cli.py`'s YAML-subset config parser; PR classification (every branch of the assigned/created/draft/declined/signed-off/waiting/actionable rules, including `AZVICLI_HIDE_ANCIENT_DAYS` widening/narrowing/falling back on an invalid value from the hard-coded 30); thread and @-mention counting; build-status aggregation and policy/missing-reviewer derivation; vote ratio, reviewer summary and humanized-date formatting; `Config.path()`'s `AZVICLI_CONFIG` override (with `~` expansion); and an NDJSON serialization check of the emitted field list. HTTP is mocked by swapping `AzureDevOpsPullRequestSource.fetch` for a fake - no network access or live Azure DevOps instance is needed. |
| `test_pr_actions.py` | `azure-cli.py`'s PR-action subcommands (`PrActions` - threads/iterations passthrough, posting/replying/editing/deleting comments, thread status, vote, complete, auto-complete) and the `AZVICLI_PREFETCH=1`/`all` branch-prefetch modes. HTTP is mocked the same way `test_provider.py` mocks it (`PrActions.fetch` swapped for a fake); git is exercised for real for `post_inline`'s git-show line-length lookup. Also `default_prefetch_dir()`'s platform branches (Windows `%LOCALAPPDATA%`, else `$XDG_CACHE_HOME`, each with its own no-env fallback) and both call sites (`PrActions.__init__`, `cmd_prefetch`) actually using it when `AZVICLI_PREFETCH_DIR` is unset. |
| `test_work_items.py` | `azure-cli.py`'s work-item subcommands (`WorkItemActions` - `--wi-list`'s sprint resolution/WIQL/batch fetch, `--wi-detail`'s parent/child/comment/pull-request assembly and HTML flattening, `--wi-state`'s transitions/reasons derivation and state changes, `--wi-edit`'s create/set/comment/link-pr/unlink-pr JSON Patch bodies). HTTP is mocked the same way, via `WorkItemActions.fetch`. Also `work_items.states:`/`sprint_scope:` parsing and defaults, and the `states`/wider-iteration-list `--wi-list current`/`sprints` output they carry (including an undated iteration sorting last under `sprint_scope: all`). |
| `test_serve.py` | `azure-cli.py`'s `--serve` daemon: `dispatch()`'s in-process request runner (a `--ping`, a missing config returning 1 instead of exiting the process, an unhandled handler exception being caught, per-request `env` threaded through rather than read off `os.environ`, a monkeypatched handler's captured output coming back verbatim, and concurrent `dispatch()` calls on different threads never seeing each other's captured stdout) and `serve()`'s request loop (a real `--ping` round trip, a clean exit on EOF, a malformed/non-object JSON line getting an `"id": null` error response, concurrent requests completing out of order and still matched up by id, and a request's `env` overrides reaching `dispatch()` merged over the daemon's own environment) - stdin/stdout are faked (`sys.stdin.buffer` an `io.BytesIO` pre-loaded with every request line, `sys.stdout` a plain `io.StringIO`), everything else (the `ThreadPoolExecutor`, real threads) is real. Also covers `get_cached_config()` (a serving daemon keeps its start-up config whatever happens to the file afterwards; outside `--serve` every call reads the file) and the `.userid` cache's atomic (temp-file-then-`os.replace`) write. |

The prefetch/split/decorate tests run against a small scratch git repo the
runner builds in a temp dir (two branches, `tgt` and `src`, exposed as
`refs/remotes/origin/{tgt,src}` since that's what the prefetch pipeline
diffs). Everything is cleaned up on exit.

The five headless `nvim` smokes (skipped, not failed, when `nvim` isn't on
PATH): `setup()`/`config.lua` - `require('azure-cli').setup()` then asserting
`require('azure-cli.config').get().keys.diff.next_hunk` resolves - proves
`require("azure-cli")` and its dependents actually resolve through
`'runtimepath'` the way a plugin-manager install would (`--cmd "set
rtp+=$REPO_ROOT"`, not this repo's own working-directory layout);
`standalone/init.lua` - runs the launcher's real entry point against a temp,
deliberately unpopulated `XDG_CONFIG_HOME` and asserts the dashboard buffer
renders (`filetype == 'azurecli-dashboard'`) even though `--list` fails fast on
"configuration does not exist"; a `keys` override - `setup({keys={diff=
{next_hunk="]h"}}})` then asserting `keys.lua`'s `resolve` actually returns
`]h`, not just that the default exists; and `:AzureCli status` -
`setup({python=..., config=...})` then asserting `require('azure-cli').status()`'s
returned table carries those exact values, not the probe/platform defaults;
and the fake-provider demo - `bash tests/demo.sh --headless` (see
[Trying it without Azure DevOps](#trying-it-without-azure-devops) below)
asserting the dashboard lists the fake PRs, through `rpc.lua`'s real daemon
client, and that the reviewer then opens PR #101 with its file list, through
the warm-all prefetch's real `git fetch` and the reviewer's `git diff`
pipeline.

`tests/gen-keys-table.lua` (`luajit tests/gen-keys-table.lua`) prints the
[Keys](commands-and-keys.md#keys) section's tables straight from `config.lua`'s defaults - not
part of the `run.sh` gate (there's nothing to assert; it's a generator, not
a test), but re-run it and paste the output over that section after
changing a default, so the two can't quietly drift apart.

GitHub Actions (`.github/workflows/ci.yml`) runs `bash tests/run.sh` on
every push and pull request.

### Trying it without Azure DevOps

```
bash tests/demo.sh                # plugin mode: the dashboard in a plain nvim
bash tests/demo.sh --standalone   # the launcher's own standalone/init.lua entry point
bash tests/demo.sh --headless     # the self-check tests/run.sh runs
bash tests/demo.sh --fresh        # rebuild the workspace (forgets what you did)
```

The Lua side never talks to Azure DevOps itself - every PR/work-item
action, the branch prefetch and the `--serve` daemon go through the
`python azure-cli.py` argv `config.lua`'s `provider_cmd()` builds - so
the whole UI can be driven by a stand-in. `tests/fake-provider.py` is
that stand-in: `demo.sh` points `AZVICLI_PY` at it, so the argv becomes
`fake-provider.py azure-cli.py <args>` and the fake answers every
subcommand (`--list`, `--threads`, `--post`, `--vote`, `--wi-list`, ...,
`--serve`) from a workspace it builds under `$TMPDIR`/`/tmp`:

- **Real git.** A bare `file://` "origin" per fixture repository and a
  clone under `<ws>/clones` for the ones the `--list` records call cloned
  (`gadgets` deliberately isn't, so opening PR #201 exercises
  clone-on-open). Every PR is a real branch with real commits, so the
  reviewer's file list, diffs, commit log, word diff and "changes since
  my last review" run the real git commands.
- **Stateful.** Posting, replying, editing and deleting comments, thread
  status, votes, complete/auto-complete, re-queue and every work-item
  state/field edit update the workspace's `state.json`, so the next
  refresh shows what you did the way it would after a server round trip
  (a vote moves the PR between dashboard sections, a reply shows up in
  the thread, ...). Votes on #104's conflicting PR still complete-fail,
  like the real thing.
- **Traceable.** Every provider call the Lua side made - argv plus the
  `AZVICLI_*` environment it carried - is appended to `<ws>/calls.log`.
- **Isolated.** `XDG_CONFIG_HOME`/`XDG_DATA_HOME`/`XDG_CACHE_HOME` point
  into the workspace, so your real `azure-cli.yml`, viewed marks and
  prefetch cache are never read or written; `AZVICLI_TOASTS=0` keeps
  desktop notifications quiet.

Fixtures: repo `widgets` with PRs #101 (Actionable, an inline thread
that @-mentions you, a resolved one and a general one), #102 (yours),
#103 (draft), #104 (waiting for author, failed build, merge conflict,
whitespace-only file), #105 (signed off, auto-complete on); repo
`gadgets` with #201; three sprints of work items with a parent feature,
comments and linked PRs. Everything is in `PR_FIXTURES`/`WI_FIXTURES`
at the top of `tests/fake-provider.py` - add a PR there and `--fresh`
rebuilds the branches to match.

What this doesn't cover: `azure-cli.py`'s own REST layer (that's
`tests/test_*.py`'s job, against fakes) and anything only a real server
can tell you - PAT scopes, on-prem quirks, real identities. For those,
a free dev.azure.com organization with one small repo and one open PR is
enough: put it in a throwaway config and run the standalone launcher
with `XDG_CONFIG_HOME` pointed at it.

### Screenshots

```
python3 tests/screenshots.py            # rewrites docs/images/*.png
```

The images under `docs/images/` are generated, not hand-taken: the script
runs `tests/demo.sh --standalone` in a fixed-size detached `tmux` pane,
walks through the fake provider's fixtures (dashboard, PR #101, its diff,
the inline thread, the complete dialog, work items, a work item), captures
each screen with its colours and rasterises it through ImageMagick's
`pango:` coder. Needs tmux, an ImageMagick with pango support and a
monospace font (Noto Sans Mono by default - `--font` picks another); no
display. Re-run it after a UI change and commit the result; add a step to
`SHOTS` in the script for a new screen.

### Extending the reviewer

`review/init.lua` is a large file sitting close to LuaJIT's hard
200-active-local ceiling (98+ keymap/help/winbar call sites, the whole
reviewer's state), so every reviewer feature hangs off one table, `EXT`,
instead of adding its own top-level `local`s, and lives in its own module
under `review/` (`review/{nav,comments,commits,range,batch,since,followup}.lua`)
- each `require()`d module is a separate compiled chunk with its own
200-local budget. To add a feature:

1. Write `lua/azure-cli/review/<name>.lua` (CRLF, like `review/init.lua`)
   returning `function(ctx) ... end` - or a table with a
   `__call` metamethod if you also want pure helpers reachable without
   calling it (see `review/comments.lua`, whose tests do exactly
   that).
2. Wire it in at the very end of `review/init.lua`'s closing `(function() ...
   end)()` block: `EXT.<name> = require("azure-cli.review.<name>")(ctx)`.
   That block stays an immediately-invoked function expression, not a bare
   `do...end` - a plain `do...end` block's locals still count against
   `review/init.lua`'s own 200-local ceiling (they only go out of scope,
   they're still active while declared), but a nested function gets its own
   separate budget; keeping it anonymous (not `local loader = function()
   ... end`) also avoids spending one more of `review/init.lua`'s own
   locals just to hold the loader itself.
3. Register keys with `ctx.add_key(kind, action, fn, desc, mode)` for `kind`
   in `"list"` / `"diff"` / `"overview"` / `"nav"` - `action` is an action
   name (not a literal key), resolved through `lua/azure-cli/keys.lua`
   against `config.lua`'s defaults for that surface exactly like every other
   binding in this plugin (see [Keys](commands-and-keys.md#keys)); add your new action's default
   key(s) to `config.lua`'s `DEFAULT_KEYS[kind]` first, or `ctx.add_key`
   will resolve to nothing and bind nothing (an unknown action there is
   silently unbound, the same as any other action a user's config set to
   `false` - `ctx.add_key` doesn't distinguish "not in the defaults" from
   "user unbound it"; check `config.lua` if a module's key seems to do
   nothing). A successful resolution appends to `EXT.keys[kind]` (applied to
   that surface's buffer, including any that already exist by the time
   modules load) and `EXT.help[kind]` (appended to that surface's `?`
   popup). `mode` is optional and defaults to `"n"` (normal mode); pass
   `"x"` for a visual-mode mapping (see `review/range.lua`'s
   `comment_range` action, bound alongside the diff surface's normal-mode
   `comment` action on the same default key without colliding, since the
   mode differs). The K popup (view the comments on a line) is a fresh
   float per view rather than a persistent buffer, so it isn't one of the
   four kinds above and isn't configurable through `keys.lua` - use
   `ctx.on_comment_popup(fn)` instead; `fn(fbuf, threads)` runs each time the
   popup opens; there is no persistent buffer to re-apply `EXT.keys.*` to.
4. Never add a top-level `local` to `review/init.lua` itself - everything
   new goes in the module, or in a nested function inside that closing block.
5. If your module needs a field the closing `(function() ... end)()` block
   doesn't already close over (a `local` declared elsewhere in
   `review/init.lua`), and that block is already close to LuaJIT's
   60-upvalues-per-function ceiling (see `EXT.rebuild_view`'s own comment,
   right before that block, for how close - it already pushed one function
   out for exactly this reason), don't reference the local directly from
   inside it. Assign it onto `EXT` instead, as its own statement at the main
   chunk's top level (anywhere after the local it reads already exists,
   before the closing block runs) - `EXT.<name> = <local>` costs nothing
   (`EXT` is that one already-spent top-level local everything else here
   hangs off), and then, inside the closing block, `ctx.<name> = EXT.<name>`
   - reading a field off `EXT`, which the block already closes over for a
   dozen other purposes, adds no new upvalue either. `review/followup.lua`'s
   `ctx.open_file`/`ctx.ensure_diff_content`/`ctx.reply_to_thread`/
   `ctx.apply_status`/`ctx.STATUS_OPTIONS` are wired this way (see the
   comment right before `EXT.open_file = open_file` in `review/init.lua`).

`ctx` exposes: `git_args`, `notify`, `open_float`, `run_write`,
`retry_prompt`, `redraw`, `refresh_threads`, `show_hits`, `open_revision`,
`ensure_revision_buf`, `when_loaded`, `nav_context`, `find_thread`,
`my_id()`, `my_display_name`, `current_pr_record`, `files()`, `threads()`
(returns `threads_by_key, file_threads_by_path, general_threads`),
`comments_by_buf`, `maps_by_buf`, `paths_by_buf`, `diff_win()`, `list_win()`,
`overview_buf()`, `threads_to_lines`, `build_overview`, `ID` / `ORG` /
`PROJECT` / `SOURCE` / `TARGET` / `REPO_PATH` / `EMBED`,
`provider` (`EXT.provider` - builds the `azure-cli.py` argv a module's own
job should run, e.g. `review/since.lua`'s `--iterations` fetch),
`add_key`, `on_comment_popup`, `decorate_diff`, `ft_for_path`, `parse_diff`
(`cache.lua`'s `M.parse_diff`), `nav_show`, `nav_back`,
`mark_current_file`, `overview_commits()`, `post_new_thread`,
`add_pending_thread`, `confirm_pending_thread`, `drop_pending_thread`,
`pending_threads()`, `pending_replies()`, `remove_entry`, `VOTE_OPTIONS`,
`since()`, `set_since(state-or-nil)`, `rebuild_view(reload_files)`,
`open_file`, `ensure_diff_content`, `reply_to_thread`, `apply_status`,
`STATUS_OPTIONS`, `fetch_since_base` (`review/since.lua`'s `M.fetch_base` -
see that function's own comment).
Anything `review/init.lua` reassigns later (`files`, the three thread tables,
`list_win`/`diff_win`, `overview_buf`, `overview_commits`) is exposed as a
function so a module always reads the live value instead of whatever it was
when `ctx` was built - `pending_threads()`/`pending_replies()` are the same
idea, since `review/batch.lua` needs the live tables `reapply_pending`
(review/init.lua's own, run after every thread refetch) reads, not a snapshot.

`since()`/`set_since(state-or-nil)` read/write the reviewer's "changes since
my last review" state (`review/since.lua`'s `gi`): `nil` when the
mode is off, else `{ range, variant, short, base, new_iterations, at,
file_count }` - `range` and `variant` are what `build_diff_async`/
`load_files`/`prefetch_all_diffs` substitute for the PR's usual range/cache
variant everywhere they're used, so no other module needs to know the mode
exists. `rebuild_view(reload_files)` re-runs everything a mode switch (`gw`
or `gi`) needs to reflect on screen - recomputing the active diff cache
bucket, dropping and rebuilding diff buffers, refreshing every winbar/
decoration, and, when `reload_files` is true (any time the file list itself
could have changed - entering, leaving or re-picking a since-range; never
needed for a plain `gw` toggle), reloading the file list too.

`post_new_thread(args, bucket, where, path, side, lineno, text, label,
retry_label, end_lineno)` posts a new thread optimistically (shown at once,
tagged "(sending…)" until confirmed, reverted with a prefilled retry on
failure) the same way `comment_here`/`comment_on_file`/`comment_on_pr` do -
`bucket` is `"line"` / `"file"` / `"general"` and `where` is the matching
bucket key (`path\tside\tlineno`, `path`, or `nil`). The trailing
`end_lineno` is optional and, when given, lands on the synthetic pending
entry the same way a server thread's `rightFileEnd`/`leftFileEnd` does via
`parse_threads` - `review/range.lua` uses it so a range comment's
highlight shows immediately instead of waiting for the next thread refetch.
`add_pending_thread(text, bucket, where, path, side, lineno, end_lineno)` is
the lower-level piece `post_new_thread` itself calls, for a module that
needs to manage the write (`ctx.run_write`) itself instead.

A module can also take a write over completely instead of just building on
top of it: `post_new_thread` and `send_reply` (the two functions every
comment/file-comment/PR-comment/reply ultimately goes through) each start by
calling `EXT.batch.intercept(kind, info)` - `"thread"` with
`{ args, bucket, where, path, side, lineno, text, label, retry_label,
end_lineno }` for a new thread, `"reply"` with `{ target, comment, text,
on_success }` for a reply (the comment is already appended to `target`'s
thread by then) - and return immediately, without sending anything, when it
returns `true`. `review/batch.lua` is the only module that currently
sets `EXT.batch`, and only calls this before `EXT.batch` exists is skipped
(`EXT.batch and EXT.batch.intercept` guards both call sites), so this costs
nothing when the module hasn't loaded; a future module wanting the same hook
would need to compose with it (batch mode already being on takes priority),
not add a second guarded call site. `EXT.batch.tag()` is the matching
half for display: `set_list_winbar`/`set_diff_winbar` splice its return
value (a `"  [batch: N]"` string, or `""`) straight into the winbar.
