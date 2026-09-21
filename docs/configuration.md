# Configuration

_Part of the [azure-vicli](../README.md) docs._

## Configuration

The config file is `%APPDATA%\azure-cli.yml` on Windows and
`$XDG_CONFIG_HOME/azure-cli.yml` (default `~/.config/azure-cli.yml`) elsewhere.
Press `gO` in any dashboard to open it.

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
| `pat` | account | Personal access token. Required - there is no Azure AD sign-in. |
| `hide_ancient` | account | Drop PRs whose latest commit is older than `hide_ancient_days` (default 30 - see [setup() options](#setup-options) below, `setup({hide_ancient_days=...})`). |
| `clones_dir` | account | Directory holding one clone per repository, named after the repo. Repos are cloned here on demand when you open a PR. |
| `work_items` | account | Enables the [work-item screens](work-items.md#work-items) for this account: `org_url`/`project_name` become the work-item collection/project. Absent by default - no account's work items are queried until one account has this block. `team` (required) is a team under that project; `assignee` (optional) defaults to your own signed-in display name; `types` (optional, a YAML list or a plain comma-separated string) defaults to `User Story, Bug`; `states` (optional, a YAML list or a plain comma-separated string - see [Work items](work-items.md#work-items)) defaults to `[Active, New, Implemented, Resolved, Closed, Removed]`; `sprint_scope` (optional, `parent` or `all` - see [Work items](work-items.md#work-items)) defaults to `parent`. |

The config file is the only source of credentials. Ambient `AZURE_DEVOPS_EXT_PAT`
or `ADO_PAT` variables in your shell are never consulted.

Only one account's `work_items:` block is ever active: the first account in
`accounts:` that has one, unless `AZVICLI_WI_ACCOUNT` (see
[Environment variables](#environment-variables)) names a different account by
its `project_name`. With no account configured this way and no
`AZVICLI_WI_TEAM` override either, the work-item screens show a "no
`work_items:` block" message instead of a PR/work-item mix-up.

## setup() options

`require("azure-cli").setup(opts)` is always optional - every surface
applies the defaults below until it's called - and every option can be set
independently; leaving one out never resets another. `opts` is validated
immediately: an unknown `keys`/`timing` field, or a value of the wrong
type, raises an error at `setup()` time naming the field, rather than
failing silently or only surfacing later.

**Standalone launcher users** have no `init.lua` to call `setup()` from.
Put an `azure-cli.lua` next to your `azure-cli.yml` (same directory) that
returns the same table, and the launcher passes it to `setup()`.
`:AzureCli options` writes one with every option at its default so you can
edit from a complete list:

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
| `timing` | `{ poll_seconds = 60, hover_ms = 500, warm_concurrency = 4, cached_prs = 24, threads_ttl_seconds = 120, aged_days = 14 }` | `setup({timing={...}})` merges over these, field by field - a partial table leaves the rest at their default. `poll_seconds` drives both the PR dashboard's list poll and the reviewer's threads poll; `hover_ms` is the work-items dashboard's cursor-settle debounce before prefetching; `warm_concurrency` is how many PRs the dashboard's warm-all pass fetches at once; `cached_prs`/`threads_ttl_seconds` become `cache.lua`'s `M.MAX_PRS`/`M.THREADS_TTL`; `aged_days` is the PR dashboard's "aged" (dim) date threshold. No env override for any of these - `setup()` is the only way to change them. |
| `hide_ancient_days` | `30` | `setup({hide_ancient_days=...})` is exported to the provider as `AZVICLI_HIDE_ANCIENT_DAYS` (an ambient value already in the environment is left alone, same as `AZVICLI_PREFETCH_DIR`'s default below), read by an account's `hide_ancient: true` (see [Configuration](#configuration)) in place of a hard-coded 30. |
| `notifications` | `"float"` | `setup({notifications="notify"})` turns transient status messages (`lua/azure-cli/notify.lua`'s `M.flash` - "Opening PR…", "Comment posted.", "Refresh already in progress…", ...) into plain `vim.notify` calls instead of a floating window stack, for a setup where `vim.notify` is already handled by another plugin (e.g. nvim-notify) that should see these too. An error still also goes through `vim.notify` at `ERROR` level either way, so `:messages` never loses one. |
| `collapsed_sections` | `{ "SignedOff", "Drafts" }` | `setup({collapsed_sections={...}})` sets which PR dashboard sections (`"Mentions"`, `"Actionable"`, `"Waiting"`, `"SignedOff"`, `"Drafts"`, `"Created"`) start collapsed - see [Pull request dashboard](dashboard.md#pull-request-dashboard). Only seeds the very first render of the session; `za`/`zR`/`zM` then own it for the rest of the session (even across a W/P dashboard swap), same as the ignore-whitespace toggle does for the reviewer. No env override. |

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
| `AZVICLI_WI_ACCOUNT` | Selects which account's `work_items:` block backs the work-item screens, by `project_name`, when more than one account has one (default: the first account in `accounts:` that has one). |
| `AZVICLI_WI_COLLECTION`, `AZVICLI_WI_PROJECT`, `AZVICLI_WI_TEAM`, `AZVICLI_WI_ASSIGNEE`, `AZVICLI_WI_TYPES` | Override the selected account's `org_url`/`project_name`/`work_items:` fields (see [Configuration](#configuration)) one at a time, without editing azure-cli.yml. |
| `AZVICLI_PREFETCH_DIR` | Where branch-prefetch markers and the `.userid` cache are written. Default: the plugin sets this to Neovim's own cache directory (`stdpath("cache") .. "/azure-cli"`) for every provider call, so a plain `azure-cli.py` invocation with no Lua session around it (headless `--list`/`--print-pat`/...) falls back to the platform cache directory's own `azure-cli/` subfolder instead - `%LOCALAPPDATA%\azure-cli\cache` on Windows, `$XDG_CACHE_HOME/azure-cli` (default `~/.cache/azure-cli`) elsewhere. |
| `AZVICLI_CONFIG` | Overrides the config file path entirely (`~` expanded), ahead of the platform default - see [setup() options](#setup-options)' `config`, which sets this. The `--serve` daemon re-reads it on every request (`Config.path()`), so a changed value takes effect on the daemon's next request without a restart, the same as an edited `azure-cli.yml`. |
| `AZVICLI_HIDE_ANCIENT_DAYS` | The `hide_ancient: true` threshold, in days (default 30) - see [setup() options](#setup-options)' `hide_ancient_days`, which sets this. |
| `AZVICLI_TOASTS` | Set to `0` to disable desktop toast notifications (also toggleable per-session with `gN`). |
| `AZVICLI_NO_DAEMON` | Set to `1` to disable the `azure-cli.py --serve` daemon for this session: every provider call (`rpc.lua`'s `M.run`) always falls back to a plain one-shot `vim.fn.jobstart`. Useful to rule the daemon in or out while debugging a provider call. |
| `AZVICLI_DEBUG` | Set to `1` to have a failed `azure-cli.py` action print its full python traceback on stderr, after the one-line `azure-cli <flag> failed: <message>` summary it always prints. Unset (or `0`), only that one line goes out - the Lua side records the full text either way (`lua/azure-cli/log.lua`) and shows it with [`:AzureCli log`](commands-and-keys.md#commands) regardless of this variable; it only affects what reaches a terminal running the provider directly. |
