# Commands and keys

_Part of the [azure-vicli](../README.md) docs._

## Commands

Installed as a plugin, everything goes through one user command:

| Command | Effect |
|---|---|
| `:AzureCli` / `:AzureCli dashboard` | Open the [pull request dashboard](dashboard.md#pull-request-dashboard), in a new tab. |
| `:AzureCli review <id>` | Open the [reviewer](reviewer.md#reviewer) for pull request `<id>` directly, in a new tab - looked up in the dashboard's own cached list, so open the dashboard at least once first this session. |
| `:AzureCli workitems` | Open the [work-items dashboard](work-items.md#work-items), in a new tab. |
| `:AzureCli doctor` | Check the setup and show the result in a float: Neovim version, python, git, the config file, its fields, a sign-in to every configured organization, and the work-items block - each line says what to fix. `:checkhealth azure-cli` runs the same checks through Neovim's health UI, and `./azure-cli --doctor` from a terminal. |
| `:AzureCli toasts` | Toggle [desktop notifications](dashboard.md#desktop-notifications) for the rest of this session - the same switch the dashboard's own `gN` key flips. |
| `:AzureCli status` | Show the [provider daemon's](development.md#architecture) status, plus the resolved python interpreter and config file path (see [setup() options](configuration.md#setup-options)). |
| `:AzureCli log` | Open this session's error log (`lua/azure-cli/log.lua`) in a scratch split - every provider failure's full text, oldest first; `q` closes it. See [Troubleshooting](troubleshooting.md#troubleshooting). |
| `:AzureCli options` | Create `azure-cli.lua` next to `azure-cli.yml` with every `setup()` option at its default (generated from the code, so it can't drift), or open it if it already exists. The standalone launcher loads that file; plugin users can copy its contents into their own `setup()` call. |
| `:AzureCli help` | List these. |

Tab-completion works on the subcommand. The standalone launcher (`azure-cli`/
`azure-cli.cmd`) doesn't use this command at all - it opens the dashboard
directly, in the current window, the same way it always has (see
[Running](../README.md#running) and standalone/init.lua in the
[Architecture](development.md#architecture) table).

## Keys

Every key in every table in these docs is a *default* - `setup()`'s `keys`
option remaps or unbinds any of them, per **surface** (`dashboard`, `list`,
`diff`, `overview`, `nav`, `workitems`, `workitem_view` - roughly, one per
screen this tool shows) and **action** (a stable name for what the key
does, independent of which key it's bound to):

```lua
require("azure-cli").setup({
  keys = {
    diff = {
      next_hunk = "]h",   -- rebind: ]c is vim's own "next diff hunk" outside this tool
      status = false,     -- unbind entirely
    },
    dashboard = {
      vote = { "gv", "V" },  -- a list binds every key in it to the same action
    },
    prefix = {
      dashboard = "<leader>a",  -- prepended to every dashboard key above
    },
  },
})
```

An unknown surface or action name in `keys` raises an error immediately
(naming which one), rather than silently doing nothing. `setup()` is
optional; every surface applies the defaults below until it's called.
Nothing about the *behaviour* behind an action changes - only which key (if
any) triggers it - and `j`/`k`/native Neovim motions are never remapped by
this tool, so they aren't part of this table.

The tables below are generated from `lua/azure-cli/config.lua`'s own
defaults by `tests/gen-keys-table.lua` (`luajit tests/gen-keys-table.lua`),
so they can't drift from what the plugin actually binds; re-run it and
paste the output here after changing a default.

<!-- BEGIN GENERATED KEYS TABLE (tests/gen-keys-table.lua) -->
#### dashboard

| Action | Default key(s) |
|---|---|
| `auto_complete` | `ga` |
| `browser` | `o` |
| `collapse_all` | `zM` |
| `complete` | `gm` |
| `config` | `gO` |
| `copy_link` | `gy` |
| `description` | `gd` |
| `expand_all` | `zR` |
| `filter` | `/` |
| `first_pr` | `gg` |
| `help` | `?` |
| `last_pr` | `G` |
| `open` | `<CR>` |
| `open_build` | `gb` |
| `quit` | `q` |
| `refresh` | `r` |
| `requeue_build` | `gr` |
| `toasts` | `gN` |
| `toggle_section` | `za` |
| `vote` | `gv` |
| `workitems` | `W` |

#### list

| Action | Default key(s) |
|---|---|
| `active_filter` | `gA` |
| `back` | `<BS>` |
| `batch_queue` | `gQ` |
| `batch_submit` | `gS` |
| `batch_toggle` | `gB` |
| `comment_file` | `C` |
| `commits` | `gc` |
| `complete` | `gm` |
| `config` | `gO` |
| `filters` | `gF` |
| `followup` | `gu` |
| `help` | `?` |
| `ignore_ws` | `gw` |
| `next_file_with_comments` | `]C` |
| `next_unviewed` | `]m` |
| `open` | `<CR>` |
| `pr_comment` | `gC` |
| `prev_file_with_comments` | `[C` |
| `prev_unviewed` | `[m` |
| `quit` | `q` |
| `resize_less` | `<` |
| `resize_more` | `>` |
| `search` | `g/` |
| `since` | `gi` |
| `toggle_viewed` | `m` |
| `vote` | `gv` |

#### diff

| Action | Default key(s) |
|---|---|
| `active_filter` | `gA` |
| `back` | `<BS>` |
| `batch_queue` | `gQ` |
| `batch_submit` | `gS` |
| `batch_toggle` | `gB` |
| `comment` | `c` |
| `comment_file` | `C` |
| `comment_range` | `c` |
| `commits` | `gc` |
| `complete` | `gm` |
| `config` | `gO` |
| `expand_thread` | `<Tab>` |
| `filters` | `gF` |
| `find_references` | `gr` |
| `followup` | `gu` |
| `goto_definition` | `gd` |
| `help` | `?` |
| `ignore_ws` | `gw` |
| `next_comment` | `]C` |
| `next_hunk` | `]c` |
| `next_unviewed` | `]m` |
| `open_file` | `gf` |
| `prev_comment` | `[C` |
| `prev_hunk` | `[c` |
| `prev_unviewed` | `[m` |
| `quit` | `q` |
| `reply` | `R` |
| `resize_less` | `<` |
| `resize_more` | `>` |
| `search` | `g/` |
| `since` | `gi` |
| `status` | `s` |
| `toggle_viewed` | `m` |
| `view_comments` | `K` |
| `vote` | `gv` |

#### overview

| Action | Default key(s) |
|---|---|
| `active_filter` | `gA` |
| `back` | `<BS>` |
| `batch_queue` | `gQ` |
| `batch_submit` | `gS` |
| `batch_toggle` | `gB` |
| `comment` | `c` |
| `complete` | `gm` |
| `config` | `gO` |
| `delete_comment` | `dd` |
| `edit_comment` | `e` |
| `filters` | `gF` |
| `followup` | `gu` |
| `help` | `?` |
| `ignore_ws` | `gw` |
| `next_comment` | `]C` |
| `open_commit` | `<CR>` |
| `prev_comment` | `[C` |
| `quit` | `q` |
| `reply` | `R` |
| `resize_less` | `<` |
| `resize_more` | `>` |
| `search` | `g/` |
| `since` | `gi` |
| `status` | `s` |
| `vote` | `gv` |

#### nav

| Action | Default key(s) |
|---|---|
| `back` | `<BS>` |
| `back_to_diff` | `q` |
| `config` | `gO` |
| `find_references` | `gr` |
| `goto_definition` | `gd` |
| `help` | `?` |
| `resize_less` | `<` |
| `resize_more` | `>` |
| `search` | `g/` |

#### workitems

| Action | Default key(s) |
|---|---|
| `assign` | `ga` |
| `browser` | `o` |
| `click` | `<LeftMouse>` |
| `config` | `gO` |
| `copy_link` | `gy` |
| `edit_title` | `ge` |
| `filter` | `/` |
| `goto_sprint_n` | `gt` |
| `help` | `?` |
| `link_pr` | `gl` |
| `move_sprint` | `gi` |
| `new` | `n` |
| `next_sprint` | `]` / `<Tab>` |
| `open` | `<CR>` |
| `pr_list` | `P` |
| `prev_sprint` | `[` / `<S-Tab>` |
| `priority` | `gp` |
| `quit` | `q` |
| `refresh` | `r` |
| `state` | `gs` |
| `unlink_pr` | `gL` |

#### workitem_view

| Action | Default key(s) |
|---|---|
| `assign` | `ga` |
| `back` | `<BS>` |
| `browser` | `o` |
| `comment` | `gc` |
| `copy_link` | `gy` |
| `edit_title` | `ge` |
| `help` | `?` |
| `link_pr` | `gl` |
| `move_sprint` | `gi` |
| `open` | `<CR>` |
| `priority` | `gp` |
| `quit` | `q` |
| `refresh` | `r` |
| `state` | `gs` |
| `unlink_pr` | `gL` |
<!-- END GENERATED KEYS TABLE -->
