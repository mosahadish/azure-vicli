# azure-vicli

A terminal dashboard for Azure DevOps that lives entirely inside Neovim.

It shows the pull requests waiting on you, lets you review and comment on them
with vim navigation, and has a second dashboard for the work items assigned to
you in the current sprint. Everything a review needs is prefetched in the
background, so opening a PR, switching files, and jumping to a definition are
instant.

## Contents

- [Requirements](#requirements)
- [Install](#install)
- [Configuration](#configuration)
- [Running](#running)
- [Pull request dashboard](#pull-request-dashboard)
- [Reviewer](#reviewer)
- [Code navigation](#code-navigation)
- [Work items](#work-items)
- [How it stays fast](#how-it-stays-fast)
- [Architecture](#architecture)
- [Environment variables](#environment-variables)
- [Troubleshooting](#troubleshooting)
- [Development](#development)

## Requirements

- Windows with Git for Windows (git-bash) is the primary platform. Linux and
  macOS work for the C# and Lua parts; the shell scripts assume bash 4+.
- .NET 6 SDK, to build the data provider.
- Neovim 0.9 or newer (0.11 recommended).
- git, curl, python 3.
- An Azure DevOps personal access token (PAT) with Code read/write and Work
  Items read/write scopes. Azure AD login is used as a fallback on Windows
  when an account has no PAT, but the work-item screens need a PAT.

## Install

```
git clone https://github.com/mosahadish/azure-vicli
cd azure-vicli
bash install.sh
```

`install.sh` checks or installs the dependencies, builds the project, creates
the config file at its platform location with placeholders, and opens it for
editing. It is safe to re-run and never overwrites an existing config.

## Configuration

The config file is `%APPDATA%\azure-cli.yml` on Windows and
`$XDG_CONFIG_HOME/azure-cli.yml` (default `~/.config/azure-cli.yml`) elsewhere.
Press `gO` in any dashboard to open it.

```yaml
# Machine-wide settings.
bash_path: C:\Program Files\Git\bin\bash.exe   # optional; well-known paths are probed

accounts:
  - project_name: MyProject
    org_url: https://dev.azure.com/my-org        # or an on-prem collection URL
    pat: <personal access token>
    hide_ancient: true                            # hide PRs with no commit in 30 days
    clones_dir: C:\Users\me\source\repos          # where repos are (or get) cloned
```

| Field | Scope | Meaning |
|---|---|---|
| `bash_path` | top level | git-bash to run the helper scripts under. Optional on Windows; probed when unset. |
| `repo_path` | top level | Legacy single-clone fallback. Prefer `clones_dir`. |
| `project_name` | account | The Azure DevOps project. |
| `org_url` | account | Organization or collection URL. Several accounts may share one. |
| `pat` | account | Personal access token. Required for work items; optional on Windows for PRs. |
| `hide_ancient` | account | Drop PRs whose latest commit is older than 30 days. |
| `clones_dir` | account | Directory holding one clone per repository, named after the repo. Repos are cloned here on demand when you open a PR. |

The config file is the only source of credentials. Ambient `AZURE_DEVOPS_EXT_PAT`
or `ADO_PAT` variables in your shell are never consulted.

## Running

```
src\bin\Debug\net6.0\azure-cli.exe
```

With no arguments the exe launches Neovim with the dashboard and the
environment the helper scripts need. Headless flags exist for scripting:

| Flag | Output |
|---|---|
| `--list` | Every relevant PR as newline-delimited JSON. |
| `--requeue <id>` | Re-queue expired or failed build validation for a PR. |
| `--print-pat --org <url> [--project <name>]` | The configured PAT for that account. |
| `--whoami --org <url> [--project <name>]` | The authenticated identity as JSON. |

## Pull request dashboard

PRs are grouped into sections: Actionable, Waiting for author, Signed off,
Drafts, and Created by me. Within a section the most recently updated PR is
first. The list refreshes every minute.

| Key | Action |
|---|---|
| `j` / `k` | Move |
| `<CR>` | Open the PR in the reviewer, cloning its repo first if needed |
| `gd` | Show the description |
| `gy` | Copy the PR link |
| `o` | Open in the browser |
| `/` | Filter by title, repo or author |
| `gv` | Vote |
| `gm` | Complete (merge) |
| `ga` | Toggle auto-complete |
| `gr` | Re-queue build validation |
| `gO` | Open the config file |
| `r` | Refresh |
| `W` | Switch to the work-items dashboard |
| `q` | Quit |

Each row carries badges to the left of the id:

| Badge | Meaning |
|---|---|
| `●` | Unread comment activity since you last opened the PR |
| `⇣` | Branches or content being fetched in the background right now |
| `◆` | Fully prefetched; opens instantly |

The build column to the right of the id shows `✓` succeeded, `✗` failed,
`↻` expired, and `●` running with the queue position when known. `⚠` marks a
merge conflict and `A` marks auto-complete.

Votes, completion and auto-complete apply to the row immediately and are
reverted with an error if the call fails.

## Reviewer

Opening a PR adds a tab with the file list on the left and the selected
content on the right. The first row is always the Overview: title,
description, commits, and PR-level comments.

File list:

| Key | Action |
|---|---|
| `j` / `k` | Move; the right pane previews the file as you go |
| `<CR>` | Open and focus the file |
| `cf` | Comment on the whole file |
| `gC` | New PR-level comment |
| `]C` / `[C` | Next / previous file with comments |
| `gA` | Show only active (unresolved) comments |
| `gF` | Manage text filters that hide matching threads |
| `gv` / `gm` | Vote / complete |
| `<` / `>` | Resize the list |
| `<BS>` | Back to the PR list |
| `q` | Close the reviewer |

Diff pane:

| Key | Action |
|---|---|
| `]c` / `[c` | Next / previous change |
| `c` | Comment on the current line |
| `K` | View the comments on the current line in a popup; `R` and `s` work inside it |
| `R` | Reply to the thread on the current line |
| `s` | Set the thread's status |
| `]C` / `[C` | Next / previous thread |
| `gd` / `gr` / `gf` | Code navigation, see below |
| `<BS>` | Back to the file list |

Comments, replies and status changes appear the instant you submit them,
tagged "(sending…)" until the server confirms. If the call fails the entry is
removed and the prompt reopens with your text, so nothing is lost. Threads
refresh in the background every minute, and new comments on your PR or on
threads you took part in raise a notification.

## Code navigation

The reviewer navigates code across the whole repository at the PR's revision
without a checkout or a language server. `git grep` searches the source
branch (the target branch when the cursor is on a deleted line), and
`git show` reads files at that revision.

| Key | Action |
|---|---|
| `gd` | Go to the definition of the identifier under the cursor |
| `gr` | Find references |
| `gf` | Open the current file at the PR's revision, on the same line |

`gr` and `gd` open a peek view: hits on the left, and on the right the file
at that revision centred on the selected hit with the line and every
occurrence highlighted. Moving through the list re-previews. `<CR>` opens the
hit, `q` closes the peek.

Opened files and previews show the PR's changes: added lines in green, and
the lines the PR removed in red as virtual lines where they used to be. In a
revision buffer `gd` and `gr` keep working, `<BS>` walks back one jump, and
`q` returns to the diff.

The definition lookup is a heuristic that ranks grep hits by declaring
keywords, modifiers, and shapes such as a type followed by `Name(`. When one
line clearly wins it opens directly; ties show the candidates; no plausible
definition falls back to the references list.

## Work items

Press `W` in the PR dashboard. The work-items dashboard shows the user stories
and bugs assigned to you in the current sprint, with tabs for the other
sprints of the quarter.

| Key | Action |
|---|---|
| `<CR>` | Open the item: parent, children, description |
| `gs` | Change the item's state, with the allowed transitions and reasons |
| `[` / `]` | Previous / next sprint (also `<S-Tab>` / `<Tab>`) |
| `{n}gt` | Jump to sprint n |
| `r` | Refresh |
| `P` | Back to the PR dashboard |
| `q` | Quit |

In the detail view `<CR>` on a parent or child opens it, `gs` changes state,
`o` opens the browser, and `<BS>` returns to the list.

The collection, project, team, assignee and item types default to values in
`wi-list.sh` and can be overridden with the `WIDASH_*` variables listed below.

## How it stays fast

- **One pass for the list.** The data provider connects once per
  organization, requests the assigned and created listings together, and
  runs each PR's thread and build lookups concurrently under a bounded gate,
  fetching threads once per PR. Results keep listing order so the dashboard
  never reshuffles.
- **No process spawn for credentials.** The exe exports every account's PAT
  when it launches Neovim. The scripts resolve it with a pure-bash scan and
  only fall back to `--print-pat` when Neovim was started by hand.
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
invalidates it automatically. It holds 24 PRs. Knobs: `WARM_CONCURRENCY` and
`WARM_RANK` in `azure-cli.lua`, `MAX_PRS` and `THREADS_TTL` in
`prdash-cache.lua`.

## Architecture

```
azure-cli.exe (C#)        headless data provider + launcher
  --list  ───────────────▶ azure-cli.lua      PR dashboard (Neovim)
                             │  <CR>            ▼
                             │               pr-review.lua   reviewer
                             │  W                │ gd/gr/gf, comments, votes
                             ▼                   ▼
                          wi-dash.lua        review-pr.sh    REST via curl (threads, comments,
                          wi-view.lua                        votes, complete, prefetch)
                             │
                          wi-list.sh / wi-detail.sh / wi-state.sh   REST via curl + python
                             │
                          resolve-pat.sh     shared PAT lookup
                          prdash-cache.lua   shared content cache + prefetch pipeline
```

| File | Role |
|---|---|
| `src/` | C# data provider. `EntryPoint.cs` handles flags and launches Neovim; `DataSource/AzureDevOpsPullRequestSource.cs` classifies PRs and gathers thread and build status; `PullRequestListWriter.cs` emits NDJSON. |
| `azure-cli.lua` | PR dashboard: rendering, badges, hover and warm-all prefetch, optimistic actions. |
| `pr-review.lua` | Reviewer: file list, diffs, comments, optimistic writes, code navigation and peek view. |
| `prdash-cache.lua` | Per-PR content cache shared by dashboard and reviewer, and the prefetch pipeline that fills it. |
| `review-pr.sh` | REST helpers for PR actions, plus the branch prefetch modes. |
| `resolve-pat.sh` | PAT lookup from the exported table with `--print-pat` fallback. |
| `wi-dash.lua`, `wi-view.lua` | Work-item dashboard and detail view. |
| `wi-list.sh`, `wi-detail.sh`, `wi-state.sh` | Work-item data providers. |
| `install.sh` | One-shot setup. |

State that survives restarts lives in Neovim's data directory: the per-PR
"seen" snapshot for the unread badge, per-thread read counts, and persistent
comment text filters.

## Environment variables

Set by the exe when it launches Neovim; only needed when starting Neovim by hand.

| Variable | Meaning |
|---|---|
| `PRDASH_EXE` | Path to `azure-cli.exe`. |
| `PRDASH_SCRIPT` | Path to `review-pr.sh`. |
| `PRDASH_BASH` | bash to run the scripts under. |
| `PRDASH_PATS` | One `org<TAB>project<TAB>pat` line per account, read from the config. |
| `PRDASH_REPO_PATH` | Legacy single clone path. |
| `WIDASH_LIST`, `WIDASH_DETAIL` | Paths to the work-item scripts (`WIDASH_STATE` defaults to `wi-state.sh` next to them). |

Optional overrides:

| Variable | Meaning |
|---|---|
| `WIDASH_COLLECTION`, `WIDASH_PROJECT`, `WIDASH_TEAM`, `WIDASH_ASSIGNEE`, `WIDASH_TYPES` | Work-item query parameters. |
| `PRDASH_PREFETCH_DIR` | Where branch-prefetch markers are written (default `.prefetch/` next to the scripts). |
| `PRDASH_TIMING`, `PRDASH_TIMING_LOG` | Append phase timings of `review-pr.sh` to a log. |

## Troubleshooting

- **"Configuration does not exist"**: create the config file at the path
  printed, or run `install.sh`.
- **"No PAT available"**: add `pat:` to the matching account. The org URL is
  compared case-insensitively with the trailing slash ignored.
- **A PR won't open, "branch not found"**: the source branch was deleted, or
  `clones_dir` points at a different repository. Check the clone path in the
  error.
- **Comments show but the badge or counts look stale**: the thread poll runs
  once a minute; press `r` in the dashboard to refresh now.
- **Peek panes have no titles**: Neovim is older than 0.9. Everything else works.
- **Slow first open on a big repo**: the warm-all pass may still be running.
  The `⇣` badge shows which PRs are in progress; `◆` means ready.

## Development

```
dotnet build src/azure-cli.csproj      # data provider
dotnet test test/azure-cli-test.csproj # needs a .NET 6 runtime
```

Most files use CRLF line endings; edit them byte-wise. The Lua files can be
syntax-checked with `luajit -bl` on a CR-stripped copy and the scripts with
`bash -n`. Build outputs and `.prefetch/` are ignored by git.
