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
  every `timing.poll_seconds` (30 s), slower while Neovim is idle or
  unfocused, never overlapping themselves, and a half-second hover debounce.
- **Kept-alive connections.** Idle connections to the same host are reused
  from a pool (up to 8 per host, dropped after 60 s idle), and a read that
  fails on a pooled one is retried once on a fresh connection.
  `AZVICLI_NO_POOL=1` turns the pool off.
- **`connectionData` once per organization.** Under `--serve` the daemon
  keeps each organization's `connectionData` for 10 minutes, keyed by
  organization and PAT, and drops it when a request there answers 401, 403
  or 203.
- **Every account at once.** `--list` fetches all accounts together on one
  pool of 8 and prints them in config order.

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
  keys.lua        resolves a surface+action to the configured key(s); binds, renders ? popup lines, the g. palette
  keyhints.lua    g and a pause: the float of the screen's g keys (a buffer-local g that replays what follows)
  palette.lua     azure-vicli's own colours (the standalone launcher's; ui.palette = "azure-vicli")
  ui.lua          the shared look: winbars (UI.winbar), floats and their border, theme groups (UI.THEME), tabline/statusline, the column-width solver (UI.layout)
  shell.lua       shared housekeeping: flash, config file, browser/clipboard, JSON state files, failed-job summary
  state.lua       the one shared table every surface reads/writes (list/content caches, daemon state, ...)
  migrate.lua     one-time data-file rename, M.ensure(old, new)
  cache.lua       per-PR content cache + prefetch pipeline
  notify.lua      desktop toast notifications + in-editor flash notifications
  merge.lua       the complete-PR dialog shared by the dashboard's and the reviewer's gm
  hosts.lua       what each code host offers (votes, thread statuses, merge methods, mention form) and the PR key
  log.lua         in-session error log (M.record/M.summary) + :AzureCli log
  editor.lua      floating comment editor (drafts, @ mentions)
  home.lua        the home screens (Pull requests, Work items, Agents, and Issues with a GitHub issues: account), each in its own tab; P/W/A/I switch, closing a plan goes back to the tab it came from
  innertabs.lua   inner tabs: PRs stay grouped under Pull requests, work items under Work items, issues under Issues, plans and changes under Agents (hidden from the tab line, the strip in the winbar, giving way to the window's own), ]r/[r/g1..g9, q goes to the previous one
  poll.lua        the one scheduler every network poll runs on: slower while Neovim is unfocused or idle, a refresh on return
  perf.lua        :AzureCli perf, a summary of the provider's perf log (AZVICLI_DEBUG=1)
  web.lua         the phone dashboard: :AzureCli web start/stop/status/rotate, its token, the rows it pushes to azure-cli.py --web-dashboard
  chat/           the chat panel: init.lua (conversations, the panel), run.lua (running the agent:
                  send, cancel, its MCP config), actions.lua (what the panel's keys do), view.lua (what's on screen),
                  tools.lua (the agent's MCP tools), bridge.lua (the 127.0.0.1 endpoint --mcp relays to),
                  plan.lua (the plan: storage, its gate on start_fix/start_story, the tools - with
                  plan_text.lua's pure helpers and plan_view.lua's tab), threads.lua (ga: a
                  question answered under a line - the plan's and the change viewer's), agents.lua
                  (gP: an agent per work item, the max_agents queue), agents_view.lua (the Agents screen),
                  notes.lua (annotate_code's notes, saved per PR), watch.lua (the chat's
                  PRs, polled for new comments: suggest /triage, or start an agent),
                  skills.lua (the agent's SKILL.md skills, the /skills popup; an allowed one's prompts don't ask),
                  tools_agents.lua (the main chat's start_agents / list_agents / message_agent,
                  task agents included),
                  plan_changes.lua (the plan view's Changes section), plan_discard.lua (dd / gD: discarding a plan),
                  waiting.lua (]w / [w on every screen: the next question, approval or change waiting for you)
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
    images.lua               reviewer-feature module: images in the description and comments (<CR>/gx, inline)
    overview_syntax.lua      the Overview's azurecli-overview filetype: Markdown only in the description and comment bodies
  workitems/
    dashboard.lua   work-items dashboard
    view.lua        work-item detail view
    parent.lua      gU: change or remove a work item's parent
plugin/azure-cli.lua   defines :AzureCli (see Commands) - no side effects beyond that
standalone/init.lua    the launcher's Neovim entry point: adds the plugin root
                       to 'runtimepath', calls setup(), applies the standalone
                       colour palette, opens the dashboard in the current window
azure-cli.py           headless data provider + launcher + daemon (repo root)
github_host.py         its GitHub backend: GitHub PRs/threads/pushes in the shapes azure-cli.py's Azure code uses
github_issues.py       GitHub Issues and a Projects v2 project as the work-items backend (the Issues tab)
github_rest.py         github_host.py's queries answered from GitHub's REST API where GraphQL is refused
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
| `lua/azure-cli/hosts.lua` | Per-host capabilities: the vote choices (with their glyphs and which count as signed), the thread statuses `s` offers, the merge methods, the form an `@` mention is sent in, and the PR's key and display ref. A PR record's `host` picks the table (Azure when absent) and its `caps` override parts of it; `is_open` is the one rule for whether a thread is unresolved. Pure. |
| `lua/azure-cli/merge.lua` | The complete-PR dialog (merge type, work-item/branch toggles, build/threads/votes summary and warnings) that both the dashboard's `gm` and the reviewer's `gm` open; its `MERGE_TYPES` list, `build_label`, `warnings` and `lines` are pure and shared with the winbar. |
| `lua/azure-cli/log.lua` | The in-session error log every provider-failure path records into (`M.record`) and shows a one-line summary from (`M.summary`); `M.open` is [`:AzureCli log`](commands-and-keys.md#commands). |
| `lua/azure-cli/chat/*.lua` | The [chat panel](chat.md): `init.lua` the split (transcript + input) that follows you into every azure-vicli tab, and each message's headless agent run (session resume via `followup`, else replay); `view.lua` the "what's on screen" snapshot every screen registers a describer for; `tools.lua` the agent's tools (reads, direct writes, writes that ask); `bridge.lua` the 127.0.0.1 + token endpoint `azure-cli.py --mcp` forwards MCP tool calls to. |
| `lua/azure-cli/chat/core.lua`, `store.lua`, `refs.lua` | The chat's pure helpers (message composition, the stream reader for Claude Code's stream-json / json / plain output, saved prompts, `!`/`#` reference parsing, transcript rendering); saved conversations and the audit log under `stdpath("data")/azure-cli-chat/`; resolving, describing, completing and opening references. |
| `lua/azure-cli/chat/tools_pr.lua`, `tools_board.lua`, `tools_fix.lua`, `tools_agents.lua` | The agent's tool groups beyond the basics: build log, failed tests, thread status, reviewers, description, create/complete PR, re-queue, `open_in_ui`, `annotate_code`; child tasks, assignment, sprints, comments; the fix flow (a worktree under `stdpath("cache")/azure-cli/fix-worktrees`, its diff, commit and push); the main chat coordinating the agents (start, list, message them - refused inside an agent's own conversation). `tools.lua` holds the registry, per-tool permissions, the audit log and the undoers. |
| `lua/azure-cli/review/chat.lua` | Reviewer-feature module: `i` (and `<CR>` on a selection) in the reviewer, its describer (file, line, code, the change around the cursor, a selection's file lines, the thread), `STATE.review_openers` for `open_in_ui`, and drawing `annotate_code` notes (called from `decorate_comments`). |
| `lua/azure-cli/editor.lua` | The floating comment editor (see [Reviewer](reviewer.md#reviewer)'s "Comment editor") - drafts, title formatting, `@` mention translation. |
| `lua/azure-cli/rpc.lua` | Shared client for the `azure-cli.py --serve` daemon - one daemon per Neovim session, `require()`'d by every file above; `M.run(argv, opts)` is a `vim.fn.jobstart`-compatible drop-in that routes a provider call to the daemon when it's usable and falls back to a plain job otherwise. |
| `lua/azure-cli/review/nav.lua` | Reviewer-feature module (see "Extending the reviewer" below): code navigation without an LSP - `gd` (go to definition, ranked by `def_score`), `gr` (find references), `gf` (open this file at the PR's revision), `g/` (search the changed files), the two-float peek view and the read-only revision buffers you keep navigating from, with `<BS>` walking back one jump. Loaded **first** of the review modules: `review/{commits,followup,since}.lua` reach the peek and those buffers through the `ctx` fields filled in from its return value. |
| `lua/azure-cli/review/comments.lua` | Reviewer-feature module (see "Extending the reviewer" below): edit/delete your own PR comments, from the K popup or the Overview page. |
| `lua/azure-cli/review/commits.lua` | Reviewer-feature module: per-commit diffs - `gc`'s commit list, a commit's changed files, and a single commit's diff for one of them. |
| `lua/azure-cli/review/range.lua` | Reviewer-feature module: visual-mode `c` comments on a selected range of lines instead of just one. |
| `lua/azure-cli/review/batch.lua` | Reviewer-feature module: batched review - `gB` queues comments/replies instead of sending them right away, `gQ` lists the queue, `gS` submits it all with a vote. |
| `lua/azure-cli/review/since.lua` | Reviewer-feature module: `gi` toggles showing only changes since your last review. |
| `lua/azure-cli/review/followup.lua` | Reviewer-feature module: `gu` opens a picker of every thread you started, tagged closed-as-is/changed/unchanged/addressed/n/a for whether anything landed nearby since your last review and whether the thread has since been resolved. Its per-path since-diffs are cached on (base, source tip, path) - the tip belongs in the key because a push moves the answer without moving the base. |
| `lua/azure-cli/review/filelist.lua` | The file list's layout: `M.build` (pure) groups files by directory, trims their common prefix, and formats each row's status letter/+-stats/comment count; `M.render` writes it into the list buffer. `EXT.refresh_file_list` (review/init.lua) is the only caller - every row->file lookup goes through the model it returns instead of indexing `files` by row. |
| `lua/azure-cli/review/images.lua` | Reviewer-feature module: image references in the Overview and the K popup; `<CR>`/`gx` (chained onto the keys' previous handlers through `ctx.add_key`'s `chain`) download one with `azure-cli.py --fetch-image` into a `0600` temp file and open it; with snacks.nvim's image module or image.nvim and a terminal that draws images, `ctx.on_overview_render` places them inline (`images.inline`). |
| `lua/azure-cli/review/overview_syntax.lua` | The Overview's `azurecli-overview` filetype: Vim's markdown syntax as a contained cluster, used only in the description and comment-body regions, `markdownError` cleared in that buffer only. |
| `lua/azure-cli/review/thread_text.lua` | How a comment reads in the `K` popup, the reply editor's thread and the inline thread: a markdown link as its text with the address under the comment, `[KEY]: value` reference lines (a bot's metadata) left out, text wrapped under the `│` gutter, and the popup's colours. |
| `lua/azure-cli/people.lua` | Finding people on a PR's host (`--find-people`): `gR`'s add-a-reviewer and the comment editor's `<C-t>` tag; everyone found joins `@` completion (`hosts.remember`). |
| `lua/azure-cli/picker.lua` | The plugin's own popups for `prompt.lua`: a list with a search line that narrows it fuzzily as you type (`M.open`, with an `on_query` hook for a host search - gR's people, `ga`'s `--wi-list people`) and a one-line text prompt (`M.input`). |
| `lua/azure-cli/workitems/edit.lua` | `ge`'s edit form over a work item's view: every field that can change, held until `<C-s>` saves them (one `--wi-edit set` each); state and parent through `gs`'s and `gU`'s popups. |
| `lua/azure-cli/poll.lua` | The one scheduler every network poll runs on (the PR dashboard, a review, the boards, the chat's watched PRs): each ticks at its base rate while you're here; while Neovim is unfocused or idle for `timing.idle_after`, each tick doubles its interval up to `timing.max_poll_seconds`, and on return an overdue poll ticks once at once. |
| `lua/azure-cli/perf.lua` | [`:AzureCli perf`](commands-and-keys.md#commands): reads the perf log `AZVICLI_DEBUG=1` makes `azure-cli.py` write and summarises it per screen, per endpoint and by the slowest requests. |
| `lua/azure-cli/web.lua` | The [phone dashboard](chat.md#phone-dashboard): `:AzureCli web`, starting `azure-cli.py --web-dashboard` with the token's file path (never the token) on its command line, the stored token under `stdpath("state")`, rotating it, and pushing the Agents screen's rows. |
| `lua/azure-cli/chat/plan_changes.lua`, `plan_discard.lua` | The plan view's Changes section (the agent's diff beside the plan, file by file); discarding a plan (`dd` on the Agents screen, `gD` in the plan), asking first (Discard / Cancel), then deleting its files, and its worktree and local branch in the background. |
| `lua/azure-cli/workitems/parent.lua` | `gU`: change or remove a work item's (or issue's) parent, from the board and the item view. |
| `github_rest.py` | Where GraphQL is refused (a REST-only proxy, an Enterprise Server with GraphQL off, or `AZVICLI_GITHUB_REST=1`), each of `github_host.py`'s queries answered from REST calls in the same shape, so its converters and the Lua side don't change. `Client.graphql` switches an API root to it at the first refusal; see [Configuration](configuration.md#github-accounts) for what REST can't do. |
| `github_issues.py` | GitHub Issues and a Projects v2 project as the work-items backend: answers `--wi-list`/`--wi-detail`/`--wi-state`/`--wi-edit` for a GitHub account's `issues:` block (iterations or milestones as tabs, the Status field as state). |
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
(`__pycache__/`) are ignored by git; prefetch markers live under
Neovim's/the platform's cache directory (see `AZVICLI_PREFETCH_DIR` in [Environment variables](configuration.md#environment-variables)),
not inside the repo.

Every `tests/*.lua` test (the `gen-keys-table.lua` generator aside) loads
`tests/sandbox.lua` first, and `run.sh` checks it does. The sandbox runs
each test with its own XDG directories and an empty `HOME` in a temp dir,
so a test never reads your `~/.claude/skills`, `~/.gitconfig` or the like
(the scripts loaded into a harness's nvim get theirs from `run.sh` and
`demo.sh --headless`). `run.sh` itself
clears every `AZVICLI_*` variable plus `VIM`, `VIMRUNTIME`, `NVIM`,
`MYVIMRC` and `NVIM_LOG_FILE`, and sets its own `XDG_DATA_HOME`,
`XDG_CACHE_HOME`, `XDG_STATE_HOME` and `XDG_CONFIG_HOME` under a temp dir.

`tests/run.sh` is the whole test suite (bash, git, luajit and python3; a
real `nvim` on PATH enables the stricter Neovim load check and the headless
smokes - see below): a `luajit -bl` syntax check and a global-name scan
(catches a `local` read before its declaration - easy to do by accident in
these long, forward-referencing files) over every file under `lua/`,
`plugin/` and `standalone/` (globbed, not a hand-written list, so a new
module is picked up automatically), `bash -n` over every shell script (and
the `azure-cli` launcher), thirty-seven Lua unit tests under `tests/` run
by `luajit` (plus `test-sandbox.lua`, started from a polluted environment
to prove the sandbox holds), `python3 -m unittest discover` over
`tests/test_*.py`, and, in headless `nvim`, twenty more Lua tests that need
Neovim itself (marked "Runs in headless nvim" below) and eight smokes:

| Test | Covers |
|---|---|
| `test-split.lua` | `cache.lua`'s `split_diff`/`parse_diff` against per-file `git diff` output, over a real multi-file range of this repo's own history (`--no-renames` throughout - see the file's own header comment for why a rename's single-file vs. whole-diff hunks aren't guaranteed identical otherwise, independent of split_diff/parse_diff correctness) |
| `test-prefetch.lua` | The prefetch pipeline end to end (caching, coalescing concurrent calls, refetch on thread-count change, the failure path, eviction, the ignore_ws `":iws"` bucket and its whitespace-only-file placeholder, a named string variant bucket and a `range` override for it - what `gi`'s "changes since my last review" uses - kept warm alongside the plain/iws ones and evicted with the rest), with a shimmed `vim.fn.jobstart` against a scratch git repo and a stub provider `--threads` |
| `test-nav.lua` | `review/nav.lua`'s `def_score` definition heuristic (extracted verbatim by pattern) against real code lines, and `git grep` output parsing |
| `test-decorate.lua` | The revision-buffer decoration line walk (extracted verbatim by pattern) against a real diff, both sides |
| `test-worddiff.lua` | `cache.lua`'s `word_diff` pairing and token-diff (single-token change, unequal block sizes, a whole-line rewrite, a whitespace-only change, the byte-size cap) |
| `test-notify.lua` | `notify.lua`'s toast backend selection, XML/PowerShell/AppleScript escaping, the `AZVICLI_TOASTS` opt-out (via `state.lua`, `require()`d through `LUA_PATH` - see `tests/run.sh`), and same-title rate-limit coalescing, with a shimmed `vim.fn.jobstart`/`timer_start`; also `M.flash`'s queueing (up to `MAX_FLASH` at once, a push past that evicting the oldest), an error also going through `vim.notify` unconditionally, dismiss ordering/timing against a shimmed `vim.fn.timer_start`/`timer_stop` and a fake `vim.api` window/buffer, and `setup({notifications="notify"})` turning it into a plain `vim.notify` pass-through, with a shimmed `vim.api` |
| `test-editor.lua` | `editor.lua`'s pure helpers: draft keying/storage over a plain table, `@Name` → `@<guid>` mention translation (longest match first, an unknown name left untranslated), the window title every call site builds, and the 3-to-8-line auto-grow height rule |
| `test-editor-mode.lua` | Runs in headless nvim with the main loop (real input, `luafile` rather than `-l`): `<C-j>` in `editor.lua`'s comment editor breaks the line, and sending with `<CR>` while typing submits the text and leaves the window underneath in normal mode, not insert mode (which used to carry over into a read-only plan or diff and fail the next key with E21) |
| `test-prompt.lua` | `prompt.lua`'s `select`/`input`/`confirm` wrappers under a `vim.ui` shim: the shape handed to `vim.ui.*` (trailing colon/space on the prompt, the current item marked, a predicate or plain-string items), answers and cancels mapped back to `cb(item|nil)` (a cancel quietly, an empty list cancelling with a warning, input trimmed, blank as a cancel unless `allow_empty`, only "yes" confirming), and `ui.confirm = "popup"` sending a short menu or yes/no question to `ui.lua`'s popup while a long or `search` list stays `vim.ui.select` |
| `test-log.lua` | `log.lua`'s `M.summary` (first non-empty line for plain text, the last non-empty line - with an HTTP-flavoured exception's class prefix stripped, a plain one kept - for a python traceback, truncation to width) and `M.record`/`M.entries` (oldest-first, the most recent 200 kept) |
| `test-rpc.lua` | `rpc.lua`'s `M.run`/`M.status`: a provider argv is routed to the daemon with the right JSON request (argv tail + env), a non-provider (git) argv falls straight through to `jobstart`, chunked/partial daemon stdout is reassembled into complete lines and dispatched to the right pending request by id (including two responses landing in the same chunk out of submission order), the buffered on_stdout/on_stderr line shape (trailing `""`, no trailing `""`, a lone `""` for empty output), a daemon exit fails every pending request and the next call restarts it exactly once before falling back for the cooldown window, the per-request timeout (plus a late response after it being dropped), and `AZVICLI_NO_DAEMON=1` - with a shimmed `vim.fn.jobstart`/`chansend`/`timer_start`/`nvim_create_autocmd` and a minimal JSON codec |
| `test-review-comments.lua` | `review/comments.lua`'s pure helpers: the line-to-comment mapping over a synthetic popup rendering, and optimistic edit/delete apply-and-revert against a synthetic thread table with a fake `run_write` that succeeds or fails |
| `test-review-commits.lua` | `review/commits.lua`'s pure helpers: parsing an Overview commit row and pulling a sha out of one, finding the commit under the cursor scoped to the "Commits (who pushed):" block, parsing `git show --name-status` output (including a rename), and root-commit detection from `git rev-list --parents` output |
| `test-review-range.lua` | `review/range.lua`'s pure helpers: resolving a visual selection to a `{side, start, stop}` range over a synthetic diff map (forward/reversed selections, a single-line collapse, mixed-side and non-commentable ends), and the `--post` argv it builds, with and without an `endLine` |
| `test-review-batch.lua` | `review/batch.lua`'s pure helpers: the winbar tag text, queueing/removing/serialising items, the argv a queued item submits with, and submission order/vote timing against a fake `run_write` (a failed item staying queued while the rest confirm, and the vote going out last and only when chosen), and for a native-review host (GitHub) the one-review payload (verdict, body from the reason/PR comments/Conversation replies, the rest as items) and its all-or-nothing submit; a reply's thread status set right after the reply (and after a native review lands), a failed status leaving the reply sent |
| `test-review-since.lua` | `review/since.lua`'s pure helpers: ISO-8601 timestamp normalisation (fraction padding, numeric UTC-offset folding across a day/month/year boundary) and comparison, picking my last review point out of a synthetic thread list (including a vote-only "system" comment, and "no comments at all"), picking the base iteration to diff from out of a synthetic iterations list (including "every iteration is newer than my last review"), and the `since:<short-sha>`/`:iws` variant and range string composition |
| `test-review-followup.lua` | `review/followup.lua`'s pure helpers: selecting "my" anchored/unanchored threads out of a synthetic flat thread list (first-comment authorship, someone else's thread excluded, file-level/PR-level threads routed to "unanchored"), parsing `git diff --unified=0` hunk headers (add-only, delete-only, a modify, an omitted single-line count), the new-side overlap/window check, the old-side -> new-side line-mapping rule (shift accumulation across several hunks, a line inside a deleted range returning nil), classification ("n/a" for a target-side thread, "unchanged" for no nearby/no hunks at all, "changed" otherwise), the resolved-status crossing (closed-as-is/addressed) and its sort order, the hunk cache being keyed on the source tip as well as the base (and never caching a tip that didn't resolve to a sha), row formatting and changed-first/path/line sorting, and the summary-line/row-map builder (singular/plural iteration and thread counts, the "Unanchored" section only appearing when there is one) |
| `test-review-pane.lua` | `review/pane.lua`'s pure fold-level and gutter computations: far context folding while 3 lines either side of a change (and of a commented line) stay open, a too-short foldable run left unfolded, the one-column line-number gutter across a hunk (context and added lines show the new number, a deleted line its old one, dimmed; the width following the larger side, an unmapped line blank), `set_keep` recomputing levels, and `forget` |
| `test-review-viewed.lua` | `review/viewed.lua` against an in-memory store: marking/counting viewed files, a new push clearing the mark, separate PRs kept apart, toggling off/on, next/previous unviewed file (wrapping, `nil` once all are viewed), remembered folds (round trip, per variant and PR, nothing open deleting the record, `folds_drop`) beside the marks, and a store written before folds were remembered still loading its marks |
| `test-review-folds.lua` | `review/folds.lua`'s pure parts: fold runs and their new-side line-range ids, which runs a remembered set reopens (exact, zR's every run, a fold split by a new comment reopening both halves, junk ignored), the diff stamp (same lines same stamp, changed lines a new one), and the remember/drop rules through `review/viewed.lua` |
| `test-review-bom.lua` | `review/bom.lua` on real `cache.lua` `parse_diff` output: a UTF-8 BOM on both sides, on the new or old side only (one unchanged line 1, the rest of a removal kept, gutter numbers still the file's), none (the same tables back), alongside a real line-1 change, a comment on line 1 landing on buffer line 1, and `fix` normalizing a cache entry once |
| `test-review-images.lua` | `review/images.lua`: finding image references on a line, the terminal/renderer detection with stubbed snacks.nvim / image.nvim (present and absent), placing and removing with a stubbed renderer, and `<CR>`/`gx` end to end against `tests/fake-provider.py`'s `--fetch-image` - a `0600` download, credentials only for the PR's own host, another host opened in the browser without them, and the keys on other lines doing what they did |
| `test-review-overview-syntax.lua` | Runs in headless nvim: `review/overview_syntax.lua` - only the description and comment bodies are Markdown, the header, branches, reviewers and commits are plain text, an intraword `_` is never a `markdownError`, and the user's own `markdownError` highlight stays as it was |
| `test-review-thread-text.lua` | Runs in headless nvim: `review/thread_text.lua` - a SonarQube-style bot comment reads as text with its link's address on its own line, the reference lines gone, wrapped to the width under the gutter without breaking the address, and the popup's colours |
| `test-keys.lua` | `config.lua`'s `setup()` merge/validate (override, unbind via `false`, a multi-key action, per-surface `prefix`, an unknown action/surface name erroring clearly) and `keys.lua`'s `resolve`/`bind`/`line`/`label` against it |
| `test-keys-palette.lua` | Runs in headless nvim: `keys.lua`'s action palette (`M.palette`, `g.`) - binding a screen's keys binds its palette, it lists that buffer's normal-mode actions once each, the pick runs in the window it was opened from, cancelling runs nothing, each buffer lists its own actions, `?` lists the palette key, and `palette = false` binds and lists none |
| `test-key-hints.lua` | Runs in headless nvim with the main loop (real input): `keyhints.lua`'s pure `wanted`/`lines` (`ui.key_hints` `"auto"`/`true`/`false`, the write marker, a "N more" row, a long description cut), `keys.lua`'s `writes_on`, then the g-key float - `g` and a pause put it up with vote marked, the next key closes it and runs, `gg` typed fast shows no float, a count still applies, `<Esc>` does nothing - and which-key (under `"auto"`) or `ui.key_hints = false` leaving `g` unmapped |
| `test-perf.lua` | `perf.lua`'s pure helpers behind `:AzureCli perf`: which screen a request belongs to, folding ids out of a path, and the summary and its lines |
| `test-web.lua` | `web.lua`'s pure helpers: the phone dashboard's page JSON built from the Agents screen's rows (keeping only what the page may show) and its URL |
| `test-shell.lua` | `shell.lua`'s `open_url` without `vim.ui.open` (Neovim 0.9): it starts `xdg-open` / `open` itself, detached |
| `test-sandbox.lua` | `tests/sandbox.lua`'s own probe, started straight from a polluted environment (XDG dirs and `HOME` at a sentinel directory, a bogus `VIMRUNTIME`, `AZVICLI_CHAT_*` set) under both `luajit` and headless nvim: it ends up in a fresh sandbox with its own `HOME`, and `run.sh` checks the sentinel directory stayed empty |
| `test-merge.lua` | `merge.lua`'s pure helpers: `build_label` for every build state (queued included), `warnings` (a green build/no conflict/zero threads is clean, an unknown thread count is not a warning, singular/plural threads), and `lines` for a full spec and a bare one (toggle states, merge-type cycling, the `?` placeholders, the warning line only when there is one) |
| `test-hosts.lua` | `hosts.lua`: the host falls back to Azure, record overrides layer without touching the host's table, the key and ref, vote lookup and glyphs, which statuses are open, and mention tokens |
| `test-prs.lua` | `prs.lua`'s pure PR-record helpers: `surname` parsing, applying/undoing my vote (key, ratio, summary, adding me when absent), `iso_epoch` of the provider's UTC stamps (a summer and a winter stamp pinned so the local-offset correction is checked, unparseable/`nil` as 0, ordering), and `drop_completed`/`mark_completed` (a PR completed this session hidden while ADO still lists it, forgotten once gone, back after the grace period, undo unmarking) |
| `test-pr-workitems.lua` | `pr_workitems.lua`'s pure helpers: a PR row's linked-work-item badge (none/one/several), `describe` (full and id-only), and `gW`'s picker lines (with and without an assignee) |
| `test-migrate.lua` | `migrate.lua`'s `M.ensure`: old present/new absent copies the old file's content into the new one verbatim (line-for-line, multi-line included), new already present leaves it untouched and never even needs to read the old file, and neither existing is a harmless no-op - with a shimmed `vim.fn.filereadable`/`readfile`/`writefile` against a tiny in-memory fake filesystem |
| `test-states.lua` | `workitems/states.lua`'s pure `M.build`/`M.rank`/`M.hl`: the fallback (no `states:` configured) reproduces the built-in per-name rank/highlight tables exactly, a configured list's position→rank and position→highlight-group rules (1st/2nd/last/second-to-last/others), an unconfigured state ranking last with a neutral colour, and a duplicate name in the list keeping its first position |
| `test-state-dialog.lua` | `workitems/state_dialog.lua`'s pure helpers behind `gs`'s popup: `child_target` (same name when reachable, else the same category, already there, no state in the category, names only without categories), `default_on` (forward vs. backward moves, into Removed, nothing to map to), `reason_options`, the rendered `lines` (loading/empty/pending rows, the reason cycler, skipped children saying why, grandchildren indented, progress counts, long titles cut) and the `toggle_all`/`toggle_kid` "also set children" toggles, plus `tree_order` |
| `test-linked-prs.lua` | `workitems/linked_prs.lua`'s pure helpers: the dashboard's PR marker (none/one/several), PR status (active, draft, a completed draft as completed, unread), the detail view's PR lines (an unread PR as just its id, no author), and `marker_range`/`marker_group` for highlighting the marker column |
| `test-config.lua` | `config.lua`'s `setup()` options beyond `keys` (already `test-keys.lua`'s): `python`/`config` precedence (env `AZVICLI_PY` > `setup()` > probe; `setup({config=...})` always wins) and validation, `M.config_path()`, the `AZVICLI_PREFETCH_DIR`/`AZVICLI_HIDE_ANCIENT_DAYS` defaults `provider_cmd()` sets (never overwriting an ambient value), `timing`/`hide_ancient_days` defaults/partial-override/validation, `cached_prs`/`threads_ttl_seconds` actually landing on a real `cache.lua` instance via `setup()` (pre-seeded into `package.loaded` so `config.lua`'s own internal `require("azure-cli.cache")` resolves to the same table the test inspects), and `collapsed_sections` defaults/override/reset/empty-table/validation |
| `test-ui.lua` | `ui.lua`'s pure `UI.winbar` (context/tags/help joining, blank entries skipped) and `UI.layout` (growing to ideal by weight, `grow` columns soaking up leftover width, the lowest-priority-first drop order when even the minimums don't fit, an undroppable column surviving regardless) |
| `test-innertabs.lua` | `innertabs.lua`'s pure helpers: next/previous wrapping around the strip, where closing an inner tab goes (the one before it, else the list), and the strip's text (the list first, the current entry bracketed and in the title group, long titles cut with an ellipsis, the current one keeping more, `%` escaped) |
| `test-confirm.lua` | Runs in headless nvim with the main loop (real input): `ui.lua`'s question popup (`UI.choose`/`UI.confirm`) - its lines (buttons in a row or one per line, the focused one lit, wrapping), every way out (`y`/`n`, `<CR>` on the focused or `default` button, `<Tab>`/`j`/`k`, `q`/`<Esc>`, `opts.cancel`, leaving the window), stray editing keys ignored, `arm_ms` ignoring an instant answer but not `<Esc>`, the details window above it, `ui.confirm = "select"`, keeping insert mode across it, and the two callers: the chat's "may the agent ...?" and approving a plan (Approve / Approve and push / Cancel) |
| `test-review-filelist.lua` | `review/filelist.lua`'s pure `M.diff_stats` (add/del counts from a parsed-diff map) and `M.build` (directory grouping and sorting, common-prefix trimming - including "no common prefix" and a lone file still getting its own header row - the row_to_file/file_to_row/ordered_files maps, status-letter/stats/thread-count row formatting including the uncached "(?)" and no-status-yet cases, and the AzureCliFileDir/Added/Deleted/Renamed highlight assignment, "M" deliberately getting none) |
| `test-chat.lua` | Runs in headless nvim (needs `vim.json`/`vim.api` at load): the chat's message composition (first/resumed/replayed), task agents' pure parts (#143: key, label, gate, first message, read-only rule, Agents screen row), answer parsing (Claude Code's envelope, plain text, `session_pattern`), `can_resume`, models, transcript rendering, the view description, the tool list's shape and ask/write split, a declined "ask" tool never running, and `review/chat.lua`'s thread shape; the stream reader (partial lines, stream-json events, our own MCP tools not listed twice, `strip`), saved prompts, reference parsing/resolution/completion, permissions (overrides, a denied tool hidden and refused), the store (in a scratch directory: saving, a slim audit entry, undone marks) and the reviewer's hunk/selection-line helpers |
| `test-chat-plan.lua` | Runs in headless nvim: the pure parts of `chat/plan.lua` (sections, missing template sections, planned files and `check_files`, resolving a line by its text, plan/code links, `revision_changes`, the plan gate, `push_check`, `run_log`, `section_text`, `pr_description`, skill detection/listing, `chat.skill_dirs` and the `/skills` popup (`<Space>` allows / asks again, `<CR>` uses one), `approval_message`, `pr_allowed`), the questions under a line (`chat/threads.lua`) and the change viewer's file list (`chat/changes.lua`), and the Agents screen's rows |
| `test-chat-persistent.lua` | Runs in headless nvim against `tests/fake-persistent-agent.py`: `chat/init.lua`'s `send` keeping one agent process across messages (same pid, turn 2, one process ever started), per-turn cost, a new chat stopping it, `gm` starting a new process with the conversation replayed, one conversation per plan key (two processes at once, the main one staying current), restoring a plan's conversation, and the main chat's `message_agent` to a plan's agent mid-turn queued in that agent's queue and delivered in order when the turn ends (#60), the timeouts (#27: a quiet agent stopped by the idle one, steady output past it never stopped, the cap stopped however steady, each saying which - also on the Agents screen), and a one-shot CLI (`tests/fake-oneshot-agent.py`) reported as one that can't stay running |
| `test-chat-watchdog.lua` | Runs in headless nvim, pure: `chat/watchdog.lua` on a hand-turned clock - the idle timeout (reset by output, paused while a tool works or a popup waits), the cap (less popup time), the old `timeout_seconds` name, and the status and line saying which fired |
| `test-chat-acp.lua` | Runs in headless nvim against `tests/fake-acp-agent.py`: `agent.acp` (`send_acp` + `chat/acp.lua`) keeping one ACP session warm across messages and handing an http-only agent `azure-cli.py --mcp-http`; tool permissions (reads allowed, edits asked, planning refusing edits, an approved plan's files/build/test commands not asking, an unplanned file asking and joining the plan once allowed, read-only shell searches, skills allowed from the popup, the `chat.permissions` groups, `run_tests`), `usage_update` cost/context and premium-request counting, `planner_model`/`implementer_model` switching, the main chat coordinating plan agents (`/plan`, `list_agents`, `message_agent`, `start_agents`), task agents (#143: `start_agents` with `task` under `chat.max_agents`, read-only on every turn - edits and write tools refused, drafts and reads allowed, a shell command still asking - the answer back to the main chat as a note and in its next message without a turn of its own, the Agents screen's "answered", planning for its own task in a `<repo>-task<n>` worktree, adopting a work item's plan, refused when that item has an agent, restored after a restart), and the idle timeout over ACP (stopped through `session/cancel`, the session surviving it, a popup's wait not counted) |
| `test-chat-bridge.lua` | Runs in headless nvim: `chat/bridge.lua` over a real socket - it listens with a 32-hex-digit token, a request with the token is answered, a wrong token is refused, and one growing past `MAX_REQUEST` without a newline is dropped while the bridge keeps answering |
| `test-chat-exit.lua` | Runs in headless nvim (`luafile`, under `timeout 30`): quitting while agents work with more queued (`max_agents = 1`, `tests/fake-persistent-agent.py`) exits straight away - `run.sh` fails it if it takes 10s or more or never reports an agent working |
| `test-chat-insert-send.lua` | Runs in headless nvim with the main loop (real input): in the chat's input box `<CR>` while typing sends and leaves insert mode, `<C-j>` (and `<S-CR>` where the terminal reports it) breaks the line, `<CR>` with the completion menu open picks the entry, and while the agent answers `<CR>` queues the message instead |
| `test-agents-enter-mode.lua` | Runs in headless nvim with the main loop (real input): `<CR>` on an Agents row opens its agent - the plan with its conversation, or before it has planned the conversation in a popup - and leaves you in normal mode; only `i` goes into the chat's input box |
| `test-plan-discard.lua` | Runs in headless nvim: `dd` on the Agents screen and `gD` in a plan view discard a plan - asking first (Discard / Cancel, Discard first; Cancel leaves everything), refused while its agent works, the files deleted, the worktree deleted even with uncommitted or unpushed changes and its local branch with it (the server's stays), a plan with no agent conversation and a queued one handled too - against real git worktrees in the sandbox |
| `test-plan-tabline.lua` | Runs in headless nvim: the tab line's "N plans wait for you" is redrawn whenever the plans index changes (a discard, an approval, a new plan), without a chat render or a tab switch, and once for a burst of saves |
| `test-start-story.lua` | Runs in headless nvim: `start_story` against a real scratch origin and clone - the worktree on the branch (detached only when git can't, saying why), the clone found from `clones_dir` before the PR list has loaded, a story on an existing branch pushed straight to it with no PR step, and the read-only worktree before the plan is approved becoming the story's once it is |
| `test-web-token.lua` | Runs in headless nvim: the phone dashboard's token end to end, `web.lua` starting the real `azure-cli.py --web-dashboard` - two starts give the same URL, the stored file is `0600`, `rotate` changes the URL (running) or deletes the file (stopped), an unsafe file is replaced with a warning, and the token is on neither the server's argv nor in a message or `:AzureCli log` |
| `test-poll.lua` | Runs in headless nvim: `poll.lua` on a hand-turned clock - polls slowing while Neovim is unfocused or idle and refreshing once on return, the phone dashboard's feed keeping its rate - and, run again on a `tests/fake-provider.py` workspace, every real poll (the PR dashboard, both boards, a review, the chat's watched PRs) going through it |
| `test-boards.lua` | Runs in headless nvim on a `tests/fake-provider.py` workspace, twice: with only an Azure account there's no `I` in any key map, help or palette and three home tabs open; with a GitHub account that has `issues:`, `I` is bound on the PR dashboard, Work items and Agents, four home tabs open, and `I` goes to the Issues tab |
| `demo-smoke.lua` | The headless half of `tests/demo.sh --headless` (the fake-provider demo smoke below): each check prints its own marker, so one failure doesn't take the later ones down with it |
| `test-chat-acp-live.lua` | Manual only - not run by `tests/run.sh`: needs a locally authenticated `copilot` CLI and makes two small real requests; `agent.acp` against a real `copilot --acp` - both turns answer and reuse the same tracked ACP connection. Run by hand (`nvim -u NONE --headless --cmd "set rtp+=<repo>" -l tests/test-chat-acp-live.lua`) after touching the ACP code |
| `test-chat-acp-mcp-live.lua` | Manual only - not run by `tests/run.sh`: needs a locally authenticated `copilot` CLI and makes one real request; checks azure-vicli's tools reach a real `copilot --acp` session over `--mcp-http` (the agent reports `current_view`'s screen). `test-chat-acp.lua` covers the same path against a fake agent |
| `test_chat_provider.py` | `azure-cli.py`'s `--wi-edit create-branch` (the exact source ref out of a prefix-matched `filter=`, the all-zero `oldObjectId` POST, the `vstfs:///Git/Ref/...%2FGB<branch>` "Branch" link, no link without a work item, a rejected update, a failed link still reporting the branch) and the `--mcp` relay (`initialize`, notifications, `tools/list`/`tools/call` relayed, tool errors as tool results, an unreachable bridge, `mcp_serve`'s line loop, and a real TCP round trip carrying the token); also `delete-branch` (refusing once someone pushed), `--build-log` (failed records, issues, log tails, a JSON-lines log body), `--test-results` (each run's failed results, a server ignoring `outcomes`, stack traces cut to 30 lines), `--add-reviewer` (identity search on vssps for Services, the collection on Server, an ambiguous name, an id added without a search), `--find-people` (people, not groups, with their account), `--set-description` and `--create-pr` (work item refs, draft) |
| `test_provider.py` | `azure-cli.py`'s YAML-subset config parser; PR classification (every branch of the assigned/created/draft/declined/signed-off/waiting/actionable rules, including `AZVICLI_HIDE_ANCIENT_DAYS` widening/narrowing/falling back on an invalid value from the hard-coded 30); thread and @-mention counting; build-status aggregation and policy/missing-reviewer derivation; vote ratio, reviewer summary and humanized-date formatting; `Config.path()`'s `AZVICLI_CONFIG` override (with `~` expansion); and an NDJSON serialization check of the emitted field list. HTTP is mocked by swapping `AzureDevOpsPullRequestSource.fetch` for a fake - no network access or live Azure DevOps instance is needed. |
| `test_github.py` | `github_host.py`, the GitHub backend: the GraphQL/`gh` host names (github.com and Enterprise Server), a PR's reviews as Azure votes (a re-requested reviewer waits again, a comment doesn't undo an approval, the author and teams), fork PRs sourced from `refs/pull/<n>/head`, review threads and the Conversation tab as Azure threads (line, range, left side, file-level, outdated), `@login` mentions, commits and force pushes as iterations plus my last review's commit, `--list`'s sections and record fields (key, location, counts that leave the Conversation thread out), the per-PR thread cache, `host:`/`owner:`/`api_url:` in the config, which account an action belongs to, and the fork prefetch refspec. The writes: line and range comments (either side, on the head commit, a line outside the hunks explained), file and Conversation comments, replies in a thread and in the Conversation, edits and deletes of either kind, resolving and reopening by the thread's first comment, votes as reviews (a stock reason for changes requested, dismissing my latest review), a batch as one review (every comment into a pending review then submitted with the verdict, a pending review of mine joined, deleted again when a step fails, items that can't be in a review refused up front), GitHub's error text, and merging still refused. The GraphQL/REST client is faked; no network. |
| `test_github_rest.py` | `github_rest.py`: a GraphQL refusal switching the host to REST (not a rate limit or a bad token; `AZVICLI_GITHUB_REST=1`; a query with no builder saying so), search hits and repository listings as PR nodes (reviewers and votes, dismissed reviews, teams, conflicts, checks, a gone branch, forks), the clones in `clones_dir` as the repositories to list, `--list` over REST, review comments grouped into threads (ranges, the left side, outdated, file-level, the Conversation, resolved through the proxy's route or not at all), resolving by the first comment, pushes and force pushes as iterations, a batch as one REST review with the replies and file comments after it (nothing posted when the review fails, a later failure reported rather than retried, a pending review of mine refused), reviewers by login or team, the description, the body's closing lines as the PR's issues, merge state (a draft, a failed check) and auto-merge through the proxy's route. REST is faked by method and path; no network. |
| `test_github_issues.py` | `github_issues.py`: a GitHub account's Projects v2 project answering `--wi-list`/`--wi-detail`/`--wi-state`/`--wi-edit`. The client's fetch answers GraphQL by a word in the query and REST by method and path, and records every call; no network. |
| `test_fetch_image.py` | `--fetch-image`: an image is downloaded with the PAT or token only from the PR's own server, the credential never reaches another host (directly or through a redirect) or the log, and the file is `0600`, named from its Content-Type - against two real HTTP servers on 127.0.0.1, never the network. |
| `test_web_dashboard.py` | The phone dashboard's server (`--web-dashboard`): what the page JSON keeps, which binds are refused, and the token, cookie, GET-only and header rules over real HTTP. |
| `test_http_pool.py` | The keep-alive connection pool: requests to one host share a connection, a stale one is retried once for a read and never for a write, proxies (`HTTPS_PROXY`'s CONNECT tunnel, `HTTP_PROXY`, `NO_PROXY`) still apply, and the perf log says new/reused - against a local server and proxy. |
| `test_connection_data_cache.py` | The `--serve` daemon's connectionData cache: one request per org and PAT within its TTL, refetched after it, on a 401/403/203, a PAT change, a config load or a daemon start; one request for concurrent workers; a retry once when a cached identity fails; off outside the daemon, for `--doctor`/`--whoami` and for GitHub. |
| `test_list_parallel.py` | `--list` listing accounts (orgs and GitHub accounts) at once on a pool of 8: records in the same order as a serial run, one account's error or timeout reported for that account only, connectionData still fetched once per org. |
| `test_perf.py` | The perf log: with `AZVICLI_DEBUG` on, one line per provider HTTP request and one total per command in `<AZVICLI_PREFETCH_DIR>/perf.log`, never a header, PAT or token; with it off, nothing written. |
| `test_pr_actions.py` | `azure-cli.py`'s PR-action subcommands (`PrActions` - threads/iterations passthrough, posting/replying/editing/deleting comments, thread status, vote, complete, auto-complete) and the `AZVICLI_PREFETCH=1`/`all` branch-prefetch modes. HTTP is mocked the same way `test_provider.py` mocks it (`PrActions.fetch` swapped for a fake); git is exercised for real for `post_inline`'s git-show line-length lookup. Also `default_prefetch_dir()`'s platform branches (Windows `%LOCALAPPDATA%`, else `$XDG_CACHE_HOME`, each with its own no-env fallback) and both call sites (`PrActions.__init__`, `cmd_prefetch`) actually using it when `AZVICLI_PREFETCH_DIR` is unset. |
| `test_work_items.py` | `azure-cli.py`'s work-item subcommands (`WorkItemActions` - `--wi-list`'s sprint resolution/WIQL/batch fetch, `--wi-detail`'s parent/child/comment/pull-request assembly and HTML flattening, `--wi-state`'s transitions/reasons derivation and state changes, `--wi-edit`'s create/set/comment/link-pr/unlink-pr JSON Patch bodies). HTTP is mocked the same way, via `WorkItemActions.fetch`. Also `work_items.states:`/`sprint_scope:` parsing and defaults, and the `states`/wider-iteration-list `--wi-list current`/`sprints` output they carry (including an undated iteration sorting last under `sprint_scope: all`). |
| `test_serve.py` | `azure-cli.py`'s `--serve` daemon: `dispatch()`'s in-process request runner (a `--ping`, a missing config returning 1 instead of exiting the process, an unhandled handler exception being caught, per-request `env` threaded through rather than read off `os.environ`, a monkeypatched handler's captured output coming back verbatim, and concurrent `dispatch()` calls on different threads never seeing each other's captured stdout) and `serve()`'s request loop (a real `--ping` round trip, a clean exit on EOF, a malformed/non-object JSON line getting an `"id": null` error response, concurrent requests completing out of order and still matched up by id, and a request's `env` overrides reaching `dispatch()` merged over the daemon's own environment) - stdin/stdout are faked (`sys.stdin.buffer` an `io.BytesIO` pre-loaded with every request line, `sys.stdout` a plain `io.StringIO`), everything else (the `ThreadPoolExecutor`, real threads) is real. Also covers `get_cached_config()` (a serving daemon keeps its start-up config whatever happens to the file afterwards; outside `--serve` every call reads the file) and the `.userid` cache's atomic (temp-file-then-`os.replace`) write. |
| `test_launcher.py` | `azure-cli.py`'s standalone launcher (`launch_dashboard` exporting `AZVICLI_PY`/the provider, `AZVICLI_REPO_PATH` only when `repo_path` is configured, never a stale one), the `AZVICLI_*`/`AZVICLI_WI_*` request-env names `PrActions`/`WorkItemActions` read (and report when missing) after the rename from `PRDASH_`/`WIDASH_`, and `--init-config` (the template written once, its path printed, a bare launch without a config still starting nvim) |

The prefetch/split/decorate tests run against a small scratch git repo the
runner builds in a temp dir (two branches, `tgt` and `src`, exposed as
`refs/remotes/origin/{tgt,src}` since that's what the prefetch pipeline
diffs). Everything is cleaned up on exit.

The eight headless `nvim` smokes and the twenty nvim-run Lua tests
(skipped, not failed, when `nvim` isn't on PATH). The smokes: `gO`'s menu
naming both config files (the options as `azure-cli.lua` in standalone
mode, `setup()` otherwise) and `:AzureCli status`'s `options` line; `setup()`/`config.lua` - `require('azure-cli').setup()` then asserting
`require('azure-cli.config').get().keys.diff.next_hunk` resolves - proves
`require("azure-cli")` and its dependents actually resolve through
`'runtimepath'` the way a plugin-manager install would (`--cmd "set
rtp+=$REPO_ROOT"`, not this repo's own working-directory layout);
`standalone/init.lua`, twice - the launcher's real entry point against a
temp, deliberately unpopulated `XDG_CONFIG_HOME`: the first run writes the
config template and opens it (filetype `yaml`, a `TODO` in it), and a
second launch asserts the dashboard buffer renders (`filetype ==
'azurecli-dashboard'`) even though `--list` fails fast on the still-TODO
config; a `keys` override - `setup({keys={diff=
{next_hunk="]h"}}})` then asserting `keys.lua`'s `resolve` actually returns
`]h`, not just that the default exists; `:AzureCli status` -
`setup({python=..., config=...})` then asserting `require('azure-cli').status()`'s
returned table carries those exact values, not the probe/platform defaults;
`setup({accounts=...})` - with no `azure-cli.yml` at all, the first
`:AzureCli` opens the dashboard (not the first-run template) and the
provider reads the token from the account's `pat_file`;
and the fake-provider demo - `bash tests/demo.sh --headless` (see
[Trying it without Azure DevOps](#trying-it-without-azure-devops) below)
asserting the dashboard lists the fake PRs, through `rpc.lua`'s real daemon
client, and that the reviewer then opens PR #101 with its file list, through
the warm-all prefetch's real `git fetch` and the reviewer's `git diff`
pipeline. It also drives the [chat panel](chat.md) with
`tests/fake-chat-agent.py`, a real MCP client of `azure-cli.py --mcp`: from
a thread in auth.py's diff it checks the view the agent is given, a drafted
reply landing in the batch queue unposted, `gm`'s model and a resumed
session, a branch created on the fake origin and linked to #3001, a vote
that asks and is denied, and the panel following into the dashboard's tab.
A second step covers the rest: a streamed (stream-json) answer, a visual
selection and a `!102` reference carried into the message, `/build`
reading a build log, `open_in_ui` landing the reviewer on `throttle.py:4`, an
`annotate_code` note drawn in the diff, the fix flow (worktree, diff, asked
before the push, the commit on the fake origin's branch), the board tools
and undoing the link from `gH`, `gr`, switching agents with `gM` (a
replayed turn) and `gh` bringing a conversation back.

`tests/gen-keys-table.lua` (`luajit tests/gen-keys-table.lua`) prints the
[Keys](commands-and-keys.md#keys) section's tables straight from `config.lua`'s defaults - not
part of the `run.sh` gate (there's nothing to assert; it's a generator, not
a test), but re-run it and paste the output over that section after
changing a default, so the two can't quietly drift apart.

`tests/test-keys.lua` also refuses a default key that changes something on
one screen (an action in `keys.lua`'s `WRITES`, or approving a plan) and is
harmless on another, unless the acting one asks first: it lists those in
`ASKS_FIRST`, each with how it asks. A new action that writes to Azure
DevOps goes in `WRITES`, so `?` marks it and the check covers it.

GitHub Actions (`.github/workflows/ci.yml`) runs `bash tests/run.sh` on
every push and pull request, on ubuntu-latest with the distro's Neovim
installed by apt (0.9.x, the minimum the plugin supports).

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
  desktop notifications quiet. `--headless` also gets an empty `HOME` in
  the workspace; the interactive modes keep yours, so a real agent opened
  from the demo's chat keeps its login.

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
the inline thread, the complete dialog, a GitHub PR's merge dialog, work
items, a work item, then the
chat's plan window, a question under a line of a change, the Agents
screen and the `/skills` popup - those scenes are seeded by
`tests/shot-{plan,change,agents,skills}.lua` through `:luafile`, since no agent runs), captures each screen with its colours and rasterises it through ImageMagick's
`pango:` coder. Needs tmux, an ImageMagick with pango support and a
monospace font (Noto Sans Mono by default - `--font` picks another); no
display. Re-run it after a UI change and commit the result; add a step to
`SHOTS` in the script for a new screen.

### Extending the reviewer

`review/init.lua` is a large file sitting close to LuaJIT's hard
200-active-local ceiling (98+ keymap/help/winbar call sites, the whole
reviewer's state), so every reviewer feature hangs off one table, `EXT`,
instead of adding its own top-level `local`s, and lives in its own module
under `review/` (`review/{nav,comments,commits,range,batch,since,followup,workitems,chat,images}.lua`)
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
   Two features can share one key: `ctx.add_key(kind, action, fn, desc,
   mode, { chain = true })` calls `fn(prev, key)`, `prev` being the handler
   an earlier module registered for that key and mode (nil if none), which
   this one replaces - so it can hand over where it has nothing to do
   (`review/images.lua`'s `<CR>` on a line with no image goes on to
   `review/commits.lua`'s `open_commit`, which is why images.lua loads after
   it). `ctx.on_overview_render(fn)` runs `fn(buf, lines)` after every
   Overview render (images.lua draws its inline images there).
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
`add_key`, `on_comment_popup`, `on_overview_render`, `decorate_diff`, `ft_for_path`, `parse_diff`
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
