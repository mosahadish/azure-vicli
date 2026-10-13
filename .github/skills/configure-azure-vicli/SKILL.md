---
name: configure-azure-vicli
description: Configure azure-vicli for the user - its config files and where they live, accounts and PATs, keys, the chat agent, permissions and skills. Use when asked to set up, configure or change azure-vicli's settings.
---

# Configuring azure-vicli

You are changing the user's azure-vicli settings - before it's ever been
launched, or later. Everything here works from a terminal in this
repository (the azure-vicli clone); nothing needs azure-vicli running.
Edit the user's files in place, keep everything already there, check field
names against the docs linked below instead of guessing, run the checks at
the end, and finish by telling the user which files you changed.

Never print, copy or commit a PAT: ask the user to paste it into the file
themselves. Don't put settings in this repository - the user's config lives
outside it.

## First: standalone or plugin?

azure-vicli runs two ways, and where settings go depends on which:

- **Standalone**: its own Neovim session, started with `./azure-cli`
  (`azure-cli.cmd` on Windows) from this folder. Settings live in
  `azure-cli.yml` and `azure-cli.lua` (below). Good for someone who
  doesn't use Neovim otherwise - nothing to add to a Neovim config.
- **Plugin**: `:AzureCli` inside the user's own Neovim, installed through
  their plugin manager (lazy.nvim, packer). Accounts can stay in
  `azure-cli.yml`; options go in their `setup({...})` call.

Look before asking:

- Their Neovim config (`%LOCALAPPDATA%\nvim` on Windows, `~/.config/nvim`
  elsewhere) mentions `azure-vicli` or `require("azure-cli")` -> plugin.
- An `azure-cli.lua` next to `azure-cli.yml` -> standalone.

If that doesn't settle it - or nothing is set up yet - **ask the user which
they want**, with the one-line description of each above, before writing
anything. Suggest standalone when they don't have a Neovim config of their
own, plugin when they do.

