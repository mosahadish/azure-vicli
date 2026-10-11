# Commands and keys

_Part of the [azure-vicli](../README.md) docs._

## Commands

Installed as a plugin, everything goes through one user command:

| Command | Effect |
|---|---|
| `:AzureCli` / `:AzureCli dashboard` | Open the [pull request dashboard](dashboard.md#pull-request-dashboard), in a new tab. |
| `:AzureCli review <id>` | Open the [reviewer](reviewer.md#reviewer) for pull request `<id>` directly, in a new tab - looked up in the dashboard's own cached list, so open the dashboard at least once first this session. |
| `:AzureCli workitems` | Open the [work-items dashboard](work-items.md#work-items), in a new tab. |
| `:AzureCli chat` | Show or hide the [chat panel](chat.md) - the same as `gq` on any azure-vicli screen. |
| `:AzureCli agents` | Every plan's agent - what each is doing ([Chat](chat.md#several-agents-at-once)) |
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

Two keys work on every screen: `?` lists that screen's keys, grouped by what
they're for, with `↑` before the ones that change something on Azure DevOps
(a vote, a comment, a link, a work item's state - a comment in batch mode
only once `gS` sends it); and `g.` (the
`palette` action) lists every action bound there by what it does, through
`vim.ui.select` - so with Telescope's, fzf-lua's or another picker standing
in for it, you can type "approve" or "unlink" instead of remembering the key.
The action you pick runs where you were, cursor and all. Actions that only
work on a visual selection aren't listed.

**The three home screens** - Pull requests, Work items and Agents - each
have a tab of their own: `P` goes to the pull requests, `W` to the work
items, `A` to the Agents screen, from any of them (or click the tab). The
standalone launcher opens all three at startup and keeps them the first
three tabs, in that order; a PR or a plan you open goes after them, and
closing it takes you back to the tab you opened it from.

Press `g` and pause, and a small float in the bottom-right corner lists the
screen's `g` keys and what each does (with the `↑` marks); the next key
closes it and does what it always did - `gg`, a count (`5g`, pause, `g`), a
register (`"ag`, pause, `p`), your own `g` mappings. Type the second key
straight away and there's no float at all. The pause is Neovim's own
`'timeoutlen'`. With [which-key](https://github.com/folke/which-key.nvim) or
mini.clue installed, this stays off and they show the same keys and
descriptions themselves; `ui.key_hints` ([Configuration](configuration.md))
turns it on or off regardless.

Every key in every table in these docs is a *default* - `setup()`'s `keys`
option remaps or unbinds any of them, per **surface** (`dashboard`, `list`,
`diff`, `overview`, `nav`, `workitems`, `workitem_view`, `chat`, `plan`, `agents` - roughly, one per
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
| `agents` | `A` |
| `browser` | `o` |
| `chat` | `gq` |
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
| `link_workitem` | `gl` |
| `open` | `<CR>` |
| `open_build` | `gb` |
| `open_workitem` | `gW` |
| `palette` | `g.` |
| `plan_agents` | `gP` |
| `quit` | `q` |
| `refresh` | `r` |
| `requeue_build` | `gr` |
| `toasts` | `gN` |
| `toggle_section` | `za` / `<Space>` |
| `unlink_workitem` | `gL` |
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
| `chat` | `gq` |
| `comment_file` | `C` |
| `commits` | `gc` |
| `complete` | `gm` |
| `config` | `gO` |
| `filters` | `gF` |
| `followup` | `gu` |
| `help` | `?` |
| `ignore_ws` | `gw` |
| `link_workitem` | `gl` |
| `next_file_with_comments` | `]C` |
| `next_unviewed` | `]m` |
| `open` | `<CR>` |
| `open_workitem` | `gW` |
| `palette` | `g.` |
| `plan_agents` | `gP` |
| `pr_comment` | `gC` |
| `prev_file_with_comments` | `[C` |
| `prev_unviewed` | `[m` |
| `quit` | `q` |
| `refresh` | `r` |
| `resize_less` | `<` |
| `resize_more` | `>` |
| `run_tests` | `gb` |
| `search` | `g/` |
| `since` | `gi` |
| `toggle_viewed` | `m` |
| `unlink_workitem` | `gL` |
| `vote` | `gv` |

#### diff

| Action | Default key(s) |
|---|---|
| `accept_hunk` | `gy` |
| `active_filter` | `gA` |
| `ask` | `ga` |
| `back` | `<BS>` |
| `batch_queue` | `gQ` |
| `batch_submit` | `gS` |
| `batch_toggle` | `gB` |
| `chat` | `gq` |
| `comment` | `c` |
| `comment_file` | `C` |
| `comment_range` | `c` |
| `commits` | `gc` |
| `complete` | `gm` |
| `config` | `gO` |
| `delete_thread` | `dd` |
| `expand_thread` | `<Tab>` |
| `filters` | `gF` |
| `find_references` | `gr` |
| `followup` | `gu` |
| `goto_definition` | `gd` |
| `goto_plan` | `gp` |
| `help` | `?` |
| `ignore_ws` | `gw` |
| `link_workitem` | `gl` |
| `next_comment` | `]C` |
| `next_hunk` | `]c` |
| `next_unviewed` | `]m` |
| `open_file` | `gf` |
| `open_workitem` | `gW` |
| `palette` | `g.` |
| `plan_agents` | `gP` |
| `prev_comment` | `[C` |
| `prev_hunk` | `[c` |
| `prev_unviewed` | `[m` |
| `quit` | `q` |
| `refresh` | `r` |
| `reject_hunk` | `gn` |
| `reply` | `R` |
| `resize_less` | `<` |
| `resize_more` | `>` |
| `run_tests` | `gb` |
| `search` | `g/` |
| `since` | `gi` |
| `status` | `s` |
| `toggle_viewed` | `m` |
| `unlink_workitem` | `gL` |
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
| `chat` | `gq` |
| `comment` | `c` |
| `complete` | `gm` |
| `config` | `gO` |
| `delete_comment` | `dd` |
| `edit_comment` | `e` |
| `filters` | `gF` |
| `followup` | `gu` |
| `help` | `?` |
| `ignore_ws` | `gw` |
| `link_workitem` | `gl` |
| `next_comment` | `]C` |
| `open_commit` | `<CR>` |
| `open_workitem` | `gW` |
| `palette` | `g.` |
| `plan_agents` | `gP` |
| `prev_comment` | `[C` |
| `quit` | `q` |
| `reply` | `R` |
| `resize_less` | `<` |
| `resize_more` | `>` |
| `search` | `g/` |
| `since` | `gi` |
| `status` | `s` |
| `unlink_workitem` | `gL` |
| `vote` | `gv` |

#### nav

| Action | Default key(s) |
|---|---|
| `back` | `<BS>` |
| `back_to_diff` | `q` |
| `chat` | `gq` |
| `config` | `gO` |
| `find_references` | `gr` |
| `goto_definition` | `gd` |
| `help` | `?` |
| `palette` | `g.` |
| `resize_less` | `<` |
| `resize_more` | `>` |
| `search` | `g/` |

#### workitems

| Action | Default key(s) |
|---|---|
| `agents` | `A` |
| `assign` | `ga` |
| `browser` | `o` |
| `chat` | `gq` |
| `click` | `<LeftMouse>` |
| `collapse_all` | `zM` |
| `config` | `gO` |
| `copy_link` | `gy` |
| `edit_title` | `ge` |
| `expand_all` | `zR` |
| `filter` | `/` |
| `goto_sprint_n` | `gt` |
| `help` | `?` |
| `link_pr` | `gl` |
| `move_sprint` | `gi` |
| `new` | `n` |
| `next_sprint` | `]` / `<Tab>` |
| `open` | `<CR>` |
| `open_pr` | `gR` |
| `palette` | `g.` |
| `plan_agents` | `gP` |
| `pr_list` | `P` |
| `prev_sprint` | `[` / `<S-Tab>` |
| `priority` | `gp` |
| `quit` | `q` |
| `refresh` | `r` |
| `state` | `gs` |
| `toggle_fold` | `za` / `<Space>` |
| `tree` | `T` |
| `unlink_pr` | `gL` |

#### workitem_view

| Action | Default key(s) |
|---|---|
| `assign` | `ga` |
| `back` | `<BS>` |
| `browser` | `o` |
| `chat` | `gq` |
| `comment` | `gc` |
| `copy_link` | `gy` |
| `edit_title` | `ge` |
| `help` | `?` |
| `link_pr` | `gl` |
| `move_sprint` | `gi` |
| `open` | `<CR>` |
| `open_pr` | `gR` |
| `palette` | `g.` |
| `priority` | `gp` |
| `quit` | `q` |
| `refresh` | `r` |
| `state` | `gs` |
| `unlink_pr` | `gL` |

#### chat

| Action | Default key(s) |
|---|---|
| `agent` | `gM` |
| `agents` | `A` |
| `audit` | `gH` |
| `back` | `<BS>` |
| `cancel` | `<C-c>` |
| `changes` | `gd` |
| `expand` | `<Tab>` |
| `focus_input` | `i` / `a` |
| `help` | `?` |
| `hide` | `q` |
| `history` | `gh` |
| `model` | `gm` |
| `new_chat` | `gn` |
| `next_message` | `<Down>` |
| `open_ref` | `<CR>` |
| `palette` | `g.` |
| `prev_message` | `<Up>` |
| `prompts` | `gp` |
| `resize_less` | `<` |
| `resize_more` | `>` |
| `send` | `<CR>` |
| `send_insert` | `<C-s>` |
| `toggle` | `gq` |
| `use_as_reply` | `gr` |
| `why` | `ga` |

#### plan

| Action | Default key(s) |
|---|---|
| `answer` | `gr` |
| `approve` | `gA` |
| `ask` | `ga` |
| `back` | `<BS>` |
| `chat` | `gq` |
| `delete_thread` | `dd` |
| `expand_thread` | `<Tab>` |
| `goto_code` | `gd` |
| `help` | `?` |
| `next_thread` | `]t` |
| `open` | `<CR>` |
| `open_file` | `gf` |
| `palette` | `g.` |
| `prev_thread` | `[t` |
| `quit` | `q` |
| `refresh` | `r` |
| `request` | `gc` |
| `resize_less` | `<` |
| `resize_more` | `>` |
| `revise` | `gR` |
| `run_log` | `gH` |
| `since` | `gi` |
| `view_thread` | `K` |

#### agents

| Action | Default key(s) |
|---|---|
| `approve` | `gA` |
| `cancel` | `<C-c>` |
| `changes` | `gd` |
| `chat` | `gq` |
| `help` | `?` |
| `open` | `<CR>` |
| `palette` | `g.` |
| `pr_list` | `P` |
| `quit` | `q` |
| `refresh` | `r` |
| `run_log` | `gH` |
| `workitems` | `W` |
<!-- END GENERATED KEYS TABLE -->
