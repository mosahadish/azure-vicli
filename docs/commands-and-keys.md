# Commands and keys

_Part of the [azure-vicli](../README.md) docs._

## Commands

Installed as a plugin, everything goes through one user command:

| Command | Effect |
|---|---|
| `:AzureCli` / `:AzureCli dashboard` | Open the [pull request dashboard](dashboard.md#pull-request-dashboard), in a new tab. |
| `:AzureCli review <id>` | Open the [reviewer](reviewer.md#reviewer) for pull request `<id>` directly, as an inner tab of Pull requests (see Inner tabs below) - looked up in the dashboard's own cached list, so open the dashboard at least once first this session. |
| `:AzureCli workitems` | Open the [work-items dashboard](work-items.md#work-items), in a new tab. |
| `:AzureCli issues` | Open the [issues dashboard](work-items.md#issues-github), in a new tab: a GitHub account's `issues:` project. With no such account it says so instead. |
| `:AzureCli chat` | Show or hide the [chat panel](chat.md) - `i` on any azure-vicli screen goes to its input box. |
| `:AzureCli agents` | Every plan's agent - what each is doing ([Chat](chat.md#several-agents-at-once)) |
| `:AzureCli doctor` | Check the setup and show the result in a float: Neovim version, python, git, the config file, its fields, a sign-in to every configured organization, and the work-items block - each line says what to fix. `:checkhealth azure-cli` runs the same checks through Neovim's health UI, and `./azure-cli --doctor` from a terminal. |
| `:AzureCli toasts` | Toggle [desktop notifications](dashboard.md#desktop-notifications) for the rest of this session - the same switch the dashboard's own `gN` key flips. |
| `:AzureCli status` | Show the [provider daemon's](development.md#architecture) status, plus the resolved python interpreter, config file path and where the options come from (`azure-cli.lua`, or your `setup()`; see [setup() options](configuration.md#setup-options)). |
| `:AzureCli log` | Open this session's error log (`lua/azure-cli/log.lua`) in a scratch split - every provider failure's full text, oldest first; `q` closes it. See [Troubleshooting](troubleshooting.md#troubleshooting). |
| `:AzureCli perf` | Summarise the perf log `AZVICLI_DEBUG=1` writes (`lua/azure-cli/perf.lua`): requests and wall ms per poll tick for the PR dashboard, a PR review and the work-items / issues board, the slowest requests, and requests per endpoint. `r` reads the log again, `q` closes it. See [Troubleshooting](troubleshooting.md#troubleshooting). |
| `:AzureCli web start` / `stop` / `status` / `rotate` | The [phone dashboard](chat.md#phone-dashboard): a read-only web page of the Agents screen, served from this machine. Off until `dashboard_web.enabled` is set; `start` (and `status`) show its URL, token included, in a float. The token is kept across restarts; `rotate` makes a new one (the old link gets 401 at once) and shows the new URL. `web` alone is `status`. |
| `:AzureCli options` | Every `setup()` option at its default, generated from the code so it can't drift. In the standalone launcher: creates `azure-cli.lua` next to `azure-cli.yml` with them (the file it loads), or opens it if it already exists. In your own Neovim, where that file isn't read: shows the same list in a scratch buffer to copy into your `setup()` call, writing nothing. `gO`'s "Options" does the same. |
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
three tabs, in that order; what you open from them stays inside them, as
inner tabs (below).

**Inner tabs.** A pull request you open stays inside the Pull requests tab,
as an inner tab: the tab line keeps one entry for Pull requests, and the
winbar shows a strip - `Pull requests │ !101 Fix auth │ [!102 Cache]` - the
list first, then each open review, the one you're on in brackets. `]r` /
`[r` go to the next / previous one, `g1`..`g9` to the n-th (`g1` the list),
and `q` in a review closes it and goes to the one before it (the list when
there's none). Opening a PR that's already open goes to its inner tab. Each
keeps its own cursor, file list and diff while you're in another. (Each is
still a Neovim tab underneath, so `gt` / `gT` visit them too; in your own
Neovim, a `'tabline'` of your own lists them - azure-vicli's
`ui.tabline()`, see [Configuration](configuration.md), doesn't.)
The same goes for work items (inside Work items), issues (inside Issues)
and plans (inside Agents): `<CR>` on an Agents row whose plan is already
open goes back to it as you left it - the older revision you were reading,
the Changes file you were on - and `dd` on that row closes its tab. One
opened from elsewhere (`gW` in a review, a plan the chat's agent wrote)
goes back there when you close it.

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
`diff`, `overview`, `nav`, `workitems`, `workitem_view`, `chat`, `plan`, `agents`, `tabs` - roughly, one per
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
| `agent_chat` | `ga` |
| `agents` | `A` |
| `browser` | `o` |
| `chat_input` | `i` |
| `chat_selection` | `<CR>` |
| `collapse_all` | `zM` |
| `complete` | `gm` |
| `config` | `gO` |
| `copy_link` | `gy` |
| `description` | `gd` |
| `expand_all` | `zR` |
| `filter` | `/` |
| `first_pr` | `gg` |
| `help` | `?` |
| `issues` | `I` |
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
| `chat_input` | `i` |
| `chat_selection` | `<CR>` |
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
| `chat_input` | `i` |
| `chat_selection` | `<CR>` |
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
| `next_note` | `]a` |
| `next_unviewed` | `]m` |
| `open_file` | `gf` |
| `open_workitem` | `gW` |
| `palette` | `g.` |
| `plan_agents` | `gP` |
| `prev_comment` | `[C` |
| `prev_hunk` | `[c` |
| `prev_note` | `[a` |
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
| `toggle_fold` | `za` / `<Space>` |
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
| `chat_input` | `i` |
| `chat_selection` | `<CR>` |
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
| `chat_input` | `i` |
| `chat_selection` | `<CR>` |
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
| `chat_input` | `i` |
| `chat_selection` | `<CR>` |
| `click` | `<LeftMouse>` |
| `collapse_all` | `zM` |
| `config` | `gO` |
| `copy_link` | `gy` |
| `edit_title` | `ge` |
| `expand_all` | `zR` |
| `filter` | `/` |
| `first_row` | `gg` |
| `goto_sprint_n` | `gt` |
| `help` | `?` |
| `issues` | `I` |
| `last_row` | `G` |
| `link_pr` | `gl` |
| `move_sprint` | `gi` |
| `new` | `n` |
| `next_sprint` | `<Tab>` |
| `open` | `<CR>` |
| `open_pr` | `gR` |
| `palette` | `g.` |
| `plan_agents` | `gP` |
| `pr_list` | `P` |
| `prev_sprint` | `<S-Tab>` |
| `priority` | `gp` |
| `quit` | `q` |
| `refresh` | `r` |
| `set_parent` | `gU` |
| `state` | `gs` |
| `toggle_fold` | `za` / `<Space>` |
| `tree` | `T` |
| `unlink_pr` | `gL` |
| `workitems` | `W` |

#### workitem_view

| Action | Default key(s) |
|---|---|
| `assign` | `ga` |
| `back` | `<BS>` |
| `browser` | `o` |
| `chat_input` | `i` |
| `chat_selection` | `<CR>` |
| `comment` | `gc` |
| `copy_link` | `gy` |
| `description` | `gE` |
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
| `set_parent` | `gU` |
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
| `newline` | `<S-CR>` / `<C-j>` |
| `next_message` | `<Down>` |
| `open_ref` | `<CR>` |
| `palette` | `g.` |
| `prev_message` | `<Up>` |
| `prompts` | `gp` |
| `queue_drop` | `dd` |
| `queue_edit` | `cc` |
| `resize_less` | `<` |
| `resize_more` | `>` |
| `send` | `<CR>` |
| `send_insert` | `<CR>` / `<C-s>` |
| `use_as_reply` | `gr` |
| `why` | `ga` |

#### plan

| Action | Default key(s) |
|---|---|
| `answer` | `gr` |
| `approve` | `gA` |
| `ask` | `ga` |
| `back` | `<BS>` |
| `chat_input` | `i` |
| `chat_selection` | `<CR>` |
| `delete_thread` | `dd` |
| `discard` | `gD` |
| `edit_request` | `cc` |
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
| `revisions` | `gh` |
| `run_log` | `gH` |
| `since` | `gi` |
| `view_thread` | `K` |

#### agents

| Action | Default key(s) |
|---|---|
| `approve` | `gA` |
| `cancel` | `<C-c>` |
| `changes` | `gd` |
| `chat_input` | `i` |
| `discard` | `dd` |
| `first_row` | `gg` |
| `help` | `?` |
| `issues` | `I` |
| `last_row` | `G` |
| `open` | `<CR>` |
| `palette` | `g.` |
| `pr_list` | `P` |
| `quit` | `q` |
| `refresh` | `r` |
| `run_log` | `gH` |
| `show_finished` | `gF` |
| `workitems` | `W` |

#### tabs

| Action | Default key(s) |
|---|---|
| `next` | `]r` |
| `pick` | `g1` / `g2` / `g3` / `g4` / `g5` / `g6` / `g7` / `g8` / `g9` |
| `prev` | `[r` |
<!-- END GENERATED KEYS TABLE -->