For a new plugin install, adding the plugin to their plugin manager is an
edit to their Neovim config: show them the snippet from the README's
[As a plugin](../../../README.md#as-a-plugin) and ask before adding it. For
standalone, `bash install.sh` checks the dependencies (Neovim, git-bash,
python); run it only if the user agrees.

Also ask whether they keep their settings in a dotfiles repo; if so, see
the README's [Keeping your settings in git](../../../README.md#keeping-your-settings-in-git)
and put them there.

## Where the config lives

There are two files, side by side in one folder:

| File | Holds | Windows | Linux / macOS |
|---|---|---|---|
| `azure-cli.yml` | accounts: org URL, project, PAT, clones folder, work items | `%APPDATA%\azure-cli.yml` | `$XDG_CONFIG_HOME/azure-cli.yml` (default `~/.config/azure-cli.yml`) |
| `azure-cli.lua` | everything else (the `setup()` options): keys, timing, ui, chat | `%APPDATA%\azure-cli.lua` | `~/.config/azure-cli.lua` |

Per install type:

- **Standalone launcher** (`azure-cli` / `azure-cli.cmd`): both files above.
  `azure-cli.lua` is `return { ... }` - create it if it's missing.
- **Plugin in the user's own Neovim**: look for
  `require("azure-cli").setup({...})` (or lazy.nvim `opts = {...}` for
  `mosahadish/azure-vicli`) in their Neovim config (`:echo stdpath("config")`;
  `%LOCALAPPDATA%\nvim` on Windows, `~/.config/nvim` elsewhere). Options go
  in that call, not in `azure-cli.lua`. Accounts can go there too
  (`accounts = { ... }`, same field names), which then wins over
  `azure-cli.yml`.
- **Another path**: `setup({ config = "..." })` or the `AZVICLI_CONFIG`
  environment variable moves `azure-cli.yml` (and `azure-cli.lua` with it).

Once it runs, `:AzureCli status` prints both files in use, and `gO`
opens either one.

Starting from nothing (run these here, in the repository):

- `python azure-cli.py --init-config` (`python3` outside Windows) writes
  the `azure-cli.yml` template with `TODO`s, if there isn't one, and prints
  its path. Fill that in rather than writing one from scratch.
- `nvim -u NONE --headless --cmd "set rtp+=." -c "lua print(require('azure-cli.config').write_options())" -c q`
  writes `azure-cli.lua` next to it with every option at its default, and
  prints its path (`true` when it was just created). Or write just the
  options you need: `return { chat = { ... } }`.

Other places azure-vicli keeps state (don't hand-edit unless asked):
Neovim's `stdpath("data")/azure-cli-chat/` (conversations, plans,
`allowed_skills.json`, the audit log) and `stdpath("cache")/azure-cli/`.

## Accounts (`azure-cli.yml`)

```yaml
accounts:
  - project_name: MyProject
    org_url: https://dev.azure.com/my-org        # or an on-prem collection URL
    pat_file: ~/.config/azure-cli/pat            # or pat: <token>; pat_file keeps the secret out
    clones_dir: C:\Users\me\source\repos
    work_items:                                  # optional: the work-item screens
      team: My Team
```

The PAT needs Code (read & write) and Work Items (read & write). Prefer
`pat_file`, kept outside any git checkout. Every field:
[docs/configuration.md](../../../docs/configuration.md#configuration).

## Options (`azure-cli.lua` or `setup()`)

```lua
return {
  keys = { diff = { next_hunk = "]h" }, dashboard = { vote = false } },  -- false unbinds
  timing = { poll_seconds = 120 },
  ui = { border = "rounded", confirm = "popup" },
  chat = { ... },  -- below
}
```

Every option: [docs/configuration.md](../../../docs/configuration.md#setup-options);
every key: [docs/commands-and-keys.md](../../../docs/commands-and-keys.md#keys).
An unknown field or a wrong type is an error at start-up naming it.

## The chat agent (`chat`)

GitHub Copilot:

```lua
chat = {
  agent = {
    label = "Copilot", acp = true,
    models = { "claude-sonnet-5", "gpt-5.5" },  -- the names `copilot --help` lists
    cmd = { "copilot", "--acp", "--add-dir", "{fix_root}", "--allow-tool", "azure-vicli" },
  },
}
```

Claude Code and every `chat.agent` field: [docs/chat.md](../../../docs/chat.md#setting-it-up).
Check model names and flags against the installed CLI (`copilot --help`,
`claude --help`). The full step-by-step for an agent setting itself up is
"Let the agent set itself up" in that file.

Other `chat` fields: `position`, `size`, `max_agents`, `test_cmd`,
`plan_first`, `on_new_comments`, `watch_seconds`, `prompts`, ... -
[docs/chat.md](../../../docs/chat.md#fields).

### Permissions (`chat.permissions`)

Each key is a tool name or a group; each value `"allow"`, `"ask"` or
`"deny"`. A tool's own name wins over its group, a group over `"all"`.

| Key | Covers |
|---|---|
| `"azure-vicli-tools"` | azure-vicli's own tools (posting, voting, pushing, opening PRs) |
| `"agent-commands"` | the agent's own prompts other than file edits (shell commands, ...) |
| `"agent-edits"` | the agent's file edits |
| `"all"` | anything its group doesn't set |
| a tool name (`vote`, `commit_and_push_fix`, ...) | that tool |

```lua
chat = { permissions = { all = "allow", vote = "ask" } }  -- nothing asks but votes
```

Only set `"allow"` on `"all"` or a group when the user asks for it -
it removes their chance to stop a push or a vote. Details:
[docs/chat.md](../../../docs/chat.md#what-the-agent-can-do).

### Skills

- `chat.skill_dirs`: the folders searched for `*/SKILL.md`, in the
  repository the agent runs in and in the home folder. Default
  `{ ".github/skills", ".claude/skills", ".agents/skills", ".copilot/skills" }`;
  `~/...` or an absolute path is used as it is.
Which skills are allowed (their commands and edits don't ask) isn't
config: `/skills` in the chat opens a popup of what's found, where
`<Space>` allows one or makes it ask again. An old `chat.allowed_skills`
makes setup fail - take it out.

## Check it

Run these here, in the repository, and fix what they report:

- `python azure-cli.py --doctor`: the yml parses, its fields are filled
  in, and sign-in works for every organization. A FAIL line says what to
  fix.
- The options file (standalone launcher):
  `nvim -u NONE --headless --cmd "set rtp+=." -c "lua local ok, e = pcall(function() require('azure-cli').setup(dofile(require('azure-cli.config').options_path())) end) print(ok and 'azure-cli.lua: ok' or e)" -c q`
  prints `azure-cli.lua: ok`, or the field that's wrong. (A plugin user's
  `setup()` is checked when their Neovim starts.)

Then tell the user to start azure-vicli (`./azure-cli`, `azure-cli.cmd`,
or `:AzureCli`), or restart it if it was running. For the chat: `gq` on
the PR dashboard and ask "what am I looking at?" - the answer should name
the PR under the cursor.

Problems: [docs/troubleshooting.md](../../../docs/troubleshooting.md).
