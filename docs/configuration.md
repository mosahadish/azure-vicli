# Configuration

_Part of the [azure-vicli](../README.md) docs._

An agent can do this for you: open it in the azure-vicli folder and ask it
to "configure azure-vicli" - [the configure-azure-vicli skill](../.github/skills/configure-azure-vicli/SKILL.md)
walks it through these files, before azure-vicli has ever run.

## Configuration

The config file is `%APPDATA%\azure-cli.yml` on Windows and
`$XDG_CONFIG_HOME/azure-cli.yml` (default `~/.config/azure-cli.yml`) elsewhere.
You don't create it by hand: the first `./azure-cli` or `:AzureCli` with no
file there writes the template below (with `TODO` placeholders) and opens it;
saving it opens the dashboard. `azure-cli --init-config` does the same from
a terminal. Later, `gO` on any screen asks which file to open: the
accounts (`azure-cli.yml`) or the options (`azure-cli.lua` next to it - see
[setup() options](#setup-options) - or, in your own Neovim, a pointer to
your `setup()` call). `:AzureCli status` prints where both are.

```yaml
accounts:
  - project_name: MyProject
    org_url: https://dev.azure.com/my-org        # or an on-prem collection URL
    pat: <personal access token>
    hide_ancient: true                            # hide PRs with no commit in hide_ancient_days (default 30)
    clones_dir: C:\Users\me\source\repos          # where repos are (or get) cloned
    work_items:                                   # optional - enables the work-item screens
      team: My Team                               # required to enable them
      assignee: Doe, Jane                         # optional; default = your signed-in display name
      types: [User Story, Bug]                    # optional; default: User Story, Bug
      states: [Active, New, Implemented, Resolved, Closed, Removed]  # optional; see below for the default
      sprint_scope: parent                        # optional; parent (default) or all
```

| Field | Scope | Meaning |
|---|---|---|
| `repo_path` | top level | Optional. A single clone to use when an account has no `clones_dir`. Prefer `clones_dir`. |
| `project_name` | account | The Azure DevOps project. |
| `org_url` | account | Organization or collection URL. Several accounts may share one. |
| `pat` | account | Personal access token. Required (or `pat_file`) - there is no Azure AD sign-in. |
| `pat_file` | account | Instead of `pat`: the path of a file holding nothing but the token (`~` expands). Keeps the secret out of a config you might commit; `chmod 600` it and keep it outside any git checkout - `:AzureCli doctor` flags a file other users can read, and one inside the plugin folder or any git working tree (a dotfiles repo, say). |
| `hide_ancient` | account | Drop PRs whose latest commit is older than `hide_ancient_days` (default 30 - see [setup() options](#setup-options) below, `setup({hide_ancient_days=...})`). Off when absent. |
| `clones_dir` | account | Directory holding one clone per repository, named after the repo. Repos are cloned here on demand when you open a PR. |
| `work_items` | account | Enables the [work-item screens](work-items.md#work-items) for this account: `org_url`/`project_name` become the work-item collection/project. Absent by default - no account's work items are queried until one account has this block. `team` (required) is a team under that project; `assignee` (optional) defaults to your own signed-in display name; `types` (optional, a YAML list or a plain comma-separated string) defaults to `User Story, Bug`; `states` (optional, a YAML list or a plain comma-separated string - see [Work items](work-items.md#work-items)) defaults to `[Active, New, Implemented, Resolved, Closed, Removed]` (with `In Progress` ranked as `Active`); `sprint_scope` (optional, `parent` or `all` - see [Work items](work-items.md#work-items)) defaults to `parent`. |

The config file is the only source of credentials. Ambient `AZURE_DEVOPS_EXT_PAT`
or `ADO_PAT` variables in your shell are never consulted.

Only one account's `work_items:` block is ever active: the first account in
`accounts:` that has one, unless `AZVICLI_WI_ACCOUNT` (see
[Environment variables](#environment-variables)) names a different account by
its `project_name`. With no account configured this way and no
`AZVICLI_WI_TEAM` override either, the work-item screens show a "no
`work_items:` block" message instead of a PR/work-item mix-up.

### GitHub accounts

An account with `host: github` lists GitHub pull requests on the same
dashboard, beside the Azure DevOps ones:

```yaml
accounts:
  - host: github
    owner: my-org                # optional: only this user's or organization's repositories
    clones_dir: ~/src
    # api_url: https://ghe.example.com/api/v3   # GitHub Enterprise Server (default: github.com)
    # pat_file: ~/.config/azure-cli/gh-token    # optional: without one, `gh auth token` is used
    # issues: { project: 3 }                    # optional: the Issues tab (I) on this Projects v2 project
```

| Field | Meaning |
|---|---|
| `host` | `github` (an account without it is Azure DevOps). |
| `owner` | Optional. Limit the account to one user's or organization's repositories; without it, every PR you're asked to review, have reviewed or opened, anywhere. |
| `api_url` | Optional. The REST root of a GitHub Enterprise Server (`https://<host>/api/v3`); default `https://api.github.com`. |
| `pat` / `pat_file` | Optional. A token with the `repo` scope (and `project` for `issues:`); in `setup()` only `pat_file` is accepted, as for an Azure account. Without one, the provider asks the GitHub CLI (`gh auth token`, for the account's host) - so after `gh auth login` nothing else is needed. It asks once per session: after a new `gh auth login`, restart Neovim. |
| `clones_dir`, `hide_ancient` | As for an Azure account. |
| `issues` | Optional. Turns on the [Issues tab](work-items.md#issues-github) (`I`) for a GitHub Projects v2 project; see below. |

**Without GraphQL.** azure-vicli talks to GitHub through its GraphQL API.
Where that's refused - a proxy that lets only REST through (a Claude Code
cloud session's does), or an Enterprise Server with GraphQL turned off - the
first refusal switches that account to the REST API for the rest of the
session, by itself (`AZVICLI_GITHUB_REST=1` starts there). The PR list, the
reviewer, comments, reviews (`gS`), votes, reviewers, the description and
merging all work; what's different:

- If GitHub's search is refused too, the list is the open PRs of the
  repositories cloned in `clones_dir` (under `owner:` when it's set), or of
  the ones `AZVICLI_GITHUB_REPOS` names (`owner/name`, comma-separated).
- Whether a conversation is resolved, resolving one, and auto-merge exist
  only in GraphQL. A proxy that offers them (Claude Code's does) is used;
  without one every conversation shows as active, and resolving or
  auto-merge says it needs GraphQL.
- The merge dialog can't tell which checks are required, and a PR's issues
  (`gW`) are only its body's `Closes #n` lines.
- The Issues tab (`issues:`) still needs GraphQL.
- More requests: each PR is a few REST calls, kept until the PR changes.

`project_name`, `org_url` and `work_items` don't apply (`work_items:` on a
GitHub account is an error). `:AzureCli doctor` checks the sign-in, and
with `issues:` that the project can be read.

**`issues:`** shows the issues in one of the owner's Projects v2 projects
(yours, when the account has no `owner:`) on
the work-items screens, as a tab of their own (`I`), next to the Azure work
items (`W`):

```yaml
    issues:
      project: 3          # the project's number (from its URL) or its title
      repo: gizmos        # optional: where `n` creates issues
      scope: all          # optional: mine (default) or all
```

| Field | Meaning |
|---|---|
| `project` | Required. The project, by its number (`github.com/orgs/<owner>/projects/<number>`) or its title. |
| `repo` | Optional. The repository new issues go into, as `name` (under the owner) or `owner/name`. It defaults to the project's only linked repository; with several linked and none set, `n` says to set it. |
| `scope` | Optional. `mine` (default) lists the issues assigned to you (or to `AZVICLI_WI_ASSIGNEE` when it's set) in each iteration; `all` lists everyone's. Anything else is an error. |

The short form `issues: { project: 3 }` works too, and `issues:` goes in
`setup({ accounts = ... })` the same way. On an Azure account it's an error.
Reading and changing a project needs the token's `project` scope; with the
GitHub CLI, add it with `gh auth refresh -s project`. Without a GitHub
account that has `issues:`, there's no `I` key and no Issues tab. With
several, the Issues tab uses the first, unless `AZVICLI_WI_ACCOUNT` names
another by its `owner`.

On the dashboard a GitHub PR sits in the same sections, and the reviewer
reviews, comments on and merges it as it does an Azure DevOps one; the
agent's tools work on it too. What differs - verdicts instead of votes,
resolving instead of thread statuses, the repository's merge types and
checks - is in [Pull request dashboard](dashboard.md#github-pull-requests)
and [Reviewer](reviewer.md#on-github). Re-queuing (`gr`) re-runs the failed
jobs of the head commit's failed GitHub Actions runs, and the agent's build
log and test results read those jobs' logs and failure annotations.

### Accounts in setup() instead of a file (plugin)

A plugin install doesn't need `azure-cli.yml` at all: pass the same
accounts to `setup()`, with the same field names, and no file is read or
written (the [first-run template](#configuration) only appears when neither
is configured). The token comes from a `pat_file`, so `init.lua` holds no
secret and can live in a dotfiles repo:

```lua
require("azure-cli").setup({
  accounts = {
    {
      project_name = "MyProject",
      org_url = "https://dev.azure.com/my-org",
      pat_file = "~/.config/azure-cli/pat",   -- a file holding just the token (chmod 600)
      clones_dir = "~/src",
      -- hide_ancient = true,
      -- work_items = { team = "My Team", types = { "User Story", "Bug" } },
    },
    {
      host = "github",
      owner = "my-org",                         -- optional
      clones_dir = "~/src",
      -- pat_file = "~/.config/azure-cli/gh-token",   -- optional: without one, `gh auth token` is used
      -- issues = { project = 3 },                    -- optional: the Issues tab (I)
    },
  },
})
```

`setup()` validates the table up front (a missing field, a missing
`pat_file` on an Azure account, a `pat` anywhere, an unknown key) and hands it to the provider, which
prefers it over `azure-cli.yml` outright. `gO` then says so instead of
opening the file, and `:AzureCli status`/`:AzureCli doctor` report
"setup({accounts=...})" as the source. The standalone launcher has no
`init.lua`, so it keeps using the file (its `azure-cli.lua` options file
may carry `accounts` too, if you'd rather).

## setup() options

`require("azure-cli").setup(opts)` is always optional - every surface
applies the defaults below until it's called - and every option can be set
independently; leaving one out never resets another. `opts` is validated
immediately: an unknown `keys`/`timing` field, or a value of the wrong
type, raises an error at `setup()` time naming the field, rather than
failing silently or only surfacing later. (`azure-cli.yml` isn't checked
that strictly: an account field it doesn't know - a misspelt `pat_file`, or
a `token:` that doesn't exist - is ignored, so check the names against the
tables above.)

**Standalone launcher users** have no `init.lua` to call `setup()` from.
Put an `azure-cli.lua` next to your `azure-cli.yml` (same directory) that
returns the same table, and the launcher passes it to `setup()`.
`:AzureCli options` (or `gO` -> Options) writes one with every option at
its default so you can edit from a complete list. In your own Neovim the
same command shows that list in a scratch buffer to copy from instead -
the plugin never reads `azure-cli.lua`:

```lua
-- %APPDATA%\azure-cli.lua  (or ~/.config/azure-cli.lua)
return {
  keys = {
    diff = { next_hunk = "]h", prev_hunk = "[h" },
    dashboard = { vote = false },  -- unbind
  },
  timing = { poll_seconds = 120 },
}
```

| Option | Default | Precedence |
|---|---|---|
| `keys` | see [Keys](commands-and-keys.md#keys) above | `setup({keys=...})` merges over the per-surface defaults, action by action; `false` unbinds an action, a list binds several keys to it. No env override - see [Keys](commands-and-keys.md#keys) for the full shape (`prefix`, unbind, multi-key). |
| `python` | probed: `python3` if it's on `PATH`, else `python` | `AZVICLI_PY` (an ambient env var, if already set before Neovim starts) > `setup({python=...})` > the probe. |
| `config` | the platform default - `%APPDATA%\azure-cli.yml` on Windows, `$XDG_CONFIG_HOME/azure-cli.yml` (default `~/.config/azure-cli.yml`) elsewhere | `setup({config="~/x.yml"})` sets `AZVICLI_CONFIG` outright (an ambient value some other tool already exported is overwritten, not deferred to - calling `setup({config=...})` at all is itself the explicit override). `~` is expanded by whoever reads it (`Config.path()` on the provider side, `config.lua`'s own `M.config_path()` for `gO`/`:AzureCli status`). |
| `timing` | `{ poll_seconds = 30, hover_ms = 500, warm_concurrency = 4, cached_prs = 24, threads_ttl_seconds = 120, aged_days = 14, idle_after = 300, max_poll_seconds = 300 }` | `setup({timing={...}})` merges over these, field by field - a partial table leaves the rest at their default. `poll_seconds` drives the PR dashboard's list poll, the reviewer's threads poll and the work-items / Issues boards' poll; while you're away - Neovim unfocused, or no key for `idle_after` seconds - those polls and the chat's watched-PR poll (`chat.watch_seconds`) double their interval each tick, up to `max_poll_seconds` (never faster than their own base, never stopped; `max_poll_seconds = poll_seconds` turns this off), and on your return (focus, or the first key) the ones that are due refresh once at once and go back to their base. Unfocused needs the terminal to send focus events (tmux: `set -g focus-events on`); idle works without them. Agents, the Agents screen and the [phone dashboard](chat.md#phone-dashboard) keep their pace while you're away - they make no requests; `hover_ms` is the work-items dashboard's cursor-settle debounce before prefetching; `warm_concurrency` is how many PRs the dashboard's warm-all pass fetches at once; `cached_prs`/`threads_ttl_seconds` become `cache.lua`'s `M.MAX_PRS`/`M.THREADS_TTL`; `aged_days` is the PR dashboard's "aged" (dim) date threshold. No env override for any of these - `setup()` is the only way to change them. |
| `hide_ancient_days` | `30` | `setup({hide_ancient_days=...})` is exported to the provider as `AZVICLI_HIDE_ANCIENT_DAYS` (an ambient value already in the environment is left alone, same as `AZVICLI_PREFETCH_DIR`'s default below), read by an account's `hide_ancient: true` (see [Configuration](#configuration)) in place of a hard-coded 30. |
| `row_numbers` | `"relative"` | Row numbers inside the PR and work-items dashboards' boxes, just inside the left border. `"relative"` numbers each row by its distance from the cursor, so `5j` / `5k` jumps straight to it (the cursor row shows its own line number); `"absolute"` shows plain line numbers (`:12` jumps there); `false` hides them. |
| `notifications` | `"float"` | `setup({notifications="notify"})` turns transient status messages (`lua/azure-cli/notify.lua`'s `M.flash` - "Opening PR…", "Comment posted.", "Refresh already in progress…", ...) into plain `vim.notify` calls instead of a floating window stack, for a setup where `vim.notify` is already handled by another plugin (e.g. nvim-notify) that should see these too. An error still also goes through `vim.notify` at `ERROR` level either way, so `:messages` never loses one. |
| `chat` | `{ position = "right", size = 0.35, input_height = 3 }`, no agent | The chat panel (`i`): where it sits and the agent it talks to - see [Chat](chat.md#setting-it-up). Validated at `setup()` time. Among its options: an agent's `idle_timeout_seconds` (600), `max_turn_seconds` (7200) and `interrupt_grace_seconds` (5) ([Fields](chat.md#fields)), `plan_revisions` (3, [Plans](chat.md#plans-and-asking-why)) and `max_agents` (3, [Several agents](chat.md#several-agents-at-once)). |
| `ui` | `{ border = "rounded", palette = "colorscheme", key_hints = "auto", confirm = "popup" }` | The shared look: `confirm` is how azure-vicli asks: `"popup"` puts yes/no questions (an agent's tool call, approving a plan, deleting a comment, re-queuing a build, ...) and short menus (a vote, a thread's status, a priority - up to 7 entries, numbered) in a popup in the middle of the screen, with any details above it. A yes/no question is answered Yes or Cancel, Yes focused; only the agent's own questions differ (Allow / Deny, Deny focused). Longer lists (assignees, earlier conversations, the `g.` palette) stay `vim.ui.select`. `"select"` sends everything through `vim.ui.select`, so Telescope, fzf-lua or dressing.nvim draw it all. `key_hints` is the float `g` and a pause put up, listing the screen's `g` keys ([Keys](commands-and-keys.md#keys)) - `"auto"` shows it unless which-key or mini.clue is installed (they list the same keys themselves), `true` always, `false` never. `palette = "azure-vicli"` uses the standalone launcher's own dark colours (`lua/azure-cli/palette.lua`) instead of your colorscheme's, set again after every `:colorscheme` (your tab line and status lines stay yours). `border` is every popup's border (`"rounded"`, `"single"`, `"double"`, `"bold"`, `"solid"`, `"shadow"`, `"none"`, or a list of border characters). The colours of the winbars, popups, the plan window and the questions under a line are highlight groups linked to your colorscheme's (`AzureCliWinbar*`, `AzureCliFloat*`, `AzureCliSection`, `AzureCliStatus*`, `AzureCliThread*` - `:hi` restyles them). The standalone launcher also names its tabs and status lines after the screens; in your own Neovim that's `vim.o.tabline = "%!v:lua.require'azure-cli.ui'.tabline()"` (and `.statusline()`). |
| `dashboard_web` | `{ enabled = false, bind = "127.0.0.1", port = 8797, persist_token = true }` | The [phone dashboard](chat.md#phone-dashboard) (`:AzureCli web start`). `enabled` lets it start (it never starts by itself); `bind` is the one address it listens on - set it to this machine's LAN or VPN (e.g. Tailscale) address to reach it from a phone; `0.0.0.0` / `::` (every interface) are refused. `port` `0` takes any free port. `persist_token` keeps the token in `stdpath("state")/azure-cli/web-token` (mode `0600`) so the URL survives restarts until `:AzureCli web rotate`; `false` makes a new one every start. Validated at `setup()` time. |
| `images` | `{ inline = true }` | [Images](reviewer.md#images) in a PR's description and comments. `<CR>`/`gx` always opens one; `inline` also draws them under their line in the Overview (the first 10, up to 15 rows each) when snacks.nvim's image module or image.nvim is installed and the terminal can draw images. `false` keeps just `<CR>`/`gx`. Validated at `setup()` time. |
| `collapsed_sections` | `{ "SignedOff", "Drafts" }` | `setup({collapsed_sections={...}})` sets which PR dashboard sections (`"Mentions"`, `"Actionable"`, `"Waiting"`, `"SignedOff"`, `"Drafts"`, `"Created"`) start collapsed - see [Pull request dashboard](dashboard.md#pull-request-dashboard). Only seeds the very first render of the session; `za`/`zR`/`zM` then own it for the rest of the session (even across W/P switches between the dashboards), same as the ignore-whitespace toggle does for the reviewer. No env override. |

`:AzureCli status` shows the currently resolved python interpreter and
config file path, so a mismatch between what you expected `setup()` to do
and what's actually in effect is visible without re-reading your `setup()`
call or checking `AZVICLI_*` env vars by hand.

## Environment variables

Set by the standalone launcher when it starts Neovim; only needed when starting Neovim by hand.

| Variable | Meaning |
|---|---|
| `AZVICLI_EXE` | Path to the `azure-cli` launcher script. |
| `AZVICLI_PY` | The python interpreter (`sys.executable`) every surface's `config.lua`-derived `provider_cmd()` re-invokes `azure-cli.py` with, for every PR action, work-item action and prefetch job. |
| `AZVICLI_PROVIDER` | Absolute path to `azure-cli.py`, run as `$AZVICLI_PY $AZVICLI_PROVIDER <subcommand> ...` - see `lua/azure-cli/config.lua`'s `provider_cmd()`, which `EXT.provider` (review/init.lua) and every other surface call instead of resolving this themselves. |
| `AZVICLI_REPO_PATH` | A single clone path, used when the account has no `clones_dir` (the same thing as `repo_path` in the config file). |

Optional overrides:

| Variable | Meaning |
|---|---|
| `AZVICLI_WI_ACCOUNT` | Selects which account's `work_items:` block backs the work-item screens, by `project_name`, when more than one account has one (default: the first account in `accounts:` that has one). For the Issues tab it names a GitHub account's `issues:` by its `owner`. |
| `AZVICLI_WI_COLLECTION`, `AZVICLI_WI_PROJECT`, `AZVICLI_WI_TEAM`, `AZVICLI_WI_ASSIGNEE`, `AZVICLI_WI_TYPES` | Override the selected account's `org_url`/`project_name`/`work_items:` fields (see [Configuration](#configuration)) one at a time, without editing azure-cli.yml. |
| `AZVICLI_PREFETCH_DIR` | Where branch-prefetch markers and the `.userid` cache are written. Default: the plugin sets this to Neovim's own cache directory (`stdpath("cache") .. "/azure-cli"`) for every provider call, so a plain `azure-cli.py` invocation with no Lua session around it (headless `--list`/`--print-pat`/...) falls back to the platform cache directory's own `azure-cli/` subfolder instead - `%LOCALAPPDATA%\azure-cli\cache` on Windows, `$XDG_CACHE_HOME/azure-cli` (default `~/.cache/azure-cli`) elsewhere. |
| `AZVICLI_CONFIG` | Overrides the config file path entirely (`~` expanded), ahead of the platform default - see [setup() options](#setup-options)' `config`, which sets this. The `--serve` daemon reads it once, at start-up: a changed value takes effect after a Neovim restart. |
| `AZVICLI_HIDE_ANCIENT_DAYS` | The `hide_ancient: true` threshold, in days (default 30) - see [setup() options](#setup-options)' `hide_ancient_days`, which sets this. |
| `AZVICLI_TOASTS` | Set to `0` to disable desktop toast notifications (also toggleable per-session with `gN`). |
| `AZVICLI_NO_DAEMON` | Set to `1` to disable the `azure-cli.py --serve` daemon for this session: every provider call (`rpc.lua`'s `M.run`) always falls back to a plain one-shot `vim.fn.jobstart`. Useful to rule the daemon in or out while debugging a provider call. |
| `AZVICLI_NO_POOL` | Set to `1` to have `azure-cli.py` open a new connection for every HTTP request (plain urllib), instead of keeping idle connections to each host open and reusing them. Proxies (`HTTPS_PROXY`, `NO_PROXY`, system settings) are honoured either way; this is the switch to try when a corporate proxy in front of an on-prem TFS misbehaves with kept-alive connections. Read once at start-up, so the `--serve` daemon picks a change up after a Neovim restart. |
| `AZVICLI_DEBUG` | Set to `1` to have a failed `azure-cli.py` action print its full python traceback on stderr, after the one-line `azure-cli <flag> failed: <message>` summary it always prints. Unset (or `0`), only that one line goes out - the Lua side records the full text either way (`lua/azure-cli/log.lua`) and shows it with [`:AzureCli log`](commands-and-keys.md#commands) regardless of this variable; it only affects what reaches a terminal running the provider directly. It also turns on the perf log: one line per provider HTTP request and one total per command in `perf.log` in the plugin's cache dir (never headers, PATs or tokens), summarised by [`:AzureCli perf`](commands-and-keys.md#commands) - see [Troubleshooting](troubleshooting.md#troubleshooting). |
