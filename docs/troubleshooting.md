# Troubleshooting

_Part of the [azure-vicli](../README.md) docs._

## Troubleshooting

- **Start here**: `:AzureCli doctor` (or `:checkhealth azure-cli`, or
  `./azure-cli --doctor` from a terminal) checks the Neovim version,
  python, git, the config file, its fields, a sign-in to every configured
  organization and the work-items block, and says what to fix for each
  line that fails. A failed dashboard load names the config file and the
  commands that get at it.

- **Where do errors go?**: every provider failure shows a short one-line
  summary (a transient float, or a "Failed to ..." line in a buffer) instead
  of a raw stderr blob - `:AzureCli log` (`lua/azure-cli/log.lua`) has the
  full text of every one from this session, oldest first; a summary line
  always ends with `(:AzureCli log)` as a reminder. Set `AZVICLI_DEBUG=1`
  (see [Environment variables](configuration.md#environment-variables)) to also have
  `azure-cli.py` print a full traceback when run directly from a terminal.
- **"Configuration does not exist"**: open the dashboard (`./azure-cli` or
  `:AzureCli`) - it writes a template at the path printed and opens it - or
  run `azure-cli --init-config` from a terminal.
- **"pat_file ... is readable by other users"** (from `:AzureCli doctor`):
  `chmod 600` the file - it holds your token.
- **"No PAT available" / "no configured PAT"**: add `pat:` (or `pat_file:`) to the matching
  account. The org URL is compared case-insensitively with the trailing
  slash ignored. Every account needs one - there is no Azure AD sign-in.
- **A PR won't open, "branch not found"**: the source branch was deleted, or
  `clones_dir` points at a different repository. Check the clone path in the
  error.
- **Comments show but the badge or counts look stale**: the thread poll runs
  once a minute; press `r` in the dashboard to refresh now.
- **Peek panes have no titles**: Neovim is older than 0.9. Everything else works.
- **Slow first open on a big repo**: the warm-all pass may still be running.
  The `⇣` badge shows which PRs are in progress; `◆` means ready.
- **Is the daemon actually running?**: `:AzureCli status` prints it (or, from
  a standalone session or any other Lua context,
  `:lua print(vim.inspect(require("azure-cli.rpc").status()))`) - `rpc.lua`'s
  `M.status()` returns `{ running, fallback, pid }`. `:AzureCli status`
  (`init.lua`'s own `M.status()`) also prints and returns the currently
  resolved `python` interpreter and `config` file path, so a `setup({python=
  ..., config=...})` mismatch is visible the same way. A provider action
  that's noticeably slower than usual, or a `pid` that keeps changing between
  calls, usually means it crashed and is being restarted (see
  `rpc.lua`'s own header comment for the one-retry-then-30s-cooldown
  rule) - check the account/PAT config is still valid, since a config the
  daemon can no longer parse fails every request the same way a one-shot
  call would. Setting `AZVICLI_NO_DAEMON=1` rules the daemon in or out of a
  problem entirely (every provider call runs as its own one-shot process
  instead).
- **A provider action seems to use a stale `azure-cli.yml`**: the daemon
  reads the config file once, when it starts, and never reloads it. An
  edit (through `gO` or any other editor), a rotated `pat_file` or a
  changed `setup({config=...})` takes effect after you restart Neovim,
  not before. If `gO` doesn't open
  the file you expected, check `:AzureCli status`'s `config` line and
  `AZVICLI_CONFIG` (see [setup() options](configuration.md#setup-options)/[Environment
  variables](configuration.md#environment-variables)) - a `setup({config=...})` call
  overrides the config path outright.
- **Where are prefetch markers/the `.userid` cache?**: under
  `AZVICLI_PREFETCH_DIR` (see [Environment variables](configuration.md#environment-variables))
  - Neovim's own cache directory's `azure-cli/` subfolder by default (a
  plain `stdpath("cache")`, printable with `:lua print(vim.fn.stdpath("cache"))`),
  or the platform cache directory's `azure-cli/` subfolder for a headless
  `azure-cli.py` call with no Lua session around it. Deleting this directory
  is always safe - everything in it is a cache, rebuilt on demand.
